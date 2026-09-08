import Foundation

/// A rectangle in an abstract, top-left-origin coordinate space.
public struct TreemapRect: Hashable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = max(0, width)
    self.height = max(0, height)
  }

  public static let zero = TreemapRect(x: 0, y: 0, width: 0, height: 0)

  public var area: Double { width * height }
  public var maxX: Double { x + width }
  public var maxY: Double { y + height }
  public var isEmpty: Bool { width <= 0 || height <= 0 }

  public func contains(x px: Double, y py: Double) -> Bool {
    px >= x && px < maxX && py >= y && py < maxY
  }

  public func insetBy(_ inset: Double) -> TreemapRect {
    insetBy(top: inset, left: inset, bottom: inset, right: inset)
  }

  /// Shrinks the rectangle. A rectangle too small for the inset collapses to an empty one
  /// that still lies inside the original, so callers never see tiles leaking out of parents.
  public func insetBy(top: Double, left: Double, bottom: Double, right: Double) -> TreemapRect {
    let newWidth = max(0, width - left - right)
    let newHeight = max(0, height - top - bottom)
    let newX = min(x + left, maxX - newWidth)
    let newY = min(y + top, maxY - newHeight)
    return TreemapRect(x: newX, y: newY, width: newWidth, height: newHeight)
  }

  public func intersects(_ other: TreemapRect) -> Bool {
    x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
  }
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk).
public enum Treemap {
  /// Lays out `weights` inside `bounds`, returning one rectangle per weight in input order.
  ///
  /// Weights should be sorted descending for the best aspect ratios, but any order is
  /// accepted. Non-positive weights get an empty rectangle. Areas are proportional to
  /// weights and the rectangles tile `bounds` without overlapping.
  public static func squarify(weights: [Double], in bounds: TreemapRect) -> [TreemapRect] {
    var rects = Array(
      repeating: TreemapRect(x: bounds.x, y: bounds.y, width: 0, height: 0), count: weights.count)
    let positive = weights.enumerated().filter { $0.element > 0 && $0.element.isFinite }
    let total = positive.reduce(0) { $0 + $1.element }
    guard total > 0, !bounds.isEmpty else {
      return rects
    }

    let scale = bounds.area / total
    var remaining = bounds
    var row: [(index: Int, area: Double)] = []

    func layoutRow(isFinal: Bool) {
      guard !row.isEmpty else { return }
      let rowArea = row.reduce(0) { $0 + $1.area }
      if remaining.width >= remaining.height {
        // Vertical strip along the left edge. The final strip takes whatever is left so
        // floating point drift never leaves a sliver or overshoots the bounds.
        let stripWidth =
          isFinal ? remaining.width : (remaining.height > 0 ? rowArea / remaining.height : 0)
        var y = remaining.y
        for (offset, entry) in row.enumerated() {
          let h = stripWidth > 0 ? entry.area / stripWidth : 0
          let isLast = offset == row.count - 1
          let height = isLast ? remaining.maxY - y : h
          rects[entry.index] = TreemapRect(x: remaining.x, y: y, width: stripWidth, height: height)
          y += h
        }
        remaining = TreemapRect(
          x: remaining.x + stripWidth,
          y: remaining.y,
          width: remaining.width - stripWidth,
          height: remaining.height
        )
      } else {
        // Horizontal strip along the top edge.
        let stripHeight =
          isFinal ? remaining.height : (remaining.width > 0 ? rowArea / remaining.width : 0)
        var x = remaining.x
        for (offset, entry) in row.enumerated() {
          let w = stripHeight > 0 ? entry.area / stripHeight : 0
          let isLast = offset == row.count - 1
          let width = isLast ? remaining.maxX - x : w
          rects[entry.index] = TreemapRect(x: x, y: remaining.y, width: width, height: stripHeight)
          x += w
        }
        remaining = TreemapRect(
          x: remaining.x,
          y: remaining.y + stripHeight,
          width: remaining.width,
          height: remaining.height - stripHeight
        )
      }
      row.removeAll()
    }

    func worstAspect(_ candidate: [(index: Int, area: Double)], side: Double) -> Double {
      guard side > 0 else { return .infinity }
      let sum = candidate.reduce(0) { $0 + $1.area }
      guard sum > 0 else { return .infinity }
      var worst = 0.0
      for entry in candidate {
        let sideSquared = side * side
        let ratio = max(
          sideSquared * entry.area / (sum * sum), (sum * sum) / (sideSquared * entry.area))
        worst = max(worst, ratio)
      }
      return worst
    }

    for (index, weight) in positive {
      let area = weight * scale
      let side = min(remaining.width, remaining.height)
      if row.isEmpty {
        row.append((index, area))
        continue
      }
      let current = worstAspect(row, side: side)
      let extended = worstAspect(row + [(index, area)], side: side)
      if extended <= current {
        row.append((index, area))
      } else {
        layoutRow(isFinal: false)
        row.append((index, area))
      }
    }
    layoutRow(isFinal: true)

    return rects
  }
}

/// One tile in the treemap. Category nodes contain item nodes; aggregate nodes stand in
/// for many small items that would be unreadable on their own.
public struct TreemapNode: Hashable, Sendable, Identifiable {
  public enum Role: Hashable, Sendable {
    case category
    case item
    case aggregate
  }

  public let id: String
  public let role: Role
  public let kind: DockerResourceKind
  public let resourceID: DockerResourceID?
  /// Resource IDs represented by an aggregate node.
  public let aggregatedIDs: [DockerResourceID]
  public let title: String
  public let subtitle: String
  public let weightBytes: UInt64
  public let isRemovable: Bool
  public var rect: TreemapRect
  /// Rectangle available to children (category content area below the header).
  public var contentRect: TreemapRect
  public var children: [TreemapNode]

  public init(
    id: String,
    role: Role,
    kind: DockerResourceKind,
    resourceID: DockerResourceID?,
    aggregatedIDs: [DockerResourceID] = [],
    title: String,
    subtitle: String,
    weightBytes: UInt64,
    isRemovable: Bool,
    rect: TreemapRect,
    contentRect: TreemapRect? = nil,
    children: [TreemapNode] = []
  ) {
    self.id = id
    self.role = role
    self.kind = kind
    self.resourceID = resourceID
    self.aggregatedIDs = aggregatedIDs
    self.title = title
    self.subtitle = subtitle
    self.weightBytes = weightBytes
    self.isRemovable = isRemovable
    self.rect = rect
    self.contentRect = contentRect ?? rect
    self.children = children
  }

  /// Depth-first search for the deepest node containing the point.
  public func hitTest(x: Double, y: Double) -> TreemapNode? {
    guard rect.contains(x: x, y: y) else { return nil }
    for child in children {
      if let hit = child.hitTest(x: x, y: y) {
        return hit
      }
    }
    return self
  }

  public func flattened() -> [TreemapNode] {
    [self] + children.flatMap { $0.flattened() }
  }
}

/// Turns a usage report into a laid-out tree of tiles.
public struct TreemapBuilder: Sendable {
  public var padding: Double
  public var categoryHeaderHeight: Double
  /// Items whose tile would be smaller than this many square points are folded into an
  /// aggregate tile so labels stay legible.
  public var minimumTileArea: Double
  /// Never fold the largest N items of a category, so a category always shows detail.
  public var alwaysShowCount: Int

  public init(
    padding: Double = 4,
    categoryHeaderHeight: Double = 22,
    minimumTileArea: Double = 900,
    alwaysShowCount: Int = 3
  ) {
    self.padding = padding
    self.categoryHeaderHeight = categoryHeaderHeight
    self.minimumTileArea = minimumTileArea
    self.alwaysShowCount = alwaysShowCount
  }

  /// Builds the root level. With `focus` nil every category is a tile containing its items;
  /// with a focus kind the items of that category are laid out directly.
  public func build(report: UsageReport, focus: DockerResourceKind?, in bounds: TreemapRect)
    -> [TreemapNode]
  {
    if let focus {
      guard let category = report.category(for: focus) else { return [] }
      return itemNodes(for: category, in: bounds)
    }

    let categories = report.categories.filter { $0.attributedBytes > 0 }
    let weights = categories.map { Double($0.attributedBytes) }
    let rects = Treemap.squarify(weights: weights, in: bounds)
    var nodes: [TreemapNode] = []
    for (category, rect) in zip(categories, rects) {
      let tile = rect.insetBy(padding / 2)
      let content = tile.insetBy(
        top: categoryHeaderHeight, left: padding, bottom: padding, right: padding)
      var node = TreemapNode(
        id: "category:\(category.kind.rawValue)",
        role: .category,
        kind: category.kind,
        resourceID: nil,
        title: category.kind.displayName,
        subtitle:
          "\(ByteFormat.string(category.attributedBytes)) · \(ByteFormat.count(category.items.count, singular: category.kind.singularName, plural: category.kind.pluralName))",
        weightBytes: category.attributedBytes,
        isRemovable: false,
        rect: tile,
        contentRect: content
      )
      if !content.isEmpty {
        node.children = itemNodes(for: category, in: content)
      }
      nodes.append(node)
    }
    return nodes
  }

  private func itemNodes(for category: UsageCategory, in bounds: TreemapRect) -> [TreemapNode] {
    let items = category.items.filter { $0.attributedBytes > 0 }
    let total = items.reduce(UInt64(0)) { $0 + $1.attributedBytes }
    guard total > 0, !bounds.isEmpty else { return [] }

    let areaPerByte = bounds.area / Double(total)
    var visible: [UsageItem] = []
    var folded: [UsageItem] = []
    for (index, item) in items.enumerated() {
      let area = Double(item.attributedBytes) * areaPerByte
      if index < alwaysShowCount || area >= minimumTileArea {
        visible.append(item)
      } else {
        folded.append(item)
      }
    }
    // Do not fold a single item; a lone aggregate is worse than a small tile.
    if folded.count == 1, let lone = folded.first {
      visible.append(lone)
      folded.removeAll()
    }

    var weights = visible.map { Double($0.attributedBytes) }
    let foldedBytes = folded.reduce(UInt64(0)) { $0 + $1.attributedBytes }
    if !folded.isEmpty {
      weights.append(Double(foldedBytes))
    }
    let rects = Treemap.squarify(weights: weights, in: bounds)

    var nodes: [TreemapNode] = []
    for (item, rect) in zip(visible, rects) {
      nodes.append(
        TreemapNode(
          id: item.id.description,
          role: .item,
          kind: item.kind,
          resourceID: item.id,
          title: item.title,
          subtitle: ByteFormat.string(item.attributedBytes),
          weightBytes: item.attributedBytes,
          isRemovable: item.removability.isRemovableNow,
          rect: rect.insetBy(padding / 2)
        )
      )
    }
    if !folded.isEmpty, let rect = rects.last {
      nodes.append(
        TreemapNode(
          id: "aggregate:\(category.kind.rawValue)",
          role: .aggregate,
          kind: category.kind,
          resourceID: nil,
          aggregatedIDs: folded.map { $0.id },
          title: "\(folded.count) more \(category.kind.pluralName)",
          subtitle: ByteFormat.string(foldedBytes),
          weightBytes: foldedBytes,
          isRemovable: false,
          rect: rect.insetBy(padding / 2)
        )
      )
    }
    return nodes
  }
}
