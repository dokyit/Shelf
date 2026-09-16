import AppKit
import ApplicationServices
import ServiceManagement
import ShelfCore
import ShelfNative

final class NativeAssertionHandle: VisibilityAssertionHandle, @unchecked Sendable {
    private let inner: SHVisibilityAssertion

    init(allowedBundles: [String], systemItems: [Int]) {
        inner = SHVisibilityAssertion(
            allowedBundles: allowedBundles,
            systemItems: systemItems.map(NSNumber.init(value:))
        )
    }

    func activate(completion: @escaping @Sendable (Error?) -> Void) {
        inner.activate { error in completion(error) }
    }

    func invalidate() {
        inner.invalidate()
    }
}

final class InventoryBox: @unchecked Sendable {
    weak var inventory: MenuBarInventory?
}

struct NativeAssertionFactory: VisibilityAssertionFactory {
    var isBackendAvailable: Bool {
        if #available(macOS 27, *) {
            return SHVisibilityAssertion.isAvailable()
        }
        return false
    }

    func makeAssertion(allowedBundles: [String], allowedSystemItems: [Int]) -> VisibilityAssertionHandle? {
        guard isBackendAvailable else { return nil }
        return NativeAssertionHandle(allowedBundles: allowedBundles, systemItems: allowedSystemItems)
    }
}

@MainActor
final class VisibilityManager: ObservableObject {
    enum Blocker: Equatable {
        case unsupportedOS
        case backendUnavailable
        case bartenderRunning
        case accessibilityRequired
        case inventoryUnavailable
        case ownIconMissing
        case ownIconOverflowed
    }

    enum ItemActivationResult: Equatable {
        case success
        case failure(String)
        case needsOverflowReveal
    }

    nonisolated static let bartenderBundleID = "com.surteesstudios.Bartender"

    @Published private(set) var blocker: Blocker?
    @Published private(set) var lastError: String?
    @Published private(set) var isRestricted = false
    @Published private(set) var isApplying = false
    @Published private(set) var temporarilyRevealedScopes: Set<String> = []
    @Published var actionMessage: String?

    @Published var layout: ShelfLayout
    @Published var showShelfInMenuBar: Bool {
        didSet {
            defaults.set(showShelfInMenuBar, forKey: Self.showShelfInMenuBarKey)
            requestApply()
        }
    }

    let engine: VisibilityController
    private let defaults = UserDefaults.standard
    private var savedLayout: ShelfLayout
    private var pendingApply = false
    private var applyTask: Task<Void, Never>?
    private var activatingScopes: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var settingsHandler: (() -> Void)?
    private let inventoryBox = InventoryBox()

    private static let showShelfInMenuBarKey = "shelf.showShelfInMenuBar"
    private static let autoCloseKey = "shelf.autoCloseShelf"

    var autoCloseShelf: Bool {
        get { defaults.object(forKey: Self.autoCloseKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.autoCloseKey) }
    }

    @Published private(set) var launchAtLogin = false

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private(set) weak var inventory: MenuBarInventory?

    init() {
        let box = inventoryBox
        let stored = UserDefaults.standard.data(forKey: ShelfLayout.storageKey)
        let initial = stored.flatMap(ShelfLayout.decoded(from:)) ?? ShelfLayout()
        layout = initial
        savedLayout = initial
        showShelfInMenuBar = UserDefaults.standard.bool(forKey: Self.showShelfInMenuBarKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        engine = VisibilityController(environment: VisibilityController.Environment(
            factory: NativeAssertionFactory(),
            ownBundleID: Bundle.main.bundleIdentifier ?? "com.pinnyutility.Shelf",
            runningBundleIDs: {
                Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            },
            itemsForVerification: {
                await box.inventory?.captureFreshItems()
            }
        ))
    }

    func attach(inventory: MenuBarInventory, openSettings: @escaping () -> Void) {
        self.inventory = inventory
        inventoryBox.inventory = inventory
        self.settingsHandler = openSettings
        inventory.restrictionActive = isRestricted
        inventory.hiddenScopesProvider = { [weak self] in
            guard let self else { return [] }
            return self.layout.hiddenScopes(
                revealed: self.temporarilyRevealedScopes,
                showShelfInMenuBar: self.showShelfInMenuBar
            )
        }
        inventory.onChangeHandlers.append { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.refreshBlocker()
                if self.blocker == nil, self.isRestricted || !self.layout.hiddenScopes().isEmpty {
                    self.requestApply()
                }
            }
        }
    }

    func startWatchingConflicts() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.conflictStateChanged() }
            })
        }
    }

    func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        applyTask?.cancel()
        Task { await engine.suspend() }
    }

    nonisolated func hasBartender() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.bartenderBundleID
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    var backendAvailable: Bool {
        if #available(macOS 27, *) {
            return SHVisibilityAssertion.isAvailable()
        }
        return false
    }

    func refreshBlocker() {
        if !backendAvailable {
            blocker = .unsupportedOS
        } else if hasBartender() {
            blocker = .bartenderRunning
        } else if !accessibilityTrusted {
            blocker = .accessibilityRequired
        } else if let inventory, inventory.availability == .needsAccessibility {
            blocker = .accessibilityRequired
        } else if let inventory, inventory.availability == .unavailable {
            blocker = .inventoryUnavailable
        } else if let own = inventory?.ownItem {
            blocker = own.isNativeOverflow ? .ownIconOverflowed : nil
        } else if inventory?.availability == .ready {
            blocker = .ownIconMissing
        } else {
            blocker = nil
        }
    }

    private func conflictStateChanged() {
        let previous = blocker
        refreshBlocker()
        if blocker == .bartenderRunning, previous != .bartenderRunning {
            temporarilyRevealedScopes = []
            Task { await engine.suspend() }
            isRestricted = false
            inventory?.restrictionActive = false
        } else if blocker == nil, previous == .bartenderRunning {
            requestApply()
        }
    }

    func setSection(_ scope: String, to section: ItemSection) {
        layout.assign(scope, to: section)
        requestApply()
    }

    func requestApply() {
        guard !isApplying else {
            pendingApply = true
            return
        }
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            await self?.applyLayout()
        }
    }

    func applyLayout() async {
        if isApplying {
            pendingApply = true
            return
        }
        refreshBlocker()
        guard blocker != .bartenderRunning, blocker != .unsupportedOS, blocker != .accessibilityRequired else {
            await engine.suspend()
            isRestricted = false
            inventory?.restrictionActive = false
            return
        }
        isApplying = true

        let items: [ManagedItem]? = inventory?.availability == .ready ? inventory?.items : nil
        let result = await engine.apply(
            layout: layout,
            items: items,
            temporaryReveal: temporarilyRevealedScopes,
            showShelfInMenuBar: showShelfInMenuBar,
            isConflicting: { [weak self] in self?.hasBartender() ?? false }
        )
        isRestricted = await engine.isRestricted
        inventory?.restrictionActive = isRestricted

        switch result {
        case .success:
            lastError = nil
            savedLayout = layout
            persist()
            blocker = nil
        case .failure(let failure):
            layout = savedLayout
            lastError = describe(failure)
            if failure == .ownItemUnreachable {
                refreshBlocker()
            }
        }

        isApplying = false
        if pendingApply {
            pendingApply = false
            await applyLayout()
        }
    }

    func currentHiddenScopes() -> Set<String> {
        layout.hiddenScopes(
            revealed: temporarilyRevealedScopes,
            showShelfInMenuBar: showShelfInMenuBar
        )
    }

    func activateItem(_ item: ManagedItem, button: MenuBarClickButton = .left) async -> ItemActivationResult {
        if item.isNativeOverflow && !currentHiddenScopes().contains(item.scope) {
            return .needsOverflowReveal
        }
        if currentHiddenScopes().contains(item.scope) {
            temporarilyRevealedScopes.insert(item.scope)
            await applyLayout()
            guard temporarilyRevealedScopes.contains(item.scope) else {
                return .failure("Shelf could not apply the layout change.")
            }
            var resolved: ManagedItem?
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if let fresh = await inventory?.captureFreshItems(),
                   let match = fresh.first(where: {
                       $0.scope == item.scope && $0.isPresent && !$0.isNativeOverflow
                   }) {
                    resolved = match
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let target = resolved else {
                temporarilyRevealedScopes.remove(item.scope)
                await applyLayout()
                if let fresh = await inventory?.captureFreshItems(),
                   fresh.contains(where: { $0.scope == item.scope && $0.isNativeOverflow }) {
                    return .needsOverflowReveal
                }
                return .failure("\(item.name) could not be brought into the menu bar.")
            }
            activatingScopes.insert(item.scope)
            let pressed = await inventory?.pressItem(target, button: button) ?? false
            activatingScopes.remove(item.scope)
            guard pressed else {
                return .failure("\(item.name) is visible in the menu bar now — click it there.")
            }
            endReveal(scope: item.scope)
            return .success
        }
        activatingScopes.insert(item.scope)
        let pressed = await inventory?.pressItem(item, button: button) ?? false
        activatingScopes.remove(item.scope)
        return pressed ? .success : .failure("Could not open \(item.name) right now.")
    }

    func revealNativeOverflow() async -> Bool {
        await inventory?.revealNativeOverflow() ?? false
    }

    private var isReordering = false

    func reorderItems(in section: ItemSection, scopesInOrder: [String], movedScope: String? = nil) {
        for (index, scope) in scopesInOrder.enumerated() {
            if var rule = layout.rules[scope], rule.section == section {
                rule.order = index
                layout.rules[scope] = rule
            } else if section == .alwaysShow, layout.rules[scope] == nil {
                layout.rules[scope] = ItemRule(section: .alwaysShow, order: index)
            }
        }
        savedLayout = layout
        persist()
        guard !isReordering, scopesInOrder.count > 1, let movedScope else { return }
        isReordering = true
        Task { [weak self] in
            switch section {
            case .alwaysShow:
                await self?.applyVisibleOrderToBar(scopesInOrder, movedScope: movedScope)
            case .alwaysHide:
                await self?.applyHiddenOrderToBar(scopesInOrder, movedScope: movedScope)
            case .onShelf:
                break
            }
            self?.isReordering = false
        }
    }

    private func applyVisibleOrderToBar(_ scopes: [String], movedScope: String) async {
        guard accessibilityTrusted, blocker == nil else { return }
        activatingScopes.formUnion(scopes)
        defer { activatingScopes.subtract(scopes) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let fresh = await inventory?.captureFreshItems() {
                let present = fresh.filter {
                    scopes.contains($0.scope) && $0.isPresent && !$0.isNativeOverflow && $0.frame.width > 0
                }
                if present.count == scopes.count { break }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await placeMovedItem(scopes, movedScope: movedScope)
    }

    private func applyHiddenOrderToBar(_ scopes: [String], movedScope: String) async {
        guard accessibilityTrusted, blocker == nil else { return }
        activatingScopes.formUnion(scopes)
        temporarilyRevealedScopes.formUnion(scopes)
        defer {
            temporarilyRevealedScopes.subtract(scopes)
            activatingScopes.subtract(scopes)
            requestApply()
        }
        await applyLayout()
        let deadline = Date().addingTimeInterval(3)
        var present: [ManagedItem] = []
        while Date() < deadline {
            if let fresh = await inventory?.captureFreshItems() {
                present = fresh.filter {
                    scopes.contains($0.scope) && $0.isPresent && !$0.isNativeOverflow && $0.frame.width > 0
                }
                if present.count == scopes.count { break }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard present.count > 1 else { return }
        await placeMovedItem(scopes, movedScope: movedScope)
    }

    private func placeMovedItem(_ scopes: [String], movedScope: String) async {
        guard let index = scopes.firstIndex(of: movedScope),
              let fresh = await inventory?.captureFreshItems(),
              let item = fresh.first(where: { $0.scope == movedScope }),
              item.isPresent, item.frame.width > 0, !item.isNativeOverflow,
              item.isManageable, item.ownerPID != getpid() else { return }
        func visible(_ scope: String) -> ManagedItem? {
            fresh.first { $0.scope == scope && $0.isPresent && $0.frame.width > 0 && !$0.isNativeOverflow }
        }
        var left: ManagedItem?
        for j in stride(from: index - 1, through: 0, by: -1) {
            if let n = visible(scopes[j]) { left = n; break }
        }
        var right: ManagedItem?
        for j in (index + 1)..<scopes.count {
            if let n = visible(scopes[j]) { right = n; break }
        }
        let inPlace = (left == nil || item.frame.minX > left!.frame.maxX)
            && (right == nil || item.frame.maxX < right!.frame.minX)
        guard !inPlace else { return }
        let target: CGFloat
        if let left {
            target = left.frame.maxX + 4
        } else if let right {
            target = right.frame.minX - 4
        } else {
            return
        }
        _ = await inventory?.dragItem(item, toX: target)
    }

    func noteOutsideClick() {
        guard !temporarilyRevealedScopes.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            for scope in temporarilyRevealedScopes where !activatingScopes.contains(scope) {
                if let item = inventory?.items.first(where: { $0.scope == scope }),
                   await inventory?.hasOpenMenu(item) == true {
                    continue
                }
                endReveal(scope: scope)
            }
        }
    }

    func endReveal(scope: String) {
        guard temporarilyRevealedScopes.remove(scope) != nil else { return }
        requestApply()
    }

    func endAllReveals() {
        guard !temporarilyRevealedScopes.isEmpty else { return }
        temporarilyRevealedScopes = []
        requestApply()
    }

    private func persist() {
        if let data = layout.encoded() {
            defaults.set(data, forKey: ShelfLayout.storageKey)
        }
    }

    private func describe(_ failure: VisibilityFailure) -> String {
        switch failure {
        case .backendUnavailable:
            return "This macOS version does not support Shelf's hiding engine."
        case .conflict:
            return "Paused because Bartender is running."
        case .inventoryUnavailable:
            return "Menu bar inventory is unavailable."
        case .ownItemUnreachable:
            return "The Shelf icon is not visible in the menu bar, so hiding was not applied."
        case .activationFailed(let message):
            return "macOS could not apply the menu bar layout (\(message)). Nothing was changed."
        case .activationTimedOut:
            return "macOS did not respond in time. Nothing was changed."
        case .verificationFailed(let violations):
            let detail = violations.prefix(3).joined(separator: "; ")
            return "macOS could not keep required items visible. Nothing was changed. (\(detail))"
        case .cancelled:
            return "The layout change was interrupted. Nothing was changed."
        }
    }
}
