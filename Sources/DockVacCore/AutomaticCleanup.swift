import Foundation

/// How far an automatic cleanup goes.
///
/// No level removes a container or a volume. A container holds whatever was written
/// inside it and is the row that would disappear from Docker Desktop's list; a volume
/// holds data nothing can bring back. The levels differ only in which unused images
/// count as reproducible, because that is the one judgement call: build cache and
/// untagged leftovers always are, and an image Docker cannot fetch or rebuild never is.
public enum AutomaticCleanupLevel: String, CaseIterable, Hashable, Sendable, Identifiable {
  /// Untagged image leftovers and unused build cache. This is the ground Docker's own
  /// `image prune` and `builder prune` cover.
  case safe
  /// Also unused images that a registry can serve again, identified by their digest.
  case thorough

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .safe: return "Rebuildable"
    case .thorough: return "Rebuildable and re-pullable"
    }
  }

  /// Short label for a button or a menu item.
  public var menuTitle: String {
    switch self {
    case .safe: return "Clean Up Rebuildable Space"
    case .thorough: return "Clean Up Rebuildable and Re-pullable Space"
    }
  }

  /// One line describing what the level removes.
  public var summary: String {
    switch self {
    case .safe: return "Untagged images and unused build cache"
    case .thorough: return "Also unused images a registry can serve again"
    }
  }

  /// What the level removes and what it deliberately keeps, for the confirmation UI.
  public var explanation: String {
    switch self {
    case .safe:
      return """
        Removes untagged images left over from rebuilds and build cache no build is using. \
        Docker makes both again the next time you build, so this costs build time, never data.
        """
    case .thorough:
      return """
        Also removes images no container uses that carry a registry digest, so docker pull \
        fetches the same bytes back. This costs download time. Images that only ever existed \
        locally stay, because nothing could fetch them again.
        """
    }
  }

  /// Whether an unused image of this shape can be had back without rebuilding it from
  /// sources the user may no longer have.
  func reclaims(_ image: DockerImage) -> Bool {
    switch self {
    case .safe:
      return image.isDangling
    case .thorough:
      // A digest means a registry served exactly these bytes and can serve them again.
      // An image with tags but no digest was built here, and its build context may be gone.
      return image.isDangling || !image.repoDigests.isEmpty
    }
  }
}

extension UsageReport {
  /// The resources an automatic cleanup at `level` removes, images before build cache.
  ///
  /// Only images and build cache records qualify, so no container leaves Docker Desktop's
  /// list and no volume contents are lost. Anything Docker would refuse without `force`,
  /// and anything that would need another resource removed first, is left out as well:
  /// an image used by a stopped container stays, rather than dragging that container into
  /// the plan. A plan built from these IDs therefore has no prerequisites and no exclusions.
  public func automaticCleanupIDs(_ level: AutomaticCleanupLevel) -> [DockerResourceID] {
    // One pass into a set: `item(for:)` scans a category, and a busy daemon has thousands
    // of build cache records to check.
    let removableNow = Set(items.lazy.filter { $0.removability.isRemovableNow }.map(\.id))
    let candidates =
      usage.images.filter(level.reclaims).map(\.resourceID) + usage.buildCache.map(\.resourceID)
    return candidates.filter(removableNow.contains)
  }
}
