import DockVacCore
import DockVacDocker
import XCTest

@testable import DockVac

final class DockerServiceTests: XCTestCase {
  @MainActor
  func testChangingServersRejectsOldScanResultsAndProgress() async throws {
    let gate = ScanGate()
    let service = DockerService(
      connect: Self.connect, readUsage: { try await gate.scan($0, progress: $1) })
    let delegate = ServiceRecorder()
    service.delegate = delegate
    service.selectTarget(.ssh(try DockerSSHHost("first")))
    service.scan()
    try await gate.waitForScan("first")
    XCTAssertNil(service.connection, "An incomplete scan cannot authorize cleanup")

    service.selectTarget(.ssh(try DockerSSHHost("second")))
    service.scan()
    try await gate.waitForScan("second")
    await gate.finish("first")
    await gate.finish("second")
    try await waitForCompletion(service)

    XCTAssertEqual(service.connection?.endpoint.address, "ssh://second")
    XCTAssertEqual(delegate.finishedScans, 1)
    XCTAssertFalse(delegate.progressDates.contains(ScanGate.staleProgressDate))
  }

  @MainActor
  func testCancelledRescanKeepsTheConnectionOfTheDisplayedReport() async throws {
    let gate = ScanGate()
    let service = DockerService(
      connect: Self.connect, readUsage: { try await gate.scan($0, progress: $1) })
    service.selectTarget(.ssh(try DockerSSHHost("first")))
    service.scan()
    try await gate.waitForScan("first")
    await gate.finish("first")
    try await waitForCompletion(service)
    let completedConnection = service.connection

    service.scan()
    try await gate.waitForScan("first")
    service.cancelScan()
    await gate.finish("first")
    XCTAssertEqual(service.connection, completedConnection)

    service.selectTarget(.ssh(try DockerSSHHost("second")))
    XCTAssertNil(service.connection, "Changing servers invalidates cleanup authorization")
  }

  @MainActor
  func testCleanupLocksTheTargetAndRejectsScans() async throws {
    let service = DockerService(connect: Self.connect, readUsage: { _, _ in DockerDiskUsage() })
    let target = DockerConnectionTarget.ssh(try DockerSSHHost("first"))
    service.selectTarget(target)
    service.scan()
    try await waitForCompletion(service)
    service.runCleanup(.empty)
    XCTAssertTrue(service.isCleaning)
    service.selectTarget(.ssh(try DockerSSHHost("second")))
    service.scan()
    XCTAssertEqual(service.target, target)
    XCTAssertFalse(service.isScanning)
    XCTAssertEqual(service.connection?.endpoint.address, "ssh://first")
    service.stopCleanup()
  }

  private static func connect(_ target: DockerConnectionTarget) async throws -> DockerConnection {
    guard case .ssh(let host) = target else { throw DockerSSHHostError.invalidAddress }
    return DockerConnection(
      endpoint: DockerEndpoint(sshHost: host),
      version: DockerEngineVersion(
        version: "29.3.1", apiVersion: "1.54", minimumAPIVersion: nil, os: "linux", arch: "amd64",
        platformName: nil),
      ping: DockerPing(apiVersion: "1.54", builderVersion: nil, osType: "linux"))
  }

  @MainActor
  private func waitForCompletion(_ service: DockerService) async throws {
    let deadline = Date().addingTimeInterval(5)
    while service.isScanning, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertFalse(service.isScanning)
  }
}

private actor ScanGate {
  static let staleProgressDate = Date(timeIntervalSince1970: 1)
  private var pending: [String: CheckedContinuation<DockerDiskUsage, Error>] = [:]
  private var callbacks: [String: @Sendable (ScanProgress) -> Void] = [:]

  func scan(_ connection: DockerConnection, progress: @escaping @Sendable (ScanProgress) -> Void)
    async throws -> DockerDiskUsage
  {
    guard case .ssh(let host) = connection.endpoint.transport else {
      throw DockerSSHHostError.invalidAddress
    }
    callbacks[host.host] = progress
    return try await withCheckedThrowingContinuation { pending[host.host] = $0 }
  }

  func waitForScan(_ host: String) async throws {
    let deadline = Date().addingTimeInterval(5)
    while pending[host] == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertNotNil(pending[host])
  }

  func finish(_ host: String) {
    callbacks.removeValue(forKey: host)?(
      ScanProgress(
        stage: .containers, completedStages: 0, partial: DockerDiskUsage(),
        startedAt: host == "first" ? Self.staleProgressDate : Date()))
    pending.removeValue(forKey: host)?.resume(returning: DockerDiskUsage())
  }
}

@MainActor
private final class ServiceRecorder: DockerServiceDelegate {
  private(set) var finishedScans = 0
  private(set) var progressDates: [Date] = []

  func serviceDidConnect(_ connection: DockerConnection) {}
  func serviceDidReportScanProgress(_ progress: ScanProgress) {
    progressDates.append(progress.startedAt)
  }
  func serviceDidFinishScan(_ result: Result<DockerDiskUsage, Error>) { finishedScans += 1 }
  func serviceDidReportCleanupProgress(_ state: CleanupRunState) {}
  func serviceDidFinishCleanup(_ state: CleanupRunState) {}
}
