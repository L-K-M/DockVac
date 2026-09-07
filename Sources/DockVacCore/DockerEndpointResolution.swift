import Foundation

/// A place where a Docker daemon socket might live, and how DockVac learned about it.
public struct DockerEndpointCandidate: Hashable, Sendable {
  public let socketPath: String
  public let origin: String

  public init(socketPath: String, origin: String) {
    self.socketPath = socketPath
    self.origin = origin
  }
}

public enum DockerHostSetting: Hashable, Sendable {
  case unixSocket(path: String)
  case unsupported(value: String)
}

/// Pure helpers for finding the Docker daemon. File and environment access happens in the
/// driver; these functions only interpret what the driver read.
public enum DockerEndpointResolution {
  /// Interprets a `DOCKER_HOST`-style value such as `unix:///var/run/docker.sock`.
  public static func parseHost(_ value: String) -> DockerHostSetting? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("unix://") {
      let path = String(trimmed.dropFirst("unix://".count))
      return path.isEmpty ? nil : .unixSocket(path: path)
    }
    if trimmed.hasPrefix("/") {
      return .unixSocket(path: trimmed)
    }
    return .unsupported(value: trimmed)
  }

  /// The active Docker context name, if it is not the built-in default.
  public static func currentContextName(environment: [String: String], configJSON: Data?) -> String?
  {
    if let fromEnvironment = environment["DOCKER_CONTEXT"]?.trimmingCharacters(in: .whitespaces),
      !fromEnvironment.isEmpty
    {
      return fromEnvironment == "default" ? nil : fromEnvironment
    }
    guard let configJSON,
      let object = try? JSONSerialization.jsonObject(with: configJSON) as? [String: Any],
      let name = object["currentContext"] as? String
    else {
      return nil
    }
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty || trimmed == "default" ? nil : trimmed
  }

  public struct ContextMetadata: Hashable, Sendable {
    public let name: String
    public let host: DockerHostSetting

    public init(name: String, host: DockerHostSetting) {
      self.name = name
      self.host = host
    }
  }

  /// Reads a `~/.docker/contexts/meta/<hash>/meta.json` document.
  public static func contextMetadata(from json: Data) -> ContextMetadata? {
    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let name = object["Name"] as? String,
      let endpoints = object["Endpoints"] as? [String: Any],
      let docker = endpoints["docker"] as? [String: Any],
      let hostValue = docker["Host"] as? String,
      let host = parseHost(hostValue)
    else {
      return nil
    }
    return ContextMetadata(name: name, host: host)
  }

  /// Socket locations used by Docker Desktop and popular alternatives, most likely first.
  public static func wellKnownCandidates(homeDirectory: String) -> [DockerEndpointCandidate] {
    let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
    return [
      DockerEndpointCandidate(
        socketPath: "\(home)/.docker/run/docker.sock", origin: "Docker Desktop"),
      DockerEndpointCandidate(socketPath: "/var/run/docker.sock", origin: "system socket"),
      DockerEndpointCandidate(socketPath: "\(home)/.orbstack/run/docker.sock", origin: "OrbStack"),
      DockerEndpointCandidate(socketPath: "\(home)/.colima/default/docker.sock", origin: "Colima"),
      DockerEndpointCandidate(socketPath: "\(home)/.colima/docker.sock", origin: "Colima"),
      DockerEndpointCandidate(socketPath: "\(home)/.rd/docker.sock", origin: "Rancher Desktop"),
      DockerEndpointCandidate(socketPath: "\(home)/.lima/default/sock/docker.sock", origin: "Lima"),
    ]
  }

  /// Orders candidates: explicit environment first, then the active context, then well-known
  /// paths, without duplicates.
  public static func orderedCandidates(
    environment: [String: String],
    homeDirectory: String,
    activeContext: ContextMetadata?
  ) -> (candidates: [DockerEndpointCandidate], unsupported: [String]) {
    var candidates: [DockerEndpointCandidate] = []
    var unsupported: [String] = []

    if let hostValue = environment["DOCKER_HOST"], let host = parseHost(hostValue) {
      switch host {
      case .unixSocket(let path):
        candidates.append(DockerEndpointCandidate(socketPath: path, origin: "DOCKER_HOST"))
      case .unsupported(let value):
        unsupported.append("DOCKER_HOST=\(value)")
      }
    }

    if let activeContext {
      switch activeContext.host {
      case .unixSocket(let path):
        candidates.append(
          DockerEndpointCandidate(socketPath: path, origin: "Docker context \(activeContext.name)"))
      case .unsupported(let value):
        unsupported.append("context \(activeContext.name): \(value)")
      }
    }

    candidates.append(contentsOf: wellKnownCandidates(homeDirectory: homeDirectory))

    var seen: Set<String> = []
    let unique = candidates.filter { seen.insert($0.socketPath).inserted }
    return (unique, unsupported)
  }
}
