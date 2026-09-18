import AppKit
import ShelfCore

@MainActor
final class ItemIconCache: ObservableObject {
    @Published private(set) var icons: [String: NSImage] = [:]

    func icon(for item: ManagedItem) -> NSImage {
        if let cached = icons[item.scope] { return cached }
        let image = resolve(item)
        icons[item.scope] = image
        return image
    }

    func statusIcon(for item: ManagedItem) -> NSImage {
        // Known locally-built apps can expose a perfectly valid MenuBarExtra
        // while macOS assessment mode refuses to render it. Match the original
        // menu-bar glyph when we know it; otherwise fall back to the app icon.
        if item.bundleID == "local.tobias.FM26MacEditor26",
           let image = NSImage(
                systemSymbolName: "soccerball.circle.fill",
                accessibilityDescription: item.name
           ) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        let source = icon(for: item)
        let copy = (source.copy() as? NSImage) ?? source
        copy.size = NSSize(width: 18, height: 18)
        return copy
    }

    private func resolve(_ item: ManagedItem) -> NSImage {
        if let bundleID = item.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 24, height: 24)
            return icon
        }
        let symbol = Self.systemSymbols[item.systemIdentifier ?? ""] ?? "app.dashed"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.name)
            ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private static let systemSymbols: [String: String] = [
        "com.apple.menuextra.battery": "battery.100",
        "com.apple.menuextra.bluetooth": "antenna.radiowaves.left.and.right",
        "com.apple.menuextra.clock": "clock",
        "com.apple.menuextra.displays": "display",
        "com.apple.menuextra.textinput": "keyboard",
        "com.apple.menuextra.sound": "speaker.wave.2",
        "com.apple.menuextra.now-playing": "play.circle",
        "com.apple.menuextra.wifi": "wifi",
        "com.apple.menuextra.screenmirroring": "rectangle.on.rectangle",
        "com.apple.menuextra.controlcenter": "switch.2"
    ]
}
