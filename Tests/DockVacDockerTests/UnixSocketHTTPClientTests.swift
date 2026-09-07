import XCTest

@testable import DockVacDocker

final class UnixSocketHTTPClientTests: XCTestCase {
  func testRoundTripsAChunkedResponse() async throws {
    let payload =
      "HTTP/1.1 200 OK\r\nApi-Version: 1.54\r\nTransfer-Encoding: chunked\r\n\r\n7\r\n{\"a\":1}\r\n0\r\n\r\n"
    let server = try FakeUnixSocketServer(behaviour: .respond(Data(payload.utf8)))
    defer { server.stop() }

    let client = UnixSocketHTTPClient(socketPath: server.socketPath, idleTimeout: 5)
    let response = try await client.send(HTTPRequest(method: "GET", path: "/system/df?type=image"))

    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(response.header("Api-Version"), "1.54")
    XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "{\"a\":1}")

    let request = String(decoding: try XCTUnwrap(server.requests.first), as: UTF8.self)
    XCTAssertTrue(request.hasPrefix("GET /system/df?type=image HTTP/1.1\r\n"))
    XCTAssertTrue(request.contains("Connection: close"))
  }

  func testReadsBodiesThatEndWhenTheServerCloses() async throws {
    let payload = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\n\r\nboom"
    let server = try FakeUnixSocketServer(behaviour: .respond(Data(payload.utf8)))
    defer { server.stop() }

    let response = try await UnixSocketHTTPClient(socketPath: server.socketPath, idleTimeout: 5)
      .send(HTTPRequest(method: "GET", path: "/x"))
    XCTAssertEqual(response.statusCode, 500)
    XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "boom")
    XCTAssertFalse(response.isSuccess)
  }

  func testMissingSocketFailsFast() async {
    let client = UnixSocketHTTPClient(
      socketPath: NSTemporaryDirectory() + "dockvac-missing-\(UUID().uuidString).sock",
      idleTimeout: 5)
    do {
      _ = try await client.send(HTTPRequest(method: "GET", path: "/_ping"))
      XCTFail("expected failure")
    } catch let error as DockerEngineError {
      guard case .socketUnavailable(let path, let detail) = error else {
        return XCTFail("unexpected \(error)")
      }
      XCTAssertEqual(path, client.socketPath)
      XCTAssertFalse(detail.isEmpty)
      XCTAssertTrue(error.errorDescription?.contains("Could not connect") == true)
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testOverlongSocketPathIsRejected() async {
    let client = UnixSocketHTTPClient(
      socketPath: "/tmp/" + String(repeating: "x", count: 300), idleTimeout: 5)
    do {
      _ = try await client.send(HTTPRequest(method: "GET", path: "/_ping"))
      XCTFail("expected failure")
    } catch let error as DockerEngineError {
      guard case .socketUnavailable(_, let detail) = error else {
        return XCTFail("unexpected \(error)")
      }
      XCTAssertTrue(detail.contains("too long"))
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testIdleTimeoutFiresWhenTheServerNeverAnswers() async throws {
    let server = try FakeUnixSocketServer(behaviour: .hang)
    defer { server.stop() }

    let client = UnixSocketHTTPClient(socketPath: server.socketPath, idleTimeout: 0.6)
    let started = Date()
    do {
      _ = try await client.send(HTTPRequest(method: "GET", path: "/_ping"))
      XCTFail("expected timeout")
    } catch let error as DockerEngineError {
      XCTAssertEqual(error, .timedOut(path: server.socketPath))
      XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testCancellationUnblocksAHangingRequest() async throws {
    let server = try FakeUnixSocketServer(behaviour: .hang)
    defer { server.stop() }

    let client = UnixSocketHTTPClient(socketPath: server.socketPath, idleTimeout: 60)
    let task = Task {
      try await client.send(HTTPRequest(method: "GET", path: "/system/df"))
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    let started = Date()
    task.cancel()

    let result = await task.result
    XCTAssertLessThan(
      Date().timeIntervalSince(started), 5, "cancellation must not wait for the idle timeout")
    switch result {
    case .success:
      XCTFail("a hanging request cannot succeed")
    case .failure(let error):
      XCTAssertTrue(error is CancellationError, "unexpected \(error)")
    }
  }

  func testMalformedResponsesAreReported() async throws {
    let server = try FakeUnixSocketServer(behaviour: .respond(Data("garbage\r\n\r\n".utf8)))
    defer { server.stop() }

    do {
      _ = try await UnixSocketHTTPClient(socketPath: server.socketPath, idleTimeout: 5).send(
        HTTPRequest(method: "GET", path: "/"))
      XCTFail("expected failure")
    } catch let error as DockerEngineError {
      guard case .malformedResponse(let detail) = error else {
        return XCTFail("unexpected \(error)")
      }
      XCTAssertTrue(detail.contains("status line"))
    }
  }

  func testEngineClientMapsHTTPErrorsToDockerMessages() async throws {
    let body = "{\"message\":\"remove dv-used-data: volume is in use - [a1b3]\"}"
    let payload =
      "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    let server = try FakeUnixSocketServer(behaviour: .respond(Data(payload.utf8)))
    defer { server.stop() }

    let client = DockerEngineClient(
      endpoint: DockerEndpoint(socketPath: server.socketPath, origin: "test"), idleTimeout: 5)
    do {
      try await client.removeVolume(name: "dv-used-data")
      XCTFail("expected conflict")
    } catch let error as DockerEngineError {
      XCTAssertEqual(
        error, .api(status: 409, message: "remove dv-used-data: volume is in use - [a1b3]"))
      XCTAssertTrue(error.isConflict)
      XCTAssertFalse(error.isNotFound)
      XCTAssertEqual(error.errorDescription, "remove dv-used-data: volume is in use - [a1b3]")
    }

    let request = String(decoding: try XCTUnwrap(server.requests.first), as: UTF8.self)
    XCTAssertTrue(request.hasPrefix("DELETE /volumes/dv-used-data?force=0 HTTP/1.1\r\n"), request)
  }

  func testEngineClientEncodesReferencesAndFilters() async throws {
    let payload = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n[]"
    let server = try FakeUnixSocketServer(behaviour: .respond(Data(payload.utf8)))
    defer { server.stop() }

    let client = DockerEngineClient(
      endpoint: DockerEndpoint(socketPath: server.socketPath, origin: "test"), idleTimeout: 5)
    _ = try await client.removeImage(reference: "localhost:5000/team/dv-app:stable")
    let request = String(decoding: try XCTUnwrap(server.requests.first), as: UTF8.self)
    XCTAssertTrue(
      request.hasPrefix(
        "DELETE /images/localhost:5000/team/dv-app:stable?force=0&noprune=0 HTTP/1.1\r\n"), request)

    let pruneServer = try FakeUnixSocketServer(
      behaviour: .respond(
        Data(
          "HTTP/1.1 200 OK\r\nContent-Length: 45\r\n\r\n{\"CachesDeleted\":[\"abc\"],\"SpaceReclaimed\":12}"
            .utf8)))
    defer { pruneServer.stop() }
    let pruneClient = DockerEngineClient(
      endpoint: DockerEndpoint(socketPath: pruneServer.socketPath, origin: "test"), idleTimeout: 5)
    let result = try await pruneClient.pruneBuildCache(id: "abc")
    XCTAssertEqual(result.cachesDeleted, ["abc"])
    XCTAssertEqual(result.spaceReclaimedBytes, 12)
    let pruneRequest = String(decoding: try XCTUnwrap(pruneServer.requests.first), as: UTF8.self)
    XCTAssertTrue(
      pruneRequest.hasPrefix(
        "POST /build/prune?filters=%7B%22id%22%3A%5B%22abc%22%5D%7D HTTP/1.1\r\n"), pruneRequest)
  }

  func testEngineClientReportsDecodingProblems() async throws {
    let payload =
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\nnull"
    let server = try FakeUnixSocketServer(behaviour: .respond(Data(payload.utf8)))
    defer { server.stop() }

    let client = DockerEngineClient(
      endpoint: DockerEndpoint(socketPath: server.socketPath, origin: "test"), idleTimeout: 5)
    do {
      _ = try await client.version()
      XCTFail("expected decoding failure")
    } catch let error as DockerEngineError {
      guard case .decoding = error else { return XCTFail("unexpected \(error)") }
      XCTAssertNotNil(error.errorDescription)
    }
  }

  func testErrorMessages() {
    XCTAssertEqual(dockerErrorMessage(CancellationError()), "Cancelled.")
    XCTAssertEqual(
      dockerErrorMessage(DockerEngineError.api(status: 500, message: "")),
      "Docker returned HTTP 500.")
    let notFound = DockerEngineError.daemonNotFound(
      attempts: ["/a: nope"], unsupported: ["DOCKER_HOST=tcp://x"])
    XCTAssertTrue(notFound.errorDescription?.contains("Tried: /a: nope") == true)
    XCTAssertTrue(notFound.errorDescription?.contains("tcp://x") == true)
    XCTAssertEqual(
      DockerEngineError.timedOut(path: "/s").errorDescription,
      "Docker at /s did not answer in time.")
  }
}
