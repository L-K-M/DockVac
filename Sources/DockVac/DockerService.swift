import DockVacCore
import DockVacDocker
import Foundation

@MainActor
protocol DockerServiceDelegate: AnyObject {
  func serviceDidConnect(_ connection: DockerConnection)
  func serviceDidReportScanProgress(_ progress: ScanProgress)
  func serviceDidFinishScan(_ result: Result<DockerDiskUsage, Error>)
  func serviceDidReportCleanupProgress(_ state: CleanupRunState)
  func serviceDidFinishCleanup(_ state: CleanupRunState)
}

/// The application service the UI talks to. It owns the background tasks and delivers
/// every result on the main actor. UI code never touches sockets or the file system.
@MainActor
final class DockerService {
  weak var delegate: DockerServiceDelegate?
  private(set) var connection: DockerConnection?
  private(set) var target: DockerConnectionTarget = .automatic
  private var scanID: UUID?
  private var scanTask: Task<Void, Never>?
  private var cleanupTask: Task<Void, Never>?
  private let connect: @Sendable (DockerConnectionTarget) async throws -> DockerConnection
  private let readUsage:
    @Sendable (DockerConnection, @escaping @Sendable (ScanProgress) -> Void) async throws ->
      DockerDiskUsage

  var isScanning: Bool { scanTask != nil }
  var isCleaning: Bool { cleanupTask != nil }

  init(
    connect: @escaping @Sendable (DockerConnectionTarget) async throws -> DockerConnection = {
      try await DockerEndpointLocator().connect(to: $0)
    },
    readUsage:
      @escaping @Sendable (DockerConnection, @escaping @Sendable (ScanProgress) -> Void)
      async throws -> DockerDiskUsage = {
        try await DockerScanner(client: $0.client).scan(onProgress: $1)
      }
  ) {
    self.connect = connect
    self.readUsage = readUsage
  }

  /// Finds the daemon and reads disk usage in stages. Cancels any scan in flight.
  func scan() {
    guard !isCleaning else { return }
    cancelScan()
    let id = UUID()
    scanID = id
    let target = self.target
    // The service lives as long as the app, so the task captures it strongly; a weak
    // capture would be a mutable binding, which @Sendable progress closures may not use.
    scanTask = Task {
      let result: Result<DockerDiskUsage, Error>
      do {
        let connection = try await self.connect(target)
        try Task.checkCancellation()
        guard self.scanID == id else { return }
        self.delegate?.serviceDidConnect(connection)
        let usage = try await self.readUsage(connection) { progress in
          Task { @MainActor in
            guard self.scanID == id else { return }
            self.delegate?.serviceDidReportScanProgress(progress)
          }
        }
        try Task.checkCancellation()
        guard self.scanID == id else { return }
        // Only a complete report authorizes cleanup on this connection.
        self.connection = connection
        result = .success(usage)
      } catch {
        result = .failure(error)
      }
      guard !Task.isCancelled, self.scanID == id else { return }
      self.scanID = nil
      self.scanTask = nil
      self.delegate?.serviceDidFinishScan(result)
    }
  }

  func cancelScan() {
    scanID = nil
    scanTask?.cancel()
    scanTask = nil
  }

  func selectTarget(_ target: DockerConnectionTarget) {
    guard !isCleaning else { return }
    cancelScan()
    connection = nil
    self.target = target
  }

  func equivalentCommands(for plan: CleanupPlan) -> String {
    connection?.equivalentScript(for: plan) ?? ""
  }

  /// Runs the plan. Stopping lets the operation in flight finish and skips the rest.
  func runCleanup(_ plan: CleanupPlan) {
    guard cleanupTask == nil, scanTask == nil, let connection else { return }
    let runner = CleanupRunner(client: connection.client)
    cleanupTask = Task {
      let state = await runner.run(plan) { state in
        Task { @MainActor in
          self.delegate?.serviceDidReportCleanupProgress(state)
        }
      }
      self.cleanupTask = nil
      self.delegate?.serviceDidFinishCleanup(state)
    }
  }

  func stopCleanup() {
    cleanupTask?.cancel()
  }
}
