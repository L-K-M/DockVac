import AppKit
import DockVacCore

/// Explains the selected tile: what it is, whether it can go, and what removing it means.
final class DetailPanelView: NSView {
  weak var actions: ReportActions?

  private let scrollView = NSScrollView()
  private let stack = NSStackView()
  private var wrappingLabels: [NSTextField] = []
  private var signature: String?
  private var currentItem: UsageItem?
  private var currentCategory: UsageCategory?
  private var currentPrerequisiteTitles: [String] = []
  private var inBasket = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let document = FlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)

    scrollView.documentView = document
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func layout() {
    super.layout()
    let width = max(50, bounds.width - 28)
    for label in wrappingLabels {
      label.preferredMaxLayoutWidth = width
    }
  }

  func apply(_ state: ReportViewState) {
    let item = state.selectedItem.flatMap { state.fullReport.item(for: $0) }
    let category =
      item == nil ? state.selectedCategory.flatMap { state.fullReport.category(for: $0) } : nil
    let inBasket = item.map { state.basket.contains($0.id) } ?? false
    let prerequisites =
      item?.removability.prerequisites.compactMap { state.fullReport.item(for: $0)?.title } ?? []
    let newSignature =
      "\(item?.id.description ?? "-")|\(category?.kind.rawValue ?? "-")|\(inBasket)|\(state.fullReport.capturedAt.timeIntervalSince1970)|\(state.focus?.rawValue ?? "-")"
    guard newSignature != signature else { return }
    signature = newSignature
    currentItem = item
    currentCategory = category
    currentPrerequisiteTitles = prerequisites
    self.inBasket = inBasket
    rebuild(state: state)
  }

  private func rebuild(state: ReportViewState) {
    for view in stack.arrangedSubviews {
      view.removeFromSuperview()
    }
    wrappingLabels.removeAll()

    if let item = currentItem {
      build(for: item, state: state)
    } else if let category = currentCategory {
      build(for: category, state: state)
    } else {
      buildPlaceholder(state: state)
    }
    needsLayout = true
    scrollView.contentView.scroll(to: .zero)
  }

  // MARK: - Content

  private func buildPlaceholder(state: ReportViewState) {
    add(Theme.label("Nothing selected", size: 15, weight: .semibold))
    add(
      wrapping(
        "Click a tile or a row to see what it is and what removing it would mean. Double-click a category to zoom in.",
        size: 12, color: .secondaryLabelColor))
    if state.fullReport.totalReclaimableBytes > 0 {
      add(
        wrapping(
          "\(ByteFormat.string(state.fullReport.totalReclaimableBytes)) could be freed right now without removing anything that is in use.",
          size: 12, color: .secondaryLabelColor))
    }
  }

  private func build(for category: UsageCategory, state: ReportViewState) {
    add(Theme.label(category.kind.displayName, size: 17, weight: .bold))
    add(
      wrapping(
        "\(ByteFormat.string(category.attributedBytes)) in \(ByteFormat.count(category.items.count, singular: category.kind.singularName, plural: category.kind.pluralName)). \(ByteFormat.string(category.reclaimableBytes)) is reclaimable right now (\(category.removableCount) removable).",
        size: 12, color: .secondaryLabelColor))
    let zoom = NSButton(title: "Zoom In", target: self, action: #selector(zoomPressed))
    zoom.bezelStyle = .rounded
    add(zoom)
  }

  private func build(for item: UsageItem, state: ReportViewState) {
    let kindLabel = Theme.label(
      item.kind.singularName.capitalized, size: 11, weight: .semibold,
      color: Theme.color(for: item.kind))
    add(kindLabel)
    let title = wrapping(item.title, size: 16, weight: .bold)
    add(title)
    if !item.subtitle.isEmpty {
      add(Theme.label(item.subtitle, size: 12, color: .secondaryLabelColor))
    }

    let status = Theme.label(
      item.statusText, size: 12, weight: .semibold, color: Theme.color(for: item.tone))
    add(status)

    var sizeText = "Takes up \(ByteFormat.string(item.attributedBytes))"
    if let total = item.totalBytes, total != item.attributedBytes {
      sizeText += " of its \(ByteFormat.string(total)) total"
    }
    sizeText += "."
    if item.removability.isBlocked {
      sizeText += " Nothing is freed while it is in use."
    } else {
      sizeText += " Removing it frees about \(ByteFormat.string(item.estimatedReclaimableBytes))."
    }
    add(wrapping(sizeText, size: 12))

    if let explanation = item.removability.explanation {
      add(
        noteRow(
          symbol: item.removability.isBlocked ? "lock.fill" : "arrow.triangle.branch",
          color: Theme.color(for: item.tone), text: explanation))
    }
    for note in item.notes {
      let symbol = note.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"
      let color: NSColor = note.severity == .warning ? .systemOrange : .secondaryLabelColor
      add(noteRow(symbol: symbol, color: color, text: note.text))
    }

    add(actionButtons(for: item))

    if !item.details.isEmpty {
      add(separator())
      let grid = NSGridView(numberOfColumns: 2, rows: 0)
      grid.rowSpacing = 4
      grid.columnSpacing = 10
      grid.column(at: 0).xPlacement = .trailing
      grid.translatesAutoresizingMaskIntoConstraints = false
      for detail in item.details {
        let label = Theme.label(
          detail.label, size: 11, weight: .medium, color: .secondaryLabelColor)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let value = wrapping(detail.value, size: 11)
        value.font =
          detail.label == "ID" || detail.label == "Digests"
          ? .monospacedSystemFont(ofSize: 10.5, weight: .regular) : .systemFont(ofSize: 11)
        grid.addRow(with: [label, value])
      }
      grid.column(at: 0).width = 110
      add(grid)
      grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }
  }

  private func actionButtons(for item: UsageItem) -> NSView {
    let toggle: NSButton
    if item.removability.isBlocked {
      toggle = NSButton(title: "Cannot Be Removed", target: nil, action: nil)
      toggle.isEnabled = false
    } else if inBasket {
      toggle = NSButton(
        title: "Remove from Cleanup", target: self, action: #selector(togglePressed))
    } else if currentPrerequisiteTitles.isEmpty {
      toggle = NSButton(title: "Add to Cleanup", target: self, action: #selector(togglePressed))
    } else {
      toggle = NSButton(
        title: "Add to Cleanup with \(currentPrerequisiteTitles.joined(separator: ", "))",
        target: self, action: #selector(togglePressed))
    }
    toggle.bezelStyle = .rounded
    toggle.controlSize = .regular
    toggle.lineBreakMode = .byTruncatingTail
    toggle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let copy = NSButton(title: "Copy ID", target: self, action: #selector(copyPressed))
    copy.bezelStyle = .rounded
    copy.setContentCompressionResistancePriority(.required, for: .horizontal)

    let row = NSStackView(views: [toggle, copy])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .centerY
    return row
  }

  private func noteRow(symbol: String, color: NSColor, text: String) -> NSView {
    let icon = NSImageView(
      image: Theme.symbol(symbol, pointSize: 12, weight: .medium, color: color) ?? NSImage())
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
    icon.setContentHuggingPriority(.required, for: .horizontal)
    let label = wrapping(text, size: 11.5, color: .labelColor)
    let row = NSStackView(views: [icon, label])
    row.orientation = .horizontal
    row.alignment = .top
    row.spacing = 6
    return row
  }

  private func separator() -> NSView {
    let box = NSBox()
    box.boxType = .separator
    box.translatesAutoresizingMaskIntoConstraints = false
    box.widthAnchor.constraint(equalToConstant: 200).isActive = true
    return box
  }

  private func wrapping(
    _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor
  ) -> NSTextField {
    let label = Theme.wrappingLabel(text, size: size, weight: weight, color: color)
    label.preferredMaxLayoutWidth = max(50, bounds.width - 28)
    wrappingLabels.append(label)
    return label
  }

  private func add(_ view: NSView) {
    stack.addArrangedSubview(view)
  }

  // MARK: - Actions

  @objc private func togglePressed() {
    guard let item = currentItem else { return }
    actions?.toggleBasket(item.id)
  }

  @objc private func copyPressed() {
    guard let item = currentItem else { return }
    actions?.copyToPasteboard(item.id.rawValue)
  }

  @objc private func zoomPressed() {
    guard let category = currentCategory else { return }
    actions?.focus(on: category.kind)
  }
}

/// A document view that lays out from the top, so the stack hugs the top edge.
final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
