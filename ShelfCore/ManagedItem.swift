import CoreGraphics
import Foundation

public struct ManagedItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var scope: String
    public var bundleID: String?
    public var systemIdentifier: String?
    public var ownerPID: pid_t
    public var name: String
    public var frame: CGRect
    public var isNativeOverflow: Bool
    public var isPresent: Bool
    public var elementToken: UInt64

    public init(
        id: String,
        scope: String,
        bundleID: String?,
        systemIdentifier: String?,
        ownerPID: pid_t,
        name: String,
        frame: CGRect,
        isNativeOverflow: Bool,
        isPresent: Bool,
        elementToken: UInt64 = 0
    ) {
        self.id = id
        self.scope = scope
        self.bundleID = bundleID
        self.systemIdentifier = systemIdentifier
        self.ownerPID = ownerPID
        self.name = name
        self.frame = frame
        self.isNativeOverflow = isNativeOverflow
        self.isPresent = isPresent
        self.elementToken = elementToken
    }
}

public enum ItemScope {
    public static func app(_ bundleID: String) -> String { "app:\(bundleID)" }
    public static func system(_ identifier: String) -> String { "system:\(identifier)" }
    public static func process(_ pid: pid_t) -> String { "proc:\(pid)" }

    public static func bundleID(of scope: String) -> String? {
        scope.hasPrefix("app:") ? String(scope.dropFirst(4)) : nil
    }

    public static func systemIdentifier(of scope: String) -> String? {
        scope.hasPrefix("system:") ? String(scope.dropFirst(7)) : nil
    }

    public static func isEphemeral(_ scope: String) -> Bool {
        scope.hasPrefix("proc:")
    }
}

public enum SystemMenuBarItem {
    public struct Known: Equatable, Sendable {
        public var code: Int
        public var identifier: String
        public var displayName: String
        public var locked: Bool
        public init(code: Int, identifier: String, displayName: String, locked: Bool) {
            self.code = code
            self.identifier = identifier
            self.displayName = displayName
            self.locked = locked
        }
    }

    public static let allCodes = Array(0...8)

    public static let known: [Known] = [
        Known(code: 0, identifier: "com.apple.menuextra.battery", displayName: "Battery", locked: true),
        Known(code: 1, identifier: "com.apple.menuextra.bluetooth", displayName: "Bluetooth", locked: false),
        Known(code: 2, identifier: "com.apple.menuextra.clock", displayName: "Clock", locked: true),
        Known(code: 3, identifier: "com.apple.menuextra.displays", displayName: "Displays", locked: false),
        Known(code: 4, identifier: "com.apple.menuextra.textinput", displayName: "Input Menu", locked: false),
        Known(code: 5, identifier: "com.apple.menuextra.sound", displayName: "Sound", locked: false),
        Known(code: 6, identifier: "com.apple.menuextra.wifi", displayName: "Wi-Fi", locked: true),
        Known(code: 7, identifier: "com.apple.menuextra.screenmirroring", displayName: "Screen Mirroring", locked: false),
        Known(code: 8, identifier: "com.apple.menuextra.controlcenter", displayName: "Control Center", locked: true)
    ]

    public static func entry(for identifier: String) -> Known? {
        known.first { $0.identifier == identifier }
    }

    public static func code(for identifier: String) -> Int? {
        entry(for: identifier)?.code
    }

    public static func identifier(for code: Int) -> String? {
        known.first { $0.code == code }?.identifier
    }

    public static func isLocked(_ identifier: String) -> Bool {
        entry(for: identifier)?.locked ?? false
    }
}

public extension ManagedItem {
    var systemCode: Int? {
        guard let systemIdentifier else { return nil }
        return SystemMenuBarItem.code(for: systemIdentifier)
    }

    var isManageable: Bool {
        if bundleID != nil { return true }
        if let systemIdentifier {
            guard let entry = SystemMenuBarItem.entry(for: systemIdentifier) else { return false }
            return !entry.locked
        }
        return false
    }

    var isPreservable: Bool {
        if let bundleID { return !bundleID.hasPrefix("local.") }
        if systemIdentifier != nil { return systemCode != nil }
        return false
    }
}
