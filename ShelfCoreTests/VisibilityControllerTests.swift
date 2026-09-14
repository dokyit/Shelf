import CoreGraphics
import Foundation
import Testing
@testable import ShelfCore

private final class FakeHandle: VisibilityAssertionHandle, @unchecked Sendable {
    enum Behavior {
        case succeed
        case fail
        case manual
        case hang
    }

    let behavior: Behavior
    var onActivate: (@Sendable () -> Void)?
    private(set) var invalidated = false
    private(set) var activateCalls = 0
    private var storedCompletion: (@Sendable (Error?) -> Void)?

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func activate(completion: @escaping @Sendable (Error?) -> Void) {
        activateCalls += 1
        onActivate?()
        switch behavior {
        case .succeed:
            completion(nil)
        case .fail:
            completion(NSError(domain: "Fake", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "activation refused"
            ]))
        case .manual:
            storedCompletion = completion
        case .hang:
            break
        }
    }

    func fire(_ error: Error? = nil) {
        storedCompletion?(error)
    }

    func invalidate() {
        invalidated = true
    }
}

private final class FakeFactory: VisibilityAssertionFactory, @unchecked Sendable {
    var available = true
    var handles: [FakeHandle] = []
    var madeAllowedBundles: [[String]] = []
    var madeSystemItems: [[Int]] = []

    var isBackendAvailable: Bool { available }

    func makeAssertion(allowedBundles: [String], allowedSystemItems: [Int]) -> VisibilityAssertionHandle? {
        madeAllowedBundles.append(allowedBundles)
        madeSystemItems.append(allowedSystemItems)
        guard !handles.isEmpty else { return nil }
        return handles.removeFirst()
    }
}

struct VisibilityControllerTests {
    private let ownBundle = "com.pinnyutility.Shelf"
    private let ownPID: pid_t = 999

    private func item(
        scope: String,
        pid: pid_t,
        overflow: Bool = false,
        present: Bool = true
    ) -> ManagedItem {
        ManagedItem(
            id: "\(scope):x",
            scope: scope,
            bundleID: ItemScope.bundleID(of: scope),
            systemIdentifier: ItemScope.systemIdentifier(of: scope),
            ownerPID: pid,
            name: scope,
            frame: CGRect(x: 100 + CGFloat(pid), y: 0, width: 30, height: 24),
            isNativeOverflow: overflow,
            isPresent: present,
            elementToken: UInt64(pid)
        )
    }

    private var baseItems: [ManagedItem] {
        [
            item(scope: "app:com.pinnyutility.Shelf", pid: ownPID),
            item(scope: "app:com.example.one", pid: 100),
            item(scope: "app:com.example.two", pid: 200)
        ]
    }

    private func layout(hiding scope: String, section: ItemSection = .onShelf) -> ShelfLayout {
        var layout = ShelfLayout()
        layout.assign(scope, to: section)
        return layout
    }

    private func makeEnv(
        factory: FakeFactory,
        verifyItems: @escaping @Sendable () async -> [ManagedItem]?
    ) -> VisibilityController.Environment {
        VisibilityController.Environment(
            factory: factory,
            ownBundleID: ownBundle,
            runningBundleIDs: {
                ["com.pinnyutility.Shelf", "com.example.one", "com.example.two"]
            },
            itemsForVerification: verifyItems,
            activationTimeout: 0.2,
            settleDelay: 0.01,
            verifyWindow: 0.4
        )
    }

    @Test func successfulApplyHidesOnlyTargetBundle() async {
        let factory = FakeFactory()
        let handle = FakeHandle(behavior: .succeed)
        factory.handles = [handle]
        let after = [
            item(scope: "app:com.pinnyutility.Shelf", pid: ownPID),
            item(scope: "app:com.example.two", pid: 200)
        ]
        let engine = VisibilityController(environment: makeEnv(factory: factory) { after })
        let result = await engine.apply(
            layout: layout(hiding: "app:com.example.one"),
            items: baseItems
        ) { false }
        #expect(result == .success(.restricted(hiddenScopes: 1)))
        #expect(await engine.isRestricted)
        #expect(factory.madeAllowedBundles.count == 1)
        #expect(!factory.madeAllowedBundles[0].contains("com.example.one"))
        #expect(factory.madeAllowedBundles[0].contains("com.example.two"))
        #expect(factory.madeAllowedBundles[0].contains("com.pinnyutility.Shelf"))
        #expect(factory.madeSystemItems[0] == Array(0...8))
    }

    @Test func emptyHiddenSetInvalidatesWithoutAsserting() async {
        let factory = FakeFactory()
        let engine = VisibilityController(environment: makeEnv(factory: factory) { self.baseItems })
        let result = await engine.apply(layout: ShelfLayout(), items: baseItems) { false }
        #expect(result == .success(.unrestricted))
        #expect(factory.madeAllowedBundles.isEmpty)
        #expect(await !engine.isRestricted)
    }

    @Test func nilHandleDoesNotActivate() async {
        let factory = FakeFactory()
        let engine = VisibilityController(environment: makeEnv(factory: factory) { self.baseItems })
        let result = await engine.apply(
            layout: layout(hiding: "app:com.example.one"),
            items: baseItems
        ) { false }
        #expect(result == .failure(.backendUnavailable))
    }

    @Test func activationErrorIsReportedAndInvalidated() async {
        let factory = FakeFactory()
        let handle = FakeHandle(behavior: .fail)
        factory.handles = [handle]
        let engine = VisibilityController(environment: makeEnv(factory: factory) { self.baseItems })
        let result = await engine.apply(
            layout: layout(hiding: "app:com.example.one"),
            items: baseItems
        ) { false }
        guard case .failure(.activationFailed) = result else {
            Issue.record("expected activationFailed, got \(result)")
            return
        }
        #expect(handle.invalidated)
        #expect(await !engine.isRestricted)
    }

    @Test func activationTimeoutIsReportedAndInvalidated() async {
        let factory = FakeFactory()
        let handle = FakeHandle(behavior: .hang)
        factory.handles = [handle]
        let engine = VisibilityController(environment: makeEnv(factory: factory) { self.baseItems })
        let result = await engine.apply(
            layout: layout(hiding: "app:com.example.one"),
            items: baseItems
        ) { false }
        #expect(result == .failure(.activationTimedOut))
        #expect(handle.invalidated)
    }

    @Test func suspendDuringActivationCancelsCandidate() async {
        let factory = FakeFactory()
        let handle = FakeHandle(behavior: .manual)
        factory.handles = [handle]
        let engine = VisibilityController(environment: makeEnv(factory: factory) { self.baseItems })
        let task = Task {
            await engine.apply(
                layout: layout(hiding: "app:com.example.one"),
                items: baseItems
            ) { false }
        }
        for _ in 0..<100 where handle.activateCalls == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(handle.activateCalls == 1)
        await engine.suspend()
        handle.fire(nil)
        let result = await task.value
        #expect(result == .failure(.cancelled))
        #expect(handle.invalidated)
        #expect(await !engine.isRestricted)
    }

    @Test func unexpectedAllowedLossReleasesCandidateAndPrevious() async {
        let factory = FakeFactory()
        let first = FakeHandle(behavior: .succeed)
        let second = FakeHandle(behavior: .succeed)
        factory.handles = [first, second]

        let engine = VisibilityController(environment: makeEnv(factory: factory) {
            [
                self.item(scope: "app:com.pinnyutility.Shelf", pid: self.ownPID),
                self.item(scope: "app:com.example.two", pid: 200)
            ]
        })
        let firstResult = await engine.apply(
            layout: layout(hiding: "app:com.example.one"),
            items: baseItems
        ) { false }
        #expect(firstResult == .success(.restricted(hiddenScopes: 1)))

        var newLayout = ShelfLayout()
        newLayout.assign("app:com.example.two", to: .alwaysHide)
        let secondResult = await engine.apply(
            layout: newLayout,
            items: baseItems
        ) { false }
        guard case .failure(.verificationFailed) = secondResult else {
            Issue.record("expected verificationFailed, got \(secondResult)")
            return
        }
        #expect(second.invalidated)
        #expect(first.invalidated)
        #expect(await !engine.isRestricted)
    }

    @Test func retargetedApplyInvalidatesPreviousBeforeActivating() async {
        let factory = FakeFactory()
        let first = FakeHandle(behavior: .succeed)
        let second = FakeHandle(behavior: .succeed)
        factory.handles = [first, second]
        var firstInvalidatedWhenSecondActivated = false
        second.onActivate = {
            firstInvalidatedWhenSecondActivated = first.invalidated
        }

        let afterFirst = [
            item(scope: "app:com.pinnyutility.Shelf", pid: ownPID),
            item(scope: "app:com.example.two", pid: 200)
        ]
        let afterSecond = [item(scope: "app:com.pinnyutility.Shelf", pid: ownPID)]
        let engine = VisibilityController(environment: makeEnv(factory: factory) {
            factory.madeAllowedBundles.count >= 2 ? afterSecond : afterFirst
        })
        let firstResult = await engine.apply(
            layout: layout(hiding: "app:com.example.one"),
            items: baseItems
        ) { false }
        #expect(firstResult == .success(.restricted(hiddenScopes: 1)))

        var newLayout = ShelfLayout()
        newLayout.assign("app:com.example.one", to: .onShelf)
        newLayout.assign("app:com.example.two", to: .alwaysHide)
        let secondResult = await engine.apply(
            layout: newLayout,
            items: baseItems
        ) { false }
        #expect(secondResult == .success(.restricted(hiddenScopes: 2)))
        #expect(firstInvalidatedWhenSecondActivated)
        #expect(await engine.isRestricted)
    }

    @Test func unpreservableItemLossDoesNotFailVerification() async {
        let factory = FakeFactory()
        factory.handles = [FakeHandle(behavior: .succeed)]
        let before = [
            item(scope: "app:com.pinnyutility.Shelf", pid: ownPID),
            item(scope: "app:com.example.one", pid: 100),
            item(scope: "app:com.example.two", pid: 200),
            item(scope: "app:local.example.preview", pid: 300),
            item(scope: "proc:400", pid: 400)
        ]
        let after = [
            item(scope: "app:com.pinnyutility.Shelf", pid: ownPID),
            item(scope: "app:com.example.two", pid: 200)
        ]
        let engine = VisibilityController(environment: makeEnv(factory: factory) { after })
        let result = await engine.apply(
            layout: layout(hiding: "app:com.example.one"),
            items: before
        ) { false }
        #expect(result == .success(.restricted(hiddenScopes: 1)))
    }

    @Test func overflowedItemIsNotRequiredToStayVisible() async {
        let factory = FakeFactory()
        let handle = FakeHandle(behavior: .succeed)
        factory.handles = [handle]
        let before = [
            item(scope: "app:com.pinnyutility.Shelf", pid: ownPID),
            item(scope: "app:com.example.one", pid: 100, overflow: true),
            item(scope: "app:com.example.two", pid: 200)
        ]
        let after = [
            item(scope: "app:com.pinnyutility.Shelf", pid: ownPID),
            item(scope: "app:com.example.two", pid: 200)
        ]
        let engine = VisibilityController(environment: makeEnv(factory: factory) { after })
        let result = await engine.apply(
            layout: layout(hiding: "app:com.example.one"),
            items: before
        ) { false }
        #expect(result == .success(.restricted(hiddenScopes: 1)))
    }

    @Test func conflictPreventsActivation() async {
        let factory = FakeFactory()
        factory.handles = [FakeHandle(behavior: .succeed)]
        let engine = VisibilityController(environment: makeEnv(factory: factory) { self.baseItems })
        let result = await engine.apply(
            layout: layout(hiding: "app:com.example.one"),
            items: baseItems
        ) { true }
        #expect(result == .failure(.conflict))
        #expect(factory.madeAllowedBundles.isEmpty)
    }

    @Test func temporaryRevealDoesNotExposeAlwaysHide() async {
        let factory = FakeFactory()
        let handle = FakeHandle(behavior: .succeed)
        factory.handles = [handle]
        var layout = ShelfLayout()
        layout.assign("app:com.example.one", to: .onShelf)
        layout.assign("app:com.example.two", to: .alwaysHide)
        let after = [
            item(scope: "app:com.pinnyutility.Shelf", pid: ownPID),
            item(scope: "app:com.example.one", pid: 100)
        ]
        let engine = VisibilityController(environment: makeEnv(factory: factory) { after })
        let result = await engine.apply(
            layout: layout,
            items: baseItems,
            temporaryReveal: ["app:com.example.one"]
        ) { false }
        #expect(result == .success(.restricted(hiddenScopes: 1)))
        #expect(factory.madeAllowedBundles[0].contains("com.example.one"))
        #expect(!factory.madeAllowedBundles[0].contains("com.example.two"))
    }

    @Test func missingOwnItemBlocksApply() async {
        let factory = FakeFactory()
        factory.handles = [FakeHandle(behavior: .succeed)]
        let items = [
            item(scope: "app:com.pinnyutility.Shelf", pid: ownPID, overflow: true),
            item(scope: "app:com.example.one", pid: 100)
        ]
        let engine = VisibilityController(environment: makeEnv(factory: factory) { items })
        let result = await engine.apply(
            layout: layout(hiding: "app:com.example.one"),
            items: items
        ) { false }
        #expect(result == .failure(.ownItemUnreachable))
        #expect(factory.madeAllowedBundles.isEmpty)
    }

    @Test func missingInventoryBlocksApply() async {
        let factory = FakeFactory()
        let engine = VisibilityController(environment: makeEnv(factory: factory) { nil })
        let result = await engine.apply(
            layout: layout(hiding: "app:com.example.one"),
            items: nil
        ) { false }
        #expect(result == .failure(.inventoryUnavailable))
    }

    @Test func lateCallbackResolvesOnce() async {
        let factory = FakeFactory()
        let handle = FakeHandle(behavior: .manual)
        factory.handles = [handle]
        let engine = VisibilityController(environment: makeEnv(factory: factory) { self.baseItems })
        async let result = engine.apply(
            layout: layout(hiding: "app:com.example.one"),
            items: baseItems
        ) { false }
        try? await Task.sleep(nanoseconds: 300_000_000)
        handle.fire(nil)
        handle.fire(nil)
        let resolved = await result
        #expect(resolved == .failure(.activationTimedOut))
        #expect(handle.invalidated)
    }
}
