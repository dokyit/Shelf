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
                for item in carriedItems + lastEmitted where !freshIDs.contains(item.id) && seenIDs.insert(item.id).inserted {
                    guard isRunning(item.ownerPID) else { continue }
                    guard hiddenScopesProvider().contains(item.scope) || item.isNativeOverflow else { continue }
                    var copy = item
                    copy.isPresent = true
                    nextCarried.append(copy)
                }
                carriedItems = nextCarried
                merged.append(contentsOf: nextCarried)
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

    private func isRunning(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }
}
