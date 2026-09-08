import AppKit
import DockVacCore

/// Live view of a cleanup run: one row per operation with its outcome, and a Stop button.
final class CleanupProgressSheetController: NSWindowController, NSTableViewDataSource,
  NSTableViewDelegate
{
  private var state: CleanupRunState
  private let onStop: () -> Void
  private let onDone: () -> Void
  private let headline = Theme.label("", size: 17, weight: .bold)
  private let summary = Theme.wrappingLabel("", size: 12, color: .secondaryLabelColor)
  private let progress = NSProgressIndicator()
  private let table = NSTableView()
  private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
  private let doneButton = NSButton(title: "Done", target: nil, action: nil)
  private var stopRequested = false

  init(state: CleanupRunState, onStop: @escaping () -> Void, onDone: @escaping () -> Void) {
    self.state = state
    self.onStop = onStop
    self.onDone = onDone
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.contentView = makeContent()
    apply(state)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func makeContent() -> NSView {
    summary.isSelectable = false
    summary.preferredMaxLayoutWidth = 660

    progress.style = .bar
    progress.isIndeterminate = false
    progress.minValue = 0
    progress.maxValue = 1
    progress.translatesAutoresizingMaskIntoConstraints = false

    table.headerView = nil
    table.style = .inset
    table.intercellSpacing = NSSize(width: 0, height: 2)
    table.selectionHighlightStyle = .none
    table.usesAlternatingRowBackgroundColors = true
    table.dataSource = self
    table.delegate = self
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("operation"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .vertical)
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

    stopButton.target = self
    stopButton.action = #selector(stopPressed)
    stopButton.bezelStyle = .rounded
    doneButton.target = self
    doneButton.action = #selector(donePressed)
    doneButton.bezelStyle = .rounded
    doneButton.keyEquivalent = "\r"
    doneButton.isHidden = true
    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
    let buttons = NSStackView(views: [spacer, stopButton, doneButton])
    buttons.orientation = .horizontal
    buttons.spacing = 10

    let stack = NSStackView(views: [headline, summary, progress, scroll, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 520))
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: content.topAnchor),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      progress.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      summary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
    ])
    return content
  }

  func apply(_ newState: CleanupRunState) {
    state = newState
    progress.doubleValue = state.fractionCompleted
    let total = state.plan.operations.count
    if state.isFinished {
      headline.stringValue =
        state.failedCount > 0 ? "Cleanup finished with problems" : "Cleanup finished"
      summary.stringValue = state.summary + " DockVac will rescan Docker when you close this."
      stopButton.isHidden = true
      doneButton.isHidden = false
    } else if stopRequested {
      headline.stringValue = "Stopping…"
      summary.stringValue =
        "Waiting for the current operation to finish. Remaining operations are skipped."
      stopButton.isEnabled = false
    } else {
      headline.stringValue =
        "Removing \(ByteFormat.count(total, singular: "item", plural: "items"))…"
      summary.stringValue =
        "\(state.completedCount) of \(total) done. Stop finishes the current operation and skips the rest."
    }
    table.reloadData()
    if let current = state.currentIndex {
      table.scrollRowToVisible(current)
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    state.plan.operations.count
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    46
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let identifier = NSUserInterfaceItemIdentifier("ProgressCell")
    let cell =
      (tableView.makeView(withIdentifier: identifier, owner: self) as? OperationCellView)
      ?? OperationCellView()
    cell.identifier = identifier
    let operation = state.plan.operations[row]
    cell.configure(
      step: row + 1,
      kind: operation.id.kind,
      title: "\(operation.title): \(operation.target)",
      detail: operation.cliEquivalent,
      warning: "",
      status: state.statuses[row]
    )
    return cell
  }

  @objc private func stopPressed() {
    stopRequested = true
    apply(state)
    onStop()
  }

  @objc private func donePressed() {
    if let window, let parent = window.sheetParent {
      parent.endSheet(window)
    }
    onDone()
  }
}
