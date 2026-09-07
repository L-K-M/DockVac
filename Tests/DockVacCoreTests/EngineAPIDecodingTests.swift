import XCTest

@testable import DockVacCore

final class EngineAPIDecodingTests: XCTestCase {
  func testDecodesFullDiskUsageSnapshot() throws {
    let usage = try Fixtures.diskUsage()

    XCTAssertEqual(usage.images.count, 6)
    XCTAssertEqual(usage.containers.count, 5)
    XCTAssertEqual(usage.volumes.count, 5)
    XCTAssertEqual(usage.buildCache.count, 10)
    XCTAssertEqual(usage.layersSizeBytes, 16_427_111)
    XCTAssertEqual(usage.itemCount, 26)
  }

  func testDecodesImagesIncludingDanglingAndMultiTag() throws {
    let usage = try Fixtures.diskUsage()

    let dangling = try XCTUnwrap(usage.images.first { $0.id == Fixtures.danglingImageID })
    XCTAssertTrue(dangling.isDangling)
    XCTAssertEqual(dangling.repoTags, [])
    XCTAssertEqual(dangling.repoDigests, [])
    XCTAssertEqual(dangling.sizeBytes, 10_399_889)
    XCTAssertEqual(dangling.sharedSizeBytes, 9_899_889)
    XCTAssertEqual(dangling.uniqueSizeBytes, 500_000)
    XCTAssertEqual(dangling.shortID, "74700d03f0d3")
    XCTAssertEqual(dangling.displayName, "<untagged> 74700d03f0d3")
    XCTAssertTrue(dangling.canDeleteByID)
    XCTAssertEqual(dangling.labels["org.opencontainers.image.title"], "dv-app")

    let multiTag = try XCTUnwrap(usage.images.first { $0.id == Fixtures.multiTagImageID })
    XCTAssertEqual(
      multiTag.repoTags, ["dv-app:1.0", "dv-app:latest", "localhost:5000/team/dv-app:stable"])
    XCTAssertFalse(multiTag.canDeleteByID)
    XCTAssertEqual(multiTag.removalReferences, multiTag.repoTags)
    XCTAssertEqual(multiTag.displayName, "dv-app:1.0")

    let alpine = try XCTUnwrap(usage.images.first { $0.id == Fixtures.alpineImageID })
    XCTAssertEqual(alpine.containerCount, 3)
    XCTAssertEqual(alpine.repoDigests.count, 1)
    XCTAssertTrue(
      alpine.canDeleteByID, "one tag plus one digest in the same repository is a single reference")
    XCTAssertEqual(alpine.created, Date(timeIntervalSince1970: 1_776_383_606))
  }

  func testDecodesContainersWithStatesSizesAndMounts() throws {
    let usage = try Fixtures.diskUsage()

    let exited = try XCTUnwrap(usage.containers.first { $0.id == Fixtures.exitedContainerID })
    XCTAssertEqual(exited.names, ["dv-exited"])
    XCTAssertEqual(exited.displayName, "dv-exited")
    XCTAssertEqual(exited.state, .exited)
    XCTAssertFalse(exited.state.isActive)
    XCTAssertEqual(exited.sizeRwBytes, 2_097_152)
    XCTAssertEqual(exited.sizeRootFsBytes, 9_899_889)
    XCTAssertEqual(exited.volumeNames, ["dv-stopped-ref"])
    XCTAssertEqual(exited.imageID, Fixtures.alpineImageID)
    XCTAssertEqual(exited.imageReference, "alpine:3.20")

    let paused = try XCTUnwrap(usage.containers.first { $0.id == Fixtures.pausedContainerID })
    XCTAssertEqual(paused.state, .paused)
    XCTAssertTrue(paused.state.isActive)

    let created = try XCTUnwrap(usage.containers.first { $0.id == Fixtures.createdContainerID })
    XCTAssertEqual(created.state, .created)
    XCTAssertEqual(created.sizeRwBytes, 0, "SizeRw is omitted by the daemon when zero")

    let anon = try XCTUnwrap(usage.containers.first { $0.id == Fixtures.anonContainerID })
    XCTAssertEqual(anon.mounts.count, 1)
    XCTAssertEqual(anon.mounts[0].volumeName, Fixtures.anonymousVolumeName)
    XCTAssertNil(anon.mounts[0].source, "empty Source becomes nil")
    XCTAssertTrue(anon.mounts[0].readWrite)
  }

  func testDecodesVolumesWithUsageData() throws {
    let usage = try Fixtures.diskUsage()

    let orphan = try XCTUnwrap(usage.volumes.first { $0.name == "dv-orphan-data" })
    XCTAssertEqual(orphan.sizeBytes, 3_145_728)
    XCTAssertEqual(orphan.referenceCount, 0)
    XCTAssertFalse(orphan.isAnonymous)
    XCTAssertEqual(orphan.driver, "local")
    XCTAssertNotNil(orphan.createdAt)

    let anonymous = try XCTUnwrap(usage.volumes.first { $0.name == Fixtures.anonymousVolumeName })
    XCTAssertTrue(anonymous.isAnonymous)
    XCTAssertEqual(anonymous.referenceCount, 1)
    XCTAssertEqual(anonymous.sizeBytes, 102_400)
    XCTAssertEqual(anonymous.displayName, "anonymous 6951d436120a")

    let labeled = try XCTUnwrap(usage.volumes.first { $0.name == "dv-labeled-orphan" })
    XCTAssertEqual(labeled.labels["com.example.keep"], "true")
  }

  func testDecodesBuildCacheIncludingOddParentsKey() throws {
    let usage = try Fixtures.diskUsage()

    let record = try XCTUnwrap(usage.buildCache.first { $0.id == Fixtures.sharedCacheRecordID })
    XCTAssertEqual(
      record.parents, ["i2rqfgcne1s9cspra5goip21r"],
      "the daemon serialises parents under a key with a leading space")
    XCTAssertEqual(record.type, "regular")
    XCTAssertEqual(record.typeDisplayName, "Layer")
    XCTAssertTrue(record.shared)
    XCTAssertFalse(record.inUse)
    XCTAssertEqual(record.sizeBytes, 600_000)
    XCTAssertEqual(record.usageCount, 1)
    XCTAssertEqual(record.displayName, "[stage-1 3/3] COPY payload.txt /payload.txt")
    XCTAssertNotNil(record.createdAt)
    XCTAssertNotNil(record.lastUsedAt)

    let cacheMount = try XCTUnwrap(usage.buildCache.first { $0.type == "exec.cachemount" })
    XCTAssertEqual(cacheMount.typeDisplayName, "Cache mount")
    XCTAssertEqual(cacheMount.parents, [])
  }

  func testDecodesTypedDiskUsageEndpoints() throws {
    XCTAssertEqual(
      try DockerEngineDecoder.decodeImages(try Fixtures.data("system_df_image")).count, 6)
    XCTAssertEqual(
      try DockerEngineDecoder.decodeImages(try Fixtures.data("images_json_all_shared")).count, 6)
    XCTAssertEqual(
      try DockerEngineDecoder.decodeContainers(try Fixtures.data("system_df_container")).count, 5)
    XCTAssertEqual(
      try DockerEngineDecoder.decodeContainers(try Fixtures.data("containers_json_all_size")).count,
      5)
    XCTAssertEqual(
      try DockerEngineDecoder.decodeVolumes(try Fixtures.data("system_df_volume")).count, 5)
    XCTAssertEqual(
      try DockerEngineDecoder.decodeBuildCache(try Fixtures.data("system_df_build_cache")).count, 10
    )

    // `/volumes` has no UsageData; sizes are unknown rather than zero.
    let plain = try DockerEngineDecoder.decodeVolumes(try Fixtures.data("volumes"))
    XCTAssertEqual(plain.count, 5)
    XCTAssertTrue(plain.allSatisfy { $0.sizeBytes == nil && $0.referenceCount == nil })
  }

  func testDecodesVersion() throws {
    let version = try DockerEngineDecoder.decodeVersion(try Fixtures.data("version"))
    XCTAssertEqual(version.version, "29.3.1")
    XCTAssertEqual(version.apiVersion, "1.54")
    XCTAssertEqual(version.minimumAPIVersion, "1.40")
    XCTAssertEqual(version.platformName, "Docker Engine - Community")
    XCTAssertTrue(version.supportsAPI(atLeast: "1.42"))
    XCTAssertFalse(version.supportsAPI(atLeast: "1.55"))
    XCTAssertEqual(DockerEngineVersion.compareAPIVersions("1.9", "1.10"), -1)
  }

  func testDecodesErrorMessages() throws {
    XCTAssertEqual(
      DockerEngineDecoder.decodeErrorMessage(try Fixtures.data("delete_volume_404")),
      "get does-not-exist: no such volume")
    XCTAssertEqual(
      DockerEngineDecoder.decodeErrorMessage(try Fixtures.data("delete_running_container_409")),
      "cannot remove container \"dv-web\": container is running: stop the container before removing or force remove"
    )
    XCTAssertNil(DockerEngineDecoder.decodeErrorMessage(Data("not json".utf8)))
    XCTAssertNil(DockerEngineDecoder.decodeErrorMessage(Data("{\"message\":\"  \"}".utf8)))
  }

  func testDecodesDeleteAndPruneResponses() throws {
    let deletions = try DockerEngineDecoder.decodeImageDeleteResponse(
      Data("[{\"Untagged\":\"dv-app:1.0\"},{\"Deleted\":\"sha256:abc\"}]".utf8))
    XCTAssertEqual(
      deletions,
      [
        ImageDeleteItem(untagged: "dv-app:1.0", deleted: nil),
        ImageDeleteItem(untagged: nil, deleted: "sha256:abc"),
      ])

    let prune = try DockerEngineDecoder.decodeBuildPruneResponse(
      Data("{\"CachesDeleted\":[\"abc\"],\"SpaceReclaimed\":1234}".utf8))
    XCTAssertEqual(prune, BuildPruneResult(cachesDeleted: ["abc"], spaceReclaimedBytes: 1_234))

    let nothing = try DockerEngineDecoder.decodeBuildPruneResponse(
      Data("{\"CachesDeleted\":null,\"SpaceReclaimed\":0}".utf8))
    XCTAssertEqual(nothing.cachesDeleted, [])
  }

  func testRejectsMalformedAndInvalidPayloads() {
    XCTAssertThrowsError(try DockerEngineDecoder.decodeDiskUsage(Data("<html>".utf8))) { error in
      guard case DockerDecodingError.malformedJSON = error else {
        return XCTFail("unexpected error \(error)")
      }
    }
    XCTAssertThrowsError(
      try DockerEngineDecoder.decodeDiskUsage(Data("{\"Images\":[{\"Size\":5}]}".utf8))
    ) { error in
      XCTAssertEqual(error as? DockerDecodingError, .invalidResource("image without Id"))
    }
    XCTAssertThrowsError(
      try DockerEngineDecoder.decodeVolumes(Data("{\"Volumes\":[{\"Driver\":\"local\"}]}".utf8)))
    XCTAssertThrowsError(
      try DockerEngineDecoder.decodeBuildCache(Data("{\"BuildCache\":[{\"Size\":1}]}".utf8)))
    XCTAssertNotNil(DockerDecodingError.malformedJSON("x").errorDescription)
  }

  func testClampsNegativeAndInconsistentSizes() throws {
    let json = """
      {"Images":[{"Id":"sha256:a","Size":-5,"SharedSize":900,"Containers":-1}],
       "Containers":[{"Id":"c","SizeRw":50,"SizeRootFs":10,"State":"weird"}],
       "Volumes":[{"Name":"v","UsageData":{"Size":-1,"RefCount":-1}}],
       "BuildCache":[{"ID":"b","Size":-1,"UsageCount":-3}]}
      """
    let usage = try DockerEngineDecoder.decodeDiskUsage(Data(json.utf8))

    XCTAssertEqual(usage.images[0].sizeBytes, 0)
    XCTAssertEqual(usage.images[0].sharedSizeBytes, 0, "shared bytes are clamped to the total")
    XCTAssertNil(usage.images[0].containerCount)
    XCTAssertEqual(
      usage.containers[0].sizeRootFsBytes, 50,
      "root fs can never be smaller than the writable layer")
    XCTAssertEqual(usage.containers[0].state, .unknown("weird"))
    XCTAssertTrue(
      usage.containers[0].state.isActive,
      "unknown states are treated as active so nothing is removed by accident")
    XCTAssertNil(usage.volumes[0].sizeBytes)
    XCTAssertNil(usage.volumes[0].referenceCount)
    XCTAssertEqual(usage.buildCache[0].sizeBytes, 0)
    XCTAssertEqual(usage.buildCache[0].usageCount, 0)
  }

  func testParsesDockerTimestamps() {
    XCTAssertEqual(
      DockerEngineDecoder.parseDate("2026-09-07T18:17:00Z"),
      Date(timeIntervalSince1970: 1_788_805_020))
    let fractional = DockerEngineDecoder.parseDate("2026-09-07T18:17:14.281971512Z")
    XCTAssertNotNil(fractional)
    XCTAssertEqual(fractional.map { floor($0.timeIntervalSince1970) }, 1_788_805_034)
    XCTAssertNil(
      DockerEngineDecoder.parseDate("0001-01-01T00:00:00Z"), "Go's zero time means unknown")
    XCTAssertNil(DockerEngineDecoder.parseDate(""))
    XCTAssertNil(DockerEngineDecoder.parseDate("yesterday"))
  }

  func testStripsNoneSentinelsFromImageReferences() {
    let image = DockerImage(
      id: "sha256:abc", repoTags: ["<none>:<none>"], repoDigests: ["<none>@<none>"], created: nil,
      sizeBytes: 10, sharedSizeBytes: 20, containerCount: nil)
    XCTAssertTrue(image.isDangling)
    XCTAssertEqual(image.repoDigests, [])
    XCTAssertEqual(image.sharedSizeBytes, 10)
    XCTAssertEqual(image.uniqueSizeBytes, 0)
  }

  func testImageRepositoryParsing() {
    XCTAssertEqual(DockerImage.repository(of: "alpine:3.20"), "alpine")
    XCTAssertEqual(
      DockerImage.repository(of: "localhost:5000/team/app:stable"), "localhost:5000/team/app")
    XCTAssertEqual(DockerImage.repository(of: "localhost:5000/team/app"), "localhost:5000/team/app")
    XCTAssertEqual(DockerImage.repository(of: "alpine@sha256:deadbeef"), "alpine")

    let twoRepos = DockerImage(
      id: "sha256:x", repoTags: ["app:1"], repoDigests: ["other@sha256:1"], created: nil,
      sizeBytes: 1, sharedSizeBytes: 0, containerCount: nil)
    XCTAssertFalse(twoRepos.canDeleteByID)
    XCTAssertEqual(twoRepos.removalReferences, ["app:1", "other@sha256:1"])

    let digestsOnly = DockerImage(
      id: "sha256:y", repoTags: [], repoDigests: ["app@sha256:1", "app@sha256:2"], created: nil,
      sizeBytes: 1, sharedSizeBytes: 0, containerCount: nil)
    XCTAssertTrue(digestsOnly.canDeleteByID)
  }
}
