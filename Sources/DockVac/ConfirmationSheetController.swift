import AppKit
import DockVacCore

/// Shows exactly what will be removed, in order, and demands explicit confirmation.
final class ConfirmationSheetController: NSWindowController, NSTableViewDataSource,
  NSTableViewDelegate
{
  private let plan: CleanupPlan
  private let onDecision: (Bool) -> Void
  private let table = NSTableView()
  private let commandsContainer = NSStackView()
  private let commandsToggle = NSButton(title: "Show Equivalent Commands", target: nil, action: nil)
  private let confirmCheckbox = NSButton(
    checkboxWithTitle: "I understand these items will be deleted permanently", target: nil,
    action: nil)
  private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
  private var decided = false

  init(plan: CleanupPlan, onDecision: @escaping (Bool) -> Void) {
    self.plan = plan
    self.onDecision = onDecision
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.contentView = makeContent()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // MARK: - Building

  private func makeContent() -> NSView {
    let count = plan.operations.count
    let headline = Theme.label(
      count == 1 ? "Remove 1 item from Docker?" : "Remove \(count) items from Docker?", size: 17,
      weight: .bold)
    let intro = Theme.wrappingLabel(
      "DockVac will run the operations below in this order. Nothing is forced, so Docker still refuses anything that is in use. Removed data cannot be recovered.",
      size: 12, color: .secondaryLabelColor)
    intro.isSelectable = false
    intro.preferredMaxLayoutWidth = 660

    table.headerView = nil
    table.rowHeight = 54
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
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

    let totals = Theme.label(
      "Frees about \(ByteFormat.string(plan.estimatedReclaimableBytes)) (estimate). \(plan.summary).",
      size: 12, weight: .semibold)

    var sections: [NSView] = [headline, intro, scroll, totals]

    if !plan.exclusions.isEmpty {
      let text = plan.exclusions.map { "• \($0.title): \($0.reason)" }.joined(separator: "\n")
      let excluded = Theme.wrappingLabel(
        "Not included:\n\(text)", size: 11, color: .secondaryLabelColor)
      excluded.isSelectable = false
      excluded.preferredMaxLayoutWidth = 660
      sections.append(excluded)
    }

    commandsToggle.target = self
    commandsToggle.action = #selector(toggleCommands)
    commandsToggle.bezelStyle = .inline
    commandsToggle.setButtonType(.momentaryPushIn)
    let copyCommands = NSButton(
      title: "Copy Commands", target: self, action: #selector(copyCommands))
    copyCommands.bezelStyle = .inline
    let commandButtons = NSStackView(views: [commandsToggle, copyCommands])
    commandButtons.orientation = .horizontal
    commandButtons.spacing = 8
    sections.append(commandButtons)

    let commandsScroll = NSTextView.scrollableTextView()
    if let textView = commandsScroll.documentView as? NSTextView {
      textView.isEditable = false
      textView.isRichText = false
      textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      textView.string = plan.cliScript
      textView.textContainerInset = NSSize(width: 6, height: 6)
    }
    commandsScroll.borderType = .bezelBorder
    commandsScroll.translatesAutoresizingMaskIntoConstraints = false
    commandsScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
    let explanation = Theme.wrappingLabel(
      "These docker commands do the same thing. DockVac talks to the Docker Engine API directly, without force flags.",
      size: 11, color: .secondaryLabelColor)
    explanation.isSelectable = false
    explanation.preferredMaxLayoutWidth = 660
    commandsContainer.orientation = .vertical
    commandsContainer.alignment = .leading
    commandsContainer.spacing = 6
    commandsContainer.addArrangedSubview(commandsScroll)
    commandsContainer.addArrangedSubview(explanation)
    commandsContainer.isHidden = true
    sections.append(commandsContainer)

    confirmCheckbox.target = self
    confirmCheckbox.action = #selector(checkboxChanged)
    confirmCheckbox.state = .off
    sections.append(confirmCheckbox)

    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
    cancel.bezelStyle = .rounded
    cancel.keyEquivalent = "\u{1B}"
    removeButton.title = count == 1 ? "Remove 1 Item" : "Remove \(count) Items"
    removeButton.target = self
    removeButton.action = #selector(removePressed)
    removeButton.bezelStyle = .rounded
    removeButton.hasDestructiveAction = true
    removeButton.isEnabled = false
    let spacer = NSView()
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
    let buttons = NSStackView(views: [spacer, cancel, removeButton])
    buttons.orientation = .horizontal
    buttons.spacing = 10
    sections.append(buttons)

    let stack = NSStackView(views: sections)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.setCustomSpacing(14, after: intro)
    stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: content.topAnchor),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      commandsContainer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      commandsScroll.widthAnchor.constraint(equalTo: commandsContainer.widthAnchor),
      buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      intro.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
    ])
    return content
  }

  // MARK: - Table

  func numberOfRows(in tableView: NSTableView) -> Int {
    plan.operations.count
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    plan.operations[row].warnings.isEmpty ? 46 : 66
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let identifier = NSUserInterfaceItemIdentifier("OperationCell")
    let cell =
      (tableView.makeView(withIdentifier: identifier, owner: self) as? OperationCellView)
      ?? OperationCellView()
    cell.identifier = identifier
    let operation = plan.operations[row]
    cell.configure(
      step: row + 1,
      kind: operation.id.kind,
      title: "\(operation.title): \(operation.target)",
      detail:
        "\(operation.detail) · frees about \(ByteFormat.string(operation.estimatedReclaimableBytes))",
      warning: operation.warnings.joined(separator: " "),
      status: nil
    )
    return cell
  }

  // MARK: - Actions

  @objc private func toggleCommands() {
    commandsContainer.isHidden.toggle()
    commandsToggle.title =
      commandsContainer.isHidden ? "Show Equivalent Commands" : "Hide Equivalent Commands"
  }

  @objc private func copyCommands() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(plan.cliScript, forType: .string)
  }

  @objc private func checkboxChanged() {
    removeButton.isEnabled = confirmCheckbox.state == .on && !plan.isEmpty
  }

  @objc private func cancelPressed() {
    finish(confirmed: false)
  }

  @objc private func removePressed() {
    guard confirmCheckbox.state == .on else { return }
    finish(confirmed: true)
  }

  private func finish(confirmed: Bool) {
    guard !decided else { return }
    decided = true
    if let window, let parent = window.sheetParent {
      parent.endSheet(window)
    }
    onDecision(confirmed)
  }
}

/// One operation row shared by the confirmation and progress sheets.
final class OperationCellView: NSTableCellView {
  private let step = Theme.label("", size: 12, weight: .semibold, color: .secondaryLabelColor)
  private let dot = NSView()
  private let title = Theme.label("", size: 12.5, weight: .semibold)
  private let detail = Theme.label("", size: 11, color: .secondaryLabelColor)
  private let warning = Theme.wrappingLabel("", size: 11, color: .systemOrange)
  private let statusIcon = NSImageView()
  private let statusText = Theme.label("", size: 11, color: .secondaryLabelColor)

  init() {
    super.init(frame: .zero)
    step.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    step.alignment = .right
    step.translatesAutoresizingMaskIntoConstraints = false
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 5
    dot.translatesAutoresizingMaskIntoConstraints = false
    warning.isSelectable = false
    warning.maximumNumberOfLines = 2
    warning.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    statusIcon.translatesAutoresizingMaskIntoConstraints = false
    statusText.alignment = .right
    statusText.lineBreakMode = .byTruncatingTail
    statusText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let text = NSStackView(views: [title, detail, warning])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 1
    text.translatesAutoresizingMaskIntoConstraints = false
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let status = NSStackView(views: [statusIcon, statusText])
    status.orientation = .horizontal
    status.alignment = .centerY
    status.spacing = 4
    status.translatesAutoresizingMaskIntoConstraints = false

    addSubview(step)
    addSubview(dot)
    addSubview(text)
    addSubview(status)
    NSLayoutConstraint.activate([
      step.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      step.widthAnchor.constraint(equalToConstant: 22),
      step.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.leadingAnchor.constraint(equalTo: step.trailingAnchor, constant: 8),
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 10),
      dot.heightAnchor.constraint(equalToConstant: 10),
      text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
      text.centerYAnchor.constraint(equalTo: centerYAnchor),
      status.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 8),
      status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      status.centerYAnchor.constraint(equalTo: centerYAnchor),
      status.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
      statusIcon.widthAnchor.constraint(equalToConstant: 16),
      statusIcon.heightAnchor.constraint(equalToConstant: 16),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(
    step number: Int, kind: DockerResourceKind, title text: String, detail subtitle: String,
    warning caution: String, status: CleanupOperationStatus?
  ) {
    step.stringValue = "\(number)."
    dot.layer?.backgroundColor = Theme.color(for: kind).cgColor
    title.stringValue = text
    detail.stringValue = subtitle
    warning.stringValue = caution
    warning.isHidden = caution.isEmpty
    warning.preferredMaxLayoutWidth = 420

    guard let status else {
      statusIcon.image = nil
      statusText.stringValue = ""
      toolTip = caution.isEmpty ? nil : caution
      return
    }
    switch status {
    case .pending:
      statusIcon.image = Theme.symbol("circle", pointSize: 12, color: .tertiaryLabelColor)
      statusText.stringValue = "Waiting"
      statusText.textColor = .tertiaryLabelColor
      toolTip = nil
    case .running:
      statusIcon.image = Theme.symbol(
        "arrow.triangle.2.circlepath", pointSize: 12, color: .controlAccentColor)
      statusText.stringValue = "Removing…"
      statusText.textColor = .controlAccentColor
      toolTip = nil
    case .succeeded(let detailText):
      statusIcon.image = Theme.symbol("checkmark.circle.fill", pointSize: 12, color: .systemGreen)
      statusText.stringValue = detailText
      statusText.textColor = .systemGreen
      toolTip = detailText
    case .failed(let message):
      statusIcon.image = Theme.symbol("xmark.octagon.fill", pointSize: 12, color: .systemRed)
      statusText.stringValue = message
      statusText.textColor = .systemRed
      toolTip = message
    case .skipped(let reason):
      statusIcon.image = Theme.symbol("minus.circle", pointSize: 12, color: .secondaryLabelColor)
      statusText.stringValue = reason
      statusText.textColor = .secondaryLabelColor
      toolTip = reason
    }
  }
}
