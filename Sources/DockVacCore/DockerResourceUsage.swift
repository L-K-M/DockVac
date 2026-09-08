import Foundation

/// Stable Docker storage categories exposed to the application layer.
public enum DockerResourceKind: String, CaseIterable, Codable, Hashable, Sendable {
  case images
  case containers
  case localVolumes
  case buildCache

  /// Order used for display and for treemap grouping.
  public static let displayOrder: [DockerResourceKind] = [
    .images, .containers, .localVolumes, .buildCache,
  ]

  public var displayName: String {
    switch self {
    case .images: return "Images"
    case .containers: return "Containers"
    case .localVolumes: return "Volumes"
    case .buildCache: return "Build Cache"
    }
  }

  public var singularName: String {
    switch self {
    case .images: return "image"
    case .containers: return "container"
    case .localVolumes: return "volume"
    case .buildCache: return "build cache record"
    }
  }

  public var pluralName: String {
    switch self {
    case .images: return "images"
    case .containers: return "containers"
    case .localVolumes: return "volumes"
    case .buildCache: return "build cache records"
    }
  }
}

/// Validated storage totals passed from a Docker driver to the application.
public struct DockerResourceUsage: Equatable, Sendable {
  public let kind: DockerResourceKind
  public let totalBytes: UInt64
  public let reclaimableBytes: UInt64

  public init(kind: DockerResourceKind, totalBytes: UInt64, reclaimableBytes: UInt64) {
    self.kind = kind
    self.totalBytes = totalBytes

    // Docker output is external input; contain inconsistent totals at the boundary.
    self.reclaimableBytes = min(reclaimableBytes, totalBytes)
  }

  public var inUseBytes: UInt64 {
    totalBytes - reclaimableBytes
  }
}
