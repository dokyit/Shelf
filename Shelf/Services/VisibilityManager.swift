import AppKit
import ApplicationServices
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
    private var revealWatchTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var settingsHandler: (() -> Void)?
    private let inventoryBox = InventoryBox()

    private static let showShelfInMenuBarKey = "shelf.showShelfInMenuBar"
    private static let autoCloseKey = "shelf.autoCloseShelf"

    var autoCloseShelf: Bool {
        get { defaults.object(forKey: Self.autoCloseKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.autoCloseKey) }
    }

    private(set) weak var inventory: MenuBarInventory?

    init() {
        let box = inventoryBox
        let stored = UserDefaults.standard.data(forKey: ShelfLayout.storageKey)
        let initial = stored.flatMap(ShelfLayout.decoded(from:)) ?? ShelfLayout()
        layout = initial
        savedLayout = initial
        showShelfInMenuBar = UserDefaults.standard.bool(forKey: Self.showShelfInMenuBarKey)
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
        revealWatchTask?.cancel()
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
            revealWatchTask?.cancel()
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

    func activateItem(_ item: ManagedItem) async -> ItemActivationResult {
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
            let pressed = await inventory?.pressItem(target) ?? false
            guard pressed else {
                return .failure("\(item.name) is visible in the menu bar now — click it there.")
            }
            startRevealWatch(for: target)
            return .success
        }
        let pressed = await inventory?.pressItem(item) ?? false
        return pressed ? .success : .failure("Could not open \(item.name) right now.")
    }

    func revealNativeOverflow() async -> Bool {
        await inventory?.revealNativeOverflow() ?? false
    }

    func noteOutsideClick() {
        guard !temporarilyRevealedScopes.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            for scope in temporarilyRevealedScopes {
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
        revealWatchTask?.cancel()
        requestApply()
    }

    func endAllReveals() {
        guard !temporarilyRevealedScopes.isEmpty else { return }
        temporarilyRevealedScopes = []
        revealWatchTask?.cancel()
        requestApply()
    }

    private func startRevealWatch(for item: ManagedItem) {
        revealWatchTask?.cancel()
        revealWatchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            var menuSeen = false
            for _ in 0..<180 {
                if Task.isCancelled { return }
                guard let self else { return }
                let open = await self.inventory?.hasOpenMenu(item) ?? false
                if open {
                    menuSeen = true
                } else if menuSeen {
                    self.endReveal(scope: item.scope)
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.endReveal(scope: item.scope)
        }
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
