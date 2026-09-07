import AppKit

@main
@MainActor
struct DockVacMain {
  static func main() {
    let application = NSApplication.shared
    let delegate = DockVacApplicationDelegate()
    application.delegate = delegate
    application.run()
  }
}

@MainActor
private final class DockVacApplicationDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.mainMenu = makeMainMenu()

    let window = makeWindow()
    self.window = window
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "DockVac"
    window.center()
    window.isReleasedWhenClosed = false
    window.contentView = makeContentView()

    return window
  }

  private func makeContentView() -> NSView {
    let title = NSTextField(labelWithString: "DockVac")
    title.font = .systemFont(ofSize: 32, weight: .semibold)
    title.alignment = .center

    let statusText =
      "Ready to inspect Docker storage. Cleanup controls are not implemented yet."
    let status = NSTextField(wrappingLabelWithString: statusText)
    status.textColor = .secondaryLabelColor
    status.alignment = .center

    let stack = NSStackView(views: [title, status])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false

    let content = NSView()
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 32),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -32),
    ])

    return content
  }

  private func makeMainMenu() -> NSMenu {
    let mainMenu = NSMenu()
    let applicationItem = NSMenuItem()
    mainMenu.addItem(applicationItem)

    let applicationMenu = NSMenu()
    applicationItem.submenu = applicationMenu
    applicationMenu.addItem(
      withTitle: "About DockVac",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(
      withTitle: "Quit DockVac",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )

    return mainMenu
  }
}
