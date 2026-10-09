import AppKit
import DockVacCore

/// Collects a validated destination; SSH credentials stay with OpenSSH.
final class SSHConnectionSheetController: NSWindowController {
  private let addressField = NSTextField()
  private let errorLabel = Theme.wrappingLabel("", size: 11, color: .systemRed)
  private let onDecision: (DockerSSHHost?) -> Void

  init(host: DockerSSHHost?, onDecision: @escaping (DockerSSHHost?) -> Void) {
    self.onDecision = onDecision
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 540, height: 250),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Connect via SSH"
    super.init(window: window)

    addressField.placeholderString = "ssh://user@server:2222 or SSH config alias"
    addressField.stringValue = host?.address ?? ""
    let intro = Theme.wrappingLabel(
      "Use your SSH keys, agent, and ~/.ssh/config. First connect in Terminal to verify the host key. Docker must be on the server's PATH and your user must have socket access.",
      size: 12, color: .secondaryLabelColor)
    let socketHint = Theme.wrappingLabel(
      "The default socket is /var/run/docker.sock. For rootless Docker, append its socket path to the SSH URL.",
      size: 11, color: .secondaryLabelColor)
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
    cancel.bezelStyle = .rounded
    cancel.keyEquivalent = "\u{1B}"
    let connect = NSButton(title: "Connect", target: self, action: #selector(connectPressed))
    connect.bezelStyle = .rounded
    connect.keyEquivalent = "\r"
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let buttons = NSStackView(views: [spacer, cancel, connect])
    buttons.spacing = 10

    let stack = NSStackView(views: [intro, addressField, socketHint, errorLabel, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    let content = NSView()
    content.addSubview(stack)
    window.contentView = content
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
      intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
      addressField.widthAnchor.constraint(equalTo: stack.widthAnchor),
      socketHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
      errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    window.initialFirstResponder = addressField
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  @objc private func connectPressed() {
    do {
      finish(try DockerSSHHost(addressField.stringValue))
    } catch {
      errorLabel.stringValue = error.localizedDescription
    }
  }

  @objc private func cancelPressed() {
    finish(nil)
  }

  private func finish(_ host: DockerSSHHost?) {
    if let window, let parent = window.sheetParent { parent.endSheet(window) }
    onDecision(host)
  }
}
