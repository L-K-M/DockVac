import DockVacCore
import DockVacDocker
import Foundation

/// What the main window shows.
enum AppPhase: Equatable {
  case idle
  case connecting
  case scanning(ScanProgress?)
  case report
  case failed(title: String, message: String)

  var isScanning: Bool {
    switch self {
    case .connecting, .scanning: return true
    case .idle, .report, .failed: return false
    }
  }
}

enum ReportFilter: Int, CaseIterable {
  case everything = 0
  case reclaimable = 1

  var title: String {
    switch self {
    case .everything: return "Everything"
    case .reclaimable: return "Reclaimable"
    }
  }
}

/// Everything the report views need to draw themselves. Built by the controller on every
/// change; views compare what they care about and update only that.
struct ReportViewState {
  /// The report after the filter is applied; drives the treemap and the list.
  let report: UsageReport
  /// The unfiltered report; drives totals and plan building.
  let fullReport: UsageReport
  let focus: DockerResourceKind?
  let selectedItem: DockerResourceID?
  let selectedCategory: DockerResourceKind?
  let basket: Set<DockerResourceID>
  let plan: CleanupPlan
  let filter: ReportFilter
  let connection: DockerConnection?
}

/// Actions the report views can ask the controller to perform.
@MainActor
protocol ReportActions: AnyObject {
  func select(item: DockerResourceID?)
  func select(category: DockerResourceKind?)
  func focus(on kind: DockerResourceKind?)
  func toggleBasket(_ id: DockerResourceID)
  func addToBasket(_ ids: [DockerResourceID])
  func removeFromBasket(_ ids: [DockerResourceID])
  func clearBasket()
  func reviewAndRemove()
  func copyToPasteboard(_ text: String)
}
