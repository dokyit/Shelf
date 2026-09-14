import CoreGraphics
import Foundation
import Testing
@testable import ShelfCore

struct MenuBarItemDiscoveryTests {
    private let agentPID: pid_t = 698
    private let ownPID: pid_t = 4242

    private func appElement(token: UInt64, pid: pid_t, role: String = "AXButton", description: String? = nil) -> ElementSnapshot {
        ElementSnapshot(token: token, role: role, pid: pid, elementDescription: description)
    }

    private func systemGroup(frame: CGRect, identifier: String, token: UInt64) -> GroupSnapshot {
        GroupSnapshot(
            frame: frame,
            children: [
                ElementSnapshot(
                    token: token + 1000,
                    role: "AXGroup",
                    pid: agentPID,
                    children: [
                        ElementSnapshot(
                            token: token,
                            role: "AXMenuBarItem",
                            pid: agentPID,
                            identifier: identifier
                        )
                    ]
                )
            ]
        )
    }

    private func appGroup(frame: CGRect, token: UInt64, pid: pid_t) -> GroupSnapshot {
        GroupSnapshot(frame: frame, children: [appElement(token: token, pid: pid)])
    }

    private func info(bundleID: String? = nil, name: String? = nil) -> MenuBarAppInfo {
        MenuBarAppInfo(bundleID: bundleID, localizedName: name)
    }

    @Test func appGroupsBecomeItems() {
        let snapshot = HostSnapshot(groups: [
            appGroup(frame: CGRect(x: 1200, y: 0, width: 30, height: 24), token: 1, pid: 100)
        ])
        let items = MenuBarItemDiscovery.buildItems(
            from: snapshot, ownPID: ownPID, agentPID: agentPID
        ) { _ in info(bundleID: "com.example.one", name: "One") }
        #expect(items.count == 1)
        #expect(items[0].scope == "app:com.example.one")
        #expect(items[0].name == "One")
        #expect(items[0].ownerPID == 100)
    }

    @Test func duplicateElementTokensCountOnce() {
        let snapshot = HostSnapshot(groups: [
            appGroup(frame: CGRect(x: 1200, y: 0, width: 30, height: 24), token: 7, pid: 100),
            appGroup(frame: CGRect(x: 1200, y: 0, width: 30, height: 24), token: 7, pid: 100)
        ])
        let items = MenuBarItemDiscovery.buildItems(
            from: snapshot, ownPID: ownPID, agentPID: agentPID
        ) { _ in info(bundleID: "com.example.one", name: "One") }
        #expect(items.count == 1)
    }

    @Test func distinctItemsSameOwnerCountSeparately() {
        let snapshot = HostSnapshot(groups: [
            appGroup(frame: CGRect(x: 1200, y: 0, width: 30, height: 24), token: 1, pid: 100),
            appGroup(frame: CGRect(x: 1240, y: 0, width: 30, height: 24), token: 2, pid: 100)
        ])
        let items = MenuBarItemDiscovery.buildItems(
            from: snapshot, ownPID: ownPID, agentPID: agentPID
        ) { _ in info(bundleID: "com.example.one", name: "One") }
        #expect(items.count == 2)
        #expect(items[0].id != items[1].id)
    }

    @Test func stackedDifferentOwnersAreNativeOverflow() {
        let frame = CGRect(x: 958, y: 0, width: 38, height: 34)
        let snapshot = HostSnapshot(groups: [
            appGroup(frame: frame, token: 1, pid: 100),
            appGroup(frame: frame, token: 2, pid: 200),
            appGroup(frame: CGRect(x: 1400, y: 0, width: 30, height: 24), token: 3, pid: 300)
        ])
        let items = MenuBarItemDiscovery.buildItems(
            from: snapshot, ownPID: ownPID, agentPID: agentPID
        ) { pid in info(bundleID: "com.example.\(pid)", name: "App\(pid)") }
        #expect(items.count == 3)
        #expect(items.filter(\.isNativeOverflow).count == 2)
        #expect(items.first { $0.ownerPID == 300 }?.isNativeOverflow == false)
    }

    @Test func chevronOverlapMarksNativeOverflow() {
        let frame = CGRect(x: 958, y: 0, width: 38, height: 34)
        let snapshot = HostSnapshot(
            groups: [
                appGroup(frame: frame, token: 1, pid: 100),
                appGroup(frame: CGRect(x: 1400, y: 0, width: 30, height: 24), token: 3, pid: 300)
            ],
            overflowButtonFrame: CGRect(x: 960, y: 0, width: 34, height: 34)
        )
        let items = MenuBarItemDiscovery.buildItems(
            from: snapshot, ownPID: ownPID, agentPID: agentPID
        ) { pid in info(bundleID: "com.example.\(pid)", name: nil) }
        #expect(items.first { $0.ownerPID == 100 }?.isNativeOverflow == true)
        #expect(items.first { $0.ownerPID == 300 }?.isNativeOverflow == false)
    }

    @Test func itemIntersectingChevronIsNativeOverflow() {
        let snapshot = HostSnapshot(
            groups: [
                appGroup(frame: CGRect(x: 950, y: 0, width: 38, height: 34), token: 1, pid: 100),
                appGroup(frame: CGRect(x: 560, y: 0, width: 38, height: 34), token: 2, pid: 200),
                appGroup(frame: CGRect(x: 1400, y: 0, width: 30, height: 24), token: 3, pid: 300)
            ],
            overflowButtonFrame: CGRect(x: 975, y: 0, width: 17.5, height: 31)
        )
        let items = MenuBarItemDiscovery.buildItems(
            from: snapshot, ownPID: ownPID, agentPID: agentPID
        ) { pid in info(bundleID: "com.example.\(pid)", name: nil) }
        #expect(items.first { $0.ownerPID == 100 }?.isNativeOverflow == true)
        #expect(items.first { $0.ownerPID == 200 }?.isNativeOverflow == false)
        #expect(items.first { $0.ownerPID == 300 }?.isNativeOverflow == false)
    }

    @Test func systemLeafUsesSystemScopeAndMapping() {
        let snapshot = HostSnapshot(groups: [
            systemGroup(
                frame: CGRect(x: 1560, y: 0, width: 130, height: 34),
                identifier: "com.apple.menuextra.clock",
                token: 50
            )
        ])
        let items = MenuBarItemDiscovery.buildItems(
            from: snapshot, ownPID: ownPID, agentPID: agentPID
        ) { _ in info() }
        #expect(items.count == 1)
        #expect(items[0].scope == "system:com.apple.menuextra.clock")
        #expect(items[0].name == "Clock")
        #expect(items[0].ownerPID == agentPID)
        #expect(items[0].isManageable == false)
    }

    @Test func agentOwnedButtonIsNotAnItem() {
        let snapshot = HostSnapshot(groups: [
            GroupSnapshot(
                frame: CGRect(x: 960, y: 0, width: 34, height: 34),
                children: [
                    ElementSnapshot(
                        token: 9,
                        role: "AXButton",
                        pid: agentPID,
                        elementDescription: "Show Hidden Menu Bar Items"
                    )
                ]
            )
        ])
        let items = MenuBarItemDiscovery.buildItems(
            from: snapshot, ownPID: ownPID, agentPID: agentPID
        ) { _ in info() }
        #expect(items.isEmpty)
    }

    @Test func invalidFramesAreSkipped() {
        let snapshot = HostSnapshot(groups: [
            appGroup(frame: .zero, token: 1, pid: 100),
            appGroup(frame: CGRect(x: 0, y: 0, width: 30, height: 200), token: 2, pid: 200)
        ])
        let items = MenuBarItemDiscovery.buildItems(
            from: snapshot, ownPID: ownPID, agentPID: agentPID
        ) { pid in info(bundleID: "com.example.\(pid)", name: nil) }
        #expect(items.isEmpty)
    }

    @Test func unbundledOwnerGetsEphemeralScope() {
        let snapshot = HostSnapshot(groups: [
            appGroup(frame: CGRect(x: 1200, y: 0, width: 30, height: 24), token: 1, pid: 100)
        ])
        let items = MenuBarItemDiscovery.buildItems(
            from: snapshot, ownPID: ownPID, agentPID: agentPID
        ) { _ in info(bundleID: nil, name: "Agent") }
        #expect(items.count == 1)
        #expect(ItemScope.isEphemeral(items[0].scope))
        #expect(items[0].isManageable == false)
    }
}
