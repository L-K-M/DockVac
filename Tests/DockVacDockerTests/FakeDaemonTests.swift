import DockVacCore
import Foundation
import XCTest

@testable import DockVacDocker

#if canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Darwin)
  import Darwin
#endif

/// Drives the real driver end to end against scripts/fake-docker.py, which replays the
/// captured fixtures over a unix socket. Runs wherever python3 is available.
final class FakeDaemonTests: XCTestCase {
  private var process: Process?
  private var socketPath = ""
  private var requestLogPath = ""

  /// Extra fake-docker.py flags for the test that is about to run.
  private var extraArguments: [String] {
    switch name {
    case let name where name.contains("RepointedTag"):
      return [
        "--repoint",
        "dv-app:latest=sha256:feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface",
      ]
    case let name where name.contains("PrerequisiteFails"):
      return ["--fail-delete", "/containers/2130f5d9407c"]
    default:
      return []
    }
  }

  override func setUp() async throws {
    try await super.setUp()
    let python = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
      .first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let python else {
      throw XCTSkip("python3 is not available")
    }
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = root.appendingPathComponent("scripts/fake-docker.py")
    guard FileManager.default.fileExists(atPath: script.path) else {
      throw XCTSkip("scripts/fake-docker.py not found at \(script.path)")
    }
    let token = UUID().uuidString.prefix(8)
    socketPath = NSTemporaryDirectory() + "dockvac-fake-\(token).sock"
    requestLogPath = NSTemporaryDirectory() + "dockvac-fake-\(token).log"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments =
      [script.path, "--socket", socketPath, "--request-log", requestLogPath] + extraArguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    self.process = process

    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: socketPath) {
      guard Date() < deadline, process.isRunning else {
        throw XCTSkip("fake daemon did not start")
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  override func tearDown() async throws {
    if let process, process.isRunning {
      process.terminate()
      let deadline = Date().addingTimeInterval(2)
      while process.isRunning, Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      if process.isRunning {
        // The fixture server may have inherited an ignored SIGTERM; it holds no state.
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
    }
    process = nil
    try? FileManager.default.removeItem(atPath: socketPath)
    try? FileManager.default.removeItem(atPath: requestLogPath)
    try await super.tearDown()
  }

  /// Every request the fake daemon saw, as "METHOD PATH" lines.
  private func recordedRequests() -> [String] {
    guard let text = try? String(contentsOfFile: requestLogPath, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
  }

  private func connect() async throws -> DockerConnection {
    let locator = DockerEndpointLocator(
      environment: ["DOCKER_HOST": "unix://\(socketPath)"],
      homeDirectory: NSTemporaryDirectory() + "dockvac-nohome",
      probeTimeout: 10)
    return try await locator.connect()
  }

  func testLocatorUsesDockerHostAndReadsVersion() async throws {
    let connection = try await connect()
    XCTAssertEqual(connection.endpoint.socketPath, socketPath)
    XCTAssertEqual(connection.endpoint.origin, "DOCKER_HOST")
    XCTAssertEqual(connection.version.version, "29.3.1")
    XCTAssertEqual(connection.ping.apiVersion, "1.54")
    XCTAssertEqual(connection.summary, "DOCKER_HOST · Docker Engine - Community 29.3.1")
  }

  func testScanAnalyseAndCleanupFlow() async throws {
    let connection = try await connect()
    let usage = try await DockerScanner(client: connection.client).scan { _ in }

    XCTAssertEqual(usage.images.count, 6)
    XCTAssertEqual(usage.containers.count, 5)
    XCTAssertEqual(usage.volumes.count, 5)
    XCTAssertEqual(usage.buildCache.count, 10)
    XCTAssertEqual(usage.layersSizeBytes, 16_427_111)

    let report = UsageAnalyzer.analyze(usage)
    XCTAssertEqual(report.itemCount, 27)
    XCTAssertEqual(report.safeSuggestionIDs.count, 11)

    let plan = CleanupPlan.make(selecting: report.safeSuggestionIDs, from: report)
    XCTAssertEqual(plan.operations.count, 11)
    XCTAssertTrue(plan.exclusions.isEmpty)
    XCTAssertEqual(plan.operations.first?.id.kind, .images, "the dangling image goes first")

    let state = await CleanupRunner(client: connection.client).run(plan) { _ in }
    XCTAssertTrue(state.isFinished)
    XCTAssertEqual(state.succeededCount, 11, "\(state.statuses)")
    XCTAssertEqual(state.failedCount, 0)
    XCTAssertEqual(
      state.reportedReclaimedBytes.compactMap { $0 }.count, 10,
      "build cache reports reclaimed bytes")
    XCTAssertTrue(
      state.statuses.first.map { "\($0)".contains("Untagged 1 reference, deleted 1 layer") }
        ?? false)
  }

  func testMultiReferenceImageRemovalRemovesEveryReference() async throws {
    let connection = try await connect()
    let usage = try await connection.client.diskUsage()
    let report = UsageAnalyzer.analyze(usage)
    let multiTag = report.items.first { $0.subtitle.hasSuffix("3 tags") }
    let id = try XCTUnwrap(multiTag?.id)

    let plan = CleanupPlan.make(selecting: [id], from: report)
    let state = await CleanupRunner(client: connection.client).run(plan) { _ in }
    XCTAssertEqual(
      state.statuses.first, .succeeded(detail: "Untagged 3 references, deleted 3 layers."))
    let requests = recordedRequests()
    XCTAssertTrue(
      requests.contains { $0.hasPrefix("GET /containers/json") }, "checks for containers first")
    XCTAssertEqual(
      requests.filter { $0.hasPrefix("GET /images/") && $0.hasSuffix("/json") }.count, 3)
    XCTAssertEqual(requests.filter { $0.hasPrefix("DELETE /images/") }.count, 3)
  }

  func testRepointedTagIsNeverUntagged() async throws {
    // dv-app:latest now resolves to a different image than the one that was scanned.
    let connection = try await connect()
    let report = UsageAnalyzer.analyze(try await connection.client.diskUsage())
    let id = try XCTUnwrap(report.items.first { $0.subtitle.hasSuffix("3 tags") }?.id)

    let plan = CleanupPlan.make(selecting: [id], from: report)
    let state = await CleanupRunner(client: connection.client).run(plan) { _ in }

    guard case .failed(let message) = try XCTUnwrap(state.statuses.first) else {
      return XCTFail("expected failure, got \(state.statuses)")
    }
    XCTAssertTrue(
      message.contains("dv-app:latest now points to a different image (feedfacefeed)"), message)
    XCTAssertTrue(message.contains("Removed 1 of 3 references first."), message)
    let deletes = recordedRequests().filter { $0.hasPrefix("DELETE ") }
    XCTAssertEqual(deletes.count, 1, "only the tag that still matched was removed: \(deletes)")
    XCTAssertTrue(deletes[0].hasPrefix("DELETE /images/dv-app:1.0?"), deletes[0])
  }

  func testDependentsAreSkippedWhenAPrerequisiteFails() async throws {
    // Removing container dv-exited fails, so the volume it mounts must not be attempted.
    let connection = try await connect()
    let report = UsageAnalyzer.analyze(try await connection.client.diskUsage())
    let volume = DockerResourceID(kind: .localVolumes, rawValue: "dv-stopped-ref")
    let container = try XCTUnwrap(report.item(for: volume)?.removability.prerequisites.first)
    let orphan = DockerResourceID(kind: .localVolumes, rawValue: "dv-orphan-data")

    let plan = CleanupPlan.make(selecting: [volume, container, orphan], from: report)
    XCTAssertEqual(plan.operations.map { $0.id }, [container, orphan, volume])

    let state = await CleanupRunner(client: connection.client).run(plan) { _ in }
    guard case .failed(let message) = state.statuses[0] else {
      return XCTFail("expected the container removal to fail: \(state.statuses)")
    }
    XCTAssertTrue(message.contains("simulated"), message)
    XCTAssertEqual(
      state.statuses[1], .succeeded(detail: "Volume removed."), "independent work continues")
    XCTAssertEqual(
      state.statuses[2], .skipped(reason: "Not attempted: dv-exited could not be removed first."))
    XCTAssertEqual(state.summary, "Removed 1 item, about 3.15 MB freed. 1 failed. 1 skipped.")
    let deletes = recordedRequests().filter { $0.hasPrefix("DELETE ") }
    XCTAssertFalse(deletes.contains { $0.contains("dv-stopped-ref") }, "\(deletes)")
  }
}
