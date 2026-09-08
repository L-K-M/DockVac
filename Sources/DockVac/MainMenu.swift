import AppKit

/// Builds the menu bar. App-specific items target the controller explicitly; standard
/// editing items travel the responder chain.
@MainActor
enum MainMenu {
  static func build(for controller: AppController) -> NSMenu {
    let mainMenu = NSMenu()
    mainMenu.addItem(applicationMenu())
    mainMenu.addItem(editMenu())
    mainMenu.addItem(viewMenu(controller))
    mainMenu.addItem(cleanupMenu(controller))
    let windowItem = windowMenu()
    mainMenu.addItem(windowItem)
    NSApplication.shared.windowsMenu = windowItem.submenu
    mainMenu.addItem(helpMenu(controller))
    return mainMenu
  }

  private static func applicationMenu() -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu()
    menu.addItem(
      withTitle: "About DockVac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Hide DockVac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = menu.addItem(
      withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    menu.addItem(
      withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit DockVac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.submenu = menu
    return item
  }

  private static func editMenu() -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: "Edit")
    menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    menu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    item.submenu = menu
    return item
  }

  private static func viewMenu(_ controller: AppController) -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: "View")
    menu.addItem(targeted("Rescan Docker", #selector(AppController.rescan(_:)), "r", controller))
    let back = targeted(
      "Back to Overview", #selector(AppController.goBack(_:)),
      String(UnicodeScalar(NSUpArrowFunctionKey)!), controller)
    back.keyEquivalentModifierMask = [.command]
    menu.addItem(back)
    menu.addItem(.separator())
    menu.addItem(
      targeted("Show Everything", #selector(AppController.showEverything(_:)), "1", controller))
    menu.addItem(
      targeted(
        "Show Reclaimable Only", #selector(AppController.showReclaimable(_:)), "2", controller))
    menu.addItem(.separator())
    let fullScreen = menu.addItem(
      withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
      keyEquivalent: "f")
    fullScreen.keyEquivalentModifierMask = [.command, .control]
    item.submenu = menu
    return item
  }

  private static func cleanupMenu(_ controller: AppController) -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: "Cleanup")
    let toggle = targeted(
      "Add Selected Item to Cleanup", #selector(AppController.toggleSelectedInBasket(_:)), "a",
      controller)
    toggle.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(toggle)
    let safe = targeted(
      "Add Dangling Images and Build Cache", #selector(AppController.addSafeItems(_:)), "d",
      controller)
    safe.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(safe)
    menu.addItem(
      targeted("Clear Cleanup List", #selector(AppController.clearBasketAction(_:)), "", controller)
    )
    menu.addItem(.separator())
    let review = targeted(
      "Review and Remove…", #selector(AppController.reviewAndRemoveAction(_:)), "\r", controller)
    review.keyEquivalentModifierMask = [.command]
    menu.addItem(review)
    item.submenu = menu
    return item
  }

  private static func windowMenu() -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: "Window")
    menu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
      keyEquivalent: "")
    item.submenu = menu
    return item
  }

  private static func helpMenu(_ controller: AppController) -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: "Help")
    menu.addItem(
      targeted("DockVac on GitHub", #selector(AppController.openHelp(_:)), "", controller))
    item.submenu = menu
    return item
  }

  private static func targeted(
    _ title: String, _ action: Selector, _ key: String, _ target: AnyObject
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = target
    return item
  }
}
