import DockVacCore
import Foundation

/// A Docker daemon socket DockVac talks to.
public struct DockerEndpoint: Hashable, Sendable {
  public let socketPath: String
  /// Where the path came from, e.g. "Docker Desktop" or "DOCKER_HOST".
  public let origin: String

  public init(socketPath: String, origin: String) {
    self.socketPath = socketPath
    self.origin = origin
  }
}

public struct DockerPing: Hashable, Sendable {
  public let apiVersion: String?
  public let builderVersion: String?
  public let osType: String?

  public init(apiVersion: String?, builderVersion: String?, osType: String?) {
    self.apiVersion = apiVersion
    self.builderVersion = builderVersion
    self.osType = osType
  }
}

/// Typed access to the Engine API endpoints DockVac needs. Every destructive call is
/// non-forcing: the daemon refuses anything that is still in use.
public struct DockerEngineClient: Sendable {
  public let endpoint: DockerEndpoint
  private let http: UnixSocketHTTPClient

  public init(endpoint: DockerEndpoint, idleTimeout: TimeInterval = 900) {
    self.endpoint = endpoint
    self.http = UnixSocketHTTPClient(socketPath: endpoint.socketPath, idleTimeout: idleTimeout)
  }

  // MARK: - Reads

  public func ping() async throws -> DockerPing {
    let response = try await perform(HTTPRequest(method: "GET", path: "/_ping"))
    return DockerPing(
      apiVersion: response.header("Api-Version"),
      builderVersion: response.header("Builder-Version"),
      osType: response.header("Ostype")
    )
  }

  public func version() async throws -> DockerEngineVersion {
    let response = try await perform(HTTPRequest(method: "GET", path: "/version"))
    return try decode { try DockerEngineDecoder.decodeVersion(response.body) }
  }

  /// All containers with their writable-layer sizes.
  public func listContainers() async throws -> [DockerContainer] {
    let response = try await perform(
      HTTPRequest(method: "GET", path: "/containers/json?all=1&size=1"))
    return try decode { try DockerEngineDecoder.decodeContainers(response.body) }
  }

  /// Images with shared sizes and container counts, as `docker system df -v` reports them,
  /// plus the daemon's total layer size.
  public func imageUsage() async throws -> (images: [DockerImage], layersSizeBytes: UInt64?) {
    let response = try await diskUsageResponse(type: "image")
    return try decode { try DockerEngineDecoder.decodeImageUsage(response.body) }
  }

  /// Volumes with sizes and reference counts.
  public func volumeUsage() async throws -> [DockerVolume] {
    let response = try await diskUsageResponse(type: "volume")
    return try decode { try DockerEngineDecoder.decodeVolumes(response.body) }
  }

  public func buildCacheUsage() async throws -> [BuildCacheRecord] {
    let response = try await diskUsageResponse(type: "build-cache")
    return try decode { try DockerEngineDecoder.decodeBuildCache(response.body) }
  }

  /// The image ID a reference (tag, digest, or ID) currently points at.
  public func imageID(forReference reference: String) async throws -> String {
    let response = try await perform(
      HTTPRequest(method: "GET", path: "/images/\(pathSegment(reference))/json"))
    return try decode { try DockerEngineDecoder.decodeImageID(response.body) }
  }

  /// Everything in one call. Slower than the staged reads but useful for tests.
  public func diskUsage() async throws -> DockerDiskUsage {
    let response = try await perform(HTTPRequest(method: "GET", path: "/system/df"))
    return try decode { try DockerEngineDecoder.decodeDiskUsage(response.body) }
  }

  // MARK: - Removals

  /// `docker container rm <id>`: never forced, anonymous volumes are kept.
  public func removeContainer(id: String) async throws {
    _ = try await perform(
      HTTPRequest(method: "DELETE", path: "/containers/\(pathSegment(id))?v=0&force=0"))
  }

  /// `docker image rm <reference>`: never forced, dangling parents are pruned as usual.
  public func removeImage(reference: String) async throws -> [ImageDeleteItem] {
    let response = try await perform(
      HTTPRequest(method: "DELETE", path: "/images/\(pathSegment(reference))?force=0&noprune=0"))
    if response.body.isEmpty {
      return []
    }
    return try decode { try DockerEngineDecoder.decodeImageDeleteResponse(response.body) }
  }

  /// `docker volume rm <name>`: never forced.
  public func removeVolume(name: String) async throws {
    _ = try await perform(
      HTTPRequest(method: "DELETE", path: "/volumes/\(pathSegment(name))?force=0"))
  }

  /// `docker builder prune --filter id=<id>`: removes exactly one cache record.
  public func pruneBuildCache(id: String) async throws -> BuildPruneResult {
    let filters = "{\"id\":[\"\(id)\"]}"
    let encoded =
      filters.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? filters
    let response = try await perform(
      HTTPRequest(method: "POST", path: "/build/prune?filters=\(encoded)"))
    return try decode { try DockerEngineDecoder.decodeBuildPruneResponse(response.body) }
  }

  // MARK: - Plumbing

  private static let queryValueAllowed: CharacterSet = {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return allowed
  }()

  private func pathSegment(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "?#%")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  /// `/system/df?type=` needs API 1.42; older daemons get the full report instead.
  private func diskUsageResponse(type: String) async throws -> HTTPResponse {
    do {
      return try await perform(HTTPRequest(method: "GET", path: "/system/df?type=\(type)"))
    } catch DockerEngineError.api(let status, _) where status == 400 {
      return try await perform(HTTPRequest(method: "GET", path: "/system/df"))
    }
  }

  private func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
    let response = try await http.send(request)
    guard response.statusCode < 400 else {
      let message =
        DockerEngineDecoder.decodeErrorMessage(response.body)
        ?? (response.body.isEmpty
          ? "HTTP \(response.statusCode) \(response.reasonPhrase)"
          : String(decoding: response.body.prefix(500), as: UTF8.self))
      throw DockerEngineError.api(status: response.statusCode, message: message)
    }
    return response
  }

  private func decode<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as DockerDecodingError {
      throw DockerEngineError.decoding(error)
    }
  }
}
