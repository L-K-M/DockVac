import AppKit

/// Centered icon, headline, explanation, and one action. Used for the idle and error states.
final class MessageView: NSView {
  var onAction: (() -> Void)?

  private let iconView = NSImageView()
  private let headline = Theme.label("", size: 24, weight: .bold)
  private let message = Theme.wrappingLabel("", size: 14, color: .secondaryLabelColor)
  private let details = Theme.wrappingLabel("", size: 11, color: .tertiaryLabelColor)
  private let actionButton = NSButton(title: "Scan", target: nil, action: nil)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.translatesAutoresizingMaskIntoConstraints = false
    headline.alignment = .center
    message.alignment = .center
    details.alignment = .center
    details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    actionButton.target = self
    actionButton.action = #selector(actionPressed)
    actionButton.keyEquivalent = "\r"
    actionButton.bezelStyle = .rounded
    actionButton.controlSize = .large

    let stack = NSStackView(views: [iconView, headline, message, details, actionButton])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 10
    stack.setCustomSpacing(18, after: iconView)
    stack.setCustomSpacing(22, after: details)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: 128),
      iconView.heightAnchor.constraint(equalToConstant: 128),
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
      stack.widthAnchor.constraint(equalToConstant: 520),
      message.widthAnchor.constraint(equalTo: stack.widthAnchor),
      details.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func apply(
    icon: NSImage?, headline text: String, message body: String, details extra: String,
    action: String
  ) {
    iconView.image = icon
    headline.stringValue = text
    message.stringValue = body
    details.stringValue = extra
    details.isHidden = extra.isEmpty
    actionButton.title = action
  }

  @objc private func actionPressed() {
    onAction?()
  }
}
