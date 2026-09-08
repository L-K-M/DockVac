import Foundation

/// Errors raised while turning Docker Engine API JSON into domain models.
public enum DockerDecodingError: Error, Hashable, Sendable, LocalizedError {
  case malformedJSON(String)
  case invalidResource(String)

  public var errorDescription: String? {
    switch self {
    case .malformedJSON(let detail):
      return "Docker returned data DockVac could not read: \(detail)"
    case .invalidResource(let detail):
      return "Docker returned an invalid resource: \(detail)"
    }
  }
}

/// Result of `DELETE /images/{name}`.
public struct ImageDeleteItem: Hashable, Sendable {
  public let untagged: String?
  public let deleted: String?

  public init(untagged: String?, deleted: String?) {
    self.untagged = untagged
    self.deleted = deleted
  }
}

/// Result of `POST /build/prune`.
public struct BuildPruneResult: Hashable, Sendable {
  public let cachesDeleted: [String]
  public let spaceReclaimedBytes: UInt64

  public init(cachesDeleted: [String], spaceReclaimedBytes: UInt64) {
    self.cachesDeleted = cachesDeleted
    self.spaceReclaimedBytes = spaceReclaimedBytes
  }
}

/// Decodes Docker Engine API payloads. The wire structs are internal so the rest of the
/// app only ever sees validated domain models.
public enum DockerEngineDecoder {
  // MARK: - Public entry points

  public static func decodeDiskUsage(_ data: Data) throws -> DockerDiskUsage {
    let wire = try decode(SystemDataUsageWire.self, from: data)
    return try diskUsage(from: wire)
  }

  public static func decodeImages(_ data: Data) throws -> [DockerImage] {
    try decodeImageUsage(data).images
  }

  /// Images plus the daemon's total layer size, when the payload carries one.
  public static func decodeImageUsage(_ data: Data) throws -> (
    images: [DockerImage], layersSizeBytes: UInt64?
  ) {
    // Accept both `/images/json` (array) and `/system/df?type=image` (object).
    if let array = try? decode([ImageWire].self, from: data) {
      return (try array.map(image(from:)), nil)
    }
    let wire = try decode(SystemDataUsageWire.self, from: data)
    return (try (wire.images ?? []).map(image(from:)), wire.layersSize.map(clampBytes))
  }

  public static func decodeContainers(_ data: Data) throws -> [DockerContainer] {
    if let array = try? decode([ContainerWire].self, from: data) {
      return try array.map(container(from:))
    }
    let wire = try decode(SystemDataUsageWire.self, from: data)
    return try (wire.containers ?? []).map(container(from:))
  }

  public static func decodeVolumes(_ data: Data) throws -> [DockerVolume] {
    // `/volumes` and `/system/df?type=volume` both wrap the list in `Volumes`.
    let wire = try decode(SystemDataUsageWire.self, from: data)
    return try (wire.volumes ?? []).map(volume(from:))
  }

  public static func decodeBuildCache(_ data: Data) throws -> [BuildCacheRecord] {
    let wire = try decode(SystemDataUsageWire.self, from: data)
    return try (wire.buildCache ?? []).map(buildCacheRecord(from:))
  }

  public static func decodeVersion(_ data: Data) throws -> DockerEngineVersion {
    let wire = try decode(VersionWire.self, from: data)
    guard let version = wire.version, let apiVersion = wire.apiVersion else {
      throw DockerDecodingError.invalidResource("version response is missing Version or ApiVersion")
    }
    return DockerEngineVersion(
      version: version,
      apiVersion: apiVersion,
      minimumAPIVersion: wire.minAPIVersion,
      os: wire.os ?? "",
      arch: wire.arch ?? "",
      platformName: wire.platform?.name
    )
  }

  /// Extracts the `message` from an Engine API error body, if present.
  public static func decodeErrorMessage(_ data: Data) -> String? {
    guard let wire = try? decode(ErrorWire.self, from: data) else {
      return nil
    }
    let message = wire.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return message.isEmpty ? nil : message
  }

  /// The `Id` of an image inspect response (`GET /images/{name}/json`).
  public static func decodeImageID(_ data: Data) throws -> String {
    let wire = try decode(ImageInspectWire.self, from: data)
    guard let id = wire.id, !id.isEmpty else {
      throw DockerDecodingError.invalidResource("image inspect response without Id")
    }
    return id
  }

  public static func decodeImageDeleteResponse(_ data: Data) throws -> [ImageDeleteItem] {
    let wire = try decode([ImageDeleteWire].self, from: data)
    return wire.map { ImageDeleteItem(untagged: $0.untagged, deleted: $0.deleted) }
  }

  public static func decodeBuildPruneResponse(_ data: Data) throws -> BuildPruneResult {
    let wire = try decode(BuildPruneWire.self, from: data)
    return BuildPruneResult(
      cachesDeleted: wire.cachesDeleted ?? [],
      spaceReclaimedBytes: clampBytes(wire.spaceReclaimed)
    )
  }

  // MARK: - Conversion

  static func diskUsage(from wire: SystemDataUsageWire) throws -> DockerDiskUsage {
    DockerDiskUsage(
      images: try (wire.images ?? []).map(image(from:)),
      containers: try (wire.containers ?? []).map(container(from:)),
      volumes: try (wire.volumes ?? []).map(volume(from:)),
      buildCache: try (wire.buildCache ?? []).map(buildCacheRecord(from:)),
      layersSizeBytes: wire.layersSize.map(clampBytes)
    )
  }

  static func image(from wire: ImageWire) throws -> DockerImage {
    guard let id = wire.id, !id.isEmpty else {
      throw DockerDecodingError.invalidResource("image without Id")
    }
    return DockerImage(
      id: id,
      repoTags: wire.repoTags ?? [],
      repoDigests: wire.repoDigests ?? [],
      created: wire.created.map { Date(timeIntervalSince1970: TimeInterval($0)) },
      sizeBytes: clampBytes(wire.size),
      sharedSizeBytes: clampBytes(wire.sharedSize),
      containerCount: wire.containers.flatMap { $0 >= 0 ? $0 : nil },
      labels: wire.labels ?? [:]
    )
  }

  static func container(from wire: ContainerWire) throws -> DockerContainer {
    guard let id = wire.id, !id.isEmpty else {
      throw DockerDecodingError.invalidResource("container without Id")
    }
    return DockerContainer(
      id: id,
      names: wire.names ?? [],
      imageReference: wire.image ?? "",
      imageID: wire.imageID ?? "",
      command: wire.command ?? "",
      created: wire.created.map { Date(timeIntervalSince1970: TimeInterval($0)) },
      state: DockerContainerState(rawValue: wire.state ?? ""),
      status: wire.status ?? "",
      sizeRwBytes: clampBytes(wire.sizeRw),
      sizeRootFsBytes: clampBytes(wire.sizeRootFs),
      mounts: (wire.mounts ?? []).map { mount in
        DockerMount(
          type: mount.type ?? "",
          volumeName: mount.name.flatMap { $0.isEmpty ? nil : $0 },
          source: mount.source.flatMap { $0.isEmpty ? nil : $0 },
          destination: mount.destination ?? "",
          readWrite: mount.readWrite ?? true
        )
      },
      labels: wire.labels ?? [:]
    )
  }

  static func volume(from wire: VolumeWire) throws -> DockerVolume {
    guard let name = wire.name, !name.isEmpty else {
      throw DockerDecodingError.invalidResource("volume without Name")
    }
    let size: UInt64? = wire.usageData?.size.flatMap { $0 >= 0 ? UInt64($0) : nil }
    let references: Int? = wire.usageData?.refCount.flatMap { $0 >= 0 ? $0 : nil }
    return DockerVolume(
      name: name,
      driver: wire.driver ?? "",
      mountpoint: wire.mountpoint ?? "",
      createdAt: wire.createdAt.flatMap(parseDate),
      labels: wire.labels ?? [:],
      scope: wire.scope ?? "local",
      sizeBytes: size,
      referenceCount: references
    )
  }

  static func buildCacheRecord(from wire: BuildCacheWire) throws -> BuildCacheRecord {
    guard let id = wire.id, !id.isEmpty else {
      throw DockerDecodingError.invalidResource("build cache record without ID")
    }
    var parents = wire.parents ?? wire.parentsWithLeadingSpace ?? []
    if parents.isEmpty, let parent = wire.parent, !parent.isEmpty {
      parents = [parent]
    }
    return BuildCacheRecord(
      id: id,
      parents: parents,
      type: wire.type ?? "",
      recordDescription: wire.description ?? "",
      inUse: wire.inUse ?? false,
      shared: wire.shared ?? false,
      sizeBytes: clampBytes(wire.size),
      createdAt: wire.createdAt.flatMap(parseDate),
      lastUsedAt: wire.lastUsedAt.flatMap(parseDate),
      usageCount: max(0, wire.usageCount ?? 0)
    )
  }

  // MARK: - Helpers

  private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch let error as DecodingError {
      throw DockerDecodingError.malformedJSON(describe(error))
    } catch {
      throw DockerDecodingError.malformedJSON(String(describing: error))
    }
  }

  private static func describe(_ error: DecodingError) -> String {
    switch error {
    case .dataCorrupted(let context):
      return context.debugDescription
    case .keyNotFound(let key, let context):
      return "missing key \(key.stringValue): \(context.debugDescription)"
    case .typeMismatch(_, let context):
      return "type mismatch at \(path(context)): \(context.debugDescription)"
    case .valueNotFound(_, let context):
      return "missing value at \(path(context)): \(context.debugDescription)"
    @unknown default:
      return String(describing: error)
    }
  }

  private static func path(_ context: DecodingError.Context) -> String {
    context.codingPath.map { $0.stringValue }.joined(separator: ".")
  }

  static func clampBytes(_ value: Int64?) -> UInt64 {
    guard let value, value > 0 else { return 0 }
    return UInt64(value)
  }

  /// Parses RFC 3339 timestamps with or without fractional seconds.
  public static func parseDate(_ text: String) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("0001-01-01") else { return nil }
    // Formatters are not Sendable, so build them per call; scans parse a few hundred dates.
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plainFormatter = ISO8601DateFormatter()
    plainFormatter.formatOptions = [.withInternetDateTime]
    if let date = fractionalFormatter.date(from: trimmed) {
      return date
    }
    if let date = plainFormatter.date(from: trimmed) {
      return date
    }
    // Docker occasionally emits more than nine fractional digits; trim them.
    if let dot = trimmed.firstIndex(of: "."),
      let zoneStart = trimmed[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
    {
      let fraction = trimmed[trimmed.index(after: dot)..<zoneStart]
      let trimmedFraction = fraction.prefix(3)
      let rebuilt = String(trimmed[..<dot]) + "." + trimmedFraction + String(trimmed[zoneStart...])
      return fractionalFormatter.date(from: rebuilt)
    }
    return nil
  }
}

// MARK: - Wire structs (coding keys mirror the Engine API field names)

struct SystemDataUsageWire: Decodable {
  var layersSize: Int64?
  var images: [ImageWire]?
  var containers: [ContainerWire]?
  var volumes: [VolumeWire]?
  var buildCache: [BuildCacheWire]?

  enum CodingKeys: String, CodingKey {
    case layersSize = "LayersSize"
    case images = "Images"
    case containers = "Containers"
    case volumes = "Volumes"
    case buildCache = "BuildCache"
  }
}

struct ImageWire: Decodable {
  var id: String?
  var repoTags: [String]?
  var repoDigests: [String]?
  var created: Int64?
  var size: Int64?
  var sharedSize: Int64?
  var containers: Int?
  var labels: [String: String]?

  enum CodingKeys: String, CodingKey {
    case id = "Id"
    case repoTags = "RepoTags"
    case repoDigests = "RepoDigests"
    case created = "Created"
    case size = "Size"
    case sharedSize = "SharedSize"
    case containers = "Containers"
    case labels = "Labels"
  }
}

struct ContainerWire: Decodable {
  var id: String?
  var names: [String]?
  var image: String?
  var imageID: String?
  var command: String?
  var created: Int64?
  var state: String?
  var status: String?
  var sizeRw: Int64?
  var sizeRootFs: Int64?
  var mounts: [MountWire]?
  var labels: [String: String]?

  enum CodingKeys: String, CodingKey {
    case id = "Id"
    case names = "Names"
    case image = "Image"
    case imageID = "ImageID"
    case command = "Command"
    case created = "Created"
    case state = "State"
    case status = "Status"
    case sizeRw = "SizeRw"
    case sizeRootFs = "SizeRootFs"
    case mounts = "Mounts"
    case labels = "Labels"
  }
}

struct MountWire: Decodable {
  var type: String?
  var name: String?
  var source: String?
  var destination: String?
  var readWrite: Bool?

  enum CodingKeys: String, CodingKey {
    case type = "Type"
    case name = "Name"
    case source = "Source"
    case destination = "Destination"
    case readWrite = "RW"
  }
}

struct VolumeWire: Decodable {
  var name: String?
  var driver: String?
  var mountpoint: String?
  var createdAt: String?
  var labels: [String: String]?
  var scope: String?
  var usageData: VolumeUsageWire?

  enum CodingKeys: String, CodingKey {
    case name = "Name"
    case driver = "Driver"
    case mountpoint = "Mountpoint"
    case createdAt = "CreatedAt"
    case labels = "Labels"
    case scope = "Scope"
    case usageData = "UsageData"
  }
}

struct VolumeUsageWire: Decodable {
  var size: Int64?
  var refCount: Int?

  enum CodingKeys: String, CodingKey {
    case size = "Size"
    case refCount = "RefCount"
  }
}

struct BuildCacheWire: Decodable {
  var id: String?
  var parent: String?
  var parents: [String]?
  /// Some daemons serialise the parents list under a key with a leading space.
  var parentsWithLeadingSpace: [String]?
  var type: String?
  var description: String?
  var inUse: Bool?
  var shared: Bool?
  var size: Int64?
  var createdAt: String?
  var lastUsedAt: String?
  var usageCount: Int?

  enum CodingKeys: String, CodingKey {
    case id = "ID"
    case parent = "Parent"
    case parents = "Parents"
    case parentsWithLeadingSpace = " Parents"
    case type = "Type"
    case description = "Description"
    case inUse = "InUse"
    case shared = "Shared"
    case size = "Size"
    case createdAt = "CreatedAt"
    case lastUsedAt = "LastUsedAt"
    case usageCount = "UsageCount"
  }
}

struct VersionWire: Decodable {
  struct PlatformWire: Decodable {
    var name: String?

    enum CodingKeys: String, CodingKey {
      case name = "Name"
    }
  }

  var platform: PlatformWire?
  var version: String?
  var apiVersion: String?
  var minAPIVersion: String?
  var os: String?
  var arch: String?

  enum CodingKeys: String, CodingKey {
    case platform = "Platform"
    case version = "Version"
    case apiVersion = "ApiVersion"
    case minAPIVersion = "MinAPIVersion"
    case os = "Os"
    case arch = "Arch"
  }
}

struct ErrorWire: Decodable {
  var message: String?
}

struct ImageInspectWire: Decodable {
  var id: String?

  enum CodingKeys: String, CodingKey {
    case id = "Id"
  }
}

struct ImageDeleteWire: Decodable {
  var untagged: String?
  var deleted: String?

  enum CodingKeys: String, CodingKey {
    case untagged = "Untagged"
    case deleted = "Deleted"
  }
}

struct BuildPruneWire: Decodable {
  var cachesDeleted: [String]?
  var spaceReclaimed: Int64?

  enum CodingKeys: String, CodingKey {
    case cachesDeleted = "CachesDeleted"
    case spaceReclaimed = "SpaceReclaimed"
  }
}
