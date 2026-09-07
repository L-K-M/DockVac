import XCTest

@testable import DockVacCore

final class UsageAnalysisTests: XCTestCase {
  func testCategoriesFollowDisplayOrderAndSortBySize() throws {
    let report = try Fixtures.report()

    XCTAssertEqual(report.categories.map { $0.kind }, DockerResourceKind.displayOrder)
    XCTAssertEqual(report.itemCount, 27, "26 Docker resources plus the shared-layers tile")
    for category in report.categories {
      let sizes = category.items.map { $0.attributedBytes }
      XCTAssertEqual(
        sizes, sizes.sorted(by: >), "\(category.kind) items must be sorted by attributed size")
    }
    let images = try XCTUnwrap(report.category(for: .images))
    XCTAssertEqual(
      images.items.map { $0.title }.prefix(2), ["Shared image layers", "busybox:1.36"])
  }

  func testSharedLayersGetTheirOwnLockedTile() throws {
    let report = try Fixtures.report()
    let shared = try XCTUnwrap(report.item(for: UsageItem.sharedLayersID))

    XCTAssertEqual(shared.attributedBytes, 16_427_111 - 6_527_222)
    XCTAssertEqual(shared.estimatedReclaimableBytes, 0)
    XCTAssertTrue(shared.removability.isBlocked)
    XCTAssertEqual(shared.tone, .locked)
    XCTAssertEqual(shared.subtitle, "shared by 4 images")
    XCTAssertTrue(
      shared.details.contains { $0.label == "Shared by" && $0.value.contains("alpine:3.20") })
    XCTAssertNil(report.usage.images.first { $0.id == shared.id.rawValue }, "the tile is synthetic")

    let plan = CleanupPlan.make(selecting: [shared.id], from: report)
    XCTAssertTrue(plan.isEmpty)
    XCTAssertEqual(plan.exclusions.count, 1)

    // Without a LayersSize the analyzer cannot know the shared total and adds nothing.
    var usage = report.usage
    usage.layersSizeBytes = nil
    XCTAssertNil(UsageAnalyzer.analyze(usage).item(for: UsageItem.sharedLayersID))
    usage.layersSizeBytes = 100
    XCTAssertNil(
      UsageAnalyzer.analyze(usage).item(for: UsageItem.sharedLayersID),
      "inconsistent totals never produce a tile")
  }

  func testImageUsedByRunningContainerIsBlocked() throws {
    let report = try Fixtures.report()
    let alpine = try XCTUnwrap(report.item(for: Fixtures.imageID(Fixtures.alpineImageID)))

    XCTAssertTrue(alpine.removability.isBlocked)
    XCTAssertEqual(alpine.tone, .locked)
    XCTAssertEqual(alpine.estimatedReclaimableBytes, 0)
    XCTAssertEqual(alpine.statusText, "In use by 2 running containers")
    XCTAssertTrue(alpine.removability.explanation?.contains("dv-web") == true)
    XCTAssertTrue(alpine.removability.explanation?.contains("dv-paused") == true)
  }

  func testImageUsedByStoppedContainersRequiresThem() throws {
    let report = try Fixtures.report()
    let busybox = try XCTUnwrap(report.item(for: Fixtures.imageID(Fixtures.busyboxImageID)))

    XCTAssertEqual(
      Set(busybox.removability.prerequisites),
      [
        Fixtures.containerID(Fixtures.anonContainerID),
        Fixtures.containerID(Fixtures.createdContainerID),
      ])
    XCTAssertEqual(busybox.tone, .caution)
    XCTAssertEqual(busybox.statusText, "Used by 2 stopped containers")
    XCTAssertEqual(busybox.estimatedReclaimableBytes, 4_417_150)
  }

  func testDanglingAndUnusedImagesAreRemovableWithProvenanceNotes() throws {
    let report = try Fixtures.report()

    let dangling = try XCTUnwrap(report.item(for: Fixtures.imageID(Fixtures.danglingImageID)))
    XCTAssertTrue(dangling.removability.isRemovableNow)
    XCTAssertEqual(dangling.statusText, "Dangling (untagged)")
    XCTAssertEqual(dangling.tone, .reclaimable)
    XCTAssertEqual(dangling.attributedBytes, 500_000)
    XCTAssertEqual(dangling.totalBytes, 10_399_889)
    XCTAssertTrue(dangling.warnings.contains { $0.contains("cannot be pulled again") })

    let hello = try XCTUnwrap(report.item(for: Fixtures.imageID(Fixtures.helloWorldImageID)))
    XCTAssertEqual(hello.statusText, "Unused (no containers)")
    XCTAssertTrue(hello.warnings.isEmpty)
    XCTAssertTrue(
      hello.notes.contains { $0.severity == .info && $0.text.contains("downloaded again") })

    let multiTag = try XCTUnwrap(report.item(for: Fixtures.imageID(Fixtures.multiTagImageID)))
    XCTAssertEqual(multiTag.subtitle, "4ab5bac49e07 · 3 tags")
    XCTAssertTrue(multiTag.notes.contains { $0.text.contains("Tagged 3 times") })
    XCTAssertTrue(
      multiTag.details.contains { $0.label == "Tags" && $0.value.contains("dv-app:latest") })
  }

  func testContainersAreBlockedWhileActiveAndCautionedWhenStopped() throws {
    let report = try Fixtures.report()

    let web = try XCTUnwrap(report.item(for: Fixtures.containerID(Fixtures.webContainerID)))
    XCTAssertTrue(web.removability.isBlocked)
    XCTAssertTrue(web.removability.explanation?.contains("never stops") == true)

    let paused = try XCTUnwrap(report.item(for: Fixtures.containerID(Fixtures.pausedContainerID)))
    XCTAssertTrue(paused.removability.isBlocked)

    let exited = try XCTUnwrap(report.item(for: Fixtures.containerID(Fixtures.exitedContainerID)))
    XCTAssertTrue(exited.removability.isRemovableNow)
    XCTAssertEqual(exited.tone, .caution)
    XCTAssertEqual(exited.attributedBytes, 2_097_152)
    XCTAssertEqual(exited.totalBytes, 9_899_889)
    XCTAssertTrue(exited.warnings.contains { $0.contains("2.1 MB") })
    XCTAssertTrue(
      exited.notes.contains { $0.text.contains("Named volumes are kept: dv-stopped-ref") })
    XCTAssertTrue(exited.statusText.hasPrefix("Stopped"))

    let anon = try XCTUnwrap(report.item(for: Fixtures.containerID(Fixtures.anonContainerID)))
    XCTAssertTrue(anon.notes.contains { $0.text.contains("1 anonymous volume") })
    XCTAssertTrue(
      anon.warnings.isEmpty, "a container without writable changes has nothing to warn about")
  }

  func testVolumesDependOnMountingContainers() throws {
    let report = try Fixtures.report()

    let used = try XCTUnwrap(report.item(for: Fixtures.volumeID("dv-used-data")))
    XCTAssertTrue(used.removability.isBlocked)
    XCTAssertEqual(used.statusText, "Mounted by 1 running container")

    let stoppedRef = try XCTUnwrap(report.item(for: Fixtures.volumeID("dv-stopped-ref")))
    XCTAssertEqual(
      stoppedRef.removability.prerequisites, [Fixtures.containerID(Fixtures.exitedContainerID)])

    let anonymous = try XCTUnwrap(report.item(for: Fixtures.volumeID(Fixtures.anonymousVolumeName)))
    XCTAssertEqual(
      anonymous.removability.prerequisites, [Fixtures.containerID(Fixtures.anonContainerID)])
    XCTAssertEqual(anonymous.subtitle, "anonymous volume")
    XCTAssertTrue(anonymous.notes.contains { $0.text.contains("Anonymous volume") })

    let orphan = try XCTUnwrap(report.item(for: Fixtures.volumeID("dv-orphan-data")))
    XCTAssertTrue(orphan.removability.isRemovableNow)
    XCTAssertEqual(
      orphan.tone, .caution, "volumes hold data, so they are never presented as free wins")
    XCTAssertEqual(orphan.estimatedReclaimableBytes, 3_145_728)
    XCTAssertTrue(orphan.warnings.contains { $0.contains("permanently") })
    XCTAssertEqual(orphan.statusText, "Not mounted by any container")
  }

  func testVolumeWithInvisibleReferencesIsBlocked() {
    let volume = DockerVolume(
      name: "mystery", driver: "local", mountpoint: "", createdAt: nil, sizeBytes: nil,
      referenceCount: 2)
    let report = UsageAnalyzer.analyze(DockerDiskUsage(volumes: [volume]))
    let item = report.item(for: volume.resourceID)

    XCTAssertTrue(item?.removability.isBlocked == true)
    XCTAssertEqual(item?.statusText, "In use (2 references)")
    XCTAssertEqual(item?.attributedBytes, 0)
    XCTAssertNil(item?.totalBytes)
    XCTAssertTrue(item?.notes.contains { $0.text.contains("did not report a size") } == true)
  }

  func testComposeLabelsAreSurfaced() {
    let container = DockerContainer(
      id: "c1", names: ["/proj-db-1"], imageReference: "postgres:16", imageID: "sha256:p",
      command: "postgres",
      created: nil, state: .exited, status: "Exited (0) 2 hours ago", sizeRwBytes: 0,
      sizeRootFsBytes: 0,
      mounts: [
        DockerMount(
          type: "volume", volumeName: "proj_data", source: nil, destination: "/var/lib/postgresql",
          readWrite: true)
      ],
      labels: ["com.docker.compose.project": "proj", "com.docker.compose.service": "db"])
    let volume = DockerVolume(
      name: "proj_data", driver: "local", mountpoint: "/x", createdAt: nil,
      labels: ["com.docker.compose.project": "proj"], sizeBytes: 500, referenceCount: 1)
    let report = UsageAnalyzer.analyze(DockerDiskUsage(containers: [container], volumes: [volume]))

    let containerItem = report.item(for: container.resourceID)
    XCTAssertTrue(
      containerItem?.notes.contains { $0.text.contains("Compose project proj (service db)") }
        == true)
    let volumeItem = report.item(for: volume.resourceID)
    XCTAssertEqual(volumeItem?.subtitle, "compose: proj")
    XCTAssertEqual(volumeItem?.removability.prerequisites, [container.resourceID])
  }

  func testBuildCacheIsRemovableUnlessInUse() throws {
    let report = try Fixtures.report()
    let cache = try XCTUnwrap(report.category(for: .buildCache))

    XCTAssertEqual(cache.items.count, 10)
    XCTAssertTrue(cache.items.allSatisfy { $0.removability.isRemovableNow })
    XCTAssertEqual(cache.attributedBytes, 7_294_567)

    let shared = try XCTUnwrap(report.item(for: Fixtures.cacheID(Fixtures.sharedCacheRecordID)))
    XCTAssertEqual(shared.statusText, "Shared with other cache records")
    XCTAssertEqual(shared.subtitle, "Layer · vwsvmuey10ih")

    let inUse = BuildCacheRecord(
      id: "busy", type: "regular", recordDescription: "RUN make", inUse: true, shared: false,
      sizeBytes: 10,
      createdAt: nil, lastUsedAt: nil, usageCount: 1)
    let busyItem = UsageAnalyzer.analyze(DockerDiskUsage(buildCache: [inUse])).item(
      for: inUse.resourceID)
    XCTAssertTrue(busyItem?.removability.isBlocked == true)
    XCTAssertEqual(busyItem?.estimatedReclaimableBytes, 0)
  }

  func testTotalsAndSafeSuggestions() throws {
    let report = try Fixtures.report()

    let images = try XCTUnwrap(report.category(for: .images))
    XCTAssertEqual(
      images.attributedBytes, 16_427_111,
      "unique sizes plus the shared tile add up to Docker's LayersSize")
    XCTAssertEqual(images.removableCount, 4)
    XCTAssertEqual(images.reclaimableBytes, 600_000 + 500_000 + 1_000_000 + 10_072)
    XCTAssertEqual(report.totalAttributedBytes, 16_427_111 + 2_097_152 + 4_296_704 + 7_294_567)

    let safe = report.safeSuggestionIDs
    XCTAssertEqual(safe.count, 11)
    XCTAssertTrue(safe.contains(Fixtures.imageID(Fixtures.danglingImageID)))
    XCTAssertFalse(
      safe.contains(Fixtures.imageID(Fixtures.helloWorldImageID)),
      "tagged images are never suggested")
    XCTAssertFalse(safe.contains { $0.kind == .localVolumes || $0.kind == .containers })
  }

  func testEmptyReport() {
    XCTAssertEqual(UsageReport.empty.categories.count, 4)
    XCTAssertEqual(UsageReport.empty.itemCount, 0)
    XCTAssertEqual(UsageReport.empty.totalReclaimableBytes, 0)
  }

  func testRelativeDates() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertEqual(DateFormat.relative(now, now: now), "just now")
    XCTAssertEqual(DateFormat.relative(now.addingTimeInterval(-90), now: now), "1 minute ago")
    XCTAssertEqual(DateFormat.relative(now.addingTimeInterval(-7_200), now: now), "2 hours ago")
    XCTAssertEqual(DateFormat.relative(now.addingTimeInterval(-86_400 * 3), now: now), "3 days ago")
    XCTAssertEqual(
      DateFormat.relative(now.addingTimeInterval(-86_400 * 45), now: now), "1 month ago")
    XCTAssertEqual(
      DateFormat.relative(now.addingTimeInterval(-86_400 * 800), now: now), "2 years ago")
  }
}
