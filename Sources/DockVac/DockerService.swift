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
  private var scanTask: Task<Void, Never>?
  private var cleanupTask: Task<Void, Never>?

  var isScanning: Bool { scanTask != nil }
  var isCleaning: Bool { cleanupTask != nil }

  /// Finds the daemon and reads disk usage in stages. Cancels any scan in flight.
  func scan() {
    cancelScan()
    // The service lives as long as the app, so the task captures it strongly; a weak
    // capture would be a mutable binding, which @Sendable progress closures may not use.
    scanTask = Task {
      let result: Result<DockerDiskUsage, Error>
      do {
        let connection = try await DockerEndpointLocator().connect()
        try Task.checkCancellation()
        self.connection = connection
        self.delegate?.serviceDidConnect(connection)
        let scanner = DockerScanner(client: connection.client)
        let usage = try await scanner.scan { progress in
          Task { @MainActor in
            self.delegate?.serviceDidReportScanProgress(progress)
          }
        }
        result = .success(usage)
      } catch {
        result = .failure(error)
      }
      guard !Task.isCancelled else { return }
      self.scanTask = nil
      self.delegate?.serviceDidFinishScan(result)
    }
  }

  func cancelScan() {
    scanTask?.cancel()
    scanTask = nil
  }

  /// Runs the plan. Stopping lets the operation in flight finish and skips the rest.
  func runCleanup(_ plan: CleanupPlan) {
    guard cleanupTask == nil, let connection else { return }
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
