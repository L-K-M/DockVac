import XCTest

@testable import DockVacDocker

final class HTTPMessageTests: XCTestCase {
  func testSerializesRequestsWithConnectionClose() {
    let get = String(
      decoding: HTTPRequest(method: "GET", path: "/_ping").serialized(), as: UTF8.self)
    XCTAssertTrue(get.hasPrefix("GET /_ping HTTP/1.1\r\n"))
    XCTAssertTrue(get.contains("\r\nConnection: close\r\n"))
    XCTAssertTrue(get.contains("\r\nHost: docker\r\n"))
    XCTAssertTrue(get.hasSuffix("\r\n\r\n"))
    XCTAssertFalse(get.contains("Content-Length"))

    let post = String(
      decoding: HTTPRequest(method: "POST", path: "/build/prune").serialized(), as: UTF8.self)
    XCTAssertTrue(post.contains("\r\nContent-Length: 0\r\n"))

    let body = Data("{\"a\":1}".utf8)
    let withBody = HTTPRequest(method: "POST", path: "/x", body: body).serialized()
    let text = String(decoding: withBody, as: UTF8.self)
    XCTAssertTrue(text.contains("\r\nContent-Type: application/json\r\n"))
    XCTAssertTrue(text.contains("\r\nContent-Length: 7\r\n"))
    XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"a\":1}"))
  }

  func testParsesContentLengthBody() throws {
    var parser = HTTPResponseParser()
    try parser.feed(
      Data(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nApi-Version: 1.54\r\nContent-Length: 5\r\n\r\nhel"
          .utf8))
    XCTAssertFalse(parser.isComplete)
    try parser.feed(Data("lo".utf8))
    XCTAssertTrue(parser.isComplete)

    let response = try parser.finish()
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(response.reasonPhrase, "OK")
    XCTAssertEqual(response.header("api-version"), "1.54")
    XCTAssertEqual(response.header("Api-Version"), "1.54")
    XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "hello")
    XCTAssertTrue(response.isSuccess)
  }

  func testParsesChunkedBodyFedByteByByte() throws {
    let raw =
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;ext=1\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nExpires: soon\r\n\r\n"
    var parser = HTTPResponseParser()
    for byte in raw.utf8 {
      try parser.feed(Data([byte]))
    }
    XCTAssertTrue(parser.isComplete)
    let response = try parser.finish()
    XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "Wikipedia in\r\n\r\nchunks.")
  }

  func testChunkedBodyInOneGo() throws {
    var parser = HTTPResponseParser()
    try parser.feed(
      Data(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\ntrailing garbage ignored"
          .utf8))
    XCTAssertTrue(parser.isComplete)
    XCTAssertEqual(String(decoding: try parser.finish().body, as: UTF8.self), "abc")
  }

  func testNoContentCompletesImmediately() throws {
    var parser = HTTPResponseParser()
    try parser.feed(Data("HTTP/1.1 204 No Content\r\nApi-Version: 1.54\r\n\r\n".utf8))
    XCTAssertTrue(parser.isComplete)
    let response = try parser.finish()
    XCTAssertEqual(response.statusCode, 204)
    XCTAssertTrue(response.body.isEmpty)
  }

  func testReadsUntilCloseWithoutLengthHeaders() throws {
    var parser = HTTPResponseParser()
    try parser.feed(Data("HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nstream".utf8))
    XCTAssertFalse(parser.isComplete)
    try parser.feed(Data("ing".utf8))
    let response = try parser.finish()
    XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "streaming")
  }

  func testSkipsInformationalResponses() throws {
    var parser = HTTPResponseParser()
    try parser.feed(
      Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 409 Conflict\r\nContent-Length: 2\r\n\r\n{}".utf8)
    )
    let response = try parser.finish()
    XCTAssertEqual(response.statusCode, 409)
    XCTAssertEqual(response.reasonPhrase, "Conflict")
    XCTAssertEqual(response.body, Data("{}".utf8))
  }

  func testJoinsDuplicateHeaders() throws {
    var parser = HTTPResponseParser()
    try parser.feed(Data("HTTP/1.1 200 OK\r\nX-A: 1\r\nx-a: 2\r\nContent-Length: 0\r\n\r\n".utf8))
    XCTAssertEqual(try parser.finish().header("X-A"), "1, 2")
  }

  func testRejectsMalformedInput() {
    var parser = HTTPResponseParser()
    XCTAssertThrowsError(try parser.feed(Data("NOPE\r\n\r\n".utf8)))

    var badLength = HTTPResponseParser()
    XCTAssertThrowsError(
      try badLength.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\n".utf8)))

    var badChunk = HTTPResponseParser()
    XCTAssertThrowsError(
      try badChunk.feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".utf8)))

    var badChunkEnd = HTTPResponseParser()
    XCTAssertThrowsError(
      try badChunkEnd.feed(
        Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nabXX".utf8)))

    var noColon = HTTPResponseParser()
    XCTAssertThrowsError(try noColon.feed(Data("HTTP/1.1 200 OK\r\nbroken header\r\n\r\n".utf8)))
  }

  func testRejectsChunkSizesThatWouldOverflowOrExhaustMemory() throws {
    // Int.max as a chunk size used to overflow `remaining + 2` and trap the whole app.
    var overflowing = HTTPResponseParser()
    XCTAssertThrowsError(
      try overflowing.feed(
        Data(
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\nabc".utf8))
    ) { error in
      guard case HTTPParseError.malformed(let detail) = error else {
        return XCTFail("unexpected \(error)")
      }
      XCTAssertTrue(detail.contains("exceeds the body limit"), detail)
    }

    // A merely huge chunk is refused before it is buffered, too.
    var huge = HTTPResponseParser()
    XCTAssertThrowsError(
      try huge.feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffff\r\n".utf8)))

    // A chunk within the limit still parses.
    var fine = HTTPResponseParser()
    try fine.feed(
      Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n".utf8))
    XCTAssertEqual(String(decoding: try fine.finish().body, as: UTF8.self), "abc")
  }

  func testFinishRejectsTruncatedResponses() throws {
    var empty = HTTPResponseParser()
    XCTAssertThrowsError(try empty.finish()) { error in
      guard case HTTPParseError.incomplete = error else { return XCTFail("unexpected \(error)") }
    }

    var truncated = HTTPResponseParser()
    try truncated.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8))
    XCTAssertThrowsError(try truncated.finish())

    var chunked = HTTPResponseParser()
    try chunked.feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab".utf8))
    XCTAssertThrowsError(try chunked.finish())
    XCTAssertNotNil(HTTPParseError.malformed("x").errorDescription)
  }
}
