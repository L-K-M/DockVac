import DockVacCore
import XCTest

@testable import DockVacDocker

#if canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Darwin)
  import Darwin
#endif

final class SSHHTTPClientTests: XCTestCase {
  private var markerPath = ""

  static var fakeExecutable: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("scripts/fake-ssh.py")
  }

  override func setUpWithError() throws {
    markerPath = NSTemporaryDirectory() + "dockvac-ssh-\(UUID().uuidString)"
    let searchPaths = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":")
    guard
      searchPaths.contains(where: { FileManager.default.isExecutableFile(atPath: "\($0)/python3") })
    else {
      throw XCTSkip("python3 is required for SSH subprocess tests")
    }
  }

  override func tearDownWithError() throws {
    for suffix in [".pid", ".request"] {
      try? FileManager.default.removeItem(atPath: markerPath + suffix)
    }
  }

  private func client(_ mode: String, timeout: TimeInterval = 5) throws -> SSHHTTPClient {
    SSHHTTPClient(
      host: try DockerSSHHost("ssh://\(mode)\(markerPath)"), idleTimeout: timeout,
      executable: Self.fakeExecutable)
  }

  private func assertChildExited(file: StaticString = #filePath, line: UInt = #line) throws {
    let pid = try XCTUnwrap(
      Int32(String(contentsOfFile: markerPath + ".pid", encoding: .utf8)), file: file, line: line)
    let result = kill(pid, 0)
    let error = errno
    XCTAssertEqual(result, -1, "SSH child must be reaped", file: file, line: line)
    XCTAssertEqual(error, ESRCH, file: file, line: line)
  }

  func testUsesSafeArgumentsAndQuotesTheRemoteSocket() throws {
    let host = try DockerSSHHost("ssh://deploy@[::1]:2222/tmp/docker'%20socket.sock")
    let client = SSHHTTPClient(host: host, idleTimeout: 5, executable: Self.fakeExecutable)
    XCTAssertTrue(client.arguments.contains("BatchMode=yes"))
    XCTAssertTrue(client.arguments.contains("StrictHostKeyChecking=yes"))
    XCTAssertTrue(client.arguments.contains("ClearAllForwardings=yes"))
    XCTAssertEqual(
      Array(client.arguments.suffix(7)),
      [
        "-p", "2222", "-l", "deploy", "--", "::1",
        "docker --host 'unix:///tmp/docker'\\'' socket.sock' system dial-stdio",
      ])
  }

  func testCopyableSSHCommandsPreserveTheServerSocketAndOperation() throws {
    let socketPath = markerPath + "' socket"
    defer { try? FileManager.default.removeItem(atPath: socketPath + ".commands") }
    let host = try DockerSSHHost("ssh://command-echo\(markerPath)'%20socket")
    let client = SSHHTTPClient(host: host, idleTimeout: 5, executable: Self.fakeExecutable)
    let operation = CleanupOperation(
      id: DockerResourceID(kind: .localVolumes, rawValue: "data"),
      action: .removeVolume(name: "data"),
      title: "Remove volume", target: "data", detail: "", estimatedReclaimableBytes: 0,
      warnings: [], cliEquivalent: "docker volume rm data")
    let plan = CleanupPlan(operations: [operation], exclusions: [])
    let script = client.equivalentScript(for: plan)
    guard script.hasPrefix("'\(Self.fakeExecutable.path)'") else {
      return XCTFail("The script must use the injected SSH executable")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let command = try JSONDecoder().decode(
      [String].self, from: Data(contentsOf: URL(fileURLWithPath: socketPath + ".commands")))
    XCTAssertEqual(command, ["docker", "--host", "unix://\(socketPath)", "volume", "rm", "data"])

    let local = DockerConnection(
      endpoint: DockerEndpoint(socketPath: "/tmp/docker.sock", origin: "test"),
      version: DockerEngineVersion(
        version: "29", apiVersion: "1.54", minimumAPIVersion: nil, os: "linux", arch: "amd64",
        platformName: nil),
      ping: DockerPing(apiVersion: nil, builderVersion: nil, osType: nil))
    XCTAssertEqual(
      local.equivalentScript(for: plan), "docker --host 'unix:///tmp/docker.sock' volume rm data")
  }

  func testReadsChunkedAndCloseDelimitedResponsesAndDrainsStderr() async throws {
    for mode in ["chunked", "close-delimited", "stderr-flood"] {
      let response = try await client(mode).send(HTTPRequest(method: "GET", path: "/_ping"))
      XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "OK", mode)
      let request = try String(contentsOfFile: markerPath + ".request", encoding: .utf8)
      XCTAssertTrue(request.hasPrefix("GET /_ping HTTP/1.1\r\n"))
      try assertChildExited()
    }
  }

  func testEarlyExitDuringALargeWriteReportsSSHFailureWithoutSIGPIPE() async throws {
    do {
      _ = try await client("exit-early").send(
        HTTPRequest(method: "POST", path: "/x", body: Data(repeating: 0, count: 1_000_000)))
      XCTFail("expected SSH failure")
    } catch let error as DockerEngineError {
      guard case .sshUnavailable(_, let detail) = error else {
        return XCTFail("unexpected \(error)")
      }
      XCTAssertTrue(detail.contains("Permission denied"), detail)
    }
    try assertChildExited()
  }

  func testMalformedAndTruncatedHTTPFail() async throws {
    for mode in ["malformed", "truncated"] {
      do {
        _ = try await client(mode).send(HTTPRequest(method: "GET", path: "/_ping"))
        XCTFail("expected malformed response: \(mode)")
      } catch let error as DockerEngineError {
        guard case .malformedResponse = error else { return XCTFail("unexpected \(error)") }
      }
      try assertChildExited()
    }
  }

  func testTimeoutAndCancellationKillAndReapAHangingSSHProcess() async throws {
    do {
      _ = try await client("hang", timeout: 0.5).send(HTTPRequest(method: "GET", path: "/_ping"))
      XCTFail("expected timeout")
    } catch let error as DockerEngineError {
      XCTAssertEqual(error, .timedOut(path: try client("hang").host.address))
    }
    try assertChildExited()

    let client = try client("hang", timeout: 60)
    try FileManager.default.removeItem(atPath: markerPath + ".pid")
    let task = Task { try await client.send(HTTPRequest(method: "GET", path: "/system/df")) }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: markerPath + ".pid"), Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let cancellationStarted = Date()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    XCTAssertLessThan(Date().timeIntervalSince(cancellationStarted), 5)
    try assertChildExited()
  }

  func testAlreadyCancelledTaskCannotLaunchSSH() async throws {
    let client = try client("hang")
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await client.send(HTTPRequest(method: "GET", path: "/_ping"))
    }
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath + ".pid"))
  }
}
