import XCTest

@testable import DockVacCore

/// The automatic cleanup's promise: everything it removes, Docker can produce again,
/// and nothing a user could lose data through is ever part of it.
final class AutomaticCleanupTests: XCTestCase {
  // MARK: - What each level selects

  func testSafeLevelTakesOnlyUntaggedImagesAndPrivateBuildCache() throws {
    let report = try Fixtures.report()
    let safe = report.automaticCleanupIDs(.safe)

    XCTAssertEqual(safe.count, 6, "the dangling image plus the five private cache records")
    XCTAssertTrue(safe.contains(Fixtures.imageID(Fixtures.danglingImageID)))
    XCTAssertTrue(safe.contains(Fixtures.cacheID(Fixtures.privateCacheRecordID)))
    XCTAssertFalse(
      safe.contains(Fixtures.cacheID(Fixtures.sharedCacheRecordID)),
      "a per-record prune would silently not remove a record shared with an image layer")
    XCTAssertFalse(
      safe.contains(Fixtures.imageID(Fixtures.helloWorldImageID)),
      "an unused tagged image is reproducible but not a leftover, so the safe level keeps it")
  }

  func testThoroughLevelAddsUnusedImagesARegistryCanServeAgain() throws {
    let report = try Fixtures.report()
    let thorough = report.automaticCleanupIDs(.thorough)

    XCTAssertTrue(
      thorough.contains(Fixtures.imageID(Fixtures.helloWorldImageID)),
      "hello-world has a registry digest and no container, so docker pull gets it back")
    for id in report.automaticCleanupIDs(.safe) {
      XCTAssertTrue(thorough.contains(id), "thorough never removes less than safe: \(id.rawValue)")
    }
  }

  func testNeitherLevelTouchesAnImageThatOnlyEverExistedLocally() throws {
    let report = try Fixtures.report()
    // dv-dangling:latest is tagged with no digest, and dv-app carries three local tags.
    // Both were built here, so no registry could serve them again.
    let localOnly = [Fixtures.localOnlyImageID, Fixtures.multiTagImageID]
    for id in localOnly {
      let image = try XCTUnwrap(report.usage.images.first { $0.id == id })
      XCTAssertTrue(image.repoDigests.isEmpty, "the fixture image really is local-only")
      XCTAssertTrue(
        try XCTUnwrap(report.item(for: image.resourceID)).removability.isRemovableNow,
        "and removable on request, so only its provenance keeps it out")
    }

    for level in AutomaticCleanupLevel.allCases {
      let ids = report.automaticCleanupIDs(level)
      for id in localOnly {
        XCTAssertFalse(
          ids.contains(Fixtures.imageID(id)),
          "\(level.rawValue) must not remove a local-only image")
      }
    }
  }

  func testAnUnusedImageWithoutATagButWithADigestIsOnlyThorough() {
    let pinned = DockerImage(
      id: "sha256:pinned", repoTags: [], repoDigests: ["alpine@sha256:abc"], created: nil,
      sizeBytes: 5_000_000, sharedSizeBytes: 0, containerCount: 0)
    let report = UsageAnalyzer.analyze(DockerDiskUsage(images: [pinned]))

    XCTAssertFalse(
      report.automaticCleanupIDs(.safe).contains(pinned.resourceID),
      "Docker's own prune keeps a digest-pinned image, and so does the safe level")
    XCTAssertEqual(
      report.automaticCleanupIDs(.thorough), [pinned.resourceID],
      "but the digest means it can be pulled again")
  }

  // MARK: - What no level may ever do

  func testNoLevelRemovesAContainerOrAVolume() throws {
    let report = try Fixtures.report()
    for level in AutomaticCleanupLevel.allCases {
      let plan = CleanupPlan.make(selecting: report.automaticCleanupIDs(level), from: report)
      XCTAssertFalse(plan.isEmpty, "\(level.rawValue) should find something in the fixture")
      for operation in plan.operations {
        switch operation.action {
        case .removeContainer, .removeVolume:
          XCTFail("\(level.rawValue) planned \(operation.title) for \(operation.target)")
        case .removeImage, .pruneBuildCache:
          continue
        }
      }
    }
  }

  func testAnImageUsedByAStoppedContainerStaysInsteadOfPullingThatContainerIn() throws {
    let report = try Fixtures.report()
    // busybox:1.36 has a registry digest, so it is re-pullable, but a stopped and a created
    // container still reference it. Removing it would mean removing them and their writable
    // layers first, which an automatic cleanup must never decide on its own.
    let busybox = Fixtures.imageID(Fixtures.busyboxImageID)
    let item = try XCTUnwrap(report.item(for: busybox))
    XCTAssertFalse(item.removability.prerequisites.isEmpty, "the fixture really has users")

    XCTAssertFalse(report.automaticCleanupIDs(.thorough).contains(busybox))
    for level in AutomaticCleanupLevel.allCases {
      let plan = CleanupPlan.make(selecting: report.automaticCleanupIDs(level), from: report)
      XCTAssertTrue(
        plan.exclusions.isEmpty,
        "an automatic plan only ever contains items that need nothing removed first")
      XCTAssertTrue(plan.operations.allSatisfy { $0.prerequisites.isEmpty })
    }
  }

  func testNoLevelRemovesAnImageThatARunningContainerUses() throws {
    let report = try Fixtures.report()
    let alpine = Fixtures.imageID(Fixtures.alpineImageID)
    XCTAssertTrue(try XCTUnwrap(report.item(for: alpine)).removability.isBlocked)

    for level in AutomaticCleanupLevel.allCases {
      XCTAssertFalse(report.automaticCleanupIDs(level).contains(alpine))
    }
  }

  func testTheSyntheticSharedLayersTileIsNeverPlanned() throws {
    let report = try Fixtures.report()
    XCTAssertNotNil(report.item(for: UsageItem.sharedLayersID), "the fixture has shared layers")
    for level in AutomaticCleanupLevel.allCases {
      XCTAssertFalse(report.automaticCleanupIDs(level).contains(UsageItem.sharedLayersID))
    }
  }

  func testAnEmptyDaemonPlansNothingAtEitherLevel() {
    let report = UsageAnalyzer.analyze(.empty)
    for level in AutomaticCleanupLevel.allCases {
      XCTAssertTrue(report.automaticCleanupIDs(level).isEmpty)
    }
  }
}
