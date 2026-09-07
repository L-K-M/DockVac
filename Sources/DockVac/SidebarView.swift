import AppKit
import DockVacCore

enum SidebarRow: Equatable {
  case category(UsageCategory)
  case item(UsageItem)
}

/// Summary, item list, and detail panel on the right of the report.
final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
  weak var actions: ReportActions? {
    didSet { detail.actions = actions }
  }

  private let totalLabel = Theme.label("", size: 15, weight: .bold)
  private let subtitleLabel = Theme.wrappingLabel("", size: 11, color: .secondaryLabelColor)
  private let usageBar = UsageBarView(frame: .zero)
  private let listTitle = Theme.label(
    "Overview", size: 12, weight: .semibold, color: .secondaryLabelColor)
  private let table = NSTableView()
  private let scrollView = NSScrollView()
  private let detail = DetailPanelView(frame: .zero)

  private var rows: [SidebarRow] = []
  private var basket: Set<DockerResourceID> = []
  private var isApplyingSelection = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = Theme.panelBackground.cgColor

    subtitleLabel.isSelectable = false

    table.headerView = nil
    table.rowHeight = 44
    table.intercellSpacing = NSSize(width: 0, height: 2)
    table.style = .inset
    table.selectionHighlightStyle = .regular
    table.allowsMultipleSelection = false
    table.allowsEmptySelection = true
    table.usesAlternatingRowBackgroundColors = false
    table.backgroundColor = .clear
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(rowDoubleClicked)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

    scrollView.documentView = table
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    let header = NSStackView(views: [totalLabel, subtitleLabel, usageBar])
    header.orientation = .vertical
    header.alignment = .leading
    header.spacing = 6
    header.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 8, right: 14)
    header.translatesAutoresizingMaskIntoConstraints = false
    usageBar.translatesAutoresizingMaskIntoConstraints = false

    let listHeader = NSStackView(views: [listTitle])
    listHeader.edgeInsets = NSEdgeInsets(top: 6, left: 18, bottom: 2, right: 14)
    listHeader.translatesAutoresizingMaskIntoConstraints = false

    let divider = NSBox()
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false

    detail.translatesAutoresizingMaskIntoConstraints = false

    addSubview(header)
    addSubview(listHeader)
    addSubview(scrollView)
    addSubview(divider)
    addSubview(detail)

    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: topAnchor),
      header.leadingAnchor.constraint(equalTo: leadingAnchor),
      header.trailingAnchor.constraint(equalTo: trailingAnchor),
      usageBar.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
      usageBar.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
      subtitleLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
      listHeader.topAnchor.constraint(equalTo: header.bottomAnchor),
      listHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
      listHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: listHeader.bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      divider.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
      divider.leadingAnchor.constraint(equalTo: leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: trailingAnchor),
      detail.topAnchor.constraint(equalTo: divider.bottomAnchor),
      detail.leadingAnchor.constraint(equalTo: leadingAnchor),
      detail.trailingAnchor.constraint(equalTo: trailingAnchor),
      detail.bottomAnchor.constraint(equalTo: bottomAnchor),
      detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
    ])
    let preferredDetailHeight = detail.heightAnchor.constraint(
      equalTo: heightAnchor, multiplier: 0.42)
    preferredDetailHeight.priority = .defaultHigh
    preferredDetailHeight.isActive = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func layout() {
    super.layout()
    subtitleLabel.preferredMaxLayoutWidth = max(50, bounds.width - 28)
  }

  // MARK: - State

  func apply(_ state: ReportViewState) {
    let full = state.fullReport
    totalLabel.stringValue = "\(ByteFormat.string(full.totalAttributedBytes)) used by Docker"
    var subtitle = "\(ByteFormat.count(full.itemCount, singular: "item", plural: "items"))"
    if full.totalReclaimableBytes > 0 {
      subtitle += " · \(ByteFormat.string(full.totalReclaimableBytes)) reclaimable right now"
    }
    if state.filter == .reclaimable {
      subtitle += " · showing reclaimable items only"
    }
    subtitleLabel.stringValue = subtitle
    usageBar.apply(report: full)

    let newRows: [SidebarRow]
    if let focus = state.focus, let category = state.report.category(for: focus) {
      listTitle.stringValue =
        "\(category.kind.displayName) · \(ByteFormat.count(category.items.count, singular: category.kind.singularName, plural: category.kind.pluralName))"
      newRows = category.items.map { .item($0) }
    } else {
      listTitle.stringValue = "Overview · double-click a category to zoom in"
      newRows = state.report.categories.map { .category($0) }
    }

    // Reloading can drop the table's selection; that must not read back as a user action.
    isApplyingSelection = true
    defer { isApplyingSelection = false }

    let basketChanged = basket != state.basket
    basket = state.basket
    if newRows != rows {
      rows = newRows
      table.reloadData()
    } else if basketChanged {
      table.reloadData(forRowIndexes: IndexSet(0..<rows.count), columnIndexes: IndexSet(integer: 0))
    }

    syncSelection(state)
    detail.apply(state)
  }

  private func syncSelection(_ state: ReportViewState) {
    let targetRow = rows.firstIndex { row in
      switch row {
      case .item(let item): return item.id == state.selectedItem
      case .category(let category):
        return state.selectedItem == nil && category.kind == state.selectedCategory
      }
    }
    if let targetRow {
      if table.selectedRow != targetRow {
        table.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        table.scrollRowToVisible(targetRow)
      }
    } else if table.selectedRow >= 0 {
      table.deselectAll(nil)
    }
  }

  // MARK: - Table

  func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
    let cell =
      (tableView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView)
      ?? SidebarCellView()
    cell.identifier = identifier
    cell.checkbox.target = self
    cell.checkbox.action = #selector(checkboxToggled(_:))
    cell.checkbox.tag = row
    switch rows[row] {
    case .category(let category):
      cell.configure(category: category)
    case .item(let item):
      cell.configure(item: item, inBasket: basket.contains(item.id))
    }
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isApplyingSelection else { return }
    let row = table.selectedRow
    guard row >= 0, row < rows.count else {
      actions?.select(item: nil)
      actions?.select(category: nil)
      return
    }
    switch rows[row] {
    case .category(let category):
      actions?.select(category: category.kind)
    case .item(let item):
      actions?.select(item: item.id)
    }
  }

  @objc private func rowDoubleClicked() {
    let row = table.clickedRow
    guard row >= 0, row < rows.count else { return }
    switch rows[row] {
    case .category(let category):
      actions?.focus(on: category.kind)
    case .item(let item):
      if !item.removability.isBlocked {
        actions?.toggleBasket(item.id)
      }
    }
  }

  @objc private func checkboxToggled(_ sender: NSButton) {
    let row = sender.tag
    guard row >= 0, row < rows.count, case .item(let item) = rows[row] else { return }
    actions?.toggleBasket(item.id)
  }
}

/// One row: checkbox, colour dot, name and subtitle, size and status.
final class SidebarCellView: NSTableCellView {
  let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  private let dot = NSView()
  private let title = Theme.label("", size: 12.5, weight: .medium)
  private let subtitle = Theme.label("", size: 11, color: .secondaryLabelColor)
  private let size = Theme.label("", size: 12, weight: .semibold)
  private let status = Theme.label("", size: 10.5, color: .secondaryLabelColor)

  init() {
    super.init(frame: .zero)
    checkbox.translatesAutoresizingMaskIntoConstraints = false
    checkbox.setContentHuggingPriority(.required, for: .horizontal)
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 5
    dot.translatesAutoresizingMaskIntoConstraints = false
    size.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    size.alignment = .right
    size.setContentCompressionResistancePriority(.required, for: .horizontal)
    size.setContentHuggingPriority(.required, for: .horizontal)
    status.alignment = .right
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let text = NSStackView(views: [title, subtitle])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 1
    text.translatesAutoresizingMaskIntoConstraints = false
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let trailing = NSStackView(views: [size, status])
    trailing.orientation = .vertical
    trailing.alignment = .trailing
    trailing.spacing = 1
    trailing.translatesAutoresizingMaskIntoConstraints = false

    addSubview(checkbox)
    addSubview(dot)
    addSubview(text)
    addSubview(trailing)

    NSLayoutConstraint.activate([
      checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
      checkbox.widthAnchor.constraint(equalToConstant: 18),
      dot.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 10),
      dot.heightAnchor.constraint(equalToConstant: 10),
      text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
      text.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailing.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 8),
      trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailing.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(category: UsageCategory) {
    checkbox.isHidden = true
    dot.layer?.backgroundColor = Theme.color(for: category.kind).cgColor
    title.stringValue = category.kind.displayName
    subtitle.stringValue =
      "\(ByteFormat.count(category.items.count, singular: category.kind.singularName, plural: category.kind.pluralName)) · \(category.removableCount) removable now"
    size.stringValue = ByteFormat.string(category.attributedBytes)
    size.textColor = .labelColor
    status.stringValue =
      category.reclaimableBytes > 0
      ? "\(ByteFormat.string(category.reclaimableBytes)) reclaimable" : ""
    status.textColor = .secondaryLabelColor
    toolTip = nil
  }

  func configure(item: UsageItem, inBasket: Bool) {
    checkbox.isHidden = false
    checkbox.state = inBasket ? .on : .off
    checkbox.isEnabled = !item.removability.isBlocked
    checkbox.toolTip =
      item.removability.explanation ?? (inBasket ? "Selected for cleanup" : "Select for cleanup")
    dot.layer?.backgroundColor = Theme.color(for: item.kind).cgColor
    title.stringValue = item.title
    subtitle.stringValue = item.subtitle
    size.stringValue = ByteFormat.string(item.attributedBytes)
    size.textColor = item.removability.isBlocked ? .secondaryLabelColor : .labelColor
    status.stringValue = item.statusText
    status.textColor = Theme.color(for: item.tone)
    toolTip = item.removability.explanation
  }
}
