import AppKit

@main
@MainActor
struct DockVacMain {
  static func main() {
    let application = NSApplication.shared
    let delegate = DockVacApplicationDelegate()
    application.delegate = delegate
    // NSApplication holds its delegate weakly; keep it alive for the whole run loop.
    withExtendedLifetime(delegate) {
      application.run()
    }
  }
}

@MainActor
private final class DockVacApplicationDelegate: NSObject, NSApplicationDelegate {
  private var controller: AppController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)

    let controller = AppController()
    self.controller = controller
    application.mainMenu = MainMenu.build(for: controller)
    controller.start()
    application.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag {
      controller?.windowController.showWindow(nil)
    }
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let controller, controller.isCleaning else {
      return .terminateNow
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "A cleanup is still running"
    alert.informativeText =
      "Docker finishes the operation that is in progress either way, but DockVac will not be able to show you its result. Quit anyway?"
    alert.addButton(withTitle: "Keep Running")
    alert.addButton(withTitle: "Quit")
    return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
  }
}
