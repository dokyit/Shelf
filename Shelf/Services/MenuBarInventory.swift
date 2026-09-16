import AppKit
import ApplicationServices
import ShelfCore

@MainActor
final class MenuBarInventory: ObservableObject {
    enum Availability: Equatable {
        case pending
        case ready
        case needsAccessibility
        case unavailable
    }

    @Published private(set) var items: [ManagedItem] = []
    @Published private(set) var ownItem: ManagedItem?
    @Published private(set) var availability: Availability = .pending
    @Published private(set) var hasNativeOverflowButton = false

    var restrictionActive = false
    var hiddenScopesProvider: () -> Set<String> = { [] }
    var onChangeHandlers: [() -> Void] = []

    let bridge = MenuBarAgentBridge()

    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var generation: UInt64 = 0
    private var appInfoCache: [pid_t: MenuBarAppInfo] = [:]
    private var lastEmitted: [ManagedItem] = []
    private var carriedItems: [ManagedItem] = []

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            })
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
    }

    func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        generation &+= 1
        let current = generation
        let outcome = await bridge.capture()
        guard current == generation else { return }

        switch outcome {
        case .needsAccessibility:
            availability = .needsAccessibility
        case .unavailable:
            if availability != .needsAccessibility {
                availability = .unavailable
            }
        case .snapshot(let snapshot, let agentPID):
            availability = .ready
            hasNativeOverflowButton = snapshot.overflowButtonFrame != nil
            let ownPID = getpid()
            let fresh = MenuBarItemDiscovery.buildItems(
                from: snapshot,
                ownPID: ownPID,
                agentPID: agentPID,
                appInfo: { [weak self] pid in self?.appInfo(for: pid) ?? MenuBarAppInfo(bundleID: nil, localizedName: nil) }
            )
            var merged = fresh
            if restrictionActive {
                let freshIDs = Set(fresh.map(\.id))
                var seenIDs = Set<String>()
                var nextCarried: [ManagedItem] = []
                for item in carriedItems + lastEmitted
                where !item.id.hasPrefix("detached:") && !freshIDs.contains(item.id) && seenIDs.insert(item.id).inserted {
                    guard isRunning(item.ownerPID) else { continue }
                    guard hiddenScopesProvider().contains(item.scope) || item.isNativeOverflow else { continue }
                    var copy = item
                    copy.isPresent = true
                    nextCarried.append(copy)
                }
                carriedItems = nextCarried
                merged.append(contentsOf: nextCarried)
                merged.append(contentsOf: await detachedItems(representedBy: merged, agentPID: agentPID))
            } else {
                carriedItems = []
            }
            lastEmitted = merged
            items = merged
            ownItem = merged.first { $0.ownerPID == ownPID }
            for handler in onChangeHandlers { handler() }
        }
    }

    func captureFreshItems() async -> [ManagedItem]? {
        let outcome = await bridge.capture()
        guard case .snapshot(let snapshot, let agentPID) = outcome else { return nil }
        return MenuBarItemDiscovery.buildItems(
            from: snapshot,
            ownPID: getpid(),
            agentPID: agentPID,
            appInfo: { [weak self] pid in self?.appInfo(for: pid) ?? MenuBarAppInfo(bundleID: nil, localizedName: nil) }
        )
    }

    func pressItem(_ item: ManagedItem, button: MenuBarClickButton = .left) async -> Bool {
        await bridge.pressItem(token: item.elementToken, button: button)
    }

    func dragItem(_ item: ManagedItem, toX x: CGFloat) async -> Bool {
        await bridge.dragItem(token: item.elementToken, toX: x)
    }

    func revealNativeOverflow() async -> Bool {
        await bridge.pressOverflow()
    }

    func hasOpenMenu(_ item: ManagedItem) async -> Bool {
        await bridge.hasOpenMenu(token: item.elementToken)
    }

    private func appInfo(for pid: pid_t) -> MenuBarAppInfo {
        if let cached = appInfoCache[pid] { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        let info = MenuBarAppInfo(bundleID: app?.bundleIdentifier, localizedName: app?.localizedName)
        appInfoCache[pid] = info
        return info
    }

    // Locally-signed apps (local.* bundles) are evicted from the bar by macOS
    // whenever a restriction is active, even when allowlisted — so they never
    // appear in the MenuBarAgent snapshot. They still expose an AXExtrasMenuBar
    // element on their own process; surface those so the user can see and
    // manage them. Hidden items are already carried in `merged`, so only add
    // extras elements beyond the count a pid already has — otherwise every
    // hidden item would appear twice.
    private func detachedItems(representedBy merged: [ManagedItem], agentPID: pid_t) async -> [ManagedItem] {
        var counts: [pid_t: Int] = [:]
        for item in merged { counts[item.ownerPID, default: 0] += 1 }
        var result: [ManagedItem] = []
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0, pid != getpid(), pid != agentPID else { continue }
            let extras = await bridge.extrasElements(of: pid)
            let missing = extras.count - (counts[pid] ?? 0)
            guard missing > 0 else { continue }
            let info = appInfo(for: pid)
            let scope = info.bundleID.map(ItemScope.app) ?? ItemScope.process(pid)
            for (ordinal, extra) in extras.suffix(missing).enumerated() {
                result.append(ManagedItem(
                    id: "detached:\(scope):\(ordinal)",
                    scope: scope,
                    bundleID: info.bundleID,
                    systemIdentifier: nil,
                    ownerPID: pid,
                    name: info.localizedName ?? "Menu bar item",
                    frame: .zero,
                    isNativeOverflow: false,
                    isPresent: true,
                    elementToken: await bridge.registerDetached(extra.element, ownerPID: pid)
                ))
            }
        }
        return result
    }

    private func isRunning(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }
}
