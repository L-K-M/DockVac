import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Darwin)
  import Darwin
#endif

/// A tiny unix-socket server for exercising the HTTP client without Docker.
final class FakeUnixSocketServer: @unchecked Sendable {
  enum Behaviour {
    /// Read the request, then write these bytes and close.
    case respond(Data, delay: TimeInterval = 0)
    /// Accept the connection and never answer.
    case hang
  }

  let socketPath: String
  private let behaviour: Behaviour
  private var listener: Int32 = -1
  private var thread: Thread?
  private let lock = NSLock()
  private var receivedRequests: [Data] = []

  init(behaviour: Behaviour) throws {
    self.behaviour = behaviour
    socketPath = NSTemporaryDirectory() + "dockvac-test-" + UUID().uuidString.prefix(8) + ".sock"
    try listen()
  }

  var requests: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return receivedRequests
  }

  func stop() {
    if listener >= 0 {
      shutdown(listener, Int32(SHUT_RDWR))
      close(listener)
      listener = -1
    }
    unlink(socketPath)
  }

  private func listen() throws {
    #if canImport(Glibc) || canImport(Musl)
      let streamType = Int32(SOCK_STREAM.rawValue)
    #else
      let streamType = SOCK_STREAM
    #endif
    listener = socket(AF_UNIX, streamType, 0)
    guard listener >= 0 else { throw ServerError.failed("socket") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = socketPath.utf8CString
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= capacity else { throw ServerError.failed("path too long") }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        for (index, byte) in bytes.enumerated() {
          destination[index] = byte
        }
      }
    }
    #if canImport(Darwin)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        bind(listener, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else { throw ServerError.failed("bind: \(String(cString: strerror(errno)))") }
    #if canImport(Glibc) || canImport(Musl)
      guard Glibc.listen(listener, 4) == 0 else { throw ServerError.failed("listen") }
    #else
      guard Darwin.listen(listener, 4) == 0 else { throw ServerError.failed("listen") }
    #endif

    let thread = Thread { [self] in self.serve() }
    thread.start()
    self.thread = thread
  }

  private func serve() {
    while true {
      let client = accept(listener, nil, nil)
      guard client >= 0 else { return }
      switch behaviour {
      case .hang:
        // Keep the descriptor open until the process exits; the client must time out or cancel.
        continue
      case .respond(let data, let delay):
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var request = Data()
        while true {
          let count = read(client, &buffer, buffer.count)
          guard count > 0 else { break }
          request.append(contentsOf: buffer[0..<count])
          if request.range(of: Data("\r\n\r\n".utf8)) != nil {
            break
          }
        }
        lock.lock()
        receivedRequests.append(request)
        lock.unlock()
        if delay > 0 {
          Thread.sleep(forTimeInterval: delay)
        }
        data.withUnsafeBytes { raw in
          var offset = 0
          while offset < raw.count, let base = raw.baseAddress {
            let written = write(client, base.advanced(by: offset), raw.count - offset)
            if written <= 0 { break }
            offset += Int(written)
          }
        }
        close(client)
      }
    }
  }

  enum ServerError: Error {
    case failed(String)
  }
}
