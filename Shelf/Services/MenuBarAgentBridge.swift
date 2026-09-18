import AppKit
import ApplicationServices
import ShelfCore

enum BridgeCapture {
    case needsAccessibility
    case unavailable
    case snapshot(HostSnapshot, agentPID: pid_t)
}

enum MenuBarClickButton {
    case left
    case right
}

actor MenuBarAgentBridge {
    private var pressableByToken: [UInt64: AXUIElement] = [:]
    private var ownerPIDByToken: [UInt64: pid_t] = [:]
    private var elementsByToken: [UInt64: AXUIElement] = [:]
    private var overflowElement: AXUIElement?

    private(set) var agentPID: pid_t = -1

    func capture() -> BridgeCapture {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        guard AXIsProcessTrusted() else { return .needsAccessibility }
        guard let agent = agentProcess() else { return .unavailable }
        agentPID = agent

        let appElement = AXUIElementCreateApplication(agent)
        guard let window = primaryMenuBarWindow(of: appElement) else { return .unavailable }

        var groups: [GroupSnapshot] = []
        var overflowFrame: CGRect?
        pressableByToken = [:]
        ownerPIDByToken = [:]
        elementsByToken = [:]
        overflowElement = nil

        for child in axChildren(of: window) {
            guard let frame = axFrame(of: child) else { continue }
            let selfSnapshot = describe(child, depth: 0)
            if isOverflowButton(selfSnapshot) {
                overflowFrame = frame
                overflowElement = child
                continue
            }
            let children = describeChildren(of: child, depth: 3)
            groups.append(GroupSnapshot(frame: frame, children: children))

            for element in children {
                let token = element.token
                let isAppItem = (element.role == "AXApplication" || element.role == "AXButton")
                    && element.pid != agent && element.pid >= 0
                if isAppItem {
                    ownerPIDByToken[token] = element.pid
                    pressableByToken[token] = resolveExtrasElement(ownerPID: element.pid, groupFrame: frame)
                        ?? elementsByToken[token]
                } else if let leaf = firstMenuExtraLeaf(in: element) {
                    ownerPIDByToken[leaf.token] = leaf.pid
                    pressableByToken[leaf.token] = elementsByToken[leaf.token]
                }
            }
        }
        return .snapshot(HostSnapshot(groups: groups, overflowButtonFrame: overflowFrame), agentPID: agent)
    }

    func pressItem(token: UInt64, button: MenuBarClickButton = .left) async -> Bool {
        guard let element = pressableByToken[token] else { return false }

        if button == .left {
            // Some SwiftUI MenuBarExtra items report kAXErrorCannotComplete even
            // though AXPress successfully opens their menu. Judge the result by
            // whether a menu actually appeared, not by the return code.
            _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if await menuOpenedSoon(token: token) { return true }
        }

        guard let frame = axFrame(of: element), frame.width > 0, frame.height > 0 else { return false }
        guard click(at: CGPoint(x: frame.midX, y: frame.midY), button: button) else { return false }
        if await menuOpenedSoon(token: token) { return true }

        if button == .right {
            _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if await menuOpenedSoon(token: token) { return true }
            guard let fresh = axFrame(of: element), fresh.width > 0, fresh.height > 0 else { return false }
            guard click(at: CGPoint(x: fresh.midX, y: fresh.midY), button: .left) else { return false }
            return await menuOpenedSoon(token: token)
        }
        return false
    }

    func pressDetachedItem(ownerPID: pid_t, ordinal: Int, button: MenuBarClickButton = .left) async -> Bool {
        let extras = extrasElements(of: ownerPID)
        guard ordinal >= 0, ordinal < extras.count else { return false }
        let element = extras[ordinal].element

        // Detached/local items can carry a stale physical frame that overlaps a
        // completely different status item. Never synthesize a click at that
        // frame. AXPress targets the owning app directly.
        _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return await menuOpenedSoon(element: element, ownerPID: ownerPID)
    }

    func dragItem(token: UInt64, toX x: CGFloat) async -> Bool {
        guard let element = pressableByToken[token] ?? elementsByToken[token],
              let frame = axFrame(of: element),
              frame.width > 0 else { return false }
        let source = CGPoint(x: frame.midX, y: frame.midY)
        let target = CGPoint(x: x, y: frame.midY)
        let originalPointer = CGEvent(source: nil)?.location
        let display = CGMainDisplayID()
        CGDisplayHideCursor(display)
        defer {
            if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
            CGDisplayShowCursor(display)
        }

        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(
            mouseEventSource: src, mouseType: .leftMouseDown,
            mouseCursorPosition: source, mouseButton: .left
        ) else { return false }
        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 120_000_000)

        guard let drag = CGEvent(
            mouseEventSource: src, mouseType: .leftMouseDragged,
            mouseCursorPosition: target, mouseButton: .left
        ) else { return false }
        drag.flags = .maskCommand
        drag.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 90_000_000)

        guard let up = CGEvent(
            mouseEventSource: src, mouseType: .leftMouseUp,
            mouseCursorPosition: target, mouseButton: .left
        ) else { return false }
        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)
        return true
    }

    private func menuOpenedSoon(token: UInt64) async -> Bool {
        for _ in 0..<8 {
            if hasOpenMenu(token: token) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func menuOpenedSoon(element: AXUIElement, ownerPID: pid_t) async -> Bool {
        for _ in 0..<8 {
            if axChildren(of: element).contains(where: isVisibleMenu) || hasOpenMenu(ownerPID: ownerPID) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func click(at point: CGPoint, button: MenuBarClickButton = .left) -> Bool {
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let cgButton: CGMouseButton = button == .left ? .left : .right
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(
            mouseEventSource: source, mouseType: downType,
            mouseCursorPosition: point, mouseButton: cgButton
        ), let up = CGEvent(
            mouseEventSource: source, mouseType: upType,
            mouseCursorPosition: point, mouseButton: cgButton
        ) else { return false }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        up.post(tap: .cghidEventTap)
        return true
    }

    func pressOverflow() -> Bool {
        guard let element = overflowElement, let frame = axFrame(of: element) else { return false }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left
        ) else { return false }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        up.post(tap: .cghidEventTap)
        return true
    }

    func hasOpenMenu(token: UInt64) -> Bool {
        guard let element = pressableByToken[token] else { return false }
        if axChildren(of: element).contains(where: isVisibleMenu) {
            return true
        }
        guard let pid = ownerPIDByToken[token] else { return false }
        return hasOpenMenu(ownerPID: pid)
    }

    func hasOpenMenu(ownerPID: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(ownerPID)
        if axChildren(of: app).contains(where: isVisibleMenu) {
            return true
        }

        // SwiftUI MenuBarExtra menus may be nested below an application child.
        func containsVisibleMenu(_ element: AXUIElement, depth: Int) -> Bool {
            guard depth <= 4 else { return false }
            if isVisibleMenu(element) { return true }
            return axChildren(of: element).contains {
                containsVisibleMenu($0, depth: depth + 1)
            }
        }
        return axChildren(of: app).contains {
            containsVisibleMenu($0, depth: 1)
        }
    }

    private func isVisibleMenu(_ element: AXUIElement) -> Bool {
        guard axRole(of: element) == "AXMenu",
              let frame = axFrame(of: element) else { return false }
        return frame.width > 4 && frame.height > 4
    }

    func extrasElementFrame(ownerPID pid: pid_t, near frame: CGRect) -> CGRect? {
        guard let element = resolveExtrasElement(ownerPID: pid, groupFrame: frame) else { return nil }
        return axFrame(of: element)
    }

    private func agentProcess() -> pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }?.processIdentifier
    }

    private func primaryMenuBarWindow(of appElement: AXUIElement) -> AXUIElement? {
        let displayWidth = CGDisplayBounds(CGMainDisplayID()).width
        var firstMatch: AXUIElement?
        for child in axChildren(of: appElement) {
            guard axRole(of: child) == "AXWindow", let frame = axFrame(of: child) else { continue }
            guard abs(frame.width - displayWidth) < 4 && frame.minY >= -4 && frame.minY <= 64 else { continue }
            if firstMatch == nil { firstMatch = child }
            for group in axChildren(of: child) {
                guard axRole(of: group) == "AXButton" else { continue }
                let label = axString(of: group, attribute: "AXDescription") ?? axString(of: group, attribute: "AXTitle")
                if label == MenuBarItemDiscovery.overflowButtonDescription {
                    return child
                }
            }
        }
        return firstMatch
    }

    private func describeChildren(of element: AXUIElement, depth: Int) -> [ElementSnapshot] {
        axChildren(of: element).map { describe($0, depth: depth) }
    }

    private func describe(_ element: AXUIElement, depth: Int) -> ElementSnapshot {
        let role = axRole(of: element)
        var pid: pid_t = -1
        AXUIElementGetPid(element, &pid)
        let token = UInt64(CFHash(element))
        elementsByToken[token] = element
        let grandchildren: [ElementSnapshot]
        if depth > 0 && role == "AXGroup" {
            grandchildren = describeChildren(of: element, depth: depth - 1)
        } else {
            grandchildren = []
        }
        return ElementSnapshot(
            token: token,
            role: role,
            pid: pid,
            identifier: axString(of: element, attribute: "AXIdentifier"),
            title: axString(of: element, attribute: "AXTitle"),
            elementDescription: axString(of: element, attribute: "AXDescription"),
            children: grandchildren
        )
    }

    private func firstMenuExtraLeaf(in element: ElementSnapshot) -> ElementSnapshot? {
        if element.role == "AXMenuBarItem",
           let identifier = element.identifier,
           identifier.hasPrefix(MenuBarItemDiscovery.menuExtraPrefix) {
            return element
        }
        if element.role == "AXGroup" {
            for child in element.children {
                if let found = firstMenuExtraLeaf(in: child) { return found }
            }
        }
        return nil
    }

    private func isOverflowButton(_ element: ElementSnapshot) -> Bool {
        guard element.role == "AXButton", element.pid == agentPID else { return false }
        let labels = [element.elementDescription, element.title]
        return labels.contains { $0 == MenuBarItemDiscovery.overflowButtonDescription }
    }

    func extrasElements(of pid: pid_t) -> [(element: AXUIElement, frame: CGRect)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var extras: AnyObject?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success,
              let extrasElement = extras as! AXUIElement? else { return [] }
        return axChildren(of: extrasElement).compactMap { child in
            guard let frame = axFrame(of: child) else { return nil }
            return (child, frame)
        }
    }

    func registerDetached(_ element: AXUIElement, ownerPID: pid_t) -> UInt64 {
        let token = UInt64(CFHash(element))
        elementsByToken[token] = element
        pressableByToken[token] = element
        ownerPIDByToken[token] = ownerPID
        return token
    }

    private func resolveExtrasElement(ownerPID: pid_t, groupFrame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(ownerPID)
        var extras: AnyObject?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success,
              let extrasElement = extras as! AXUIElement? else { return nil }
        for child in axChildren(of: extrasElement) {
            if let frame = axFrame(of: child),
               groupFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                return child
            }
        }
        return nil
    }

    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private func axRole(of element: AXUIElement) -> String? {
        axString(of: element, attribute: kAXRoleAttribute)
    }

    private func axString(of element: AXUIElement, attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
           let frameValue = value as! AXValue? {
            var frame = CGRect.zero
            if AXValueGetValue(frameValue, .cgRect, &frame) { return frame }
        }
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionAX = positionValue as! AXValue?,
              let sizeAX = sizeValue as! AXValue? else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
