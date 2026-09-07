import AppKit
import DockVacCore
import DockVacDocker

/// Application state and every user action. Views render what it hands them and call
/// back through `ReportActions`; Docker work goes through `DockerService`.
@MainActor
final class AppController: NSObject, ReportActions, DockerServiceDelegate, NSMenuItemValidation {
  let windowController = MainWindowController()
  private let service = DockerService()

  private(set) var phase: AppPhase = .idle
  private(set) var report: UsageReport = .empty
  private(set) var connection: DockerConnection?
  private(set) var focus: DockerResourceKind?
  private(set) var filter: ReportFilter = .everything
  private(set) var selectedItem: DockerResourceID?
  private(set) var selectedCategory: DockerResourceKind?
  private(set) var basket: Set<DockerResourceID> = []
  private var scanStartedAt: Date?
  private var scanTimer: Timer?
  private var confirmationSheet: ConfirmationSheetController?
  private var progressSheet: CleanupProgressSheetController?
  private var lastRunState: CleanupRunState?
  private var smokeScriptStarted = false

  var isCleaning: Bool { service.isCleaning }

  override init() {
    super.init()
    service.delegate = self
    windowController.controller = self
    windowController.reportView.actions = self
    windowController.scanningView.onCancel = { [weak self] in self?.cancelScan() }
    windowController.messageView.onAction = { [weak self] in self?.rescan(nil) }
  }

  func start() {
    windowController.showWindow(nil)
    rescan(nil)
  }

  // MARK: - Derived state

  var displayedReport: UsageReport {
    switch filter {
    case .everything:
      return report
    case .reclaimable:
      return report.filtered {
        $0.removability.isRemovableNow || !$0.removability.prerequisites.isEmpty
      }
    }
  }

  var plan: CleanupPlan {
    CleanupPlan.make(selecting: basket, from: report)
  }

  private var viewState: ReportViewState {
    ReportViewState(
      report: displayedReport,
      fullReport: report,
      focus: focus,
      selectedItem: selectedItem,
      selectedCategory: selectedCategory,
      basket: basket,
      plan: plan,
      filter: filter,
      connection: connection
    )
  }

  // MARK: - Scanning

  @objc func rescan(_ sender: Any?) {
    guard !service.isCleaning else { return }
    phase = .connecting
    scanStartedAt = Date()
    startScanTimer()
    service.scan()
    render()
  }

  func cancelScan() {
    service.cancelScan()
    stopScanTimer()
    phase = report.itemCount > 0 && report.capturedAt.timeIntervalSince1970 > 0 ? .report : .idle
    render()
  }

  private func startScanTimer() {
    stopScanTimer()
    scanTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.phase.isScanning else { return }
        self.windowController.scanningView.apply(
          phase: self.phase, connection: self.connection, startedAt: self.scanStartedAt)
      }
    }
  }

  private func stopScanTimer() {
    scanTimer?.invalidate()
    scanTimer = nil
  }

  func serviceDidConnect(_ connection: DockerConnection) {
    self.connection = connection
    phase = .scanning(nil)
    render()
  }

  func serviceDidReportScanProgress(_ progress: ScanProgress) {
    guard phase.isScanning else { return }
    phase = .scanning(progress)
    render()
  }

  func serviceDidFinishScan(_ result: Result<DockerDiskUsage, Error>) {
    stopScanTimer()
    switch result {
    case .success(let usage):
      report = UsageAnalyzer.analyze(usage)
      basket = basket.filter { report.item(for: $0) != nil }
      if let selectedItem, report.item(for: selectedItem) == nil {
        self.selectedItem = nil
      }
      if let focus, report.category(for: focus) == nil {
        self.focus = nil
      }
      phase = .report
      runSmokeScriptIfRequested()
    case .failure(let error):
      if error is CancellationError {
        phase = report.capturedAt.timeIntervalSince1970 > 0 ? .report : .idle
      } else {
        let title: String
        if let engineError = error as? DockerEngineError, case .daemonNotFound = engineError {
          title = "Docker isn't running"
        } else {
          title = "Couldn't read Docker"
        }
        phase = .failed(title: title, message: dockerErrorMessage(error))
      }
    }
    render()
  }

  // MARK: - ReportActions

  func select(item id: DockerResourceID?) {
    selectedItem = id
    if id != nil {
      selectedCategory = id?.kind
    }
    render()
  }

  func select(category kind: DockerResourceKind?) {
    selectedCategory = kind
    selectedItem = nil
    render()
  }

  func focus(on kind: DockerResourceKind?) {
    guard phase == .report else { return }
    focus = kind
    if let kind {
      selectedCategory = kind
      if let selectedItem, selectedItem.kind != kind {
        self.selectedItem = nil
      }
    }
    render()
  }

  func toggleBasket(_ id: DockerResourceID) {
    if basket.contains(id) {
      removeFromBasket([id])
    } else {
      addToBasket([id])
    }
  }

  func addToBasket(_ ids: [DockerResourceID]) {
    let additions = report.selectionClosure(ids).filter {
      report.item(for: $0)?.removability.isBlocked == false
    }
    basket.formUnion(additions)
    render()
  }

  func removeFromBasket(_ ids: [DockerResourceID]) {
    basket.subtract(ids)
    // Items that needed one of the removed prerequisites cannot stay either.
    for id in basket {
      if let item = report.item(for: id),
        item.removability.prerequisites.contains(where: { ids.contains($0) })
      {
        basket.remove(id)
      }
    }
    render()
  }

  func clearBasket() {
    basket.removeAll()
    render()
  }

  func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  func setFilter(_ newFilter: ReportFilter) {
    filter = newFilter
    if let selectedItem, displayedReport.item(for: selectedItem) == nil {
      self.selectedItem = nil
    }
    render()
  }

  // MARK: - Cleanup

  func reviewAndRemove() {
    guard phase == .report, !service.isCleaning, confirmationSheet == nil,
      let window = windowController.window
    else { return }
    let plan = self.plan
    guard !plan.isEmpty || !plan.exclusions.isEmpty else { return }
    let sheet = ConfirmationSheetController(plan: plan) { [weak self] confirmed in
      guard let self else { return }
      self.confirmationSheet = nil
      if confirmed, !plan.isEmpty {
        self.runCleanup(plan)
      }
    }
    confirmationSheet = sheet
    if let sheetWindow = sheet.window {
      window.beginSheet(sheetWindow) { _ in }
    }
  }

  private func runCleanup(_ plan: CleanupPlan) {
    guard let window = windowController.window else { return }
    let initial = CleanupRunState(plan: plan)
    lastRunState = initial
    let sheet = CleanupProgressSheetController(
      state: initial,
      onStop: { [weak self] in self?.service.stopCleanup() },
      onDone: { [weak self] in
        guard let self else { return }
        self.progressSheet = nil
        if let finished = self.lastRunState {
          for (operation, status) in zip(finished.plan.operations, finished.statuses) {
            if case .succeeded = status {
              self.basket.remove(operation.id)
            }
          }
        }
        self.rescan(nil)
      })
    progressSheet = sheet
    if let sheetWindow = sheet.window {
      window.beginSheet(sheetWindow) { _ in }
    }
    service.runCleanup(plan)
    windowController.updateChrome(connection: connection, filter: filter, phase: phase)
  }

  func serviceDidReportCleanupProgress(_ state: CleanupRunState) {
    lastRunState = state
    progressSheet?.apply(state)
  }

  func serviceDidFinishCleanup(_ state: CleanupRunState) {
    lastRunState = state
    progressSheet?.apply(state)
    windowController.updateChrome(connection: connection, filter: filter, phase: phase)
  }

  // MARK: - Menu actions

  @objc func goBack(_ sender: Any?) {
    focus(on: nil)
  }

  @objc func showEverything(_ sender: Any?) {
    setFilter(.everything)
  }

  @objc func showReclaimable(_ sender: Any?) {
    setFilter(.reclaimable)
  }

  @objc func toggleSelectedInBasket(_ sender: Any?) {
    guard let selectedItem else { return }
    toggleBasket(selectedItem)
  }

  @objc func addSafeItems(_ sender: Any?) {
    addToBasket(report.safeSuggestionIDs)
  }

  @objc func clearBasketAction(_ sender: Any?) {
    clearBasket()
  }

  @objc func reviewAndRemoveAction(_ sender: Any?) {
    reviewAndRemove()
  }

  @objc func openHelp(_ sender: Any?) {
    if let url = URL(string: "https://github.com/L-K-M/dockvac") {
      NSWorkspace.shared.open(url)
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let action = menuItem.action else { return false }
    let inReport = phase == .report && !service.isCleaning
    switch action {
    case #selector(rescan(_:)):
      return !phase.isScanning && !service.isCleaning
    case #selector(goBack(_:)):
      return inReport && focus != nil
    case #selector(showEverything(_:)):
      menuItem.state = filter == .everything ? .on : .off
      return inReport
    case #selector(showReclaimable(_:)):
      menuItem.state = filter == .reclaimable ? .on : .off
      return inReport
    case #selector(toggleSelectedInBasket(_:)):
      guard inReport, let selectedItem, let item = report.item(for: selectedItem) else {
        menuItem.title = "Add Selected Item to Cleanup"
        return false
      }
      menuItem.title =
        basket.contains(selectedItem)
        ? "Remove Selected Item from Cleanup" : "Add Selected Item to Cleanup"
      return !item.removability.isBlocked
    case #selector(addSafeItems(_:)):
      return inReport && !report.safeSuggestionIDs.isEmpty
    case #selector(clearBasketAction(_:)):
      return inReport && !basket.isEmpty
    case #selector(reviewAndRemoveAction(_:)):
      return inReport && !basket.isEmpty
    default:
      return true
    }
  }

  // MARK: - Smoke script

  /// `DOCKVAC_SMOKE_SCRIPT=focus-images,select-first,add-safe,review` walks through the UI
  /// two seconds per step after the first scan, so CI can screenshot each screen. Steps only
  /// change what is shown; nothing is ever confirmed or removed.
  private func runSmokeScriptIfRequested() {
    guard !smokeScriptStarted,
      let script = ProcessInfo.processInfo.environment["DOCKVAC_SMOKE_SCRIPT"], !script.isEmpty
    else { return }
    smokeScriptStarted = true
    let steps = script.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    for (index, step) in steps.enumerated() {
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(index + 1) * 2_000_000_000)
        self?.performSmokeStep(step)
      }
    }
  }

  private func performSmokeStep(_ step: String) {
    switch step {
    case "focus-images": focus(on: .images)
    case "focus-containers": focus(on: .containers)
    case "focus-volumes": focus(on: .localVolumes)
    case "focus-build-cache": focus(on: .buildCache)
    case "back": focus(on: nil)
    case "select-first":
      let items =
        focus.flatMap { displayedReport.category(for: $0)?.items } ?? displayedReport.items
      select(item: items.first?.id)
    case "add-safe": addSafeItems(nil)
    case "filter-reclaimable": setFilter(.reclaimable)
    case "review": reviewAndRemove()
    default: break
    }
  }

  // MARK: - Rendering

  private func render() {
    switch phase {
    case .idle:
      windowController.messageView.apply(
        icon: NSApp.applicationIconImage,
        headline: "Ready to scan Docker",
        message:
          "DockVac shows what Docker keeps on disk and lets you remove exactly the pieces you choose. Nothing is deleted without your confirmation.",
        details: "",
        action: "Scan Docker")
      windowController.show(windowController.messageView)
    case .connecting, .scanning:
      windowController.scanningView.apply(
        phase: phase, connection: connection, startedAt: scanStartedAt)
      windowController.show(windowController.scanningView)
    case .report:
      windowController.reportView.apply(viewState)
      windowController.show(windowController.reportView)
    case .failed(let title, let message):
      let (body, details) = splitErrorMessage(message)
      windowController.messageView.apply(
        icon: Theme.symbol(
          "exclamationmark.triangle", pointSize: 72, weight: .light, color: .systemOrange),
        headline: title,
        message: body.isEmpty
          ? "Start Docker Desktop (or OrbStack, Colima, Rancher Desktop) and try again." : body,
        details: details,
        action: "Try Again")
      windowController.show(windowController.messageView)
    }
    windowController.updateChrome(connection: connection, filter: filter, phase: phase)
  }

  /// The first line is the headline explanation; the rest are the technical details.
  private func splitErrorMessage(_ message: String) -> (String, String) {
    var lines = message.components(separatedBy: "\n")
    guard !lines.isEmpty else { return ("", "") }
    let first = lines.removeFirst()
    return (first, lines.joined(separator: "\n"))
  }
}
