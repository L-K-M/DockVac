import Foundation

/// A minimal HTTP/1.1 request for the Docker Engine API.
public struct HTTPRequest: Hashable, Sendable {
  public var method: String
  public var path: String
  public var body: Data?
  public var contentType: String?

  public init(method: String, path: String, body: Data? = nil, contentType: String? = nil) {
    self.method = method
    self.path = path
    self.body = body
    self.contentType = contentType
  }

  /// Wire bytes. `Connection: close` keeps the exchange to one request per socket, so the
  /// end of the response is unambiguous even for servers that stream.
  public func serialized() -> Data {
    var head = "\(method) \(path) HTTP/1.1\r\n"
    head += "Host: docker\r\n"
    head += "User-Agent: DockVac\r\n"
    head += "Accept: application/json\r\n"
    head += "Connection: close\r\n"
    if let body {
      head += "Content-Type: \(contentType ?? "application/json")\r\n"
      head += "Content-Length: \(body.count)\r\n"
    } else if method == "POST" || method == "PUT" {
      head += "Content-Length: 0\r\n"
    }
    head += "\r\n"
    var data = Data(head.utf8)
    if let body {
      data.append(body)
    }
    return data
  }
}

public struct HTTPResponse: Hashable, Sendable {
  public let statusCode: Int
  public let reasonPhrase: String
  /// Header names are lowercased; repeated headers are joined with ", ".
  public let headers: [String: String]
  public let body: Data

  public init(statusCode: Int, reasonPhrase: String, headers: [String: String], body: Data) {
    self.statusCode = statusCode
    self.reasonPhrase = reasonPhrase
    self.headers = headers
    self.body = body
  }

  public func header(_ name: String) -> String? {
    headers[name.lowercased()]
  }

  public var isSuccess: Bool {
    (200..<300).contains(statusCode)
  }
}

/// Incremental HTTP/1.1 response parser supporting Content-Length, chunked transfer
/// encoding, and read-until-close bodies.
public struct HTTPResponseParser: Sendable {
  private enum Phase: Equatable {
    case head
    case fixedBody(remaining: Int)
    case chunkedBody
    case untilClose
    case complete
  }

  private static let crlf = Data("\r\n".utf8)
  private static let headTerminator = Data("\r\n\r\n".utf8)
  private static let maximumHeadSize = 256 * 1024
  private static let maximumBodySize = 512 * 1024 * 1024

  private var buffer = Data()
  private var phase = Phase.head
  private var chunkRemaining: Int?
  private var statusCode = 0
  private var reasonPhrase = ""
  private var headers: [String: String] = [:]
  private var body = Data()

  public init() {}

  public var isComplete: Bool {
    phase == .complete
  }

  /// Consumes more bytes from the socket.
  public mutating func feed(_ data: Data) throws {
    guard !data.isEmpty else { return }
    buffer.append(data)
    try process()
  }

  /// Call once the peer closed the connection.
  public mutating func finish() throws -> HTTPResponse {
    switch phase {
    case .complete:
      break
    case .untilClose:
      phase = .complete
    case .head:
      throw HTTPParseError.incomplete("connection closed before any response arrived")
    case .fixedBody(let remaining):
      throw HTTPParseError.incomplete("connection closed with \(remaining) body bytes outstanding")
    case .chunkedBody:
      throw HTTPParseError.incomplete("connection closed inside a chunked body")
    }
    return HTTPResponse(
      statusCode: statusCode, reasonPhrase: reasonPhrase, headers: headers, body: body)
  }

  // MARK: - Parsing

  private mutating func process() throws {
    while true {
      switch phase {
      case .head:
        guard let terminator = buffer.range(of: Self.headTerminator) else {
          if buffer.count > Self.maximumHeadSize {
            throw HTTPParseError.malformed("response headers exceed \(Self.maximumHeadSize) bytes")
          }
          return
        }
        let head = buffer[buffer.startIndex..<terminator.lowerBound]
        buffer = Data(buffer[terminator.upperBound...])
        try parseHead(head)
        if (100..<200).contains(statusCode) {
          // Informational responses precede the real one; keep parsing.
          headers = [:]
          continue
        }
        if statusCode == 204 || statusCode == 304 {
          phase = .complete
        } else if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
          phase = .chunkedBody
          chunkRemaining = nil
        } else if let lengthText = headers["content-length"] {
          guard let length = Int(lengthText.trimmingCharacters(in: .whitespaces)), length >= 0
          else {
            throw HTTPParseError.malformed("invalid Content-Length \(lengthText)")
          }
          guard length <= Self.maximumBodySize else {
            throw HTTPParseError.malformed("body of \(length) bytes is too large")
          }
          phase = length == 0 ? .complete : .fixedBody(remaining: length)
        } else {
          phase = .untilClose
        }

      case .fixedBody(let remaining):
        let take = min(remaining, buffer.count)
        guard take > 0 else { return }
        body.append(buffer[buffer.startIndex..<buffer.startIndex + take])
        buffer = Data(buffer[(buffer.startIndex + take)...])
        if remaining - take == 0 {
          phase = .complete
        } else {
          phase = .fixedBody(remaining: remaining - take)
          return
        }

      case .chunkedBody:
        if try !consumeChunk() {
          return
        }

      case .untilClose:
        body.append(buffer)
        buffer.removeAll()
        try enforceBodyLimit()
        return

      case .complete:
        return
      }
    }
  }

  private mutating func parseHead(_ head: Data) throws {
    let text = String(decoding: head, as: UTF8.self)
    var lines = text.components(separatedBy: "\r\n")
    guard !lines.isEmpty else {
      throw HTTPParseError.malformed("empty status line")
    }
    let statusLine = lines.removeFirst()
    let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]),
      (100..<600).contains(code)
    else {
      throw HTTPParseError.malformed("unexpected status line \"\(statusLine)\"")
    }
    statusCode = code
    reasonPhrase = parts.count == 3 ? String(parts[2]) : ""

    var parsed: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else {
        throw HTTPParseError.malformed("header line without colon: \(line)")
      }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if let existing = parsed[name] {
        parsed[name] = existing + ", " + value
      } else {
        parsed[name] = value
      }
    }
    headers = parsed
  }

  /// Returns false when more bytes are needed.
  private mutating func consumeChunk() throws -> Bool {
    if let remaining = chunkRemaining {
      if remaining == 0 {
        // Trailer section: header lines until an empty line.
        guard let lineEnd = buffer.range(of: Self.crlf) else {
          return false
        }
        let line = buffer[buffer.startIndex..<lineEnd.lowerBound]
        buffer = Data(buffer[lineEnd.upperBound...])
        if line.isEmpty {
          phase = .complete
        }
        return true
      }
      guard buffer.count >= remaining + 2 else {
        return false
      }
      let chunkEnd = buffer.startIndex + remaining
      body.append(buffer[buffer.startIndex..<chunkEnd])
      guard buffer[chunkEnd] == 0x0D, buffer[chunkEnd + 1] == 0x0A else {
        throw HTTPParseError.malformed("chunk data not followed by CRLF")
      }
      buffer = Data(buffer[(chunkEnd + 2)...])
      chunkRemaining = nil
      try enforceBodyLimit()
      return true
    }

    guard let lineEnd = buffer.range(of: Self.crlf) else {
      if buffer.count > 1_024 {
        throw HTTPParseError.malformed("chunk size line too long")
      }
      return false
    }
    let line = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
    buffer = Data(buffer[lineEnd.upperBound...])
    let sizeText =
      line.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
      ?? ""
    guard let size = Int(sizeText, radix: 16), size >= 0 else {
      throw HTTPParseError.malformed("invalid chunk size \"\(line)\"")
    }
    chunkRemaining = size
    return true
  }

  private func enforceBodyLimit() throws {
    if body.count > Self.maximumBodySize {
      throw HTTPParseError.malformed("body exceeds \(Self.maximumBodySize) bytes")
    }
  }
}

public enum HTTPParseError: Error, Hashable, Sendable, LocalizedError {
  case malformed(String)
  case incomplete(String)

  public var errorDescription: String? {
    switch self {
    case .malformed(let detail): return detail
    case .incomplete(let detail): return detail
    }
  }
}
