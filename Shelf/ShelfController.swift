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
    private var preservedStatusItems: [String: NSStatusItem] = [:]
    private var preservedSources: [String: ManagedItem] = [:]
    private var panel: ShelfBarPanel?
    private var outsideMonitor: Any?

    init(inventory: MenuBarInventory, visibility: VisibilityManager) {
        self.inventory = inventory
        self.visibility = visibility
        iconItem = NSStatusBar.system.statusItem(withLength: 28)
        super.init()
        configureIconItem()
        visibility.onLayoutReorder = { [weak self] section, scope, scopes in
            guard section == .alwaysShow else { return }
            Task { @MainActor [weak self] in
                await self?.movePreservedStatusItem(scope: scope, scopes: scopes)
            }
        }
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

    func updatePreservedStatusItems() {
        let candidates = inventory.items.filter { item in
            guard visibility.isRestricted,
                  item.ownerPID != getpid(),
                  item.id.hasPrefix("detached:"),
                  !item.isPreservable else { return false }
            let section = visibility.layout.section(for: item.scope)
            return section == .alwaysShow || (section == .onShelf && visibility.showShelfInMenuBar)
        }

        var wanted = Set<String>()
        var newlyCreatedScopes: [String] = []
        for item in candidates {
            let key = item.id
            wanted.insert(key)
            preservedSources[key] = item

            let statusItem: NSStatusItem
            if let existing = preservedStatusItems[key] {
                statusItem = existing
            } else {
                statusItem = NSStatusBar.system.statusItem(withLength: 28)
                statusItem.behavior = []
                statusItem.autosaveName = "Shelf.Preserve." + key
                    .replacingOccurrences(of: ":", with: ".")
                    .replacingOccurrences(of: "/", with: ".")
                preservedStatusItems[key] = statusItem
                newlyCreatedScopes.append(item.scope)
            }

            guard let button = statusItem.button else { continue }
            button.image = icons.statusIcon(for: item)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(preservedIconActivated(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = item.name
            button.setAccessibilityLabel(item.name)
            button.setAccessibilityHelp("Shelf is keeping this locally managed menu bar item visible.")
        }

        for key in preservedStatusItems.keys where !wanted.contains(key) {
            if let statusItem = preservedStatusItems.removeValue(forKey: key) {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            preservedSources.removeValue(forKey: key)
        }

        if !newlyCreatedScopes.isEmpty {
            let order = desiredAlwaysShowScopes()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard let self, !Task.isCancelled else { return }
                for scope in newlyCreatedScopes {
                    await self.movePreservedStatusItem(scope: scope, scopes: order)
                }
            }
        }
    }

    private func desiredAlwaysShowScopes() -> [String] {
        var seen = Set<String>()
        let candidates = inventory.items.filter { item in
            guard item.isPresent,
                  item.ownerPID != getpid(),
                  visibility.layout.section(for: item.scope) == .alwaysShow,
                  seen.insert(item.scope).inserted else { return false }
            return true
        }

        func trailingRank(_ item: ManagedItem) -> Int? {
            switch item.systemIdentifier {
            case "com.apple.menuextra.sound": return 0
            case "com.apple.menuextra.wifi": return 1
            case "com.apple.menuextra.battery": return 2
            case "com.apple.menuextra.controlcenter": return 4
            case "com.apple.menuextra.clock": return 5
            default: return nil
            }
        }

        let movable = candidates.filter { trailingRank($0) == nil }.sorted { lhs, rhs in
            let lo = visibility.layout.rules[lhs.scope]?.order
            let ro = visibility.layout.rules[rhs.scope]?.order
            if lo != ro {
                if let lo, let ro { return lo < ro }
                if lo != nil { return true }
                if ro != nil { return false }
            }
            let lx = lhs.frame.width > 0 ? lhs.frame.minX : .greatestFiniteMagnitude
            let rx = rhs.frame.width > 0 ? rhs.frame.minX : .greatestFiniteMagnitude
            return lx == rx ? lhs.name < rhs.name : lx < rx
        }
        let trailing = candidates.filter { trailingRank($0) != nil }
            .sorted { trailingRank($0)! < trailingRank($1)! }
        return (movable + trailing).map(\.scope)
    }

    private func frameForScope(_ scope: String) -> CGRect? {
        if let key = preservedSources.first(where: { $0.value.scope == scope })?.key,
           let frame = preservedStatusItems[key]?.button?.window?.frame,
           frame.width > 0 {
            return frame
        }
        return inventory.items.first {
            $0.scope == scope
                && $0.ownerPID != getpid()
                && $0.isPresent
                && !$0.isNativeOverflow
                && $0.frame.width > 0
        }?.frame
    }

    private func movePreservedStatusItem(scope: String, scopes: [String]) async {
        guard let key = preservedSources.first(where: { $0.value.scope == scope })?.key,
              let statusItem = preservedStatusItems[key],
              let source = statusItem.button?.window?.frame,
              let index = scopes.firstIndex(of: scope) else { return }

        var left: CGRect?
        if index > 0 {
            for i in stride(from: index - 1, through: 0, by: -1) {
                if let frame = frameForScope(scopes[i]) { left = frame; break }
            }
        }
        var right: CGRect?
        if index + 1 < scopes.count {
            for i in (index + 1)..<scopes.count {
                if let frame = frameForScope(scopes[i]) { right = frame; break }
            }
        }

        let inPlace = (left == nil || source.minX > left!.maxX)
            && (right == nil || source.maxX < right!.minX)
        guard !inPlace else { return }

        let targetX: CGFloat
        if let left, let right {
            targetX = (left.maxX + right.minX) / 2
        } else if let left {
            targetX = left.maxX + source.width / 2 + 4
        } else if let right {
            targetX = right.minX - source.width / 2 - 4
        } else {
            return
        }

        _ = await commandDragStatusItem(from: source, toX: targetX)
    }

    private func commandDragStatusItem(from frame: CGRect, toX targetX: CGFloat) async -> Bool {
        let sourcePoint = CGPoint(x: frame.midX, y: frame.midY)
        let targetPoint = CGPoint(x: targetX, y: frame.midY)
        let originalPointer = CGEvent(source: nil)?.location
        let display = CGMainDisplayID()
        CGDisplayHideCursor(display)
        defer {
            if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
            CGDisplayShowCursor(display)
        }

        let eventSource = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: sourcePoint,
            mouseButton: .left
        ) else { return false }
        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 120_000_000)

        guard !Task.isCancelled,
              let drag = CGEvent(
                mouseEventSource: eventSource,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: targetPoint,
                mouseButton: .left
              ) else { return false }
        drag.flags = .maskCommand
        drag.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 90_000_000)

        guard !Task.isCancelled,
              let up = CGEvent(
                mouseEventSource: eventSource,
                mouseType: .leftMouseUp,
                mouseCursorPosition: targetPoint,
                mouseButton: .left
              ) else { return false }
        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)
        return true
    }

    @objc private func preservedIconActivated(_ sender: NSStatusBarButton) {
        guard let key = preservedStatusItems.first(where: { $0.value.button === sender })?.key,
              let source = preservedSources[key] else { return }
        let event = NSApp.currentEvent
        let button: MenuBarClickButton = event?.type == .rightMouseUp ? .right : .left
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await visibility.activateItem(source, button: button)
            if case .failure(let message) = result {
                visibility.actionMessage = message
            }
        }
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
            iconItem.menu = menu
            button.performClick(nil)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.iconItem.menu = nil
            }
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
        for statusItem in preservedStatusItems.values {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        preservedStatusItems = [:]
        preservedSources = [:]
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
        }
        outsideMonitor = nil
    }
}
