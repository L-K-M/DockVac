import AppKit
import DockVacCore

@MainActor
protocol TreemapViewDelegate: AnyObject {
  func treemapView(_ view: TreemapView, didSelectItem id: DockerResourceID?)
  func treemapView(_ view: TreemapView, didSelectCategory kind: DockerResourceKind?)
  func treemapView(_ view: TreemapView, didRequestFocus kind: DockerResourceKind?)
  func treemapView(_ view: TreemapView, didToggleBasket id: DockerResourceID)
  func treemapView(_ view: TreemapView, copy text: String)
}

/// The spatial view: every tile's area is proportional to the disk space it occupies.
final class TreemapView: NSView {
  weak var delegate: TreemapViewDelegate?

  var report: UsageReport = .empty {
    didSet {
      if oldValue != report {
        invalidateNodes()
      }
    }
  }
  var focus: DockerResourceKind? {
    didSet {
      if oldValue != focus {
        invalidateNodes()
      }
    }
  }
  var selectedItem: DockerResourceID? {
    didSet { needsDisplay = true }
  }
  var selectedCategory: DockerResourceKind? {
    didSet { needsDisplay = true }
  }
  var basket: Set<DockerResourceID> = [] {
    didSet { needsDisplay = true }
  }

  private var nodes: [TreemapNode] = []
  private var itemsByID: [DockerResourceID: UsageItem] = [:]
  private var nodesAreStale = true
  private var hoveredNodeID: String?
  private var trackingArea: NSTrackingArea?
  private let margin: CGFloat = 12
  private let builder = TreemapBuilder(
    padding: 5, categoryHeaderHeight: 24, minimumTileArea: 1_100, alwaysShowCount: 3)

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // MARK: - Layout

  private func invalidateNodes() {
    nodesAreStale = true
    hoveredNodeID = nil
    toolTip = nil
    needsLayout = true
    needsDisplay = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    nodesAreStale = true
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    rebuildNodesIfNeeded()
  }

  private func rebuildNodesIfNeeded() {
    guard nodesAreStale else { return }
    nodesAreStale = false
    itemsByID = Dictionary(
      report.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let area = bounds.insetBy(dx: margin, dy: margin)
    guard area.width > 20, area.height > 20 else {
      nodes = []
      return
    }
    let rect = TreemapRect(x: area.minX, y: area.minY, width: area.width, height: area.height)
    nodes = builder.build(report: report, focus: focus, in: rect)
  }

  /// Nodes that represent something the user can select.
  private func node(at point: NSPoint) -> TreemapNode? {
    for node in nodes {
      if let hit = node.hitTest(x: point.x, y: point.y) {
        return hit
      }
    }
    return nil
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    Theme.treemapBackground.setFill()
    dirtyRect.fill()
    rebuildNodesIfNeeded()

    if nodes.isEmpty {
      drawEmptyMessage()
      return
    }
    for node in nodes {
      draw(node)
    }
  }

  private func drawEmptyMessage() {
    let text: String
    if report.itemCount == 0 {
      text = "Nothing here. Docker reports no disk usage for this view."
    } else if let focus, report.category(for: focus)?.attributedBytes == 0 {
      text = "\(focus.displayName) take up no measurable space."
    } else {
      text = "Nothing takes up measurable space in this view."
    }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    let size = text.size(withAttributes: attributes)
    let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
    text.draw(at: origin, withAttributes: attributes)
  }

  private func draw(_ node: TreemapNode) {
    let rect = nsRect(node.rect)
    guard rect.width >= 1, rect.height >= 1 else { return }
    let color = Theme.color(for: node.kind)

    switch node.role {
    case .category:
      let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
      color.withAlphaComponent(0.12).setFill()
      path.fill()
      let isSelected = selectedCategory == node.kind && focus == nil
      path.lineWidth = isSelected ? 2.5 : 1
      (isSelected ? NSColor.controlAccentColor : color.withAlphaComponent(0.55)).setStroke()
      path.stroke()
      if hoveredNodeID == node.id {
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        path.fill()
      }
      drawCategoryHeader(node, in: rect, color: color)
      for child in node.children {
        draw(child)
      }

    case .item, .aggregate:
      let item = node.resourceID.flatMap { itemsByID[$0] }
      let tone = item?.tone ?? .caution
      let fillAlpha: CGFloat
      switch (node.role, tone) {
      case (.aggregate, _): fillAlpha = 0.42
      case (_, .reclaimable): fillAlpha = 0.88
      case (_, .caution): fillAlpha = 0.72
      case (_, .locked): fillAlpha = 0.28
      }
      let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
      color.withAlphaComponent(fillAlpha).setFill()
      path.fill()

      if tone == .locked || (item?.removability.isRemovableNow == false && node.role == .item) {
        drawHatch(in: rect, clip: path)
      }
      if hoveredNodeID == node.id {
        NSColor.white.withAlphaComponent(0.14).setFill()
        path.fill()
      }

      let inBasket = node.resourceID.map { basket.contains($0) } ?? false
      let isSelected = node.resourceID != nil && node.resourceID == selectedItem
      if inBasket {
        path.lineWidth = 2.5
        NSColor.systemGreen.setStroke()
        path.stroke()
      }
      if isSelected {
        let outline = NSBezierPath(
          roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), xRadius: 6.5, yRadius: 6.5)
        outline.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
      }

      drawTileLabels(node, item: item, in: rect, fillAlpha: fillAlpha, inBasket: inBasket)
    }
  }

  private func drawCategoryHeader(_ node: TreemapNode, in rect: NSRect, color: NSColor) {
    let headerRect = NSRect(x: rect.minX + 10, y: rect.minY + 4, width: rect.width - 20, height: 18)
    guard headerRect.width > 30 else { return }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let title = NSAttributedString(
      string: node.title,
      attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraph,
      ])
    let titleWidth = min(title.size().width, headerRect.width)
    title.draw(
      in: NSRect(
        x: headerRect.minX, y: headerRect.minY, width: titleWidth, height: headerRect.height))

    let remaining = headerRect.width - titleWidth - 8
    if remaining > 40 {
      let subtitle = NSAttributedString(
        string: node.subtitle,
        attributes: [
          .font: NSFont.systemFont(ofSize: 12),
          .foregroundColor: NSColor.secondaryLabelColor,
          .paragraphStyle: paragraph,
        ])
      subtitle.draw(
        in: NSRect(
          x: headerRect.minX + titleWidth + 8, y: headerRect.minY + 0.5, width: remaining,
          height: headerRect.height))
    }
  }

  private func drawTileLabels(
    _ node: TreemapNode, item: UsageItem?, in rect: NSRect, fillAlpha: CGFloat, inBasket: Bool
  ) {
    let textColor: NSColor = fillAlpha >= 0.6 ? .white : .labelColor
    let inset = rect.insetBy(dx: 7, dy: 5)
    guard inset.width >= 30, inset.height >= 14 else { return }

    var badgeWidth: CGFloat = 0
    if inBasket, inset.width >= 44, inset.height >= 18 {
      if let badge = Theme.symbol(
        "checkmark.circle.fill", pointSize: 13, weight: .semibold, color: .white)
      {
        let size = NSSize(width: 16, height: 16)
        badge.draw(
          in: NSRect(
            x: inset.maxX - size.width, y: inset.minY, width: size.width, height: size.height))
        badgeWidth = size.width + 4
      }
    } else if item?.tone == .locked, inset.width >= 44, inset.height >= 18 {
      if let lock = Theme.symbol(
        "lock.fill", pointSize: 11, weight: .semibold, color: textColor.withAlphaComponent(0.8))
      {
        let size = NSSize(width: 13, height: 15)
        lock.draw(
          in: NSRect(
            x: inset.maxX - size.width, y: inset.minY, width: size.width, height: size.height))
        badgeWidth = size.width + 4
      }
    }

    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingMiddle
    let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    let title = NSAttributedString(
      string: node.title,
      attributes: [.font: titleFont, .foregroundColor: textColor, .paragraphStyle: paragraph])
    let titleRect = NSRect(
      x: inset.minX, y: inset.minY, width: inset.width - badgeWidth, height: 16)
    title.draw(in: titleRect)

    if inset.height >= 34 {
      let subtitle = NSAttributedString(
        string: node.subtitle,
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
          .foregroundColor: textColor.withAlphaComponent(0.85),
          .paragraphStyle: paragraph,
        ])
      subtitle.draw(in: NSRect(x: inset.minX, y: inset.minY + 17, width: inset.width, height: 15))
    }
    if inset.height >= 52, let item {
      let status = NSAttributedString(
        string: item.statusText,
        attributes: [
          .font: NSFont.systemFont(ofSize: 10.5),
          .foregroundColor: textColor.withAlphaComponent(0.75),
          .paragraphStyle: paragraph,
        ])
      status.draw(in: NSRect(x: inset.minX, y: inset.minY + 33, width: inset.width, height: 14))
    }
  }

  private func drawHatch(in rect: NSRect, clip: NSBezierPath) {
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    let hatch = NSBezierPath()
    hatch.lineWidth = 1
    let spacing: CGFloat = 8
    var offset = -rect.height
    while offset < rect.width {
      hatch.move(to: NSPoint(x: rect.minX + offset, y: rect.maxY))
      hatch.line(to: NSPoint(x: rect.minX + offset + rect.height, y: rect.minY))
      offset += spacing
    }
    NSColor.labelColor.withAlphaComponent(0.16).setStroke()
    hatch.stroke()
    NSGraphicsContext.restoreGraphicsState()
  }

  private func nsRect(_ rect: TreemapRect) -> NSRect {
    NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
  }

  // MARK: - Mouse

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let hit = node(at: point)
    let newID = hit?.id
    if newID != hoveredNodeID {
      hoveredNodeID = newID
      toolTip = hit.flatMap(tooltip(for:))
      needsDisplay = true
    }
  }

  override func mouseExited(with event: NSEvent) {
    if hoveredNodeID != nil {
      hoveredNodeID = nil
      needsDisplay = true
    }
  }

  private func tooltip(for node: TreemapNode) -> String? {
    switch node.role {
    case .category:
      return "\(node.title): \(node.subtitle). Double-click to zoom in."
    case .aggregate:
      return "\(node.title), \(node.subtitle). Click to zoom in and see them."
    case .item:
      guard let id = node.resourceID, let item = itemsByID[id] else { return node.title }
      var lines = ["\(item.title) · \(ByteFormat.string(item.attributedBytes))", item.statusText]
      if let explanation = item.removability.explanation {
        lines.append(explanation)
      } else {
        lines.append(
          basket.contains(id)
            ? "Selected for cleanup. Double-click to deselect."
            : "Double-click to select for cleanup.")
      }
      return lines.joined(separator: "\n")
    }
  }

  override func mouseDown(with event: NSEvent) {
    _ = window?.makeFirstResponder(self)
    let point = convert(event.locationInWindow, from: nil)
    guard let hit = node(at: point) else {
      delegate?.treemapView(self, didSelectItem: nil)
      delegate?.treemapView(self, didSelectCategory: nil)
      return
    }
    switch hit.role {
    case .category:
      if event.clickCount == 2 {
        delegate?.treemapView(self, didRequestFocus: hit.kind)
      } else {
        delegate?.treemapView(self, didSelectCategory: hit.kind)
      }
    case .aggregate:
      delegate?.treemapView(self, didRequestFocus: hit.kind)
    case .item:
      guard let id = hit.resourceID else { return }
      if event.clickCount == 2 {
        if itemsByID[id]?.removability.isBlocked == false {
          delegate?.treemapView(self, didToggleBasket: id)
        }
      } else {
        delegate?.treemapView(self, didSelectItem: id)
      }
    }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    guard let hit = node(at: point) else { return nil }
    let menu = NSMenu()

    switch hit.role {
    case .category, .aggregate:
      let zoom = NSMenuItem(
        title: "Zoom In to \(hit.kind.displayName)", action: #selector(contextZoom(_:)),
        keyEquivalent: "")
      zoom.target = self
      zoom.representedObject = hit.kind.rawValue
      menu.addItem(zoom)
    case .item:
      guard let id = hit.resourceID, let item = itemsByID[id] else { return nil }
      delegate?.treemapView(self, didSelectItem: id)
      let inBasket = basket.contains(id)
      let toggle = NSMenuItem(
        title: inBasket ? "Remove from Cleanup" : "Add to Cleanup",
        action: #selector(contextToggleBasket(_:)), keyEquivalent: "")
      toggle.target = self
      toggle.representedObject = id.description
      if let explanation = item.removability.explanation, item.removability.isBlocked {
        toggle.isEnabled = false
        toggle.toolTip = explanation
        let why = NSMenuItem(
          title: "Cannot be removed: \(item.statusText)", action: nil, keyEquivalent: "")
        why.isEnabled = false
        menu.addItem(why)
      }
      menu.addItem(toggle)
      menu.addItem(.separator())
      let copyName = NSMenuItem(
        title: "Copy Name", action: #selector(contextCopy(_:)), keyEquivalent: "")
      copyName.target = self
      copyName.representedObject = item.title
      menu.addItem(copyName)
      let copyID = NSMenuItem(
        title: "Copy Identifier", action: #selector(contextCopy(_:)), keyEquivalent: "")
      copyID.target = self
      copyID.representedObject = id.rawValue
      menu.addItem(copyID)
    }
    return menu
  }

  @objc private func contextZoom(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let kind = DockerResourceKind(rawValue: raw)
    else { return }
    delegate?.treemapView(self, didRequestFocus: kind)
  }

  @objc private func contextToggleBasket(_ sender: NSMenuItem) {
    guard let description = sender.representedObject as? String,
      let id = itemsByID.keys.first(where: { $0.description == description })
    else { return }
    delegate?.treemapView(self, didToggleBasket: id)
  }

  @objc private func contextCopy(_ sender: NSMenuItem) {
    guard let text = sender.representedObject as? String else { return }
    delegate?.treemapView(self, copy: text)
  }

  // MARK: - Keyboard

  override func keyDown(with event: NSEvent) {
    guard let characters = event.charactersIgnoringModifiers else {
      super.keyDown(with: event)
      return
    }
    switch characters {
    case " ":
      if let selectedItem, itemsByID[selectedItem]?.removability.isBlocked == false {
        delegate?.treemapView(self, didToggleBasket: selectedItem)
      }
    case "\u{1B}":
      delegate?.treemapView(self, didSelectItem: nil)
      delegate?.treemapView(self, didSelectCategory: nil)
    default:
      super.keyDown(with: event)
    }
  }
}
