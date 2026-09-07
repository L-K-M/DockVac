import DockVacCore
import Foundation

public enum ScanStage: Int, CaseIterable, Hashable, Sendable {
  case containers
  case images
  case volumes
  case buildCache

  public var title: String {
    switch self {
    case .containers: return "Listing containers"
    case .images: return "Measuring images"
    case .volumes: return "Measuring volumes"
    case .buildCache: return "Reading build cache"
    }
  }
}

/// A snapshot of an in-flight scan. `partial` grows as stages complete.
public struct ScanProgress: Hashable, Sendable {
  public let stage: ScanStage
  public let completedStages: Int
  public let partial: DockerDiskUsage
  public let startedAt: Date

  public init(stage: ScanStage, completedStages: Int, partial: DockerDiskUsage, startedAt: Date) {
    self.stage = stage
    self.completedStages = completedStages
    self.partial = partial
    self.startedAt = startedAt
  }

  public var totalStages: Int { ScanStage.allCases.count }

  public var fractionCompleted: Double {
    Double(completedStages) / Double(totalStages)
  }

  /// Bytes found so far, attributing shared image layers only once.
  public var bytesFound: UInt64 {
    let images = partial.images.reduce(UInt64(0)) { $0 + $1.uniqueSizeBytes }
    let containers = partial.containers.reduce(UInt64(0)) { $0 + $1.sizeRwBytes }
    let volumes = partial.volumes.reduce(UInt64(0)) { $0 + ($1.sizeBytes ?? 0) }
    let cache = partial.buildCache.reduce(UInt64(0)) { $0 + $1.sizeBytes }
    return images + containers + volumes + cache
  }
}

/// Reads disk usage in stages so the UI can show progress, and stops promptly when the
/// task is cancelled.
public struct DockerScanner: Sendable {
  public let client: DockerEngineClient

  public init(client: DockerEngineClient) {
    self.client = client
  }

  public func scan(onProgress: @escaping @Sendable (ScanProgress) -> Void) async throws
    -> DockerDiskUsage
  {
    let startedAt = Date()
    var usage = DockerDiskUsage()

    for (index, stage) in ScanStage.allCases.enumerated() {
      try Task.checkCancellation()
      onProgress(
        ScanProgress(stage: stage, completedStages: index, partial: usage, startedAt: startedAt))
      switch stage {
      case .containers:
        usage.containers = try await client.listContainers()
      case .images:
        let result = try await client.imageUsage()
        usage.images = result.images
        usage.layersSizeBytes = result.layersSizeBytes
      case .volumes:
        usage.volumes = try await client.volumeUsage()
      case .buildCache:
        usage.buildCache = try await client.buildCacheUsage()
      }
    }
    try Task.checkCancellation()
    return usage
  }
}
