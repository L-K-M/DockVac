import DockVacCore
import Foundation
import XCTest

@testable import DockVacDocker

/// Integration tests against a real daemon. They skip when Docker is not reachable, so
/// `swift test` stays green on machines and CI runners without Docker.
final class LiveDockerTests: XCTestCase {
  private static let prefix = "dockvac-test-\(ProcessInfo.processInfo.processIdentifier)"
  private static let image = "alpine:3.20"
  private var created: [(kind: String, name: String)] = []
  private var connection: DockerConnection!

  override func setUp() async throws {
    try await super.setUp()
    let locator = DockerEndpointLocator(probeTimeout: 5)
    do {
      connection = try await locator.connect()
    } catch {
      throw XCTSkip("Docker is not reachable: \(dockerErrorMessage(error))")
    }
    guard (try? Self.docker("image", "inspect", Self.image)) != nil else {
      throw XCTSkip("\(Self.image) is not available locally")
    }
  }

  override func tearDown() async throws {
    for resource in created.reversed() {
      switch resource.kind {
      case "container": _ = try? Self.docker("rm", "-f", resource.name)
      case "volume": _ = try? Self.docker("volume", "rm", "-f", resource.name)
      default: break
      }
    }
    created.removeAll()
    try await super.tearDown()
  }

  // MARK: - Discovery and reads

  func testLocatorFindsDaemonAndVersion() throws {
    XCTAssertFalse(connection.version.version.isEmpty)
    XCTAssertFalse(connection.version.apiVersion.isEmpty)
    XCTAssertEqual(connection.ping.apiVersion, connection.version.apiVersion)
    XCTAssertTrue(connection.summary.contains(connection.version.version))
    XCTAssertTrue(FileManager.default.fileExists(atPath: connection.endpoint.socketPath))
  }

  func testScannerReportsStagesAndFindsCreatedResources() async throws {
    let volume = try makeVolume("scan")
    let container = try makeContainer("scan", volume: volume)

    let collected = ProgressCollector()
    let usage = try await DockerScanner(client: connection.client).scan { progress in
      collected.append(progress)
    }

    let stages = collected.snapshots.map { $0.stage }
    XCTAssertEqual(stages, ScanStage.allCases)
    XCTAssertEqual(collected.snapshots.map { $0.completedStages }, [0, 1, 2, 3])
    XCTAssertTrue(
      collected.snapshots.last?.partial.containers.isEmpty == false,
      "partial results accumulate between stages")

    let foundVolume = try XCTUnwrap(usage.volumes.first { $0.name == volume })
    XCTAssertEqual(foundVolume.referenceCount, 1)
    XCTAssertNotNil(foundVolume.sizeBytes)
    let foundContainer = try XCTUnwrap(usage.containers.first { $0.names.contains(container) })
    XCTAssertEqual(foundContainer.state, .created)
    XCTAssertEqual(foundContainer.volumeNames, [volume])
    XCTAssertTrue(usage.images.contains { $0.repoTags.contains(Self.image) })

    let report = UsageAnalyzer.analyze(usage)
    let volumeItem = try XCTUnwrap(report.item(for: foundVolume.resourceID))
    XCTAssertEqual(volumeItem.removability.prerequisites, [foundContainer.resourceID])
  }

  func testFullDiskUsageMatchesStagedScan() async throws {
    _ = try makeVolume("df")
    let full = try await connection.client.diskUsage()
    let staged = try await DockerScanner(client: connection.client).scan { _ in }
    XCTAssertEqual(Set(full.volumes.map { $0.name }), Set(staged.volumes.map { $0.name }))
    XCTAssertEqual(Set(full.images.map { $0.id }), Set(staged.images.map { $0.id }))
    XCTAssertEqual(full.layersSizeBytes, staged.layersSizeBytes)
    XCTAssertNotNil(staged.layersSizeBytes)
  }

  func testScanCanBeCancelled() async throws {
    let scanner = DockerScanner(client: connection.client)
    let task = Task {
      try await scanner.scan { _ in }
    }
    task.cancel()
    switch await task.result {
    case .success:
      break  // The scan finished before the cancellation was observed; acceptable.
    case .failure(let error):
      XCTAssertTrue(error is CancellationError, "unexpected \(error)")
    }
  }

  // MARK: - Removals

  func testCleanupRemovesContainerThenDependentVolume() async throws {
    let volume = try makeVolume("cleanup")
    let container = try makeContainer("cleanup", volume: volume)
    let before = UsageAnalyzer.analyze(try await connection.client.diskUsage())
    let volumeID = DockerResourceID(kind: .localVolumes, rawValue: volume)
    let containerID = try XCTUnwrap(before.usage.containers.first { $0.names.contains(container) })
      .resourceID

    let plan = CleanupPlan.make(selecting: [volumeID, containerID], from: before)
    XCTAssertEqual(
      plan.operations.map { $0.id }, [containerID, volumeID], "the container must go first")
    XCTAssertTrue(plan.exclusions.isEmpty)

    let collected = RunCollector()
    let state = await CleanupRunner(client: connection.client).run(plan) { collected.append($0) }

    XCTAssertTrue(state.isFinished)
    XCTAssertEqual(state.succeededCount, 2, "\(state.statuses)")
    XCTAssertEqual(state.statuses[0], .succeeded(detail: "Container removed."))
    XCTAssertEqual(state.statuses[1], .succeeded(detail: "Volume removed."))
    XCTAssertTrue(collected.snapshots.contains { $0.currentIndex == 0 })
    XCTAssertTrue(collected.snapshots.contains { $0.currentIndex == 1 })
    XCTAssertEqual(collected.snapshots.last, state)

    let after = try await connection.client.diskUsage()
    XCTAssertFalse(after.volumes.contains { $0.name == volume })
    XCTAssertFalse(after.containers.contains { $0.names.contains(container) })
  }

  func testCleanupReportsPartialFailureAndKeepsGoing() async throws {
    let busyVolume = try makeVolume("busy")
    let runner = try makeRunningContainer("busy", volume: busyVolume)
    let freeVolume = try makeVolume("free")

    // Build the plan by hand to simulate a volume that became busy after the scan.
    let busyID = DockerResourceID(kind: .localVolumes, rawValue: busyVolume)
    let freeID = DockerResourceID(kind: .localVolumes, rawValue: freeVolume)
    let plan = CleanupPlan(
      operations: [
        CleanupOperation(
          id: busyID, action: .removeVolume(name: busyVolume), title: "Remove volume",
          target: busyVolume, detail: "",
          estimatedReclaimableBytes: 10, warnings: [],
          cliEquivalent: "docker volume rm \(busyVolume)"),
        CleanupOperation(
          id: freeID, action: .removeVolume(name: freeVolume), title: "Remove volume",
          target: freeVolume, detail: "",
          estimatedReclaimableBytes: 20, warnings: [],
          cliEquivalent: "docker volume rm \(freeVolume)"),
      ], exclusions: [])

    let state = await CleanupRunner(client: connection.client).run(plan) { _ in }

    XCTAssertEqual(state.failedCount, 1)
    XCTAssertEqual(state.succeededCount, 1)
    guard case .failed(let message) = state.statuses[0] else {
      return XCTFail("expected failure, got \(state.statuses[0])")
    }
    XCTAssertTrue(message.contains("in use"), message)
    XCTAssertEqual(state.statuses[1], .succeeded(detail: "Volume removed."))
    XCTAssertEqual(state.estimatedFreedBytes, 20)
    XCTAssertEqual(state.summary, "Removed 1 item, about 20 B freed. 1 failed.")

    let after = try await connection.client.diskUsage()
    XCTAssertTrue(after.volumes.contains { $0.name == busyVolume }, "the busy volume must survive")
    XCTAssertTrue(after.containers.contains { $0.names.contains(runner) })
  }

  func testCleanupStopsBetweenOperationsWhenCancelled() async throws {
    let first = try makeVolume("stop1")
    let second = try makeVolume("stop2")
    let plan = CleanupPlan.make(
      selecting: [
        DockerResourceID(kind: .localVolumes, rawValue: first),
        DockerResourceID(kind: .localVolumes, rawValue: second),
      ],
      from: UsageAnalyzer.analyze(try await connection.client.diskUsage()))
    XCTAssertEqual(plan.operations.count, 2)

    let runner = CleanupRunner(client: connection.client)
    let task = Task {
      // Give the test a moment to cancel before the first operation starts.
      try? await Task.sleep(nanoseconds: 300_000_000)
      return await runner.run(plan) { _ in }
    }
    task.cancel()
    let state = await task.value

    XCTAssertTrue(state.isFinished)
    XCTAssertEqual(state.succeededCount, 0)
    XCTAssertEqual(state.skippedCount, 2)
    XCTAssertTrue(state.statuses.allSatisfy { $0 == .skipped(reason: "Stopped by user.") })
    XCTAssertEqual(state.summary, "Nothing was removed. 2 skipped.")

    let after = try await connection.client.diskUsage()
    XCTAssertTrue(after.volumes.contains { $0.name == first })
    XCTAssertTrue(after.volumes.contains { $0.name == second })
  }

  func testRemovingRunningContainerIsRefusedByDocker() async throws {
    let name = try makeRunningContainer("refuse", volume: nil)
    let usage = try await connection.client.diskUsage()
    let container = try XCTUnwrap(usage.containers.first { $0.names.contains(name) })

    let report = UsageAnalyzer.analyze(usage)
    XCTAssertTrue(report.item(for: container.resourceID)?.removability.isBlocked == true)

    do {
      try await connection.client.removeContainer(id: container.id)
      XCTFail("Docker should refuse to remove a running container without force")
    } catch let error as DockerEngineError {
      XCTAssertTrue(error.isConflict, "\(error)")
      XCTAssertTrue(error.errorDescription?.contains("running") == true)
    }
  }

  func testRemovingUnknownVolumeIsNotFound() async {
    do {
      try await connection.client.removeVolume(name: "\(Self.prefix)-does-not-exist")
      XCTFail("expected 404")
    } catch let error as DockerEngineError {
      XCTAssertTrue(error.isNotFound, "\(error)")
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  // MARK: - Helpers

  private func makeVolume(_ label: String) throws -> String {
    let name = "\(Self.prefix)-vol-\(label)"
    _ = try Self.docker("volume", "create", name)
    created.append(("volume", name))
    return name
  }

  private func makeContainer(_ label: String, volume: String?) throws -> String {
    let name = "\(Self.prefix)-ctr-\(label)"
    var arguments = ["create", "--name", name]
    if let volume {
      arguments += ["-v", "\(volume):/data"]
    }
    arguments += [Self.image, "true"]
    _ = try Self.docker(arguments)
    created.append(("container", name))
    return name
  }

  private func makeRunningContainer(_ label: String, volume: String?) throws -> String {
    let name = "\(Self.prefix)-run-\(label)"
    var arguments = ["run", "-d", "--network=none", "--name", name]
    if let volume {
      arguments += ["-v", "\(volume):/data"]
    }
    arguments += [Self.image, "sleep", "300"]
    _ = try Self.docker(arguments)
    created.append(("container", name))
    return name
  }

  @discardableResult
  private static func docker(_ arguments: String...) throws -> String {
    try docker(arguments)
  }

  @discardableResult
  private static func docker(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["docker"] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
      throw DockerCLIError.failed(arguments.joined(separator: " "), text)
    }
    return text
  }

  enum DockerCLIError: Error {
    case failed(String, String)
  }
}

/// Thread-safe accumulators for progress callbacks.
private final class ProgressCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [ScanProgress] = []
  var snapshots: [ScanProgress] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
  func append(_ progress: ScanProgress) {
    lock.lock()
    storage.append(progress)
    lock.unlock()
  }
}

private final class RunCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CleanupRunState] = []
  var snapshots: [CleanupRunState] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
  func append(_ state: CleanupRunState) {
    lock.lock()
    storage.append(state)
    lock.unlock()
  }
}
