import DockVacCore
import Foundation

/// Executes a `CleanupPlan` one operation at a time.
///
/// Stopping is cooperative: cancelling the surrounding task lets the operation that is
/// already talking to Docker finish, then marks everything after it as skipped. A removal
/// is never interrupted half-way, so the UI always knows what really happened.
///
/// Two safety rules hold regardless of what the plan says: an operation whose prerequisite
/// did not succeed is skipped rather than attempted, and an image that must be removed tag
/// by tag is checked first so a tag that was re-pointed since the scan is never untagged.
public struct CleanupRunner: Sendable {
  public let client: DockerEngineClient

  public init(client: DockerEngineClient) {
    self.client = client
  }

  public func run(
    _ plan: CleanupPlan, onProgress: @escaping @Sendable (CleanupRunState) -> Void
  ) async -> CleanupRunState {
    var state = CleanupRunState(plan: plan)
    onProgress(state)

    for (index, operation) in plan.operations.enumerated() {
      if Task.isCancelled {
        state.skipRemaining(reason: "Stopped by user.")
        break
      }
      let unmet = state.unmetPrerequisites(of: index)
      if !unmet.isEmpty {
        let names = unmet.map { $0.target }.joined(separator: ", ")
        state.markSkipped(index, reason: "Not attempted: \(names) could not be removed first.")
        onProgress(state)
        continue
      }
      state.markRunning(index)
      onProgress(state)

      let client = self.client
      let action = operation.action
      // Detached so a Stop request never tears down a request Docker is already acting on.
      let outcome = await Task.detached(priority: .userInitiated) {
        await Self.execute(action, using: client)
      }.value

      switch outcome {
      case .succeeded(let detail, let reclaimed):
        state.markSucceeded(index, detail: detail, reportedReclaimedBytes: reclaimed)
      case .failed(let message):
        state.markFailed(index, message: message)
      }
      onProgress(state)
    }

    state.finish()
    onProgress(state)
    return state
  }

  enum Outcome: Hashable, Sendable {
    case succeeded(detail: String, reclaimedBytes: UInt64?)
    case failed(message: String)
  }

  static func execute(_ action: CleanupAction, using client: DockerEngineClient) async -> Outcome {
    do {
      switch action {
      case .removeContainer(let id):
        try await client.removeContainer(id: id)
        return .succeeded(detail: "Container removed.", reclaimedBytes: nil)

      case .removeImage(let id, let references):
        return try await removeImage(id: id, references: references, using: client)

      case .removeVolume(let name):
        try await client.removeVolume(name: name)
        return .succeeded(detail: "Volume removed.", reclaimedBytes: nil)

      case .pruneBuildCache(let id):
        let result = try await client.pruneBuildCache(id: id)
        guard result.cachesDeleted.contains(id) else {
          return .failed(
            message:
              "Docker did not remove this cache record. It may be in use by a build, or it was already gone."
          )
        }
        return .succeeded(
          detail: "Freed \(ByteFormat.string(result.spaceReclaimedBytes)).",
          reclaimedBytes: result.spaceReclaimedBytes)
      }
    } catch {
      return .failed(message: dockerErrorMessage(error))
    }
  }

  private static func removeImage(
    id: String, references: [String], using client: DockerEngineClient
  ) async throws -> Outcome {
    if references.isEmpty {
      // Deleting by ID can never hit a different image than the one that was selected.
      let items = try await client.removeImage(reference: id)
      return .succeeded(detail: describe(items), reclaimedBytes: nil)
    }

    // Docker untags each reference before it checks whether a container still uses the
    // image, so refuse up front rather than leave the image half-untagged.
    let users = try await client.listContainers().filter { $0.imageID == id }
    if !users.isEmpty {
      let names = users.map { $0.displayName }.joined(separator: ", ")
      return .failed(
        message:
          "Still used by container \(names), which was started or created after the scan. Nothing was removed."
      )
    }

    var items: [ImageDeleteItem] = []
    for (index, reference) in references.enumerated() {
      let progress =
        index == 0
        ? "Nothing was removed." : "Removed \(index) of \(references.count) references first."
      let isDigest = reference.contains("@")
      do {
        let current = try await client.imageID(forReference: reference)
        guard current == id else {
          return .failed(
            message:
              "\(reference) now points to a different image (\(dockerShortID(current))), not the one you selected. \(progress)"
          )
        }
      } catch DockerEngineError.api(let status, _) where status == 404 {
        if isDigest {
          // Digest references disappear together with the last tag of their repository.
          continue
        }
        return .failed(message: "\(reference) no longer exists. \(progress)")
      }
      do {
        items += try await client.removeImage(reference: reference)
      } catch {
        return .failed(message: "\(dockerErrorMessage(error)) \(progress)")
      }
    }
    return .succeeded(detail: describe(items), reclaimedBytes: nil)
  }

  private static func describe(_ items: [ImageDeleteItem]) -> String {
    let untagged = items.filter { $0.untagged != nil }.count
    let deleted = items.filter { $0.deleted != nil }.count
    var parts: [String] = []
    if untagged > 0 {
      parts.append(
        "untagged \(ByteFormat.count(untagged, singular: "reference", plural: "references"))")
    }
    if deleted > 0 {
      parts.append("deleted \(ByteFormat.count(deleted, singular: "layer", plural: "layers"))")
    }
    if parts.isEmpty {
      return "Image removed."
    }
    let sentence = parts.joined(separator: ", ")
    return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
  }
}
