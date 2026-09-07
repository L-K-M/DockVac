import AppKit
import DockVacCore
import DockVacDocker

/// Owns the window, the toolbar, and swaps the content view for the current phase.
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation {
  weak var controller: AppController?

  let scanningView = ScanningView(frame: .zero)
  let reportView = ReportView(frame: .zero)
  let messageView = MessageView(frame: .zero)
  private var currentContent: NSView?
  private let filterControl = NSSegmentedControl(
    labels: ReportFilter.allCases.map { $0.title }, trackingMode: .selectOne, target: nil,
    action: nil)

  private enum ItemID {
    static let back = NSToolbarItem.Identifier("back")
    static let rescan = NSToolbarItem.Identifier("rescan")
    static let filter = NSToolbarItem.Identifier("filter")
    static let review = NSToolbarItem.Identifier("review")
  }

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "DockVac"
    window.minSize = NSSize(width: 900, height: 600)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.toolbarStyle = .unified
    window.setFrameAutosaveName("DockVacMainWindow")
    window.center()
    super.init(window: window)

    let toolbar = NSToolbar(identifier: "DockVacToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar

    filterControl.target = self
    filterControl.action = #selector(filterChanged)
    filterControl.selectedSegment = 0
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // MARK: - Content

  func show(_ view: NSView) {
    guard let contentView = window?.contentView else { return }
    if currentContent === view { return }
    currentContent?.removeFromSuperview()
    view.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(view)
    NSLayoutConstraint.activate([
      view.topAnchor.constraint(equalTo: contentView.topAnchor),
      view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
    currentContent = view
    if view === reportView {
      window?.makeFirstResponder(reportView.treemap)
    }
  }

  func updateChrome(connection: DockerConnection?, filter: ReportFilter, phase: AppPhase) {
    window?.subtitle = connection?.summary ?? ""
    filterControl.selectedSegment = filter.rawValue
    filterControl.isEnabled = phase == .report
    window?.toolbar?.validateVisibleItems()
  }

  // MARK: - Toolbar

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [ItemID.back, ItemID.rescan, .flexibleSpace, ItemID.filter, .flexibleSpace, ItemID.review]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    switch itemIdentifier {
    case ItemID.back:
      item.label = "Back"
      item.paletteLabel = "Back to Overview"
      item.toolTip = "Back to the overview (⌘↑)"
      item.image = Theme.symbol("chevron.left", pointSize: 14, weight: .semibold)
      item.target = self
      item.action = #selector(backPressed)
      item.isBordered = true
      item.isNavigational = true
    case ItemID.rescan:
      item.label = "Rescan"
      item.paletteLabel = "Rescan"
      item.toolTip = "Scan Docker again (⌘R)"
      item.image = Theme.symbol("arrow.clockwise", pointSize: 14, weight: .medium)
      item.target = self
      item.action = #selector(rescanPressed)
      item.isBordered = true
    case ItemID.filter:
      item.label = "Show"
      item.paletteLabel = "Show"
      item.view = filterControl
    case ItemID.review:
      item.label = "Review & Remove"
      item.paletteLabel = "Review & Remove"
      item.toolTip = "Review the selected items and remove them (⌘↩)"
      item.image = Theme.symbol("trash", pointSize: 14, weight: .medium)
      item.target = self
      item.action = #selector(reviewPressed)
      item.isBordered = true
    default:
      return nil
    }
    return item
  }

  func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
    guard let controller else { return false }
    switch item.itemIdentifier {
    case ItemID.back:
      return controller.phase == .report && controller.focus != nil
    case ItemID.rescan:
      return !controller.phase.isScanning && !controller.isCleaning
    case ItemID.review:
      return controller.phase == .report && !controller.basket.isEmpty && !controller.isCleaning
    default:
      return true
    }
  }

  @objc private func backPressed() {
    controller?.focus(on: nil)
  }

  @objc private func rescanPressed() {
    controller?.rescan(nil)
  }

  @objc private func reviewPressed() {
    controller?.reviewAndRemove()
  }

  @objc private func filterChanged() {
    guard let filter = ReportFilter(rawValue: filterControl.selectedSegment) else { return }
    controller?.setFilter(filter)
  }
}
