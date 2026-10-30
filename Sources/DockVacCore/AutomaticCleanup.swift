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
        Also removes images no container uses whose every tag comes from a registry, so \
        docker pull fetches the same bytes back, as long as you can still reach that \
        registry and it still serves that digest. Images built locally stay, and so does \
        an image carrying a tag no registry knows, because a pull would not bring that \
        tag back.
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
      if image.isDangling {
        return true
      }
      // A digest records that a registry served exactly these bytes, so a pull can ask for
      // them again. Removing an image removes every one of its tags with it, though, and a
      // tag in a repository no digest covers was made here: no pull would bring it back.
      guard !image.repoDigests.isEmpty else {
        return false
      }
      let digestRepositories = Set(image.repoDigests.map(DockerImage.repository(of:)))
      return image.repoTags.allSatisfy {
        digestRepositories.contains(DockerImage.repository(of: $0))
      }
    }
  }
}

extension UsageReport {
  /// The resources an automatic cleanup at `level` removes.
  ///
  /// Only images and build cache records qualify, so no container leaves Docker Desktop's
  /// list and no volume contents are lost. Anything Docker would refuse without `force`,
  /// and anything that would need another resource removed first, is left out as well:
  /// an image used by a stopped container stays, rather than dragging that container into
  /// the plan. A plan built from these IDs therefore has no prerequisites and no exclusions.
  ///
  /// That guarantee describes the report these IDs came from. Plan them with
  /// `CleanupPlan.make`, which orders the operations and drops an item whose prerequisites
  /// are absent. Expanding them with `selectionClosure` against a later snapshot would
  /// instead pull in a container that appeared in between.
  public func automaticCleanupIDs(_ level: AutomaticCleanupLevel) -> [DockerResourceID] {
    // One pass into a set: `item(for:)` scans a category, and a busy daemon has thousands
    // of build cache records to check.
    let removableNow = Set(items.lazy.filter { $0.removability.isRemovableNow }.map(\.id))
    let candidates =
      usage.images.filter(level.reclaims).map(\.resourceID) + usage.buildCache.map(\.resourceID)
    return candidates.filter(removableNow.contains)
  }
}
