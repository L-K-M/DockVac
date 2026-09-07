import Foundation

/// A single non-forcing Docker removal. The Docker driver maps these to API calls.
public enum CleanupAction: Hashable, Sendable {
  case removeContainer(id: String)
  /// Removes an image. When `references` is non-empty each tag or digest reference is
  /// removed in turn (Docker refuses to delete multi-repository images by ID without
  /// `force`); otherwise the image is deleted by ID.
  case removeImage(id: String, references: [String])
  case removeVolume(name: String)
  case pruneBuildCache(id: String)

  public var kind: DockerResourceKind {
    switch self {
    case .removeContainer: return .containers
    case .removeImage: return .images
    case .removeVolume: return .localVolumes
    case .pruneBuildCache: return .buildCache
    }
  }
}

public struct CleanupOperation: Hashable, Sendable, Identifiable {
  public let id: DockerResourceID
  public let action: CleanupAction
  /// Verb phrase such as "Remove image".
  public let title: String
  /// The resource's display name.
  public let target: String
  /// Secondary identification such as the short ID.
  public let detail: String
  public let estimatedReclaimableBytes: UInt64
  public let warnings: [String]
  /// The docker CLI command that does the same thing, shown so the user knows exactly
  /// what happens.
  public let cliEquivalent: String

  public init(
    id: DockerResourceID,
    action: CleanupAction,
    title: String,
    target: String,
    detail: String,
    estimatedReclaimableBytes: UInt64,
    warnings: [String],
    cliEquivalent: String
  ) {
    self.id = id
    self.action = action
    self.title = title
    self.target = target
    self.detail = detail
    self.estimatedReclaimableBytes = estimatedReclaimableBytes
    self.warnings = warnings
    self.cliEquivalent = cliEquivalent
  }
}

/// A selected item that the plan refused to include.
public struct CleanupExclusion: Hashable, Sendable, Identifiable {
  public let id: DockerResourceID
  public let title: String
  public let reason: String

  public init(id: DockerResourceID, title: String, reason: String) {
    self.id = id
    self.title = title
    self.reason = reason
  }
}

/// An ordered, validated list of removals derived from the user's selection.
public struct CleanupPlan: Hashable, Sendable {
  public let operations: [CleanupOperation]
  public let exclusions: [CleanupExclusion]

  public init(operations: [CleanupOperation], exclusions: [CleanupExclusion]) {
    self.operations = operations
    self.exclusions = exclusions
  }

  public static let empty = CleanupPlan(operations: [], exclusions: [])

  public var isEmpty: Bool { operations.isEmpty }

  public var estimatedReclaimableBytes: UInt64 {
    operations.reduce(0) { $0 + $1.estimatedReclaimableBytes }
  }

  public var warnings: [String] {
    operations.flatMap { $0.warnings }
  }

  /// All equivalent CLI commands, one per line.
  public var cliScript: String {
    operations.map { $0.cliEquivalent }.joined(separator: "\n")
  }

  public func counts() -> [DockerResourceKind: Int] {
    var counts: [DockerResourceKind: Int] = [:]
    for operation in operations {
      counts[operation.id.kind, default: 0] += 1
    }
    return counts
  }

  /// Summary such as "2 images, 1 volume".
  public var summary: String {
    let counts = counts()
    return DockerResourceKind.displayOrder.compactMap { kind -> String? in
      guard let count = counts[kind], count > 0 else { return nil }
      return ByteFormat.count(count, singular: kind.singularName, plural: kind.pluralName)
    }.joined(separator: ", ")
  }

  /// Builds a plan from selected resource IDs.
  ///
  /// Blocked items are excluded. Items that require other removals first are included
  /// only when every prerequisite is part of the plan too. Containers are removed first,
  /// then images, volumes, and build cache, so dependent removals succeed.
  public static func make(
    selecting selection: some Sequence<DockerResourceID>, from report: UsageReport
  ) -> CleanupPlan {
    let selected = Set(selection)
    var exclusions: [CleanupExclusion] = []
    var candidates: [DockerResourceID: UsageItem] = [:]

    for id in selected {
      guard let item = report.item(for: id) else {
        exclusions.append(
          CleanupExclusion(id: id, title: id.rawValue, reason: "No longer present in Docker."))
        continue
      }
      if case .blocked(let reason) = item.removability {
        exclusions.append(CleanupExclusion(id: id, title: item.title, reason: reason))
        continue
      }
      candidates[id] = item
    }

    // Resolve prerequisites to a fixed point: an item stays only if every prerequisite stays.
    var included = candidates
    var changed = true
    while changed {
      changed = false
      for (id, item) in included {
        let missing = item.removability.prerequisites.filter { included[$0] == nil }
        if !missing.isEmpty {
          included.removeValue(forKey: id)
          let names = missing.map { report.item(for: $0)?.title ?? dockerShortID($0.rawValue) }
          exclusions.append(
            CleanupExclusion(
              id: id,
              title: item.title,
              reason:
                "Requires removing \(names.joined(separator: ", ")) first. Add it to the cleanup as well."
            ))
          changed = true
        }
      }
    }

    let ordered = included.values.sorted { lhs, rhs in
      let lhsOrder = kindOrder(lhs.kind)
      let rhsOrder = kindOrder(rhs.kind)
      if lhsOrder != rhsOrder {
        return lhsOrder < rhsOrder
      }
      if lhs.estimatedReclaimableBytes != rhs.estimatedReclaimableBytes {
        return lhs.estimatedReclaimableBytes > rhs.estimatedReclaimableBytes
      }
      return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    let operations = ordered.map { operation(for: $0, in: report) }
    let sortedExclusions = exclusions.sorted {
      $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
    return CleanupPlan(operations: operations, exclusions: sortedExclusions)
  }

  private static func kindOrder(_ kind: DockerResourceKind) -> Int {
    switch kind {
    case .containers: return 0
    case .images: return 1
    case .localVolumes: return 2
    case .buildCache: return 3
    }
  }

  static func operation(for item: UsageItem, in report: UsageReport) -> CleanupOperation {
    switch item.kind {
    case .images:
      let image = report.usage.images.first { $0.id == item.id.rawValue }
      let references = image?.removalReferences ?? []
      let cliTargets =
        references.isEmpty ? [image?.shortID ?? dockerShortID(item.id.rawValue)] : references
      return CleanupOperation(
        id: item.id,
        action: .removeImage(id: item.id.rawValue, references: references),
        title: "Remove image",
        target: item.title,
        detail: item.subtitle,
        estimatedReclaimableBytes: item.estimatedReclaimableBytes,
        warnings: item.warnings,
        cliEquivalent: "docker image rm \(cliTargets.map(shellQuote).joined(separator: " "))"
      )
    case .containers:
      let container = report.usage.containers.first { $0.id == item.id.rawValue }
      let cliTarget = container?.names.first ?? dockerShortID(item.id.rawValue)
      return CleanupOperation(
        id: item.id,
        action: .removeContainer(id: item.id.rawValue),
        title: "Remove container",
        target: item.title,
        detail: item.subtitle,
        estimatedReclaimableBytes: item.estimatedReclaimableBytes,
        warnings: item.warnings,
        cliEquivalent: "docker container rm \(shellQuote(cliTarget))"
      )
    case .localVolumes:
      return CleanupOperation(
        id: item.id,
        action: .removeVolume(name: item.id.rawValue),
        title: "Remove volume",
        target: item.title,
        detail: item.subtitle,
        estimatedReclaimableBytes: item.estimatedReclaimableBytes,
        warnings: item.warnings,
        cliEquivalent: "docker volume rm \(shellQuote(item.id.rawValue))"
      )
    case .buildCache:
      return CleanupOperation(
        id: item.id,
        action: .pruneBuildCache(id: item.id.rawValue),
        title: "Remove build cache record",
        target: item.title,
        detail: item.subtitle,
        estimatedReclaimableBytes: item.estimatedReclaimableBytes,
        warnings: item.warnings,
        cliEquivalent:
          "docker builder prune --force --filter \(shellQuote("id=\(item.id.rawValue)"))"
      )
    }
  }

  /// Quotes a shell word only when necessary.
  static func shellQuote(_ word: String) -> String {
    let safe = word.allSatisfy { character in
      character.isLetter || character.isNumber || "-_.:/@=+".contains(character)
    }
    if safe, !word.isEmpty {
      return word
    }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

// MARK: - Execution state

public enum CleanupOperationStatus: Hashable, Sendable {
  case pending
  case running
  case succeeded(detail: String)
  case failed(message: String)
  case skipped(reason: String)

  public var isFinal: Bool {
    switch self {
    case .pending, .running: return false
    case .succeeded, .failed, .skipped: return true
    }
  }
}

/// Progress of one cleanup run. The driver mutates it as operations complete; the UI
/// renders snapshots.
public struct CleanupRunState: Hashable, Sendable {
  public let plan: CleanupPlan
  public private(set) var statuses: [CleanupOperationStatus]
  /// Bytes Docker reported as reclaimed, when the API returns that information.
  public private(set) var reportedReclaimedBytes: [UInt64?]
  public private(set) var startedAt: Date
  public private(set) var finishedAt: Date?

  public init(plan: CleanupPlan, startedAt: Date = Date()) {
    self.plan = plan
    self.statuses = Array(repeating: .pending, count: plan.operations.count)
    self.reportedReclaimedBytes = Array(repeating: nil, count: plan.operations.count)
    self.startedAt = startedAt
  }

  public var isFinished: Bool { finishedAt != nil }

  public var currentIndex: Int? {
    statuses.firstIndex { $0 == .running }
  }

  public var completedCount: Int {
    statuses.filter { $0.isFinal }.count
  }

  public var succeededCount: Int {
    statuses.filter { if case .succeeded = $0 { return true } else { return false } }.count
  }

  public var failedCount: Int {
    statuses.filter { if case .failed = $0 { return true } else { return false } }.count
  }

  public var skippedCount: Int {
    statuses.filter { if case .skipped = $0 { return true } else { return false } }.count
  }

  /// Estimated bytes freed by the operations that succeeded.
  public var estimatedFreedBytes: UInt64 {
    zip(plan.operations, statuses).reduce(0) { total, pair in
      if case .succeeded = pair.1 {
        return total + pair.0.estimatedReclaimableBytes
      }
      return total
    }
  }

  public var fractionCompleted: Double {
    guard !plan.operations.isEmpty else { return 1 }
    return Double(completedCount) / Double(plan.operations.count)
  }

  public mutating func markRunning(_ index: Int) {
    guard statuses.indices.contains(index) else { return }
    statuses[index] = .running
  }

  public mutating func markSucceeded(
    _ index: Int, detail: String, reportedReclaimedBytes bytes: UInt64? = nil
  ) {
    guard statuses.indices.contains(index) else { return }
    statuses[index] = .succeeded(detail: detail)
    reportedReclaimedBytes[index] = bytes
  }

  public mutating func markFailed(_ index: Int, message: String) {
    guard statuses.indices.contains(index) else { return }
    statuses[index] = .failed(message: message)
  }

  /// Marks every unfinished operation as skipped, e.g. after the user stops the cleanup.
  public mutating func skipRemaining(reason: String) {
    for index in statuses.indices where !statuses[index].isFinal {
      statuses[index] = .skipped(reason: reason)
    }
  }

  public mutating func finish(at date: Date = Date()) {
    skipRemaining(reason: "Not attempted.")
    finishedAt = date
  }

  /// One-line outcome such as "Removed 3 items, about 1.2 GB freed. 1 failed."
  public var summary: String {
    var parts: [String] = []
    if succeededCount > 0 {
      parts.append(
        "Removed \(ByteFormat.count(succeededCount, singular: "item", plural: "items")), about \(ByteFormat.string(estimatedFreedBytes)) freed."
      )
    } else {
      parts.append("Nothing was removed.")
    }
    if failedCount > 0 {
      parts.append("\(failedCount) failed.")
    }
    if skippedCount > 0 {
      parts.append("\(skippedCount) skipped.")
    }
    return parts.joined(separator: " ")
  }
}
