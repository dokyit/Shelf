import AppKit
import SwiftUI

final class ShelfBarPanel: NSPanel {
    var onDismiss: (() -> Void)?
    var suppressOutsideDismiss = false
    private var monitors: [Any] = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
    }

    func present<Content: View>(content: Content, below anchor: NSRect?) {
        let effect = NSVisualEffectView()
        effect.material = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? .windowBackground
            : .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        contentView = effect

        let fitting = hosting.fittingSize
        let width = min(max(fitting.width, 240), 600)
        let height = min(max(fitting.height, 48), 460)
        setContentSize(NSSize(width: width, height: height))

        positionPanel(below: anchor)
        installMonitors()
        orderFront(nil)
        makeKey()
    }

    func dismiss() {
        removeMonitors()
        orderOut(nil)
        onDismiss?()
        onDismiss = nil
    }

    private func positionPanel(below anchor: NSRect?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = NSPoint(
            x: (anchor?.midX ?? visible.midX) - frame.width / 2,
            y: (anchor?.minY ?? visible.maxY) - frame.height - 4
        )
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - frame.width - 4)
        origin.y = max(origin.y, visible.minY + 4)
        setFrameOrigin(origin)
    }

    private func installMonitors() {
        removeMonitors()
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in
                guard let self, self.isVisible else { return }

                // Global monitors do not reliably populate event.window, even
                // for clicks inside this nonactivating panel. Use the actual
                // screen-space pointer location so clicking a Shelf tile does
                // not immediately dismiss Shelf.
                if self.frame.contains(NSEvent.mouseLocation) {
                    return
                }
                guard !self.suppressOutsideDismiss else { return }
                self.dismiss()
            }
        ) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                guard let self, self.isVisible, event.keyCode == 53 else { return }
                self.dismiss()
            }
        ) {
            monitors.append(monitor)
        }
    }

    private func removeMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
    }

    deinit {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
    }
}
