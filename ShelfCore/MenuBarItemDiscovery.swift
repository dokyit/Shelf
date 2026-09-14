import CoreGraphics
import Foundation

public struct ElementSnapshot: Equatable, Sendable {
    public var token: UInt64
    public var role: String?
    public var pid: pid_t
    public var identifier: String?
    public var title: String?
    public var elementDescription: String?
    public var children: [ElementSnapshot]

    public init(
        token: UInt64,
        role: String? = nil,
        pid: pid_t = -1,
        identifier: String? = nil,
        title: String? = nil,
        elementDescription: String? = nil,
        children: [ElementSnapshot] = []
    ) {
        self.token = token
        self.role = role
        self.pid = pid
        self.identifier = identifier
        self.title = title
        self.elementDescription = elementDescription
        self.children = children
    }
}

public struct GroupSnapshot: Equatable, Sendable {
    public var frame: CGRect
    public var children: [ElementSnapshot]

    public init(frame: CGRect, children: [ElementSnapshot]) {
        self.frame = frame
        self.children = children
    }
}

public struct HostSnapshot: Equatable, Sendable {
    public var groups: [GroupSnapshot]
    public var overflowButtonFrame: CGRect?

    public init(groups: [GroupSnapshot], overflowButtonFrame: CGRect? = nil) {
        self.groups = groups
        self.overflowButtonFrame = overflowButtonFrame
    }
}

public struct MenuBarAppInfo: Equatable, Sendable {
    public var bundleID: String?
    public var localizedName: String?

    public init(bundleID: String?, localizedName: String?) {
        self.bundleID = bundleID
        self.localizedName = localizedName
    }
}

public enum MenuBarItemDiscovery {
    public static let menuExtraPrefix = "com.apple.menuextra"
    public static let overflowButtonDescription = "Show Hidden Menu Bar Items"
    public static let overflowOverlapThreshold: Double = 0.8

    public static func buildItems(
        from snapshot: HostSnapshot,
        ownPID: pid_t,
        agentPID: pid_t,
        appInfo: (pid_t) -> MenuBarAppInfo
    ) -> [ManagedItem] {
        var seenTokens = Set<UInt64>()
        var ownerOrdinal: [pid_t: Int] = [:]
        var items: [ManagedItem] = []

        for group in snapshot.groups {
            guard isValidItemFrame(group.frame) else { continue }

            if let owner = appOwner(in: group, agentPID: agentPID) {
                guard seenTokens.insert(owner.token).inserted else { continue }
                let info = appInfo(owner.pid)
                let ordinal = ownerOrdinal[owner.pid] ?? 0
                ownerOrdinal[owner.pid] = ordinal + 1
                let scope = info.bundleID.map(ItemScope.app) ?? ItemScope.process(owner.pid)
                let detail = owner.identifier ?? owner.elementDescription ?? ""
                let id = "\(scope):\(detail.isEmpty ? "item\(ordinal)" : detail)"
                let name = info.localizedName ?? owner.elementDescription ?? owner.title ?? "Menu bar item"
                items.append(ManagedItem(
                    id: id,
                    scope: scope,
                    bundleID: info.bundleID,
                    systemIdentifier: nil,
                    ownerPID: owner.pid,
                    name: name,
                    frame: group.frame,
                    isNativeOverflow: false,
                    isPresent: true,
                    elementToken: owner.token
                ))
            } else if let leaf = menuExtraLeaf(in: group.children) {
                guard seenTokens.insert(leaf.token).inserted else { continue }
                guard let identifier = leaf.identifier, !identifier.isEmpty else { continue }
                let scope = ItemScope.system(identifier)
                let name = SystemMenuBarItem.entry(for: identifier)?.displayName
                    ?? leaf.elementDescription ?? leaf.title ?? identifier
                items.append(ManagedItem(
                    id: "\(scope):\(identifier)",
                    scope: scope,
                    bundleID: nil,
                    systemIdentifier: identifier,
                    ownerPID: leaf.pid >= 0 ? leaf.pid : agentPID,
                    name: name,
                    frame: group.frame,
                    isNativeOverflow: false,
                    isPresent: true,
                    elementToken: leaf.token
                ))
            }
        }

        for index in items.indices {
            items[index].isNativeOverflow = isNativeOverflow(
                frame: items[index].frame,
                ownerPID: items[index].ownerPID,
                items: items,
                overflowButtonFrame: snapshot.overflowButtonFrame
            )
        }
        return items
    }

    public static func isValidItemFrame(_ frame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && frame.height <= 64
    }

    static func appOwner(in group: GroupSnapshot, agentPID: pid_t) -> ElementSnapshot? {
        group.children.first {
            ($0.role == "AXApplication" || $0.role == "AXButton") && $0.pid != agentPID && $0.pid >= 0
        }
    }

    static func menuExtraLeaf(in elements: [ElementSnapshot]) -> ElementSnapshot? {
        for element in elements {
            if element.role == "AXMenuBarItem",
               let identifier = element.identifier,
               identifier.hasPrefix(menuExtraPrefix) {
                return element
            }
            if element.role == "AXGroup", let found = menuExtraLeaf(in: element.children) {
                return found
            }
        }
        return nil
    }

    static func isNativeOverflow(
        frame: CGRect,
        ownerPID: pid_t,
        items: [ManagedItem],
        overflowButtonFrame: CGRect?
    ) -> Bool {
        if let chevron = overflowButtonFrame, frame.intersects(chevron) {
            return true
        }
        return items.contains { other in
            other.ownerPID != ownerPID && overlapRatio(of: frame, with: other.frame) > overflowOverlapThreshold
        }
    }

    static func overlapRatio(of frame: CGRect, with other: CGRect) -> Double {
        let intersection = frame.intersection(other)
        guard !intersection.isNull, frame.width > 0, frame.height > 0 else { return 0 }
        let area = Double(intersection.width * intersection.height)
        let own = Double(frame.width * frame.height)
        return area / own
    }
}
