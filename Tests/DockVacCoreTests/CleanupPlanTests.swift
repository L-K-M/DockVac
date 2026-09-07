import XCTest

@testable import DockVacCore

final class CleanupPlanTests: XCTestCase {
  func testBlockedItemsAreExcludedWithTheirReason() throws {
    let report = try Fixtures.report()
    let plan = CleanupPlan.make(
      selecting: [Fixtures.imageID(Fixtures.alpineImageID), Fixtures.volumeID("dv-used-data")],
      from: report)

    XCTAssertTrue(plan.isEmpty)
    XCTAssertEqual(plan.exclusions.count, 2)
    XCTAssertTrue(
      plan.exclusions.contains { $0.title == "alpine:3.20" && $0.reason.contains("running") })
    XCTAssertTrue(
      plan.exclusions.contains { $0.title == "dv-used-data" && $0.reason.contains("running") })
  }

  func testPrerequisitesMustBeSelectedToo() throws {
    let report = try Fixtures.report()
    let busybox = Fixtures.imageID(Fixtures.busyboxImageID)

    let alone = CleanupPlan.make(selecting: [busybox], from: report)
    XCTAssertTrue(alone.isEmpty)
    XCTAssertEqual(alone.exclusions.count, 1)
    XCTAssertTrue(alone.exclusions[0].reason.contains("dv-anon"))
    XCTAssertTrue(alone.exclusions[0].reason.contains("dv-created"))

    let partial = CleanupPlan.make(
      selecting: [busybox, Fixtures.containerID(Fixtures.anonContainerID)], from: report)
    XCTAssertEqual(
      partial.operations.map { $0.id }, [Fixtures.containerID(Fixtures.anonContainerID)])
    XCTAssertEqual(partial.exclusions.map { $0.id }, [busybox])
  }

  func testOperationsAreOrderedContainersImagesVolumesBuildCache() throws {
    let report = try Fixtures.report()
    let selection: [DockerResourceID] = [
      Fixtures.cacheID(Fixtures.sharedCacheRecordID),
      Fixtures.volumeID("dv-orphan-data"),
      Fixtures.imageID(Fixtures.busyboxImageID),
      Fixtures.containerID(Fixtures.createdContainerID),
      Fixtures.containerID(Fixtures.anonContainerID),
      Fixtures.volumeID(Fixtures.anonymousVolumeName),
      Fixtures.imageID(Fixtures.danglingImageID),
    ]
    let plan = CleanupPlan.make(selecting: selection, from: report)

    XCTAssertTrue(plan.exclusions.isEmpty)
    XCTAssertEqual(
      plan.operations.map { $0.id.kind },
      [.containers, .containers, .images, .images, .localVolumes, .localVolumes, .buildCache])
    // Within a kind, larger reclaim first, then by name.
    XCTAssertEqual(plan.operations[0].target, "dv-anon")
    XCTAssertEqual(plan.operations[1].target, "dv-created")
    XCTAssertEqual(plan.operations[2].id, Fixtures.imageID(Fixtures.busyboxImageID))
    XCTAssertEqual(plan.operations[4].id, Fixtures.volumeID("dv-orphan-data"))
    XCTAssertEqual(
      plan.estimatedReclaimableBytes, 0 + 0 + 4_417_150 + 500_000 + 3_145_728 + 102_400 + 600_000)
    XCTAssertEqual(plan.summary, "2 images, 2 containers, 2 volumes, 1 build cache record")
    XCTAssertEqual(plan.counts()[.images], 2)
  }

  func testOperationsDescribeExactCommands() throws {
    let report = try Fixtures.report()
    let plan = CleanupPlan.make(
      selecting: [
        Fixtures.imageID(Fixtures.multiTagImageID),
        Fixtures.imageID(Fixtures.danglingImageID),
        Fixtures.containerID(Fixtures.exitedContainerID),
        Fixtures.volumeID("dv-orphan-data"),
        Fixtures.cacheID(Fixtures.sharedCacheRecordID),
      ], from: report)

    let byKind = Dictionary(grouping: plan.operations, by: { $0.id.kind })

    let images = try XCTUnwrap(byKind[.images])
    let multi = try XCTUnwrap(images.first { $0.id == Fixtures.imageID(Fixtures.multiTagImageID) })
    XCTAssertEqual(multi.title, "Remove image")
    XCTAssertEqual(multi.target, "dv-app:1.0")
    XCTAssertEqual(
      multi.cliEquivalent,
      "docker image rm dv-app:1.0 dv-app:latest localhost:5000/team/dv-app:stable")
    guard case .removeImage(let id, let references) = multi.action else {
      return XCTFail("expected image action")
    }
    XCTAssertEqual(id, Fixtures.multiTagImageID)
    XCTAssertEqual(references.count, 3)

    let dangling = try XCTUnwrap(
      images.first { $0.id == Fixtures.imageID(Fixtures.danglingImageID) })
    XCTAssertEqual(dangling.cliEquivalent, "docker image rm 74700d03f0d3")
    XCTAssertEqual(dangling.action, .removeImage(id: Fixtures.danglingImageID, references: []))
    XCTAssertTrue(dangling.warnings.contains { $0.contains("cannot be pulled again") })

    let container = try XCTUnwrap(byKind[.containers]?.first)
    XCTAssertEqual(container.cliEquivalent, "docker container rm dv-exited")
    XCTAssertEqual(container.action, .removeContainer(id: Fixtures.exitedContainerID))
    XCTAssertEqual(container.estimatedReclaimableBytes, 2_097_152)

    let volume = try XCTUnwrap(byKind[.localVolumes]?.first)
    XCTAssertEqual(volume.cliEquivalent, "docker volume rm dv-orphan-data")
    XCTAssertEqual(volume.action, .removeVolume(name: "dv-orphan-data"))

    let cache = try XCTUnwrap(byKind[.buildCache]?.first)
    XCTAssertEqual(cache.title, "Remove build cache record")
    XCTAssertEqual(
      cache.cliEquivalent, "docker builder prune --force --filter id=vwsvmuey10ihejz2y1xuio17t")
    XCTAssertEqual(cache.action, .pruneBuildCache(id: Fixtures.sharedCacheRecordID))

    XCTAssertEqual(plan.cliScript.split(separator: "\n").count, 5)
    XCTAssertEqual(
      plan.cliScript.split(separator: "\n").first?.hasPrefix("docker container rm"), true)
  }

  func testOperationsCarryTheirPrerequisites() throws {
    let report = try Fixtures.report()
    let plan = CleanupPlan.make(
      selecting: [
        Fixtures.volumeID("dv-stopped-ref"), Fixtures.containerID(Fixtures.exitedContainerID),
      ], from: report)

    XCTAssertEqual(plan.operations.map { $0.id.kind }, [.containers, .localVolumes])
    XCTAssertEqual(plan.operations[0].prerequisites, [])
    XCTAssertEqual(
      plan.operations[1].prerequisites, [Fixtures.containerID(Fixtures.exitedContainerID)])

    var state = CleanupRunState(plan: plan)
    XCTAssertEqual(state.unmetPrerequisites(of: 1).map { $0.id }, [plan.operations[0].id])
    state.markFailed(0, message: "conflict")
    XCTAssertEqual(state.unmetPrerequisites(of: 1).count, 1)
    state.markSkipped(1, reason: "Not attempted: dv-exited could not be removed first.")
    XCTAssertEqual(
      state.statuses[1], .skipped(reason: "Not attempted: dv-exited could not be removed first."))
    XCTAssertEqual(state.unmetPrerequisites(of: 0), [])
    XCTAssertEqual(state.unmetPrerequisites(of: 7), [])

    var succeeded = CleanupRunState(plan: plan)
    succeeded.markSucceeded(0, detail: "Container removed.")
    XCTAssertTrue(succeeded.unmetPrerequisites(of: 1).isEmpty)
  }

  func testUnknownSelectionIsExcluded() throws {
    let report = try Fixtures.report()
    let ghost = DockerResourceID(kind: .localVolumes, rawValue: "ghost")
    let plan = CleanupPlan.make(selecting: [ghost], from: report)

    XCTAssertEqual(plan.exclusions.map { $0.id }, [ghost])
    XCTAssertEqual(plan.exclusions[0].reason, "No longer present in Docker.")
  }

  func testShellQuoting() {
    XCTAssertEqual(CleanupPlan.shellQuote("nginx:latest"), "nginx:latest")
    XCTAssertEqual(
      CleanupPlan.shellQuote("registry.example.com:5000/team/app@sha256:abc"),
      "registry.example.com:5000/team/app@sha256:abc")
    XCTAssertEqual(CleanupPlan.shellQuote("odd name"), "'odd name'")
    XCTAssertEqual(CleanupPlan.shellQuote("it's"), "'it'\\''s'")
    XCTAssertEqual(CleanupPlan.shellQuote(""), "''")
  }

  func testRunStateTracksProgressAndSummaries() throws {
    let report = try Fixtures.report()
    let plan = CleanupPlan.make(
      selecting: [
        Fixtures.containerID(Fixtures.exitedContainerID),
        Fixtures.volumeID("dv-orphan-data"),
        Fixtures.cacheID(Fixtures.sharedCacheRecordID),
      ], from: report)
    var state = CleanupRunState(plan: plan, startedAt: Date(timeIntervalSince1970: 0))

    XCTAssertEqual(state.statuses, [.pending, .pending, .pending])
    XCTAssertEqual(state.fractionCompleted, 0)
    XCTAssertNil(state.currentIndex)
    XCTAssertFalse(state.isFinished)

    state.markRunning(0)
    XCTAssertEqual(state.currentIndex, 0)
    state.markSucceeded(0, detail: "Container removed")
    state.markRunning(1)
    state.markFailed(1, message: "volume is in use")
    XCTAssertEqual(state.completedCount, 2)
    XCTAssertEqual(state.fractionCompleted, 2.0 / 3.0, accuracy: 1e-9)

    state.skipRemaining(reason: "Stopped by user.")
    state.finish(at: Date(timeIntervalSince1970: 10))

    XCTAssertTrue(state.isFinished)
    XCTAssertEqual(state.statuses[2], .skipped(reason: "Stopped by user."))
    XCTAssertEqual(state.succeededCount, 1)
    XCTAssertEqual(state.failedCount, 1)
    XCTAssertEqual(state.skippedCount, 1)
    XCTAssertEqual(state.estimatedFreedBytes, 2_097_152)
    XCTAssertEqual(state.summary, "Removed 1 item, about 2.1 MB freed. 1 failed. 1 skipped.")

    var untouched = CleanupRunState(plan: plan)
    untouched.finish()
    XCTAssertEqual(untouched.summary, "Nothing was removed. 3 skipped.")
    XCTAssertTrue(untouched.statuses.allSatisfy { $0 == .skipped(reason: "Not attempted.") })

    var recorded = CleanupRunState(plan: plan)
    recorded.markSucceeded(2, detail: "Freed 600 kB", reportedReclaimedBytes: 600_000)
    XCTAssertEqual(recorded.reportedReclaimedBytes[2], 600_000)
    recorded.markRunning(99)
    XCTAssertEqual(recorded.statuses.count, 3, "out-of-range indices are ignored")

    XCTAssertEqual(CleanupRunState(plan: .empty).fractionCompleted, 1)
  }
}
