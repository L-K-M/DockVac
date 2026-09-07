import Foundation

/// Whether DockVac may remove a resource, and what stands in the way.
public enum Removability: Hashable, Sendable {
  /// Docker will accept a non-forced removal right now.
  case removable
  /// Removal works only after the listed resources are removed first in the same cleanup.
  case requires(prerequisites: [DockerResourceID], reason: String)
  /// DockVac refuses to remove this; the reason is shown to the user.
  case blocked(reason: String)

  public var isRemovableNow: Bool {
    if case .removable = self { return true }
    return false
  }

  public var isBlocked: Bool {
    if case .blocked = self { return true }
    return false
  }

  public var prerequisites: [DockerResourceID] {
    if case .requires(let prerequisites, _) = self { return prerequisites }
    return []
  }

  public var explanation: String? {
    switch self {
    case .removable: return nil
    case .requires(_, let reason): return reason
    case .blocked(let reason): return reason
    }
  }
}

public struct UsageNote: Hashable, Sendable {
  public enum Severity: Hashable, Sendable {
    case info
    case warning
  }

  public let severity: Severity
  public let text: String

  public init(_ severity: Severity, _ text: String) {
    self.severity = severity
    self.text = text
  }
}

public struct UsageDetail: Hashable, Sendable {
  public let label: String
  public let value: String

  public init(_ label: String, _ value: String) {
    self.label = label
    self.value = value
  }
}

/// Visual emphasis for an item's status.
public enum UsageTone: Hashable, Sendable {
  /// Removing it frees space and Docker considers it unused.
  case reclaimable
  /// Removable, but it may hold data the user still wants.
  case caution
  /// Cannot be removed right now.
  case locked
}

/// One Docker resource as shown in the visualisation and the sidebar.
public struct UsageItem: Hashable, Sendable, Identifiable {
  public let id: DockerResourceID
  public let title: String
  public let subtitle: String
  /// Bytes attributed to this item in the treemap: its unique share of disk.
  public let attributedBytes: UInt64
  /// Full size as Docker reports it, which may include bytes shared with other items.
  public let totalBytes: UInt64?
  /// Estimated bytes freed by removing this item; zero when removal is blocked.
  public let estimatedReclaimableBytes: UInt64
  public let statusText: String
  public let tone: UsageTone
  public let removability: Removability
  public let notes: [UsageNote]
  public let details: [UsageDetail]
  public let created: Date?

  public init(
    id: DockerResourceID,
    title: String,
    subtitle: String,
    attributedBytes: UInt64,
    totalBytes: UInt64?,
    estimatedReclaimableBytes: UInt64,
    statusText: String,
    tone: UsageTone,
    removability: Removability,
    notes: [UsageNote],
    details: [UsageDetail],
    created: Date?
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.attributedBytes = attributedBytes
    self.totalBytes = totalBytes
    self.estimatedReclaimableBytes = removability.isBlocked ? 0 : estimatedReclaimableBytes
    self.statusText = statusText
    self.tone = tone
    self.removability = removability
    self.notes = notes
    self.details = details
    self.created = created
  }

  public var kind: DockerResourceKind { id.kind }

  public var warnings: [String] {
    notes.filter { $0.severity == .warning }.map { $0.text }
  }

  /// Identifier of the synthetic tile that accounts for layers shared between images.
  public static let sharedLayersID = DockerResourceID(kind: .images, rawValue: "shared-layers")

  public var isSyntheticSharedLayers: Bool {
    id == Self.sharedLayersID
  }
}

public struct UsageCategory: Hashable, Sendable, Identifiable {
  public let kind: DockerResourceKind
  /// Sorted by attributed size descending, then title.
  public let items: [UsageItem]

  public init(kind: DockerResourceKind, items: [UsageItem]) {
    self.kind = kind
    self.items = items.sorted {
      if $0.attributedBytes != $1.attributedBytes {
        return $0.attributedBytes > $1.attributedBytes
      }
      return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  public var id: DockerResourceKind { kind }

  public var attributedBytes: UInt64 {
    items.reduce(0) { $0 + $1.attributedBytes }
  }

  /// Bytes that could be freed right now without removing anything else first.
  public var reclaimableBytes: UInt64 {
    items.filter { $0.removability.isRemovableNow }.reduce(0) { $0 + $1.estimatedReclaimableBytes }
  }

  public var removableCount: Int {
    items.filter { $0.removability.isRemovableNow }.count
  }
}

/// Analysed disk usage ready for display.
public struct UsageReport: Hashable, Sendable {
  public let usage: DockerDiskUsage
  public let categories: [UsageCategory]
  public let capturedAt: Date

  public init(usage: DockerDiskUsage, categories: [UsageCategory], capturedAt: Date) {
    self.usage = usage
    self.categories = categories
    self.capturedAt = capturedAt
  }

  public static let empty = UsageReport(
    usage: .empty,
    categories: DockerResourceKind.displayOrder.map { UsageCategory(kind: $0, items: []) },
    capturedAt: Date(timeIntervalSince1970: 0)
  )

  public func category(for kind: DockerResourceKind) -> UsageCategory? {
    categories.first { $0.kind == kind }
  }

  public var items: [UsageItem] {
    categories.flatMap { $0.items }
  }

  public func item(for id: DockerResourceID) -> UsageItem? {
    category(for: id.kind)?.items.first { $0.id == id }
  }

  public var totalAttributedBytes: UInt64 {
    categories.reduce(0) { $0 + $1.attributedBytes }
  }

  public var totalReclaimableBytes: UInt64 {
    categories.reduce(0) { $0 + $1.reclaimableBytes }
  }

  public var itemCount: Int {
    categories.reduce(0) { $0 + $1.items.count }
  }

  /// The same snapshot with only the items that pass `isIncluded`.
  public func filtered(_ isIncluded: (UsageItem) -> Bool) -> UsageReport {
    UsageReport(
      usage: usage,
      categories: categories.map {
        UsageCategory(kind: $0.kind, items: $0.items.filter(isIncluded))
      },
      capturedAt: capturedAt
    )
  }

  /// The selected IDs plus every prerequisite they need, so a plan built from the result
  /// never excludes an item for a missing prerequisite.
  public func selectionClosure(_ ids: some Sequence<DockerResourceID>) -> Set<DockerResourceID> {
    var closure = Set<DockerResourceID>()
    var pending = Array(ids)
    while let id = pending.popLast() {
      guard closure.insert(id).inserted, let item = item(for: id) else { continue }
      pending.append(contentsOf: item.removability.prerequisites)
    }
    return closure
  }

  /// Items that are safe to remove without losing user data: dangling images that no
  /// container uses, and build cache records that no build is using.
  public var safeSuggestionIDs: [DockerResourceID] {
    var ids: [DockerResourceID] = []
    for image in usage.images where image.isDangling {
      if let item = item(for: image.resourceID), item.removability.isRemovableNow {
        ids.append(item.id)
      }
    }
    for record in usage.buildCache {
      if let item = item(for: record.resourceID), item.removability.isRemovableNow {
        ids.append(item.id)
      }
    }
    return ids
  }
}

/// Derives relationships, reclaimability, and user-facing notes from a usage snapshot.
public enum UsageAnalyzer {
  public static func analyze(_ usage: DockerDiskUsage, capturedAt: Date = Date()) -> UsageReport {
    let containersByImage = Dictionary(grouping: usage.containers, by: { $0.imageID })
    var containersByVolume: [String: [DockerContainer]] = [:]
    for container in usage.containers {
      for volume in container.volumeNames {
        containersByVolume[volume, default: []].append(container)
      }
    }

    var images = usage.images.map { image in
      analyzeImage(image, containers: containersByImage[image.id] ?? [])
    }
    if let shared = sharedLayersItem(usage) {
      images.append(shared)
    }
    let containers = usage.containers.map { container in
      analyzeContainer(container, volumes: usage.volumes)
    }
    let volumes = usage.volumes.map { volume in
      analyzeVolume(volume, containers: containersByVolume[volume.name] ?? [])
    }
    let buildCache = usage.buildCache.map(analyzeBuildCache)

    return UsageReport(
      usage: usage,
      categories: [
        UsageCategory(kind: .images, items: images),
        UsageCategory(kind: .containers, items: containers),
        UsageCategory(kind: .localVolumes, items: volumes),
        UsageCategory(kind: .buildCache, items: buildCache),
      ],
      capturedAt: capturedAt
    )
  }

  // MARK: - Images

  static func analyzeImage(_ image: DockerImage, containers: [DockerContainer]) -> UsageItem {
    let active = containers.filter { $0.state.isActive }
    let stopped = containers.filter { !$0.state.isActive }

    let removability: Removability
    let statusText: String
    let tone: UsageTone
    if !active.isEmpty {
      removability = .blocked(
        reason:
          "Used by running \(containerList(active)). Stop the container first if you really want to remove this image."
      )
      statusText =
        "In use by \(ByteFormat.count(active.count, singular: "running container", plural: "running containers"))"
      tone = .locked
    } else if !stopped.isEmpty {
      removability = .requires(
        prerequisites: stopped.map { $0.resourceID },
        reason:
          "Used by stopped \(containerList(stopped)). Remove that container first; DockVac can do both in one cleanup."
      )
      statusText =
        "Used by \(ByteFormat.count(stopped.count, singular: "stopped container", plural: "stopped containers"))"
      tone = .caution
    } else if image.isDangling {
      removability = .removable
      statusText = "Dangling (untagged)"
      tone = .reclaimable
    } else {
      removability = .removable
      statusText = "Unused (no containers)"
      tone = .reclaimable
    }

    var notes: [UsageNote] = []
    if image.isDangling {
      notes.append(
        .init(
          .info, "Untagged leftover from a rebuild or a newer pull. Nothing references it by name.")
      )
    }
    if image.repoDigests.isEmpty {
      notes.append(
        .init(.warning, "Built or loaded locally. It cannot be pulled again from a registry."))
    } else {
      notes.append(.init(.info, "Pulled from a registry, so it can be downloaded again."))
    }
    if image.sharedSizeBytes > 0 {
      notes.append(
        .init(
          .info,
          "Shares \(ByteFormat.string(image.sharedSizeBytes)) of layers with other images. Removing it frees about \(ByteFormat.string(image.uniqueSizeBytes))."
        ))
    }
    if image.repoTags.count > 1 {
      notes.append(
        .init(
          .info,
          "Tagged \(image.repoTags.count) times: \(image.repoTags.joined(separator: ", ")). All tags are removed together."
        ))
    }

    var details: [UsageDetail] = [
      .init("ID", image.id),
      .init("Tags", image.repoTags.isEmpty ? "none" : image.repoTags.joined(separator: "\n")),
    ]
    if !image.repoDigests.isEmpty {
      details.append(.init("Digests", image.repoDigests.joined(separator: "\n")))
    }
    details.append(.init("Size", ByteFormat.string(image.sizeBytes)))
    details.append(.init("Shared", ByteFormat.string(image.sharedSizeBytes)))
    details.append(.init("Unique", ByteFormat.string(image.uniqueSizeBytes)))
    details.append(.init("Containers", containers.isEmpty ? "none" : containerList(containers)))
    if let created = image.created {
      details.append(.init("Created", DateFormat.absolute(created)))
    }

    var subtitleParts = [image.shortID]
    if image.repoTags.count > 1 {
      subtitleParts.append("\(image.repoTags.count) tags")
    }

    return UsageItem(
      id: image.resourceID,
      title: image.displayName,
      subtitle: subtitleParts.joined(separator: " · "),
      attributedBytes: image.uniqueSizeBytes,
      totalBytes: image.sizeBytes,
      estimatedReclaimableBytes: image.uniqueSizeBytes,
      statusText: statusText,
      tone: tone,
      removability: removability,
      notes: notes,
      details: details,
      created: image.created
    )
  }

  /// Layers shared by several images belong to none of them individually, yet they occupy
  /// disk. This tile makes the images category add up to Docker's own layer total.
  static func sharedLayersItem(_ usage: DockerDiskUsage) -> UsageItem? {
    guard let layersSize = usage.layersSizeBytes, !usage.images.isEmpty else { return nil }
    let unique = usage.images.reduce(UInt64(0)) { $0 + $1.uniqueSizeBytes }
    guard layersSize > unique else { return nil }
    let sharedBytes = layersSize - unique
    let sharing = usage.images.filter { $0.sharedSizeBytes > 0 }

    return UsageItem(
      id: UsageItem.sharedLayersID,
      title: "Shared image layers",
      subtitle: "shared by \(ByteFormat.count(sharing.count, singular: "image", plural: "images"))",
      attributedBytes: sharedBytes,
      totalBytes: sharedBytes,
      estimatedReclaimableBytes: 0,
      statusText: "Shared between images",
      tone: .locked,
      removability: .blocked(
        reason:
          "These layers are used by several images at once. They are freed automatically once every image that uses them is removed."
      ),
      notes: [
        .init(
          .info,
          "Docker stores each layer once. When images share a base image, the shared part is counted here instead of in any one image."
        )
      ],
      details: [
        .init("Size", ByteFormat.string(sharedBytes)),
        .init(
          "Shared by",
          sharing.isEmpty ? "unknown" : sharing.map { $0.displayName }.joined(separator: "\n")),
      ],
      created: nil
    )
  }

  // MARK: - Containers

  static func analyzeContainer(_ container: DockerContainer, volumes: [DockerVolume]) -> UsageItem {
    let removability: Removability
    let statusText: String
    let tone: UsageTone
    if container.state.isActive {
      removability = .blocked(
        reason:
          "The container is \(container.state.displayName.lowercased()). DockVac never stops or force-removes containers; stop it in Docker first."
      )
      statusText = container.status.isEmpty ? container.state.displayName : container.status
      tone = .locked
    } else {
      removability = .removable
      statusText =
        container.status.isEmpty
        ? container.state.displayName : "\(container.state.displayName) · \(container.status)"
      tone = .caution
    }

    let volumesByName = Dictionary(uniqueKeysWithValues: volumes.map { ($0.name, $0) })
    let mountedVolumes = container.volumeNames.compactMap { volumesByName[$0] }
    let anonymous = mountedVolumes.filter { $0.isAnonymous }
    let named = mountedVolumes.filter { !$0.isAnonymous }

    var notes: [UsageNote] = []
    if container.sizeRwBytes > 0 {
      notes.append(
        .init(
          .warning,
          "Removing deletes \(ByteFormat.string(container.sizeRwBytes)) of changes made inside the container (files written to its writable layer)."
        ))
    } else {
      notes.append(
        .init(
          .info, "The container has no changes in its writable layer; only its metadata is removed."
        ))
    }
    if !named.isEmpty {
      notes.append(
        .init(.info, "Named volumes are kept: \(named.map { $0.name }.joined(separator: ", "))."))
    }
    if !anonymous.isEmpty {
      notes.append(
        .init(
          .info,
          "Its \(ByteFormat.count(anonymous.count, singular: "anonymous volume", plural: "anonymous volumes")) stay on disk and show up as unused volumes afterwards."
        ))
    }
    if let project = container.labels["com.docker.compose.project"] {
      let service = container.labels["com.docker.compose.service"].map { " (service \($0))" } ?? ""
      notes.append(
        .init(
          .info,
          "Part of Docker Compose project \(project)\(service). Compose recreates it on the next `up`."
        ))
    }

    var details: [UsageDetail] = [
      .init("ID", container.id),
      .init("Name", container.names.isEmpty ? "none" : container.names.joined(separator: ", ")),
      .init(
        "Image",
        container.imageReference.isEmpty
          ? dockerShortID(container.imageID)
          : "\(container.imageReference) (\(dockerShortID(container.imageID)))"),
      .init("Command", container.command.isEmpty ? "none" : container.command),
      .init("State", container.status.isEmpty ? container.state.displayName : container.status),
      .init("Writable", ByteFormat.string(container.sizeRwBytes)),
      .init("Root FS", ByteFormat.string(container.sizeRootFsBytes)),
    ]
    if !container.mounts.isEmpty {
      details.append(
        .init(
          "Mounts",
          container.mounts.map { mount in
            let source = mount.volumeName ?? mount.source ?? mount.type
            return "\(source) → \(mount.destination)\(mount.readWrite ? "" : " (read-only)")"
          }.joined(separator: "\n")
        ))
    }
    if let created = container.created {
      details.append(.init("Created", DateFormat.absolute(created)))
    }

    return UsageItem(
      id: container.resourceID,
      title: container.displayName,
      subtitle:
        "\(container.shortID) · \(container.imageReference.isEmpty ? dockerShortID(container.imageID) : container.imageReference)",
      attributedBytes: container.sizeRwBytes,
      totalBytes: container.sizeRootFsBytes,
      estimatedReclaimableBytes: container.sizeRwBytes,
      statusText: statusText,
      tone: tone,
      removability: removability,
      notes: notes,
      details: details,
      created: container.created
    )
  }

  // MARK: - Volumes

  static func analyzeVolume(_ volume: DockerVolume, containers: [DockerContainer]) -> UsageItem {
    let active = containers.filter { $0.state.isActive }
    let stopped = containers.filter { !$0.state.isActive }

    let removability: Removability
    let statusText: String
    let tone: UsageTone
    if !active.isEmpty {
      removability = .blocked(
        reason: "Mounted by running \(containerList(active)). Stop the container first.")
      statusText =
        "Mounted by \(ByteFormat.count(active.count, singular: "running container", plural: "running containers"))"
      tone = .locked
    } else if !stopped.isEmpty {
      removability = .requires(
        prerequisites: stopped.map { $0.resourceID },
        reason:
          "Mounted by stopped \(containerList(stopped)). Remove that container first; DockVac can do both in one cleanup."
      )
      statusText =
        "Mounted by \(ByteFormat.count(stopped.count, singular: "stopped container", plural: "stopped containers"))"
      tone = .caution
    } else if let references = volume.referenceCount, references > 0 {
      removability = .blocked(
        reason:
          "Docker reports \(references) reference(s) to this volume from resources DockVac cannot see."
      )
      statusText = "In use (\(references) references)"
      tone = .locked
    } else {
      removability = .removable
      statusText = "Not mounted by any container"
      tone = .caution
    }

    var notes: [UsageNote] = [
      .init(
        .warning,
        "Volume contents are deleted permanently. Docker cannot recover them, so make sure nothing you need lives here."
      )
    ]
    if volume.isAnonymous {
      notes.append(
        .init(
          .info,
          "Anonymous volume created automatically by a container, typically for a VOLUME instruction in its image."
        ))
    }
    if let project = volume.composeProject {
      notes.append(
        .init(
          .info,
          "Belongs to Docker Compose project \(project). Compose recreates an empty volume on the next `up`."
        ))
    }
    if volume.sizeBytes == nil {
      notes.append(.init(.info, "Docker did not report a size for this volume."))
    }

    var details: [UsageDetail] = [
      .init("Name", volume.name),
      .init("Driver", volume.driver.isEmpty ? "unknown" : volume.driver),
      .init("Size", ByteFormat.string(volume.sizeBytes)),
      .init("Used by", containers.isEmpty ? "no containers" : containerList(containers)),
    ]
    if !volume.mountpoint.isEmpty {
      details.append(.init("Mountpoint", volume.mountpoint))
    }
    if let created = volume.createdAt {
      details.append(.init("Created", DateFormat.absolute(created)))
    }
    let labels = volume.labels.filter { !$0.key.hasPrefix("com.docker.volume.") }
    if !labels.isEmpty {
      details.append(
        .init(
          "Labels", labels.keys.sorted().map { "\($0)=\(labels[$0] ?? "")" }.joined(separator: "\n")
        ))
    }

    return UsageItem(
      id: volume.resourceID,
      title: volume.displayName,
      subtitle: volume.isAnonymous
        ? "anonymous volume" : (volume.composeProject.map { "compose: \($0)" } ?? volume.driver),
      attributedBytes: volume.sizeBytes ?? 0,
      totalBytes: volume.sizeBytes,
      estimatedReclaimableBytes: volume.sizeBytes ?? 0,
      statusText: statusText,
      tone: tone,
      removability: removability,
      notes: notes,
      details: details,
      created: volume.createdAt
    )
  }

  // MARK: - Build cache

  static func analyzeBuildCache(_ record: BuildCacheRecord) -> UsageItem {
    let removability: Removability
    let statusText: String
    let tone: UsageTone
    if record.inUse {
      removability = .blocked(reason: "A build is using this cache record right now.")
      statusText = "In use by a running build"
      tone = .locked
    } else {
      removability = .removable
      statusText = record.shared ? "Shared with other cache records" : "Reclaimable"
      tone = .reclaimable
    }

    var notes: [UsageNote] = [
      .init(
        .info,
        "Build cache is recreated automatically the next time you build; removing it only costs build time."
      )
    ]
    if record.shared {
      notes.append(
        .init(
          .info,
          "Shared with other cache records, so the space may only be freed once all of them are removed."
        ))
    }

    var details: [UsageDetail] = [
      .init("ID", record.id),
      .init("Type", record.typeDisplayName),
      .init("Description", record.recordDescription.isEmpty ? "none" : record.recordDescription),
      .init("Size", ByteFormat.string(record.sizeBytes)),
      .init("Used", ByteFormat.count(record.usageCount, singular: "time", plural: "times")),
    ]
    if let lastUsed = record.lastUsedAt {
      details.append(.init("Last used", DateFormat.absolute(lastUsed)))
    }
    if let created = record.createdAt {
      details.append(.init("Created", DateFormat.absolute(created)))
    }
    if !record.parents.isEmpty {
      details.append(
        .init("Parents", record.parents.map { String($0.prefix(12)) }.joined(separator: ", ")))
    }

    return UsageItem(
      id: record.resourceID,
      title: record.displayName,
      subtitle: "\(record.typeDisplayName) · \(record.shortID)",
      attributedBytes: record.sizeBytes,
      totalBytes: record.sizeBytes,
      estimatedReclaimableBytes: record.sizeBytes,
      statusText: statusText,
      tone: tone,
      removability: removability,
      notes: notes,
      details: details,
      created: record.createdAt
    )
  }

  // MARK: - Helpers

  private static func containerList(_ containers: [DockerContainer]) -> String {
    let names = containers.map { $0.displayName }
    if names.count == 1 {
      return "container \(names[0])"
    }
    return "containers \(names.joined(separator: ", "))"
  }
}

/// Date presentation shared by the core and the app.
public enum DateFormat {
  public static func absolute(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  /// Coarse relative description such as "3 days ago", matching Docker's CLI wording.
  public static func relative(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    let minute = 60.0
    let hour = 3_600.0
    let day = 86_400.0
    switch seconds {
    case ..<minute: return "just now"
    case ..<hour: return plural(Int(seconds / minute), "minute")
    case ..<day: return plural(Int(seconds / hour), "hour")
    case ..<(day * 30): return plural(Int(seconds / day), "day")
    case ..<(day * 365): return plural(Int(seconds / (day * 30)), "month")
    default: return plural(Int(seconds / (day * 365)), "year")
    }
  }

  private static func plural(_ count: Int, _ unit: String) -> String {
    "\(count) \(unit)\(count == 1 ? "" : "s") ago"
  }
}
