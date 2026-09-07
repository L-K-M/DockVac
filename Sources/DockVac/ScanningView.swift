import AppKit
import DockVacCore
import DockVacDocker

/// Shown while DockVac connects to Docker and measures disk usage.
final class ScanningView: NSView {
  var onCancel: (() -> Void)?

  private let ring = RingProgressView(frame: .zero)
  private let connectionLabel = Theme.label(
    "Looking for Docker…", size: 13, weight: .semibold, color: .secondaryLabelColor)
  private let headline = Theme.label("Scanning…", size: 26, weight: .bold)
  private let detail = Theme.wrappingLabel(
    "Connecting to the Docker daemon.", size: 13, color: .secondaryLabelColor)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    ring.translatesAutoresizingMaskIntoConstraints = false
    ring.icon = NSApp.applicationIconImage
    ring.fraction = nil

    cancelButton.target = self
    cancelButton.action = #selector(cancelPressed)
    cancelButton.keyEquivalent = "\u{1B}"

    detail.isSelectable = false
    detail.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let text = NSStackView(views: [connectionLabel, headline, detail, cancelButton])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 8
    text.setCustomSpacing(16, after: detail)
    text.translatesAutoresizingMaskIntoConstraints = false

    let row = NSStackView(views: [ring, text])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 40
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)

    NSLayoutConstraint.activate([
      ring.widthAnchor.constraint(equalToConstant: 200),
      ring.heightAnchor.constraint(equalToConstant: 200),
      text.widthAnchor.constraint(equalToConstant: 380),
      row.centerXAnchor.constraint(equalTo: centerXAnchor),
      row.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func apply(phase: AppPhase, connection: DockerConnection?, startedAt: Date?) {
    connectionLabel.stringValue = connection?.summary ?? "Looking for Docker…"
    let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
    let elapsedText = elapsed >= 1 ? "\(Int(elapsed))s elapsed" : nil

    switch phase {
    case .connecting:
      headline.stringValue = "Connecting…"
      detail.stringValue =
        "Checking DOCKER_HOST, the active Docker context, and the usual socket locations."
      ring.fraction = nil
    case .scanning(let progress):
      headline.stringValue = "Scanning…"
      if let progress {
        ring.fraction = max(0.04, progress.fractionCompleted)
        var parts = [progress.stage.title]
        let partial = progress.partial
        if partial.itemCount > 0 {
          parts.append(
            "found \(ByteFormat.count(partial.itemCount, singular: "item", plural: "items")) / \(ByteFormat.string(progress.bytesFound)) so far"
          )
        }
        if let elapsedText {
          parts.append(elapsedText)
        }
        detail.stringValue = parts.joined(separator: " · ")
      } else {
        ring.fraction = nil
        detail.stringValue = elapsedText.map { "Starting the scan · \($0)" } ?? "Starting the scan."
      }
    case .idle, .report, .failed:
      break
    }
  }

  @objc private func cancelPressed() {
    onCancel?()
  }
}
