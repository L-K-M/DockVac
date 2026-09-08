import AppKit
import DockVacCore

/// The main report: breadcrumb, treemap, sidebar, and the cleanup bar.
final class ReportView: NSView, TreemapViewDelegate {
  weak var actions: ReportActions? {
    didSet {
      sidebar.actions = actions
      basketBar.actions = actions
    }
  }

  private let breadcrumbBack = NSButton(title: "", target: nil, action: nil)
  private let breadcrumbLabel = Theme.label("Docker", size: 13, weight: .semibold)
  private let hintLabel = Theme.label("", size: 11, color: .secondaryLabelColor)
  private let legend = NSStackView()
  let treemap = TreemapView(frame: .zero)
  private let sidebar = SidebarView(frame: .zero)
  private let basketBar = BasketBarView(frame: .zero)
  private let split = NSSplitView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    treemap.delegate = self

    breadcrumbBack.image = Theme.symbol("chevron.left", pointSize: 12, weight: .semibold)
    breadcrumbBack.bezelStyle = .rounded
    breadcrumbBack.controlSize = .small
    breadcrumbBack.isBordered = true
    breadcrumbBack.target = self
    breadcrumbBack.action = #selector(backPressed)
    breadcrumbBack.toolTip = "Back to the overview"

    hintLabel.alignment = .right
    hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    legend.orientation = .horizontal
    legend.spacing = 10
    legend.alignment = .centerY
    for kind in DockerResourceKind.displayOrder {
      legend.addArrangedSubview(legendEntry(color: Theme.color(for: kind), text: kind.displayName))
    }
    legend.addArrangedSubview(
      legendEntry(color: .secondaryLabelColor, text: "hatched = in use", hatched: true))

    let crumbs = NSStackView(views: [breadcrumbBack, breadcrumbLabel, legend, hintLabel])
    crumbs.orientation = .horizontal
    crumbs.alignment = .centerY
    crumbs.spacing = 10
    crumbs.setCustomSpacing(24, after: breadcrumbLabel)
    crumbs.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 14)
    crumbs.translatesAutoresizingMaskIntoConstraints = false
    breadcrumbLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    split.isVertical = true
    split.dividerStyle = .thin
    split.translatesAutoresizingMaskIntoConstraints = false
    treemap.translatesAutoresizingMaskIntoConstraints = false
    sidebar.translatesAutoresizingMaskIntoConstraints = false
    split.addArrangedSubview(treemap)
    split.addArrangedSubview(sidebar)
    split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 250), forSubviewAt: 0)
    split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 1)

    basketBar.translatesAutoresizingMaskIntoConstraints = false

    addSubview(crumbs)
    addSubview(split)
    addSubview(basketBar)

    NSLayoutConstraint.activate([
      crumbs.topAnchor.constraint(equalTo: topAnchor),
      crumbs.leadingAnchor.constraint(equalTo: leadingAnchor),
      crumbs.trailingAnchor.constraint(equalTo: trailingAnchor),
      crumbs.heightAnchor.constraint(equalToConstant: 38),
      split.topAnchor.constraint(equalTo: crumbs.bottomAnchor),
      split.leadingAnchor.constraint(equalTo: leadingAnchor),
      split.trailingAnchor.constraint(equalTo: trailingAnchor),
      basketBar.topAnchor.constraint(equalTo: split.bottomAnchor),
      basketBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      basketBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      basketBar.bottomAnchor.constraint(equalTo: bottomAnchor),
      basketBar.heightAnchor.constraint(equalToConstant: 60),
      sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
      sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
      treemap.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private var didPositionDivider = false

  override func layout() {
    super.layout()
    // Give the sidebar its intended width once real geometry exists; afterwards the user's
    // divider position is left alone across rescans.
    if !didPositionDivider, split.bounds.width > 0 {
      didPositionDivider = true
      split.setPosition(max(400, split.bounds.width - 360), ofDividerAt: 0)
    }
  }

  private func legendEntry(color: NSColor, text: String, hatched: Bool = false) -> NSView {
    let swatch = LegendSwatch(color: color, hatched: hatched)
    swatch.translatesAutoresizingMaskIntoConstraints = false
    swatch.widthAnchor.constraint(equalToConstant: 12).isActive = true
    swatch.heightAnchor.constraint(equalToConstant: 12).isActive = true
    let label = Theme.label(text, size: 11, color: .secondaryLabelColor)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    let entry = NSStackView(views: [swatch, label])
    entry.orientation = .horizontal
    entry.spacing = 4
    entry.alignment = .centerY
    return entry
  }

  func apply(_ state: ReportViewState) {
    treemap.report = state.report
    treemap.focus = state.focus
    treemap.selectedItem = state.selectedItem
    treemap.selectedCategory = state.selectedCategory
    treemap.basket = state.basket

    if let focus = state.focus {
      breadcrumbLabel.stringValue = "Docker › \(focus.displayName)"
      breadcrumbBack.isEnabled = true
      hintLabel.stringValue = "Double-click a tile to select it for cleanup. Press ⌘↑ to go back."
    } else {
      breadcrumbLabel.stringValue = "Docker"
      breadcrumbBack.isEnabled = false
      hintLabel.stringValue = "Area = disk space. Double-click a category to zoom in."
    }
    sidebar.apply(state)
    basketBar.apply(state)
  }

  @objc private func backPressed() {
    actions?.focus(on: nil)
  }

  // MARK: - TreemapViewDelegate

  func treemapView(_ view: TreemapView, didSelectItem id: DockerResourceID?) {
    actions?.select(item: id)
  }

  func treemapView(_ view: TreemapView, didSelectCategory kind: DockerResourceKind?) {
    actions?.select(category: kind)
  }

  func treemapView(_ view: TreemapView, didRequestFocus kind: DockerResourceKind?) {
    actions?.focus(on: kind)
  }

  func treemapView(_ view: TreemapView, didToggleBasket id: DockerResourceID) {
    actions?.toggleBasket(id)
  }

  func treemapView(_ view: TreemapView, copy text: String) {
    actions?.copyToPasteboard(text)
  }
}

/// A small colour swatch, optionally hatched to explain the in-use pattern.
final class LegendSwatch: NSView {
  private let color: NSColor
  private let hatched: Bool

  init(color: NSColor, hatched: Bool) {
    self.color = color
    self.hatched = hatched
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
    color.withAlphaComponent(hatched ? 0.3 : 0.85).setFill()
    path.fill()
    if hatched {
      NSGraphicsContext.saveGraphicsState()
      path.addClip()
      let lines = NSBezierPath()
      var offset: CGFloat = -bounds.height
      while offset < bounds.width {
        lines.move(to: NSPoint(x: offset, y: 0))
        lines.line(to: NSPoint(x: offset + bounds.height, y: bounds.height))
        offset += 4
      }
      NSColor.labelColor.withAlphaComponent(0.5).setStroke()
      lines.stroke()
      NSGraphicsContext.restoreGraphicsState()
    }
  }
}
