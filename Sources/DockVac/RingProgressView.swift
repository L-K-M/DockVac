import AppKit

/// A circular progress ring with an icon in the middle, like a disk scanner's gauge.
final class RingProgressView: NSView {
  /// 0...1, or nil for an indeterminate spinning arc.
  var fraction: Double? {
    didSet {
      updateAnimation()
      needsDisplay = true
    }
  }
  var ringColor: NSColor = .controlAccentColor
  var trackColor: NSColor = .separatorColor
  var lineWidth: CGFloat = 6

  private let iconView = NSImageView()
  private var timer: Timer?
  private var rotation: CGFloat = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)
    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.62),
      iconView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.62),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  var icon: NSImage? {
    get { iconView.image }
    set { iconView.image = newValue }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateAnimation()
  }

  private func updateAnimation() {
    let shouldAnimate = window != nil && fraction == nil
    if shouldAnimate, timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.rotation += 4
          if self.rotation >= 360 { self.rotation -= 360 }
          self.needsDisplay = true
        }
      }
    } else if !shouldAnimate {
      timer?.invalidate()
      timer = nil
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let side = min(bounds.width, bounds.height)
    let center = NSPoint(x: bounds.midX, y: bounds.midY)
    let radius = side / 2 - lineWidth / 2 - 1

    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = lineWidth
    trackColor.setStroke()
    track.stroke()

    let arc = NSBezierPath()
    if let fraction {
      let clamped = max(0, min(1, fraction))
      guard clamped > 0 else { return }
      // Start at twelve o'clock and sweep clockwise.
      arc.appendArc(
        withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * clamped,
        clockwise: true)
    } else {
      let start = 90 - rotation
      arc.appendArc(
        withCenter: center, radius: radius, startAngle: start, endAngle: start - 100,
        clockwise: true)
    }
    arc.lineWidth = lineWidth
    arc.lineCapStyle = .round
    ringColor.setStroke()
    arc.stroke()
  }
}
