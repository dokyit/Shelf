import AppKit
import ShelfCore

@MainActor
final class ShelfController: NSObject, ObservableObject {
    let inventory: MenuBarInventory
    let visibility: VisibilityManager
    let icons = ItemIconCache()

    var openSettingsHandler: (() -> Void)?
    var openSearchHandler: (() -> Void)?

    @Published private(set) var shelfOpen = false
    @Published private(set) var isPlacingIcon = false

    private let iconItem: NSStatusItem
    private var panel: ShelfBarPanel?
    private var outsideMonitor: Any?

    init(inventory: MenuBarInventory, visibility: VisibilityManager) {
        self.inventory = inventory
        self.visibility = visibility
        iconItem = NSStatusBar.system.statusItem(withLength: 28)
        super.init()
        configureIconItem()
    }

    private func configureIconItem() {
        iconItem.behavior = []
        iconItem.autosaveName = "Shelf.Icon"
        iconItem.isVisible = true
        guard let button = iconItem.button else { return }
        let image = MenuBarIconRenderer.shelfImage(bookCount: 0)
        image.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(iconActivated(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Shelf")
        button.setAccessibilityHelp("Shows or hides shelf items. Right-click for more actions.")
    }

    func begin() {
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.visibility.noteOutsideClick()
            }
        }
        updateIcon()
    }

    func updateIcon() {
        let count = inventory.items.filter { $0.isPresent && $0.ownerPID != getpid() }.count
        let image = MenuBarIconRenderer.shelfImage(
            bookCount: ShelfLayout.bookCount(for: count)
        )
        image.isTemplate = true
        iconItem.button?.image = image
    }

    func iconButtonFrame() -> NSRect? {
        iconItem.button?.window?.frame
    }

    func toggleShelf() {
        if shelfOpen {
            closeShelf()
        } else {
            openShelf(mode: .shelf)
        }
    }

    func openShelf(mode: ShelfBarView.Mode) {
        closePanelOnly()
        let view = ShelfBarView(
            inventory: inventory,
            visibility: visibility,
            icons: icons,
            mode: mode,
            onClose: { [weak self] in self?.closeShelf() },
            openSettings: { [weak self] in self?.openSettingsHandler?() }
        )
        let panel = ShelfBarPanel()
        panel.onDismiss = { [weak self] in
            self?.shelfOpen = false
        }
        panel.present(content: view, below: iconButtonFrame())
        self.panel = panel
        shelfOpen = true
    }

    func closeShelf() {
        closePanelOnly()
        visibility.endAllReveals()
    }

    private func closePanelOnly() {
        panel?.dismiss()
        panel = nil
        shelfOpen = false
    }

    @objc private func iconActivated(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isContextClick {
            showContextMenu()
        } else {
            toggleShelf()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        addMenuItem(menu, title: "Shelf Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        addMenuItem(menu, title: "Search Menu Bar Items…", action: #selector(menuOpenSearch), keyEquivalent: "f")
        addMenuItem(menu, title: shelfOpen ? "Hide Shelf" : "Show Shelf", action: #selector(menuToggleShelf))
        addMenuItem(menu, title: "Menu Bar Layout…", action: #selector(menuOpenSettings))
        menu.addItem(.separator())
        let showInline = NSMenuItem(
            title: "Show On-Shelf Items in Menu Bar",
            action: #selector(menuToggleInlineShelf),
            keyEquivalent: ""
        )
        showInline.target = self
        showInline.state = visibility.showShelfInMenuBar ? .on : .off
        menu.addItem(showInline)
        if !visibility.temporarilyRevealedScopes.isEmpty {
            addMenuItem(menu, title: "Tuck Away Revealed Items", action: #selector(menuTuckAway))
        }
        menu.addItem(.separator())
        addMenuItem(menu, title: "Quit Shelf", action: #selector(menuQuit), keyEquivalent: "q")
        if let button = iconItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    private func addMenuItem(_ menu: NSMenu, title: String, action: Selector, keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
    }

    @objc private func menuOpenSettings() { openSettingsHandler?() }
    @objc private func menuOpenSearch() { openSearchHandler?() }
    @objc private func menuToggleShelf() { toggleShelf() }
    @objc private func menuToggleInlineShelf() {
        visibility.showShelfInMenuBar.toggle()
    }
    @objc private func menuTuckAway() { visibility.endAllReveals() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    func keepShelfVisible() {
        guard !isPlacingIcon else { return }
        isPlacingIcon = true
        Task { @MainActor in
            defer { isPlacingIcon = false }
            let ownBundle = Bundle.main.bundleIdentifier ?? "com.pinnyutility.Shelf"
            let outcome = await IconPlacement.keepShelfVisible(
                inventory: inventory,
                ownBundleID: ownBundle
            )
            switch outcome {
            case .placed:
                visibility.actionMessage = nil
                visibility.requestApply()
            case .failure(let message):
                visibility.actionMessage = message
                openSettingsHandler?()
            }
        }
    }

    func teardown() {
        closePanelOnly()
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
        }
        outsideMonitor = nil
    }
}
