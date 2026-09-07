import Foundation

/// Stable Docker storage categories exposed to the application layer.
public enum DockerResourceKind: CaseIterable, Equatable, Sendable {
  case images
  case containers
  case localVolumes
  case buildCache
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
