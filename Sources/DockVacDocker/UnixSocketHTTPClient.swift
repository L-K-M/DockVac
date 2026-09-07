import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Darwin)
  import Darwin
#endif

/// Speaks HTTP/1.1 to a unix domain socket. One connection per request.
///
/// Blocking socket I/O runs on a dedicated thread so Swift's cooperative pool is never
/// blocked. Task cancellation shuts the socket down, which unblocks the thread promptly.
public struct UnixSocketHTTPClient: Sendable {
  public let socketPath: String
  /// Maximum time to wait for the daemon to send anything at all. Disk usage queries on
  /// large installs can take minutes, so the default is generous.
  public var idleTimeout: TimeInterval

  public init(socketPath: String, idleTimeout: TimeInterval = 900) {
    self.socketPath = socketPath
    self.idleTimeout = idleTimeout
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    let connection = SocketConnection(socketPath: socketPath, idleTimeout: idleTimeout)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<HTTPResponse, Error>) in
        connection.start(request) { result in
          continuation.resume(with: result)
        }
      }
    } onCancel: {
      connection.cancel()
    }
  }
}

/// Owns one socket descriptor for the lifetime of a request. Thread-safe cancellation.
final class SocketConnection: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptor: Int32 = -1
  private var cancelled = false
  private let socketPath: String
  private let idleTimeout: TimeInterval

  init(socketPath: String, idleTimeout: TimeInterval) {
    self.socketPath = socketPath
    self.idleTimeout = idleTimeout
  }

  func start(
    _ request: HTTPRequest, completion: @escaping @Sendable (Result<HTTPResponse, Error>) -> Void
  ) {
    let thread = Thread { [self] in
      completion(Result { try self.perform(request) })
    }
    thread.name = "DockVac.UnixSocketHTTP"
    thread.start()
  }

  /// Wakes up any blocking call; the worker thread then throws `CancellationError`.
  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
    if descriptor >= 0 {
      shutdown(descriptor, Int32(SHUT_RDWR))
    }
  }

  // MARK: - Blocking implementation

  private func perform(_ request: HTTPRequest) throws -> HTTPResponse {
    #if canImport(Glibc) || canImport(Musl)
      let streamType = Int32(SOCK_STREAM.rawValue)
    #else
      let streamType = SOCK_STREAM
    #endif
    let fd = socket(AF_UNIX, streamType, 0)
    guard fd >= 0 else {
      throw DockerEngineError.socketUnavailable(path: socketPath, detail: Self.errnoDescription())
    }
    defer { closeDescriptor() }
    try register(fd)
    try connectSocket(fd)
    try writeAll(fd, request.serialized())

    var parser = HTTPResponseParser()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    var lastActivity = Date()

    while !parser.isComplete {
      try checkCancelled()
      var descriptorSet = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&descriptorSet, 1, 250)
      if ready < 0 {
        if errno == EINTR { continue }
        try checkCancelled()
        throw DockerEngineError.socketUnavailable(path: socketPath, detail: Self.errnoDescription())
      }
      if ready == 0 {
        if Date().timeIntervalSince(lastActivity) > idleTimeout {
          throw DockerEngineError.timedOut(path: socketPath)
        }
        continue
      }
      let count = read(fd, &chunk, chunk.count)
      if count > 0 {
        lastActivity = Date()
        do {
          try parser.feed(Data(chunk[0..<count]))
        } catch {
          throw DockerEngineError.malformedResponse(dockerErrorMessage(error))
        }
      } else if count == 0 {
        break
      } else {
        if errno == EINTR || errno == EAGAIN { continue }
        try checkCancelled()
        throw DockerEngineError.socketUnavailable(path: socketPath, detail: Self.errnoDescription())
      }
    }

    try checkCancelled()
    do {
      return try parser.finish()
    } catch {
      throw DockerEngineError.malformedResponse(dockerErrorMessage(error))
    }
  }

  private func register(_ fd: Int32) throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled {
      close(fd)
      throw CancellationError()
    }
    descriptor = fd
  }

  private func closeDescriptor() {
    lock.lock()
    defer { lock.unlock() }
    if descriptor >= 0 {
      close(descriptor)
      descriptor = -1
    }
  }

  private func checkCancelled() throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled {
      throw CancellationError()
    }
  }

  private func connectSocket(_ fd: Int32) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= capacity else {
      throw DockerEngineError.socketUnavailable(
        path: socketPath,
        detail: "socket path is too long (\(pathBytes.count - 1) bytes, limit \(capacity - 1))")
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        for (index, byte) in pathBytes.enumerated() {
          destination[index] = byte
        }
      }
    }
    #if canImport(Darwin)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      var noSigpipe: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    #endif

    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        connect(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if result != 0 {
      let code = errno
      try checkCancelled()
      throw DockerEngineError.socketUnavailable(
        path: socketPath, detail: Self.errnoDescription(code))
    }
  }

  private func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let base = raw.baseAddress else { return }
      var offset = 0
      while offset < raw.count {
        try checkCancelled()
        #if canImport(Darwin)
          let written = write(fd, base.advanced(by: offset), raw.count - offset)
        #else
          let written = send(fd, base.advanced(by: offset), raw.count - offset, Int32(MSG_NOSIGNAL))
        #endif
        if written < 0 {
          if errno == EINTR || errno == EAGAIN { continue }
          try checkCancelled()
          throw DockerEngineError.socketUnavailable(
            path: socketPath, detail: Self.errnoDescription())
        }
        offset += Int(written)
      }
    }
  }

  private static func errnoDescription(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
  }
}
