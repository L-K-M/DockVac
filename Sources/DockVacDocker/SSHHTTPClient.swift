import DockVacCore
import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Darwin)
  import Darwin
#endif

/// Carries the same Engine API bytes through OpenSSH and Docker's stdio bridge.
/// Authentication and host verification remain with the user's SSH configuration.
struct SSHHTTPClient: Sendable {
  static let executable = URL(fileURLWithPath: "/usr/bin/ssh")
  private static let connectionTimeoutSeconds = 10

  let host: DockerSSHHost
  let idleTimeout: TimeInterval
  let executable: URL

  var arguments: [String] {
    arguments(command: dockerCommand("system dial-stdio"))
  }

  func equivalentScript(for plan: CleanupPlan) -> String {
    plan.operations.map { operation in
      let command = operation.cliEquivalent.replacingOccurrences(
        of: "docker ", with: dockerCommand(""), options: .anchored)
      return ([Self.executable.path] + arguments(command: command)).map(Self.shellQuote).joined(
        separator: " ")
    }.joined(separator: "\n")
  }

  private func arguments(command: String) -> [String] {
    var arguments = [
      "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
      "-o", "ConnectTimeout=\(Self.connectionTimeoutSeconds)", "-o", "ConnectionAttempts=1",
      "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ClearAllForwardings=yes",
      "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none",
    ]
    if let port = host.port { arguments += ["-p", String(port)] }
    if let user = host.user { arguments += ["-l", user] }

    arguments += ["--", host.host, command]
    return arguments
  }

  private func dockerCommand(_ arguments: String) -> String {
    "docker --host \(Self.shellQuote("unix://\(host.socketPath)")) \(arguments)"
  }

  /// OpenSSH joins command arguments for a remote shell. Quote both that command and
  /// the outer SSH invocation when presenting a copyable cleanup script.
  private static func shellQuote(_ word: String) -> String {
    "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    let exchange = SSHExchange(
      executable: executable, arguments: arguments, address: host.address, idleTimeout: idleTimeout)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<HTTPResponse, Error>) in
        exchange.start(request) { continuation.resume(with: $0) }
      }
    } onCancel: {
      exchange.cancel()
    }
  }
}

/// One worker owns process I/O and reaping. The lock protects only cancellation and the
/// live descriptor/process, so cancellation cannot close a reused file descriptor or PID.
private final class SSHExchange: @unchecked Sendable {
  private static let bufferSize = 65_536
  private static let diagnosticLimit = 16_384
  private static let pollIntervalMilliseconds: Int32 = 100

  private let lock = NSLock()
  private var cancelled = false
  private var descriptor: Int32 = -1
  private var process: Process?
  private let executable: URL
  private let arguments: [String]
  private let address: String
  private let idleTimeout: TimeInterval

  init(executable: URL, arguments: [String], address: String, idleTimeout: TimeInterval) {
    self.executable = executable
    self.arguments = arguments
    self.address = address
    self.idleTimeout = idleTimeout
  }

  func start(
    _ request: HTTPRequest, completion: @escaping @Sendable (Result<HTTPResponse, Error>) -> Void
  ) {
    let thread = Thread { [self] in
      completion(Result { try perform(request) })
    }
    thread.name = "DockVac.SSHHTTP"
    thread.start()
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
    if descriptor >= 0 { shutdown(descriptor, Int32(SHUT_RDWR)) }
    stopProcess()
  }

  private func perform(_ request: HTTPRequest) throws -> HTTPResponse {
    try checkCancelled()
    #if canImport(Glibc) || canImport(Musl)
      let streamType = Int32(SOCK_STREAM.rawValue)
    #else
      let streamType = SOCK_STREAM
    #endif
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, streamType, 0, &descriptors) == 0 else {
      throw failure(String(cString: strerror(errno)))
    }

    let fd = descriptors[0]
    let childIO = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
    defer { try? childIO.close() }
    defer { closeDescriptor(fd) }

    // A socket pair allows SIGPIPE-safe writes, unlike a stdin pipe. Both streams are
    // polled together with stderr, preventing full-pipe deadlocks in either direction.
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
    #if canImport(Darwin)
      var noSigpipe: Int32 = 1
      guard
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
          == 0
      else {
        throw failure(String(cString: strerror(errno)))
      }
    #endif
    let diagnostics = Pipe()
    defer { try? diagnostics.fileHandleForReading.close() }
    defer { try? diagnostics.fileHandleForWriting.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = childIO
    process.standardOutput = childIO
    process.standardError = diagnostics
    try launch(process, descriptor: fd)
    defer { reap(process) }

    try? childIO.close()
    try? diagnostics.fileHandleForWriting.close()
    try makeNonblocking(fd)
    let errorFD = diagnostics.fileHandleForReading.fileDescriptor
    try makeNonblocking(errorFD)
    return try exchange(request.serialized(), fd: fd, errorFD: errorFD, process: process)
  }

  private func exchange(_ request: Data, fd: Int32, errorFD: Int32, process: Process) throws
    -> HTTPResponse
  {
    var parser = HTTPResponseParser()
    var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
    var diagnosticBytes = Data()
    var written = 0
    var outputOpen = true
    var errorsOpen = true
    var lastActivity = ProcessInfo.processInfo.systemUptime

    while !parser.isComplete && (outputOpen || errorsOpen || process.isRunning) {
      try checkCancelled()
      guard ProcessInfo.processInfo.systemUptime - lastActivity < idleTimeout else {
        throw DockerEngineError.timedOut(path: address)
      }
      let wantsWrite = written < request.count && outputOpen
      var polls = [
        pollfd(
          fd: outputOpen ? fd : -1, events: Int16(POLLIN | (wantsWrite ? POLLOUT : 0)), revents: 0),
        pollfd(fd: errorsOpen ? errorFD : -1, events: Int16(POLLIN), revents: 0),
      ]
      let ready = poll(&polls, nfds_t(polls.count), Self.pollIntervalMilliseconds)
      guard ready >= 0 else {
        if errno == EINTR { continue }
        throw failure(String(cString: strerror(errno)))
      }

      if errorsOpen && polls[1].revents != 0 {
        let count = read(errorFD, &buffer, buffer.count)
        if count > 0 {
          diagnosticBytes.append(
            contentsOf: buffer.prefix(min(count, Self.diagnosticLimit - diagnosticBytes.count)))
        } else if count == 0 {
          errorsOpen = false
        } else if errno != EINTR && errno != EAGAIN {
          throw failure(String(cString: strerror(errno)))
        }
      }

      if wantsWrite && polls[0].revents & Int16(POLLOUT) != 0 {
        let count = request.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
          #if canImport(Darwin)
            send(
              fd, bytes.baseAddress!.advanced(by: written),
              min(request.count - written, Self.bufferSize), 0)
          #else
            send(
              fd, bytes.baseAddress!.advanced(by: written),
              min(request.count - written, Self.bufferSize), Int32(MSG_NOSIGNAL))
          #endif
        }
        if count > 0 {
          written += count
          if written == request.count { shutdown(fd, Int32(SHUT_WR)) }
        } else if count < 0 && errno != EINTR && errno != EAGAIN {
          // Read the remaining stderr before reporting an early SSH exit.
          written = request.count
          shutdown(fd, Int32(SHUT_WR))
        }
      }

      guard outputOpen, polls[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 else { continue }
      let count = read(fd, &buffer, buffer.count)
      if count > 0 {
        lastActivity = ProcessInfo.processInfo.systemUptime
        do {
          try parser.feed(Data(buffer.prefix(count)))
        } catch {
          throw DockerEngineError.malformedResponse(dockerErrorMessage(error))
        }
      } else if count == 0 || (count < 0 && errno == ECONNRESET) {
        outputOpen = false
      } else if errno != EINTR && errno != EAGAIN {
        try checkCancelled()
        throw failure(String(cString: strerror(errno)))
      }
    }

    try checkCancelled()
    if !parser.isComplete {
      // EOF is meaningful for close-delimited HTTP only after a successful SSH exit.
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        let detail =
          diagnosticBytes.isEmpty
          ? "ssh exited with status \(process.terminationStatus)."
          : String(decoding: diagnosticBytes, as: UTF8.self)
        throw failure(detail)
      }
    }
    do {
      return try parser.finish()
    } catch {
      throw DockerEngineError.malformedResponse(dockerErrorMessage(error))
    }
  }

  private func launch(_ process: Process, descriptor: Int32) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { throw CancellationError() }
    do {
      try process.run()
    } catch {
      throw failure(dockerErrorMessage(error))
    }
    self.descriptor = descriptor
    self.process = process
  }

  private func reap(_ process: Process) {
    lock.lock()
    stopProcess()
    self.process = nil
    lock.unlock()
    process.waitUntilExit()
  }

  /// SIGKILL bounds teardown even if SSH inherited an ignored SIGTERM. Cleanup requests
  /// run in the runner's detached task, so Stop never reaches this cancellation path.
  private func stopProcess() {
    if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }

  private func closeDescriptor(_ fd: Int32) {
    lock.lock()
    defer { lock.unlock() }
    close(fd)
    descriptor = -1
  }

  private func checkCancelled() throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
  }

  private func makeNonblocking(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw failure(String(cString: strerror(errno)))
    }
  }

  private func failure(_ detail: String) -> DockerEngineError {
    .sshUnavailable(
      host: address,
      detail: detail.isEmpty ? "The SSH bridge closed before Docker answered." : detail)
  }
}
