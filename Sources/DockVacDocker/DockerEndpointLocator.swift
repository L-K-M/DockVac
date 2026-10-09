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

  /// Copyable equivalents must name the same daemon, independent of the local CLI's
  /// active Docker context.
  public func equivalentScript(for plan: CleanupPlan) -> String {
    switch endpoint.transport {
    case .unixSocket(let path):
      let quotedURI = "'unix://" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
      return plan.operations.map {
        $0.cliEquivalent.replacingOccurrences(
          of: "docker ", with: "docker --host \(quotedURI) ", options: .anchored)
      }.joined(separator: "\n")
    case .ssh(let host):
      return SSHHTTPClient(host: host, idleTimeout: 900, executable: SSHHTTPClient.executable)
        .equivalentScript(for: plan)
    }
  }

  /// One line for the UI, e.g. "Docker Desktop · Docker Engine 29.3.1".
  public var summary: String {
    var parts = [endpoint.origin]
    if case .ssh = endpoint.transport {
      parts.append(endpoint.address)
    }
    let engine = version.platformName?.isEmpty == false ? version.platformName! : "Docker Engine"
    parts.append("\(engine) \(version.version)")
    return parts.joined(separator: " · ")
  }
}

public enum DockerConnectionTarget: Hashable, Sendable {
  case automatic
  case local
  case ssh(DockerSSHHost)
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
  public func connect(to target: DockerConnectionTarget = .automatic) async throws
    -> DockerConnection
  {
    switch target {
    case .ssh(let host):
      return try await probe(DockerEndpoint(sshHost: host))
    case .automatic:
      if let configured = DockerEndpointResolution.configuredHost(
        environment: environment, activeContext: activeContext())
      {
        switch configured.host {
        case .ssh(let host):
          return try await probe(DockerEndpoint(sshHost: host, origin: configured.origin))
        case .unsupported(let value) where value.lowercased().hasPrefix("\(DockerSSHHost.scheme):"):
          throw DockerSSHHostError.invalidAddress
        default:
          break
        }
      }
    case .local:
      break
    }

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
      do {
        return try await probe(endpoint)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        attempts.append(
          "\(candidate.socketPath) (\(candidate.origin)): \(dockerErrorMessage(error))")
      }
    }
    throw DockerEngineError.daemonNotFound(attempts: attempts, unsupported: unsupported)
  }

  private func probe(_ endpoint: DockerEndpoint) async throws -> DockerConnection {
    let client = DockerEngineClient(endpoint: endpoint, idleTimeout: probeTimeout)
    let ping = try await client.ping()
    let version = try await client.version()
    return DockerConnection(endpoint: endpoint, version: version, ping: ping)
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
