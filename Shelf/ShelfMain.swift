import AppKit
import ShelfCore
import SwiftUI

@main
enum ShelfMain {
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = delegate.makeMainMenu()
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let inventory = MenuBarInventory()
    let visibility = VisibilityManager()

    private(set) var controller: ShelfController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = ShelfController(inventory: inventory, visibility: visibility)
        self.controller = controller
        controller.openSettingsHandler = { [weak self] in
            self?.openSettings()
        }
        controller.openSearchHandler = { [weak self] in
            self?.controller?.openShelf(mode: .search)
        }
        inventory.onChangeHandlers.append { [weak controller] in
            Task { @MainActor in
                controller?.updateIcon()
            }
        }
        visibility.attach(inventory: inventory) { [weak self] in
            self?.openSettings()
        }
        visibility.startWatchingConflicts()
        inventory.start()
        controller.begin()
        visibility.refreshBlocker()
        Task { @MainActor in
            await visibility.applyLayout()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.teardown()
        inventory.stop()
        visibility.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Shelf")
        appMenuItem.submenu = appMenu

        addItem(to: appMenu, title: "Shelf Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        addItem(to: appMenu, title: "Search Menu Bar Items…", action: #selector(searchAction), keyEquivalent: "f")
        addItem(to: appMenu, title: "Show/Hide Shelf", action: #selector(toggleShelfAction))
        addItem(to: appMenu, title: "Menu Bar Layout…", action: #selector(openSettingsAction))
        appMenu.addItem(.separator())
        addItem(to: appMenu, title: "Quit Shelf", action: #selector(quitAction), keyEquivalent: "q")
        return mainMenu
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
    }

    @objc private func openSettingsAction() { openSettings() }
    @objc private func searchAction() { controller?.openShelf(mode: .search) }
    @objc private func toggleShelfAction() { controller?.toggleShelf() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    func openSettings() {
        guard let controller else { return }
        let window = settingsWindow ?? makeSettingsWindow(controller: controller)
        settingsWindow = window
        if !window.isVisible, !window.setFrameUsingName("ShelfSettings") {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeSettingsWindow(controller: ShelfController) -> NSWindow {
        let view = SettingsView(
            inventory: inventory,
            visibility: visibility,
            icons: controller.icons,
            keepShelfVisible: { [weak controller] in
                controller?.keepShelfVisible()
            },
            showShelf: { [weak controller] in
                controller?.openShelf(mode: .shelf)
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shelf Settings"
        window.contentView = NSHostingView(rootView: view)
        window.contentMinSize = NSSize(width: 650, height: 460)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ShelfSettings")
        window.collectionBehavior.insert(.moveToActiveSpace)
        return window
    }
}
