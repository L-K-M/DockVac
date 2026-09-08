import DockVacCore
import Foundation

/// A daemon that answered, with what it told us about itself.
public struct DockerConnection: Hashable, Sendable {
  public let endpoint: DockerEndpoint
  public let version: DockerEngineVersion
  public let ping: DockerPing

  public init(endpoint: DockerEndpoint, version: DockerEngineVersion, ping: DockerPing) {
    self.endpoint = endpoint
    self.version = version
    self.ping = ping
  }

  public var client: DockerEngineClient {
    DockerEngineClient(endpoint: endpoint)
  }

  /// One line for the UI, e.g. "Docker Desktop · Docker Engine 29.3.1".
  public var summary: String {
    var parts = [endpoint.origin]
    let engine = version.platformName?.isEmpty == false ? version.platformName! : "Docker Engine"
    parts.append("\(engine) \(version.version)")
    return parts.joined(separator: " · ")
  }
}

/// Finds the local Docker daemon by checking the environment, the active Docker context,
/// and the socket paths used by Docker Desktop and its alternatives.
public struct DockerEndpointLocator: Sendable {
  public var environment: [String: String]
  public var homeDirectory: String
  /// Per-candidate probe timeout; a socket that exists but does not answer is skipped.
  public var probeTimeout: TimeInterval

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    probeTimeout: TimeInterval = 10
  ) {
    self.environment = environment
    self.homeDirectory = homeDirectory
    self.probeTimeout = probeTimeout
  }

  /// Candidate sockets in the order they will be tried.
  public func candidates() -> (candidates: [DockerEndpointCandidate], unsupported: [String]) {
    DockerEndpointResolution.orderedCandidates(
      environment: environment,
      homeDirectory: homeDirectory,
      activeContext: activeContext()
    )
  }

  /// Connects to the first candidate that answers `/_ping`.
  public func connect() async throws -> DockerConnection {
    let (candidates, unsupported) = candidates()
    var attempts: [String] = []
    let fileManager = FileManager.default

    for candidate in candidates {
      try Task.checkCancellation()
      guard fileManager.fileExists(atPath: candidate.socketPath) else {
        attempts.append("\(candidate.socketPath) (\(candidate.origin)): not present")
        continue
      }
      let endpoint = DockerEndpoint(socketPath: candidate.socketPath, origin: candidate.origin)
      let client = DockerEngineClient(endpoint: endpoint, idleTimeout: probeTimeout)
      do {
        let ping = try await client.ping()
        let version = try await client.version()
        return DockerConnection(endpoint: endpoint, version: version, ping: ping)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        attempts.append(
          "\(candidate.socketPath) (\(candidate.origin)): \(dockerErrorMessage(error))")
      }
    }
    throw DockerEngineError.daemonNotFound(attempts: attempts, unsupported: unsupported)
  }

  // MARK: - Docker contexts

  private func activeContext() -> DockerEndpointResolution.ContextMetadata? {
    let dockerDirectory = (homeDirectory as NSString).appendingPathComponent(".docker")
    let configJSON = try? Data(
      contentsOf: URL(fileURLWithPath: dockerDirectory).appendingPathComponent("config.json"))
    guard
      let name = DockerEndpointResolution.currentContextName(
        environment: environment, configJSON: configJSON)
    else {
      return nil
    }

    let metaDirectory = URL(fileURLWithPath: dockerDirectory).appendingPathComponent(
      "contexts/meta")
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: metaDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else {
      return nil
    }
    for entry in entries {
      let metaFile = entry.appendingPathComponent("meta.json")
      guard let json = try? Data(contentsOf: metaFile),
        let metadata = DockerEndpointResolution.contextMetadata(from: json),
        metadata.name == name
      else {
        continue
      }
      return metadata
    }
    return nil
  }
}
