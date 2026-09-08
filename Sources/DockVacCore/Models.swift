import Foundation

/// Identifies one Docker resource across scans. The raw value is the Docker ID
/// (image digest, container ID, volume name, or build cache record ID).
public struct DockerResourceID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let kind: DockerResourceKind
  public let rawValue: String

  public init(kind: DockerResourceKind, rawValue: String) {
    self.kind = kind
    self.rawValue = rawValue
  }

  public var description: String {
    "\(kind.rawValue):\(rawValue)"
  }
}

/// Shortens Docker identifiers the way the CLI does (12 hex characters).
public func dockerShortID(_ id: String) -> String {
  var value = id
  if let range = value.range(of: "sha256:") {
    value.removeSubrange(range)
  }
  return String(value.prefix(12))
}

public struct DockerImage: Hashable, Sendable, Identifiable {
  public let id: String
  public let repoTags: [String]
  public let repoDigests: [String]
  public let created: Date?
  public let sizeBytes: UInt64
  public let sharedSizeBytes: UInt64
  /// Number of containers using this image, when the daemon reported it.
  public let containerCount: Int?
  public let labels: [String: String]

  public init(
    id: String,
    repoTags: [String],
    repoDigests: [String],
    created: Date?,
    sizeBytes: UInt64,
    sharedSizeBytes: UInt64,
    containerCount: Int?,
    labels: [String: String] = [:]
  ) {
    self.id = id
    self.repoTags = repoTags.filter { $0 != "<none>:<none>" && !$0.isEmpty }
    self.repoDigests = repoDigests.filter { $0 != "<none>@<none>" && !$0.isEmpty }
    self.created = created
    self.sizeBytes = sizeBytes
    // Shared bytes can never exceed the image size; clamp inconsistent daemon output.
    self.sharedSizeBytes = min(sharedSizeBytes, sizeBytes)
    self.containerCount = containerCount
    self.labels = labels
  }

  /// Bytes that belong to this image alone, i.e. what removing it frees.
  public var uniqueSizeBytes: UInt64 {
    sizeBytes - sharedSizeBytes
  }

  /// Docker's own rule: an image with neither tags nor digests. An image pulled by digest
  /// is deliberately pinned, not a leftover, so `docker image prune` keeps it too.
  public var isDangling: Bool {
    repoTags.isEmpty && repoDigests.isEmpty
  }

  /// Untagged but referenced by digest: pinned on purpose.
  public var isPinnedByDigest: Bool {
    repoTags.isEmpty && !repoDigests.isEmpty
  }

  public var shortID: String {
    dockerShortID(id)
  }

  /// Human readable primary name: the first tag, else the digest repo, else the short ID.
  public var displayName: String {
    if let tag = repoTags.first {
      return tag
    }
    if let digest = repoDigests.first, let at = digest.firstIndex(of: "@") {
      return "\(digest[..<at])@\(dockerShortID(String(digest[digest.index(after: at)...])))"
    }
    return "<untagged> \(shortID)"
  }

  /// Whether `docker image rm <id>` works without `force`.
  ///
  /// This mirrors the daemon's `isSingleReference` rule: at most one tag, and every
  /// digest reference must belong to that same repository.
  public var canDeleteByID: Bool {
    let references = repoTags + repoDigests
    if references.count <= 1 {
      return true
    }
    if repoTags.count > 1 {
      return false
    }
    let digestRepositories = Set(repoDigests.map(Self.repository(of:)))
    let single = repoTags.first.map(Self.repository(of:)) ?? Self.repository(of: repoDigests[0])
    return digestRepositories.count == 1 && digestRepositories.contains(single)
  }

  /// References that must be removed one by one to delete the image without `force`.
  ///
  /// Empty when deleting by ID is allowed. Otherwise each tag and digest reference is
  /// removed in turn; the image data goes away with the last reference.
  public var removalReferences: [String] {
    canDeleteByID ? [] : repoTags + repoDigests
  }

  /// The repository part of a reference such as `localhost:5000/team/app:stable`.
  public static func repository(of reference: String) -> String {
    if let at = reference.firstIndex(of: "@") {
      return String(reference[..<at])
    }
    if let colon = reference.lastIndex(of: ":"), !reference[colon...].contains("/") {
      return String(reference[..<colon])
    }
    return reference
  }

  public var resourceID: DockerResourceID {
    DockerResourceID(kind: .images, rawValue: id)
  }
}

public enum DockerContainerState: Hashable, Sendable {
  case created
  case running
  case paused
  case restarting
  case removing
  case exited
  case dead
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue.lowercased() {
    case "created": self = .created
    case "running": self = .running
    case "paused": self = .paused
    case "restarting": self = .restarting
    case "removing": self = .removing
    case "exited": self = .exited
    case "dead": self = .dead
    default: self = .unknown(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .created: return "created"
    case .running: return "running"
    case .paused: return "paused"
    case .restarting: return "restarting"
    case .removing: return "removing"
    case .exited: return "exited"
    case .dead: return "dead"
    case .unknown(let value): return value
    }
  }

  /// True when Docker would refuse a non-forced removal because the container is alive.
  public var isActive: Bool {
    switch self {
    case .running, .paused, .restarting, .removing: return true
    case .created, .exited, .dead: return false
    case .unknown: return true
    }
  }

  public var displayName: String {
    switch self {
    case .created: return "Created"
    case .running: return "Running"
    case .paused: return "Paused"
    case .restarting: return "Restarting"
    case .removing: return "Removing"
    case .exited: return "Stopped"
    case .dead: return "Dead"
    case .unknown(let value): return value.capitalized
    }
  }
}

public struct DockerMount: Hashable, Sendable {
  public let type: String
  public let volumeName: String?
  public let source: String?
  public let destination: String
  public let readWrite: Bool

  public init(
    type: String, volumeName: String?, source: String?, destination: String, readWrite: Bool
  ) {
    self.type = type
    self.volumeName = volumeName
    self.source = source
    self.destination = destination
    self.readWrite = readWrite
  }

  public var isVolume: Bool {
    type == "volume" && volumeName != nil
  }
}

public struct DockerContainer: Hashable, Sendable, Identifiable {
  public let id: String
  public let names: [String]
  public let imageReference: String
  public let imageID: String
  public let command: String
  public let created: Date?
  public let state: DockerContainerState
  public let status: String
  public let sizeRwBytes: UInt64
  public let sizeRootFsBytes: UInt64
  public let mounts: [DockerMount]
  public let labels: [String: String]

  public init(
    id: String,
    names: [String],
    imageReference: String,
    imageID: String,
    command: String,
    created: Date?,
    state: DockerContainerState,
    status: String,
    sizeRwBytes: UInt64,
    sizeRootFsBytes: UInt64,
    mounts: [DockerMount],
    labels: [String: String] = [:]
  ) {
    self.id = id
    // The Engine API prefixes names with "/"; the CLI never shows it.
    self.names = names.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
    self.imageReference = imageReference
    self.imageID = imageID
    self.command = command
    self.created = created
    self.state = state
    self.status = status
    self.sizeRwBytes = sizeRwBytes
    self.sizeRootFsBytes = max(sizeRootFsBytes, sizeRwBytes)
    self.mounts = mounts
    self.labels = labels
  }

  public var shortID: String {
    dockerShortID(id)
  }

  public var displayName: String {
    names.first ?? shortID
  }

  public var volumeNames: [String] {
    mounts.compactMap { $0.isVolume ? $0.volumeName : nil }
  }

  public var resourceID: DockerResourceID {
    DockerResourceID(kind: .containers, rawValue: id)
  }
}

public struct DockerVolume: Hashable, Sendable, Identifiable {
  public let name: String
  public let driver: String
  public let mountpoint: String
  public let createdAt: Date?
  public let labels: [String: String]
  public let scope: String
  /// Bytes used, when the daemon could compute it (`UsageData.Size` of -1 means unknown).
  public let sizeBytes: UInt64?
  /// Containers referencing the volume, when the daemon reported it.
  public let referenceCount: Int?

  public init(
    name: String,
    driver: String,
    mountpoint: String,
    createdAt: Date?,
    labels: [String: String] = [:],
    scope: String = "local",
    sizeBytes: UInt64?,
    referenceCount: Int?
  ) {
    self.name = name
    self.driver = driver
    self.mountpoint = mountpoint
    self.createdAt = createdAt
    self.labels = labels
    self.scope = scope
    self.sizeBytes = sizeBytes
    self.referenceCount = referenceCount
  }

  public var id: String { name }

  /// Anonymous volumes are created implicitly by containers and named with a 64-hex digest.
  public var isAnonymous: Bool {
    if labels["com.docker.volume.anonymous"] != nil {
      return true
    }
    return name.count == 64 && name.allSatisfy { $0.isHexDigit }
  }

  public var composeProject: String? {
    labels["com.docker.compose.project"]
  }

  public var displayName: String {
    isAnonymous ? "anonymous \(dockerShortID(name))" : name
  }

  public var resourceID: DockerResourceID {
    DockerResourceID(kind: .localVolumes, rawValue: name)
  }
}

public struct BuildCacheRecord: Hashable, Sendable, Identifiable {
  public let id: String
  public let parents: [String]
  public let type: String
  public let recordDescription: String
  public let inUse: Bool
  public let shared: Bool
  public let sizeBytes: UInt64
  public let createdAt: Date?
  public let lastUsedAt: Date?
  public let usageCount: Int

  public init(
    id: String,
    parents: [String] = [],
    type: String,
    recordDescription: String,
    inUse: Bool,
    shared: Bool,
    sizeBytes: UInt64,
    createdAt: Date?,
    lastUsedAt: Date?,
    usageCount: Int
  ) {
    self.id = id
    self.parents = parents
    self.type = type
    self.recordDescription = recordDescription
    self.inUse = inUse
    self.shared = shared
    self.sizeBytes = sizeBytes
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
    self.usageCount = usageCount
  }

  public var shortID: String {
    String(id.prefix(12))
  }

  public var displayName: String {
    let trimmed = recordDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "\(type) \(shortID)" : trimmed
  }

  public var typeDisplayName: String {
    switch type {
    case "regular": return "Layer"
    case "source.local": return "Local source"
    case "exec.cachemount": return "Cache mount"
    case "frontend": return "Frontend"
    case "internal": return "Internal"
    default: return type
    }
  }

  public var resourceID: DockerResourceID {
    DockerResourceID(kind: .buildCache, rawValue: id)
  }
}

/// A complete snapshot of Docker disk usage.
public struct DockerDiskUsage: Hashable, Sendable {
  public var images: [DockerImage]
  public var containers: [DockerContainer]
  public var volumes: [DockerVolume]
  public var buildCache: [BuildCacheRecord]
  /// Total size of all image layers as reported by the daemon, if provided.
  public var layersSizeBytes: UInt64?

  public init(
    images: [DockerImage] = [],
    containers: [DockerContainer] = [],
    volumes: [DockerVolume] = [],
    buildCache: [BuildCacheRecord] = [],
    layersSizeBytes: UInt64? = nil
  ) {
    self.images = images
    self.containers = containers
    self.volumes = volumes
    self.buildCache = buildCache
    self.layersSizeBytes = layersSizeBytes
  }

  public static let empty = DockerDiskUsage()

  public var itemCount: Int {
    images.count + containers.count + volumes.count + buildCache.count
  }
}

public struct DockerEngineVersion: Hashable, Sendable {
  public let version: String
  public let apiVersion: String
  public let minimumAPIVersion: String?
  public let os: String
  public let arch: String
  public let platformName: String?

  public init(
    version: String,
    apiVersion: String,
    minimumAPIVersion: String?,
    os: String,
    arch: String,
    platformName: String?
  ) {
    self.version = version
    self.apiVersion = apiVersion
    self.minimumAPIVersion = minimumAPIVersion
    self.os = os
    self.arch = arch
    self.platformName = platformName
  }

  /// Compares dotted API versions such as "1.42" numerically.
  public static func compareAPIVersions(_ lhs: String, _ rhs: String) -> Int {
    let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(left.count, right.count) {
      let l = index < left.count ? left[index] : 0
      let r = index < right.count ? right[index] : 0
      if l != r {
        return l < r ? -1 : 1
      }
    }
    return 0
  }

  public func supportsAPI(atLeast required: String) -> Bool {
    Self.compareAPIVersions(apiVersion, required) >= 0
  }
}
