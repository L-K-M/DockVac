import AppKit
import DockVacCore

/// A stacked horizontal bar showing how the categories share the total, with a legend.
final class UsageBarView: NSView {
  private var segments: [(kind: DockerResourceKind, bytes: UInt64, reclaimable: UInt64)] = []
  private let legend = NSStackView()
  private let barHeight: CGFloat = 12

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    legend.orientation = .vertical
    legend.alignment = .leading
    legend.spacing = 3
    legend.translatesAutoresizingMaskIntoConstraints = false
    addSubview(legend)
    NSLayoutConstraint.activate([
      legend.topAnchor.constraint(equalTo: topAnchor, constant: barHeight + 10),
      legend.leadingAnchor.constraint(equalTo: leadingAnchor),
      legend.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      legend.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func apply(report: UsageReport) {
    segments = report.categories.map { ($0.kind, $0.attributedBytes, $0.reclaimableBytes) }
    for view in legend.arrangedSubviews {
      view.removeFromSuperview()
    }
    for category in report.categories {
      let dot = NSView()
      dot.wantsLayer = true
      dot.layer?.backgroundColor = Theme.color(for: category.kind).cgColor
      dot.layer?.cornerRadius = 4
      dot.translatesAutoresizingMaskIntoConstraints = false
      dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
      dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

      let name = Theme.label(category.kind.displayName, size: 11, weight: .medium)
      name.setContentCompressionResistancePriority(.required, for: .horizontal)
      let reclaimable =
        category.reclaimableBytes > 0
        ? " · \(ByteFormat.string(category.reclaimableBytes)) reclaimable now" : ""
      let value = Theme.label(
        "\(ByteFormat.string(category.attributedBytes)) in \(ByteFormat.count(category.items.count, singular: "item", plural: "items"))\(reclaimable)",
        size: 11, color: .secondaryLabelColor)
      let row = NSStackView(views: [dot, name, value])
      row.orientation = .horizontal
      row.spacing = 6
      row.alignment = .centerY
      legend.addArrangedSubview(row)
    }
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let barRect = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
    let clip = NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    NSColor.separatorColor.setFill()
    barRect.fill()

    let total = segments.reduce(UInt64(0)) { $0 + $1.bytes }
    if total > 0 {
      var x = barRect.minX
      for segment in segments where segment.bytes > 0 {
        let width = barRect.width * CGFloat(segment.bytes) / CGFloat(total)
        let segmentRect = NSRect(x: x, y: barRect.minY, width: width, height: barRect.height)
        Theme.color(for: segment.kind).setFill()
        segmentRect.fill()
        // Lighter band for the part that is reclaimable right now.
        if segment.reclaimable > 0 {
          let reclaimableWidth = width * CGFloat(segment.reclaimable) / CGFloat(segment.bytes)
          NSColor.white.withAlphaComponent(0.45).setFill()
          NSRect(x: x, y: barRect.minY, width: reclaimableWidth, height: barRect.height / 2).fill()
        }
        x += width
      }
    }
    NSGraphicsContext.restoreGraphicsState()
  }
}
