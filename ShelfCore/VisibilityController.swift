import Foundation

public protocol VisibilityAssertionHandle: Sendable {
    func activate(completion: @escaping @Sendable (Error?) -> Void)
    func invalidate()
}

public protocol VisibilityAssertionFactory: Sendable {
    var isBackendAvailable: Bool { get }
    func makeAssertion(allowedBundles: [String], allowedSystemItems: [Int]) -> VisibilityAssertionHandle?
}

public enum VisibilityFailure: Error, Equatable, Sendable {
    case backendUnavailable
    case conflict
    case inventoryUnavailable
    case ownItemUnreachable
    case activationFailed(String)
    case activationTimedOut
    case verificationFailed([String])
    case cancelled
}

public enum VisibilityApplyResult: Equatable, Sendable {
    case unrestricted
    case restricted(hiddenScopes: Int)
}

public enum VisibilityPlan {
    public static func hiddenTargets(
        layout: ShelfLayout,
        revealed: Set<String>,
        showShelfInMenuBar: Bool,
        ownBundleID: String
    ) -> (bundles: Set<String>, systemCodes: Set<Int>, scopes: Set<String>) {
        let scopes = layout.hiddenScopes(revealed: revealed, showShelfInMenuBar: showShelfInMenuBar)
        var bundles = Set<String>()
        var codes = Set<Int>()
        for scope in scopes {
            if let bundleID = ItemScope.bundleID(of: scope), bundleID != ownBundleID {
                bundles.insert(bundleID)
            } else if let identifier = ItemScope.systemIdentifier(of: scope),
                      let code = SystemMenuBarItem.code(for: identifier),
                      !SystemMenuBarItem.isLocked(identifier) {
                codes.insert(code)
            }
        }
        return (bundles, codes, scopes)
    }

    public static func allowedBundles(running: Set<String>, hiding: Set<String>, ownBundleID: String) -> [String] {
        var allowed = running.subtracting(hiding)
        allowed.insert(ownBundleID)
        return allowed.sorted()
    }

    public static func allowedSystemItems(hiding: Set<Int>) -> [Int] {
        SystemMenuBarItem.allCodes.filter { !hiding.contains($0) }
    }

    public static func verificationViolations(
        before: [ManagedItem],
        after: [ManagedItem],
        hiddenScopes: Set<String>,
        ownBundleID: String
    ) -> [String] {
        func isDistinctlyVisible(_ item: ManagedItem) -> Bool {
            item.isPresent && !item.isNativeOverflow
        }
        var violations: [String] = []
        let afterScopes = Dictionary(grouping: after, by: \.scope)

        for item in before where hiddenScopes.contains(item.scope) {
            if let matches = afterScopes[item.scope], matches.contains(where: isDistinctlyVisible) {
                violations.append("Hidden scope still visible: \(item.scope)")
            }
        }
        for item in before where !hiddenScopes.contains(item.scope) && isDistinctlyVisible(item) {
            if !item.isPreservable {
                continue
            }
            let matches = afterScopes[item.scope] ?? []
            if !matches.contains(where: isDistinctlyVisible) {
                violations.append("Allowed item lost: \(item.scope)")
            }
        }
        let ownVisible = after.contains { $0.bundleID == ownBundleID && isDistinctlyVisible($0) }
        if !ownVisible {
            violations.append("Shelf menu bar item was lost")
        }
        return violations
    }
}

public actor VisibilityController {
    public struct Environment: Sendable {
        public var factory: VisibilityAssertionFactory
        public var ownBundleID: String
        public var runningBundleIDs: @Sendable () -> Set<String>
        public var itemsForVerification: @Sendable () async -> [ManagedItem]?
        public var activationTimeout: TimeInterval
        public var settleDelay: TimeInterval
        public var verifyWindow: TimeInterval

        public init(
            factory: VisibilityAssertionFactory,
            ownBundleID: String,
            runningBundleIDs: @escaping @Sendable () -> Set<String>,
            itemsForVerification: @escaping @Sendable () async -> [ManagedItem]?,
            activationTimeout: TimeInterval = 3,
            settleDelay: TimeInterval = 0.3,
            verifyWindow: TimeInterval = 3
        ) {
            self.factory = factory
            self.ownBundleID = ownBundleID
            self.runningBundleIDs = runningBundleIDs
            self.itemsForVerification = itemsForVerification
            self.activationTimeout = activationTimeout
            self.settleDelay = settleDelay
            self.verifyWindow = verifyWindow
        }
    }

    private let environment: Environment
    private var current: VisibilityAssertionHandle?
    private var lastApplied: (bundles: Set<String>, codes: Set<Int>, allowed: Set<String>)?
    private var epoch: UInt64 = 0
    public private(set) var isRestricted = false

    public init(environment: Environment) {
        self.environment = environment
    }

    public func suspend() {
        epoch &+= 1
        current?.invalidate()
        current = nil
        lastApplied = nil
        isRestricted = false
    }

    @discardableResult
    public func apply(
        layout: ShelfLayout,
        items: [ManagedItem]?,
        temporaryReveal: Set<String> = [],
        showShelfInMenuBar: Bool = false,
        isConflicting: @Sendable () -> Bool
    ) async -> Result<VisibilityApplyResult, VisibilityFailure> {
        epoch &+= 1
        let myEpoch = epoch

        guard environment.factory.isBackendAvailable else { return .failure(.backendUnavailable) }
        guard !isConflicting() else { return .failure(.conflict) }
        guard let items else { return .failure(.inventoryUnavailable) }

        let targets = VisibilityPlan.hiddenTargets(
            layout: layout,
            revealed: temporaryReveal,
            showShelfInMenuBar: showShelfInMenuBar,
            ownBundleID: environment.ownBundleID
        )

        if targets.scopes.isEmpty {
            suspend()
            return .success(.unrestricted)
        }

        let allowedBundles = VisibilityPlan.allowedBundles(
            running: environment.runningBundleIDs(),
            hiding: targets.bundles,
            ownBundleID: environment.ownBundleID
        )
        let allowedSystemItems = VisibilityPlan.allowedSystemItems(hiding: targets.systemCodes)

        if let lastApplied, isRestricted,
           lastApplied.bundles == targets.bundles,
           lastApplied.codes == targets.systemCodes,
           lastApplied.allowed == Set(allowedBundles) {
            return .success(.restricted(hiddenScopes: targets.scopes.count))
        }

        let ownReachable = items.contains {
            $0.bundleID == environment.ownBundleID && $0.isPresent && !$0.isNativeOverflow
        }
        guard ownReachable else { return .failure(.ownItemUnreachable) }

        guard let candidate = environment.factory.makeAssertion(
            allowedBundles: allowedBundles,
            allowedSystemItems: allowedSystemItems
        ) else {
            return .failure(.backendUnavailable)
        }

        // Overlapping assertions union their allowlists: the old assertion would
        // keep protecting items the new one needs to hide, so it must be dropped
        // before the candidate activates.
        let previous = current
        current = nil
        lastApplied = nil
        isRestricted = false
        previous?.invalidate()

        let activationError = await activate(candidate, timeout: environment.activationTimeout)
        if Task.isCancelled || epoch != myEpoch {
            candidate.invalidate()
            return .failure(.cancelled)
        }
        if let activationError {
            candidate.invalidate()
            if case VisibilityFailure.activationTimedOut = activationError {
                return .failure(.activationTimedOut)
            }
            return .failure(.activationFailed(activationError.localizedDescription))
        }

        try? await Task.sleep(nanoseconds: UInt64(environment.settleDelay * 1_000_000_000))
        if Task.isCancelled || epoch != myEpoch {
            candidate.invalidate()
            return .failure(.cancelled)
        }

        var violations = ["Menu bar inventory unavailable after activation"]
        let deadline = Date().addingTimeInterval(environment.verifyWindow)
        while !violations.isEmpty && Date() < deadline {
            if Task.isCancelled || epoch != myEpoch {
                candidate.invalidate()
                return .failure(.cancelled)
            }
            if let after = await environment.itemsForVerification() {
                violations = VisibilityPlan.verificationViolations(
                    before: items,
                    after: after,
                    hiddenScopes: targets.scopes,
                    ownBundleID: environment.ownBundleID
                )
            }
            if !violations.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        guard violations.isEmpty else {
            candidate.invalidate()
            return .failure(.verificationFailed(violations))
        }

        current = candidate
        lastApplied = (targets.bundles, targets.systemCodes, Set(allowedBundles))
        isRestricted = true
        return .success(.restricted(hiddenScopes: targets.scopes.count))
    }

    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    private func activate(_ handle: VisibilityAssertionHandle, timeout: TimeInterval) async -> VisibilityFailure? {
        let box = ResumeBox()
        return await withCheckedContinuation { continuation in
            let timeoutItem = DispatchWorkItem {
                if box.claim() {
                    continuation.resume(returning: .activationTimedOut)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            handle.activate { error in
                timeoutItem.cancel()
                if box.claim() {
                    if let error {
                        continuation.resume(returning: .activationFailed(error.localizedDescription))
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}
