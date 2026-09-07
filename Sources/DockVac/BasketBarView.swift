import AppKit
import DockVacCore

/// The "caddy": what the user has selected for cleanup, and the button that reviews it.
final class BasketBarView: NSView {
  weak var actions: ReportActions?

  private let icon = NSImageView()
  private let summary = Theme.label("", size: 13, weight: .medium)
  private let detail = Theme.label("", size: 11, color: .secondaryLabelColor)
  private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
  private let reviewButton = NSButton(title: "Review & Remove…", target: nil, action: nil)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = Theme.panelBackground.cgColor

    icon.image = Theme.symbol(
      "trash.circle", pointSize: 22, weight: .regular, color: .secondaryLabelColor)
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setContentHuggingPriority(.required, for: .horizontal)

    clearButton.target = self
    clearButton.action = #selector(clearPressed)
    clearButton.bezelStyle = .rounded
    reviewButton.target = self
    reviewButton.action = #selector(reviewPressed)
    reviewButton.bezelStyle = .rounded
    reviewButton.controlSize = .large
    reviewButton.keyEquivalent = "\r"
    reviewButton.keyEquivalentModifierMask = [.command]

    let text = NSStackView(views: [summary, detail])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 1
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [icon, text, clearButton, reviewButton])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)

    let divider = NSBox()
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false
    addSubview(divider)

    NSLayoutConstraint.activate([
      divider.topAnchor.constraint(equalTo: topAnchor),
      divider.leadingAnchor.constraint(equalTo: leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      icon.widthAnchor.constraint(equalToConstant: 28),
      icon.heightAnchor.constraint(equalToConstant: 28),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func apply(_ state: ReportViewState) {
    let plan = state.plan
    if state.basket.isEmpty {
      icon.image = Theme.symbol(
        "trash.circle", pointSize: 22, weight: .regular, color: .secondaryLabelColor)
      summary.stringValue = "Nothing selected for cleanup"
      detail.stringValue =
        "Tick items in the list, double-click tiles, or use Cleanup › Add Dangling Images and Build Cache."
      clearButton.isEnabled = false
      reviewButton.isEnabled = false
      reviewButton.title = "Review & Remove…"
      toolTip = nil
      return
    }

    icon.image = Theme.symbol(
      "trash.circle.fill", pointSize: 22, weight: .regular, color: .systemGreen)
    summary.stringValue =
      plan.isEmpty
      ? "\(state.basket.count) selected, none removable yet"
      : "\(plan.summary) · frees about \(ByteFormat.string(plan.estimatedReclaimableBytes))"
    var details: [String] = []
    if !plan.exclusions.isEmpty {
      details.append(
        "\(ByteFormat.count(plan.exclusions.count, singular: "item", plural: "items")) cannot be removed yet"
      )
    }
    if plan.warnings.contains(where: { $0.contains("permanently") }) {
      details.append("includes volumes with data")
    }
    details.append("Nothing is removed until you confirm.")
    detail.stringValue = details.joined(separator: " · ")
    toolTip =
      plan.exclusions.isEmpty
      ? nil : plan.exclusions.map { "\($0.title): \($0.reason)" }.joined(separator: "\n")
    clearButton.isEnabled = true
    reviewButton.isEnabled = true
    reviewButton.title = plan.isEmpty ? "Review…" : "Review & Remove \(plan.operations.count)…"
  }

  @objc private func clearPressed() {
    actions?.clearBasket()
  }

  @objc private func reviewPressed() {
    actions?.reviewAndRemove()
  }
}
