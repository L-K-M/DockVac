import XCTest

@testable import DockVacCore

final class TreemapTests: XCTestCase {
  private let bounds = TreemapRect(x: 10, y: 20, width: 400, height: 300)

  func testAreasAreProportionalAndTileTheBounds() {
    let weights: [Double] = [60, 30, 10, 5, 3, 1, 1]
    let rects = Treemap.squarify(weights: weights, in: bounds)

    XCTAssertEqual(rects.count, weights.count)
    let total = weights.reduce(0, +)
    for (weight, rect) in zip(weights, rects) {
      XCTAssertEqual(rect.area, bounds.area * weight / total, accuracy: 1e-6)
      XCTAssertGreaterThanOrEqual(rect.x, bounds.x - 1e-9)
      XCTAssertGreaterThanOrEqual(rect.y, bounds.y - 1e-9)
      XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + 1e-9)
      XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + 1e-9)
    }
    assertNoOverlaps(rects)
  }

  func testEqualWeightsInSquareProduceQuadrants() {
    let square = TreemapRect(x: 0, y: 0, width: 100, height: 100)
    let rects = Treemap.squarify(weights: [1, 1, 1, 1], in: square)

    for rect in rects {
      XCTAssertEqual(rect.width, 50, accuracy: 1e-9)
      XCTAssertEqual(rect.height, 50, accuracy: 1e-9)
    }
    assertNoOverlaps(rects)
  }

  func testNonPositiveWeightsGetEmptyRects() {
    let rects = Treemap.squarify(weights: [5, 0, -2, .nan, 5], in: bounds)

    XCTAssertTrue(rects[1].isEmpty)
    XCTAssertTrue(rects[2].isEmpty)
    XCTAssertTrue(rects[3].isEmpty)
    XCTAssertEqual(rects[0].area, bounds.area / 2, accuracy: 1e-6)
    XCTAssertEqual(rects[4].area, bounds.area / 2, accuracy: 1e-6)
  }

  func testDegenerateInputs() {
    XCTAssertEqual(Treemap.squarify(weights: [], in: bounds), [])
    XCTAssertTrue(Treemap.squarify(weights: [1, 2], in: .zero).allSatisfy { $0.isEmpty })
    XCTAssertTrue(Treemap.squarify(weights: [0, 0], in: bounds).allSatisfy { $0.isEmpty })
    let single = Treemap.squarify(weights: [7], in: bounds)
    XCTAssertEqual(single, [bounds])
  }

  func testAspectRatiosStayReasonableForManyItems() {
    let weights = (1...40).map { Double(41 - $0) * Double(41 - $0) }
    let rects = Treemap.squarify(weights: weights, in: bounds)
    let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
    XCTAssertLessThan(worst, 6, "squarified layouts should avoid extreme slivers")
    assertNoOverlaps(rects)
  }

  func testBuilderCreatesCategoryTilesWithNestedItems() throws {
    let report = try Fixtures.report()
    let builder = TreemapBuilder(
      padding: 4, categoryHeaderHeight: 20, minimumTileArea: 400, alwaysShowCount: 3)
    let root = TreemapRect(x: 0, y: 0, width: 800, height: 600)
    let nodes = builder.build(report: report, focus: nil, in: root)

    XCTAssertEqual(nodes.count, 4)
    XCTAssertEqual(Set(nodes.map { $0.kind }), Set(DockerResourceKind.allCases))
    let total = report.totalAttributedBytes
    for node in nodes {
      XCTAssertEqual(node.role, .category)
      let expected = Double(node.weightBytes) / Double(total) * root.area
      XCTAssertEqual(
        node.rect.area, expected, accuracy: expected * 0.05 + 64,
        "padding shaves a little off each tile")
      XCTAssertFalse(node.children.isEmpty)
      for child in node.children {
        XCTAssertTrue(
          child.rect.x >= node.contentRect.x - 1e-6
            && child.rect.maxX <= node.contentRect.maxX + 1e-6,
          "\(child.title) \(child.rect) escapes \(node.contentRect) horizontally")
        XCTAssertTrue(
          child.rect.y >= node.contentRect.y - 1e-6
            && child.rect.maxY <= node.contentRect.maxY + 1e-6,
          "\(child.title) \(child.rect) escapes \(node.contentRect) vertically")
        XCTAssertNotEqual(child.role, .category)
      }
      assertNoOverlaps(node.children.map { $0.rect })
    }

    let images = try XCTUnwrap(nodes.first { $0.kind == .images })
    let itemIDs = images.children.compactMap { $0.resourceID }
    XCTAssertTrue(itemIDs.contains(Fixtures.imageID(Fixtures.multiTagImageID)))
    let shared = try XCTUnwrap(images.children.first { $0.resourceID == UsageItem.sharedLayersID })
    XCTAssertFalse(shared.isRemovable)
    let requiresContainers = try XCTUnwrap(
      images.children.first { $0.resourceID == Fixtures.imageID(Fixtures.busyboxImageID) })
    XCTAssertFalse(
      requiresContainers.isRemovable, "items with prerequisites are not removable on their own")
    let dangling = try XCTUnwrap(
      images.children.first { $0.resourceID == Fixtures.imageID(Fixtures.danglingImageID) })
    XCTAssertTrue(dangling.isRemovable)
  }

  func testBuilderFoldsTinyItemsIntoAnAggregate() throws {
    // One big record plus a long tail that would be unreadable at any realistic size.
    var items = [makeItem(id: "big", bytes: 5_000_000)]
    items += (1...12).map { makeItem(id: "tiny-\($0)", bytes: UInt64($0) * 100) }
    let report = UsageReport(
      usage: .empty, categories: [UsageCategory(kind: .buildCache, items: items)],
      capturedAt: Date(timeIntervalSince1970: 0))
    let builder = TreemapBuilder(
      padding: 2, categoryHeaderHeight: 10, minimumTileArea: 2_000, alwaysShowCount: 2)
    let nodes = builder.build(
      report: report, focus: .buildCache, in: TreemapRect(x: 0, y: 0, width: 240, height: 180))

    let aggregate = try XCTUnwrap(nodes.first { $0.role == .aggregate })
    let visible = nodes.filter { $0.role == .item }
    XCTAssertTrue(aggregate.title.hasSuffix("more build cache records"))
    XCTAssertFalse(aggregate.isRemovable, "an aggregate is never removable as one tile")
    XCTAssertEqual(visible.count + aggregate.aggregatedIDs.count, items.count)
    XCTAssertGreaterThanOrEqual(visible.count, 2, "alwaysShowCount tiles survive folding")
    let visibleBytes = visible.reduce(UInt64(0)) { $0 + $1.weightBytes }
    XCTAssertEqual(
      visibleBytes + aggregate.weightBytes, items.reduce(UInt64(0)) { $0 + $1.attributedBytes })
    assertNoOverlaps(nodes.map { $0.rect })
  }

  private func makeItem(id: String, bytes: UInt64) -> UsageItem {
    UsageItem(
      id: DockerResourceID(kind: .buildCache, rawValue: id), title: id, subtitle: "",
      attributedBytes: bytes, totalBytes: bytes, estimatedReclaimableBytes: bytes, statusText: "",
      tone: .reclaimable, removability: .removable, notes: [], details: [], created: nil)
  }

  func testBuilderNeverFoldsASingleItem() {
    let items = [
      UsageItem(
        id: DockerResourceID(kind: .buildCache, rawValue: "big"), title: "big", subtitle: "",
        attributedBytes: 1_000_000, totalBytes: nil,
        estimatedReclaimableBytes: 1_000_000, statusText: "", tone: .reclaimable,
        removability: .removable, notes: [], details: [], created: nil),
      UsageItem(
        id: DockerResourceID(kind: .buildCache, rawValue: "tiny"), title: "tiny", subtitle: "",
        attributedBytes: 1, totalBytes: nil,
        estimatedReclaimableBytes: 1, statusText: "", tone: .reclaimable, removability: .removable,
        notes: [], details: [], created: nil),
    ]
    let report = UsageReport(
      usage: .empty, categories: [UsageCategory(kind: .buildCache, items: items)],
      capturedAt: Date())
    let nodes = TreemapBuilder(alwaysShowCount: 1).build(
      report: report, focus: .buildCache, in: TreemapRect(x: 0, y: 0, width: 300, height: 300))

    XCTAssertEqual(nodes.count, 2)
    XCTAssertTrue(nodes.allSatisfy { $0.role == .item })
  }

  func testFocusedBuildSkipsCategoriesWithoutBytes() {
    let nodes = TreemapBuilder().build(
      report: .empty, focus: nil, in: TreemapRect(x: 0, y: 0, width: 300, height: 300))
    XCTAssertTrue(nodes.isEmpty)
    XCTAssertTrue(
      TreemapBuilder().build(
        report: .empty, focus: .images, in: TreemapRect(x: 0, y: 0, width: 300, height: 300)
      ).isEmpty)
  }

  func testHitTestReturnsDeepestNode() throws {
    let report = try Fixtures.report()
    let nodes = TreemapBuilder().build(
      report: report, focus: nil, in: TreemapRect(x: 0, y: 0, width: 800, height: 600))
    let images = try XCTUnwrap(nodes.first { $0.kind == .images })
    let child = try XCTUnwrap(images.children.first)
    let centerX = child.rect.x + child.rect.width / 2
    let centerY = child.rect.y + child.rect.height / 2

    XCTAssertEqual(images.hitTest(x: centerX, y: centerY)?.id, child.id)
    // A point in the category header belongs to the category itself.
    XCTAssertEqual(images.hitTest(x: images.rect.x + 1, y: images.rect.y + 1)?.id, images.id)
    XCTAssertNil(images.hitTest(x: -1, y: -1))
    XCTAssertEqual(images.flattened().count, images.children.count + 1)
  }

  func testRectHelpers() {
    let rect = TreemapRect(x: 10, y: 10, width: 100, height: 50)
    XCTAssertTrue(rect.contains(x: 10, y: 10))
    XCTAssertFalse(rect.contains(x: 110, y: 10), "the far edge is exclusive")
    XCTAssertEqual(rect.insetBy(5), TreemapRect(x: 15, y: 15, width: 90, height: 40))
    XCTAssertTrue(
      rect.insetBy(60).isEmpty, "negative sizes collapse to empty instead of going negative")
    XCTAssertTrue(rect.intersects(TreemapRect(x: 100, y: 40, width: 50, height: 50)))
    XCTAssertFalse(rect.intersects(TreemapRect(x: 110, y: 10, width: 5, height: 5)))
  }

  private func assertNoOverlaps(
    _ rects: [TreemapRect], file: StaticString = #filePath, line: UInt = #line
  ) {
    let visible = rects.filter { !$0.isEmpty }
    for i in visible.indices {
      for j in visible.indices where j > i {
        let a = visible[i]
        let b = visible[j]
        let overlapX = min(a.maxX, b.maxX) - max(a.x, b.x)
        let overlapY = min(a.maxY, b.maxY) - max(a.y, b.y)
        if overlapX > 1e-6 && overlapY > 1e-6 {
          XCTFail("rects overlap: \(a) and \(b)", file: file, line: line)
        }
      }
    }
  }
}
