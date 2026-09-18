import AppKit
import ApplicationServices
import ShelfCore

enum IconPlacement {
    enum Outcome: Equatable {
        case placed
        case failure(String)
    }

    static func keepShelfVisible(
        inventory: MenuBarInventory,
        ownBundleID: String
    ) async -> Outcome {
        guard AXIsProcessTrusted() else {
            return .failure("Shelf needs Accessibility permission before it can move its icon.")
        }
        if CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right) {
            return .failure("The mouse button is held down. Try again in a moment.")
        }
        let recentMotion = min(
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDragged)
        )
        if recentMotion < 0.5 {
            return .failure("The pointer is moving. Try again in a moment.")
        }

        guard var items = await inventory.captureFreshItems() else {
            return .failure("The menu bar could not be inspected.")
        }
        guard var own = items.first(where: { $0.bundleID == ownBundleID }) else {
            return .failure("The Shelf icon could not be found in the menu bar.")
        }

        if own.isNativeOverflow {
            guard await inventory.revealNativeOverflow() else {
                return .failure("The macOS overflow area could not be opened.")
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let fresh = await inventory.captureFreshItems() else {
                return .failure("The menu bar could not be inspected after opening overflow.")
            }
            items = fresh
            guard let relocated = fresh.first(where: { $0.bundleID == ownBundleID }) else {
                return .failure("The Shelf icon could not be found inside the overflow area.")
            }
            own = relocated
            if own.isNativeOverflow {
                return .failure("The Shelf icon is still hidden inside macOS overflow.")
            }
        }

        guard let controlCenter = items.first(where: {
            $0.systemIdentifier == SystemMenuBarItem.identifier(for: 8)
        }) else {
            return .failure("Control Center was not found as a drop target.")
        }

        let source = CGPoint(x: own.frame.midX, y: own.frame.midY)
        let target = CGPoint(
            x: controlCenter.frame.minX - (own.frame.width / 2) - 6,
            y: controlCenter.frame.midY
        )

        guard await postCommandDrag(from: source, to: target) else {
            return .failure("The drag events could not be posted.")
        }

        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let after = await inventory.captureFreshItems(),
              let moved = after.first(where: { $0.bundleID == ownBundleID }),
              moved.isPresent,
              !moved.isNativeOverflow else {
            return .failure("The Shelf icon could not be placed in the menu bar. Nothing was changed.")
        }
        return .placed
    }

    private static func postCommandDrag(from source: CGPoint, to target: CGPoint) async -> Bool {
        await Task.detached {
            let originalPointer = CGEvent(source: nil)?.location
            let display = CGMainDisplayID()
            CGDisplayHideCursor(display)
            defer {
                if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
                CGDisplayShowCursor(display)
            }

            let eventSource = CGEventSource(stateID: .hidSystemState)
            guard let down = CGEvent(
                mouseEventSource: eventSource,
                mouseType: .leftMouseDown,
                mouseCursorPosition: source,
                mouseButton: .left
            ) else { return false }
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 120_000_000)

            guard let drag = CGEvent(
                mouseEventSource: eventSource,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: target,
                mouseButton: .left
            ) else { return false }
            drag.flags = .maskCommand
            drag.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 90_000_000)

            guard let up = CGEvent(
                mouseEventSource: eventSource,
                mouseType: .leftMouseUp,
                mouseCursorPosition: target,
                mouseButton: .left
            ) else { return false }
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
            return true
        }.value
    }
}
