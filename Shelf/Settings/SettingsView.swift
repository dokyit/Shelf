import AppKit
import ShelfCore
import SwiftUI

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

final class SettingsViewState: ObservableObject {
    @Published var page: SettingsView.Page = .layout
    @Published var layoutSearch = ""
}

final class LayoutReorderState: ObservableObject {
    @Published var draggingScope: String?
    @Published var previewSection: ItemSection?
    @Published var previewOrder: [String]?
    @Published var foreignScope: String?

    var cardFrames: [ItemSection: CGRect] = [:]
    var gridFrames: [ItemSection: CGRect] = [:]
    var itemFrames: [ItemSection: [String: CGRect]] = [:]

    func reset() {
        draggingScope = nil
        previewSection = nil
        previewOrder = nil
        foreignScope = nil
    }
}

private final class ReorderSurface: NSView {
    var onClick: (() -> Void)?
    var onMenu: ((ReorderSurface) -> Void)?
    var onDrag: ((CGPoint, Bool) -> Void)?
    private var downAt = CGPoint.zero
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard onDrag != nil else { return }
        let point = event.locationInWindow
        if !dragging, abs(point.x - downAt.x) + abs(point.y - downAt.y) > 6 { dragging = true }
        if dragging { onDrag?(point, false) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            onDrag?(event.locationInWindow, true)
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(self) }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

private struct ReorderSurfaceRepresentable: NSViewRepresentable {
    var onClick: () -> Void
    var onMenu: (ReorderSurface) -> Void
    var onDrag: ((CGPoint, Bool) -> Void)?

    func makeNSView(context: Context) -> ReorderSurface {
        let view = ReorderSurface()
        view.onClick = onClick
        view.onMenu = onMenu
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ nsView: ReorderSurface, context: Context) {
        nsView.onClick = onClick
        nsView.onMenu = onMenu
        nsView.onDrag = onDrag
    }
}

private final class WindowFrameReporterView: NSView {
    var onChange: ((CGRect) -> Void)?
    override func layout() {
        super.layout()
        report()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report()
    }
    private func report() {
        onChange?(convert(bounds, to: nil))
    }
}

private struct WindowFrameReporter: NSViewRepresentable {
    var onChange: (CGRect) -> Void
    func makeNSView(context: Context) -> WindowFrameReporterView {
        let view = WindowFrameReporterView()
        view.onChange = onChange
        return view
    }
    func updateNSView(_ nsView: WindowFrameReporterView, context: Context) {
        nsView.onChange = onChange
    }
}

private final class MenuActionProxy: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func performMenuAction() { handler() }
}

struct SettingsView: View {
    @ObservedObject var inventory: MenuBarInventory
    @ObservedObject var visibility: VisibilityManager
    @ObservedObject var icons: ItemIconCache
    var keepShelfVisible: () -> Void = {}
    var showShelf: () -> Void = {}

    enum Page: String, CaseIterable, Identifiable {
        case layout, behavior, permissions, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .layout: return "Menu Bar Layout"
            case .behavior: return "Behavior"
            case .permissions: return "Permissions"
            case .about: return "About"
            }
        }
        var symbol: String {
            switch self {
            case .layout: return "menubar.rectangle"
            case .behavior: return "gearshape"
            case .permissions: return "lock.shield"
            case .about: return "info.circle"
            }
        }
    }

    @StateObject private var state = SettingsViewState()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Page.allCases) { entry in
                    Button {
                        state.page = entry
                    } label: {
                        Label(entry.title, systemImage: entry.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(state.page == entry ? Color.accentColor.opacity(0.22) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(8)
            .frame(width: 185)
            .frame(maxHeight: .infinity)
            .background(SidebarMaterial())
            Divider()
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 650, idealWidth: 840, minHeight: 460, idealHeight: 620)
    }

    @ViewBuilder
    private var detailView: some View {
        switch state.page {
        case .layout:
            LayoutPage(
                inventory: inventory,
                visibility: visibility,
                icons: icons,
                keepShelfVisible: keepShelfVisible,
                showShelf: showShelf,
                search: $state.layoutSearch
            )
        case .behavior:
            BehaviorPage(visibility: visibility, keepShelfVisible: keepShelfVisible)
        case .permissions:
            PermissionsPage(visibility: visibility)
        case .about:
            AboutPage()
        }
    }
}

private struct LayoutPage: View {
    @ObservedObject var inventory: MenuBarInventory
    @ObservedObject var visibility: VisibilityManager
    @ObservedObject var icons: ItemIconCache
    var keepShelfVisible: () -> Void
    var showShelf: () -> Void
    @Binding var search: String
    @StateObject private var reorderState = LayoutReorderState()

    private var ownBundleID: String {
        Bundle.main.bundleIdentifier ?? "com.pinnyutility.Shelf"
    }

    private var presentItems: [ManagedItem] {
        let filtered = inventory.items.filter { item in
            item.isPresent
                && (search.isEmpty || item.name.localizedCaseInsensitiveContains(search))
        }

        // Preservation proxies are Shelf-owned status items. They should keep
        // detached apps visible in the real menu bar without turning into
        // extra "Shelf" entries in Settings.
        var keptOwnItem = false
        return filtered.filter { item in
            guard item.bundleID == ownBundleID else { return true }
            guard !keptOwnItem else { return false }
            keptOwnItem = true
            return true
        }
    }

    private func items(for section: ItemSection) -> [ManagedItem] {
        let sectionItems = presentItems.filter { effectiveSection(of: $0) == section }
        let sorted = sectionItems.sorted { lhs, rhs in
            let leftOrder = visibility.layout.rules[lhs.scope]?.order
            let rightOrder = visibility.layout.rules[rhs.scope]?.order
            if leftOrder != rightOrder {
                if let leftOrder, let rightOrder { return leftOrder < rightOrder }
                if leftOrder != nil { return true }
                if rightOrder != nil { return false }
            }
            let lx = lhs.frame.width > 0 ? lhs.frame.minX : .greatestFiniteMagnitude
            let rx = rhs.frame.width > 0 ? rhs.frame.minX : .greatestFiniteMagnitude
            if lx != rx { return lx < rx }
            return lhs.name < rhs.name
        }
        guard section == .alwaysShow else { return sorted }
        let movable = sorted.filter { trailingRank(for: $0) == nil }
        let trailing = sorted.filter { trailingRank(for: $0) != nil }
            .sorted { trailingRank(for: $0)! < trailingRank(for: $1)! }
        return movable + trailing
    }

    private func trailingRank(for item: ManagedItem) -> Int? {
        if item.bundleID == ownBundleID { return 3 }
        switch item.systemIdentifier {
        case "com.apple.menuextra.sound": return 0
        case "com.apple.menuextra.wifi": return 1
        case "com.apple.menuextra.battery": return 2
        case "com.apple.menuextra.controlcenter": return 4
        case "com.apple.menuextra.clock": return 5
        default: return nil
        }
    }

    private func displayItems(for section: ItemSection) -> [ManagedItem] {
        var base = items(for: section)
        if let dragging = reorderState.draggingScope,
           reorderState.previewOrder != nil,
           reorderState.previewSection != section {
            base.removeAll { $0.scope == dragging }
        }
        if reorderState.previewSection == section,
           let foreign = reorderState.foreignScope,
           let item = inventory.items.first(where: { $0.scope == foreign }),
           !base.contains(where: { $0.scope == item.scope }) {
            base.append(item)
        }
        guard let order = reorderState.previewOrder,
              reorderState.previewSection == section else { return base }
        return base.sorted {
            let ai = order.firstIndex(of: $0.scope) ?? .max
            let bi = order.firstIndex(of: $1.scope) ?? .max
            if ai != bi { return ai < bi }
            return $0.name < $1.name
        }
    }

    private func sectionScopes(for section: ItemSection) -> [String] {
        items(for: section).map(\.scope)
    }

    private func commitReorder(_ section: ItemSection, movedScope: String, scopes: [String]) {
        reorderState.reset()
        guard scopes != sectionScopes(for: section) else { return }
        visibility.reorderItems(in: section, scopesInOrder: scopes, movedScope: movedScope)
    }

    private func commitForeign(_ section: ItemSection, scope: String, scopes: [String]) {
        reorderState.reset()
        visibility.setSection(scope, to: section)
        visibility.reorderItems(in: section, scopesInOrder: scopes, movedScope: scope)
    }

    private func effectiveSection(of item: ManagedItem) -> ItemSection {
        if item.bundleID == ownBundleID || isLocked(item) { return .alwaysShow }
        return visibility.layout.section(for: item.scope)
    }

    private func isLocked(_ item: ManagedItem) -> Bool {
        guard let identifier = item.systemIdentifier else { return false }
        return SystemMenuBarItem.isLocked(identifier)
    }

    private func isDraggable(_ item: ManagedItem) -> Bool {
        return item.bundleID != ownBundleID && item.isManageable && !isLocked(item)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Menu Bar Layout")
                        .font(.title2.weight(.semibold))
                    Text("Drag items to reorder them or move them between visibility groups.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                bannerArea
                ForEach(ItemSection.allCases) { section in
                    SectionCard(
                        section: section,
                        items: displayItems(for: section),
                        icons: icons,
                        visibility: visibility,
                        reorderState: reorderState,
                        isDraggable: isDraggable,
                        isPinnedTrailing: { trailingRank(for: $0) != nil },
                        scopesFor: sectionScopes,
                        lookupItem: { scope in
                            inventory.items.first { $0.scope == scope }
                        },
                        onReorder: { scope, scopes in commitReorder(section, movedScope: scope, scopes: scopes) },
                        onForeign: { scope, scopes in commitForeign(section, scope: scope, scopes: scopes) }
                    )
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem {
                Button("Show Shelf") { showShelf() }
            }
            ToolbarItem {
                Button {
                    Task { await inventory.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                TextField("Filter items", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
        }
    }

    @ViewBuilder
    private var bannerArea: some View {
        if let message = visibility.actionMessage {
            BannerRow(text: message, symbol: "info.circle")
        }
        if let error = visibility.lastError {
            BannerRow(text: error, symbol: "exclamationmark.triangle")
        }
        switch visibility.blocker {
        case .bartenderRunning:
            BannerRow(
                text: "Shelf is paused while Bartender runs, so the two apps don't fight over the menu bar.",
                symbol: "pause.circle"
            )
        case .accessibilityRequired:
            BannerRow(
                text: "Shelf needs Accessibility permission to see and manage the menu bar.",
                symbol: "lock.shield",
                actionTitle: "Request Access",
                action: { visibility.requestAccessibility() }
            )
        case .ownIconOverflowed:
            BannerRow(
                text: "The Shelf icon is inside macOS overflow, so hiding is paused.",
                symbol: "chevron.right.2",
                actionTitle: "Keep Shelf Visible",
                action: keepShelfVisible
            )
        case .ownIconMissing:
            BannerRow(
                text: "The Shelf icon isn't visible in the menu bar yet.",
                symbol: "questionmark.circle",
                actionTitle: "Keep Shelf Visible",
                action: keepShelfVisible
            )
        case .inventoryUnavailable:
            BannerRow(
                text: "The menu bar couldn't be read yet.",
                symbol: "exclamationmark.circle"
            )
        case .unsupportedOS, .backendUnavailable:
            BannerRow(
                text: "Hiding isn't supported by this macOS version. Layout editing still works.",
                symbol: "exclamationmark.triangle"
            )
        case nil:
            EmptyView()
        }
    }
}

private struct SectionCard: View {
    static let tileWidth: CGFloat = 76
    static let tileHeight: CGFloat = 58
    static let tileSpacing: CGFloat = 10

    let section: ItemSection
    let items: [ManagedItem]
    @ObservedObject var icons: ItemIconCache
    @ObservedObject var visibility: VisibilityManager
    @ObservedObject var reorderState: LayoutReorderState
    let isDraggable: (ManagedItem) -> Bool
    let isPinnedTrailing: (ManagedItem) -> Bool
    let scopesFor: (ItemSection) -> [String]
    let lookupItem: (String) -> ManagedItem?
    let onReorder: (String, [String]) -> Void
    let onForeign: (String, [String]) -> Void

    private var symbol: String {
        switch section {
        case .alwaysShow: return "eye"
        case .onShelf: return "books.vertical"
        case .alwaysHide: return "eye.slash"
        }
    }

    private var explanation: String {
        switch section {
        case .alwaysShow: return "Stays in the menu bar at all times."
        case .onShelf: return "Hidden until you open Shelf or search for it."
        case .alwaysHide: return "Stays hidden even while the shelf is open."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.title)
                        .font(.headline)
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if items.isEmpty {
                Text("Drop items here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(WindowFrameReporter { reorderState.gridFrames[section] = $0 })
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.tileWidth), spacing: Self.tileSpacing)],
                    spacing: Self.tileSpacing
                ) {
                    ForEach(items) { item in
                        tile(for: item)
                    }
                }
                .background(WindowFrameReporter { reorderState.gridFrames[section] = $0 })
                .animation(.snappy(duration: 0.16), value: items.map(\.id))
            }

            if section != .alwaysHide {
                Divider()
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(reorderState.previewSection == section ? Color.accentColor.opacity(0.06) : Color.clear)
        )
        .background(WindowFrameReporter { reorderState.cardFrames[section] = $0 })
    }

    private func insertionIndex(at point: CGPoint, in targetSection: ItemSection) -> Int {
        let order = scopesFor(targetSection)
        guard !order.isEmpty else { return 0 }

        let frames = reorderState.itemFrames[targetSection] ?? [:]
        let positioned = order.enumerated().compactMap { index, scope -> (Int, CGRect)? in
            guard let frame = frames[scope], frame.width > 0, frame.height > 0 else { return nil }
            return (index, frame)
        }
        guard !positioned.isEmpty else { return order.count }

        // Pick the visual row nearest the pointer, then use each icon's center
        // as the insertion boundary. This makes a drop feel attached to the
        // actual icons rather than to invisible card/grid boxes.
        let nearest = positioned.min { lhs, rhs in
            let ldy = abs(point.y - lhs.1.midY)
            let rdy = abs(point.y - rhs.1.midY)
            if ldy != rdy { return ldy < rdy }
            return abs(point.x - lhs.1.midX) < abs(point.x - rhs.1.midX)
        }!
        let rowTolerance = max(Self.tileHeight * 0.65, 30)
        let row = positioned
            .filter { abs($0.1.midY - nearest.1.midY) <= rowTolerance }
            .sorted { $0.1.midX < $1.1.midX }

        if let first = row.first, point.x < first.1.midX { return first.0 }
        for entry in row where point.x < entry.1.midX {
            return entry.0
        }
        if let last = row.last { return min(last.0 + 1, order.count) }
        return order.count
    }

    private func handleDrag(_ item: ManagedItem, point: CGPoint, ended: Bool) {
        if reorderState.draggingScope == nil { reorderState.draggingScope = item.scope }
        guard reorderState.draggingScope == item.scope else { return }
        guard let targetSection = ItemSection.allCases.first(where: {
            reorderState.cardFrames[$0]?.insetBy(dx: -8, dy: -8).contains(point) == true
        }) else {
            if ended { reorderState.reset() } else { reorderState.previewOrder = nil }
            return
        }
        var order = scopesFor(targetSection)
        var index = insertionIndex(at: point, in: targetSection)
        if order.contains(item.scope) {
            order.removeAll { $0 == item.scope }
            if targetSection == .alwaysShow {
                let firstPinned = order.firstIndex { scope in
                    lookupItem(scope).map(isPinnedTrailing) == true
                } ?? order.count
                index = min(index, firstPinned)
            }
            order.insert(item.scope, at: min(index, order.count))
            reorderState.foreignScope = nil
        } else {
            if targetSection == .alwaysShow {
                let firstPinned = order.firstIndex { scope in
                    lookupItem(scope).map(isPinnedTrailing) == true
                } ?? order.count
                index = min(index, firstPinned)
            }
            order.insert(item.scope, at: min(index, order.count))
            reorderState.foreignScope = item.scope
        }
        if ended {
            if reorderState.foreignScope == item.scope {
                onForeign(item.scope, order)
            } else {
                onReorder(item.scope, order)
            }
        } else {
            reorderState.previewSection = targetSection
            reorderState.previewOrder = order
        }
    }

    private func showMoveMenu(for item: ManagedItem, at view: ReorderSurface) {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for destination in ItemSection.allCases {
            let proxy = MenuActionProxy { [visibility] in
                visibility.setSection(item.scope, to: destination)
            }
            let entry = NSMenuItem(
                title: destination.title,
                action: #selector(MenuActionProxy.performMenuAction),
                keyEquivalent: ""
            )
            entry.target = proxy
            entry.representedObject = proxy
            entry.isEnabled = isDraggable(item)
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 4, y: view.bounds.height - 2), in: view)
    }

    @ViewBuilder
    private func tile(for item: ManagedItem) -> some View {
        LayoutTile(item: item, icon: icons.icon(for: item))
            .background(WindowFrameReporter { frame in
                var frames = reorderState.itemFrames[section] ?? [:]
                frames[item.scope] = frame
                reorderState.itemFrames[section] = frames
            })
            .opacity(reorderState.draggingScope == item.scope ? 0.22 : 1)
            .scaleEffect(reorderState.draggingScope == item.scope ? 0.94 : 1)
            .overlay(ReorderSurfaceRepresentable(
                onClick: {},
                onMenu: { view in showMoveMenu(for: item, at: view) },
                onDrag: isDraggable(item) ? { point, ended in handleDrag(item, point: point, ended: ended) } : nil
            ))
    }
}

private struct LayoutTile: View {
    static let width: CGFloat = 76

    let item: ManagedItem
    let icon: NSImage

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 27, height: 27)
            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .frame(width: Self.width, height: SectionCard.tileHeight)
        .contentShape(Rectangle())
        .help(item.name)
        .accessibilityLabel(item.name)
    }
}

private struct BannerRow: View {
    let text: String
    let symbol: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct BehaviorPage: View {
    @ObservedObject var visibility: VisibilityManager
    var keepShelfVisible: () -> Void

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Open Shelf at login",
                    isOn: Binding(
                        get: { visibility.launchAtLogin },
                        set: { visibility.setLaunchAtLogin($0) }
                    )
                )
            }
            Section("Shelf panel") {
                Toggle(
                    "Auto-close Shelf when clicking outside",
                    isOn: Binding(
                        get: { visibility.autoCloseShelf },
                        set: { visibility.autoCloseShelf = $0 }
                    )
                )
                Toggle(
                    "Show On-Shelf items in the menu bar",
                    isOn: $visibility.showShelfInMenuBar
                )
                Text("Always Hide items stay hidden even while On-Shelf items are shown in the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Button("Keep Shelf Visible…", action: keepShelfVisible)
                Text("Moves the Shelf icon next to Control Center using a Command-drag, then resumes hiding.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsPage: View {
    @ObservedObject var visibility: VisibilityManager

    var body: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Label("Accessibility", systemImage: "accessibility")
                    Spacer()
                    Text(visibility.accessibilityTrusted ? "Granted" : "Not granted")
                        .foregroundStyle(visibility.accessibilityTrusted ? .green : .secondary)
                    Button("Request Access") {
                        visibility.requestAccessibility()
                    }
                    .disabled(visibility.accessibilityTrusted)
                }
                Text("Needed to read the menu bar, press items, and move the Shelf icon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Compatibility") {
                HStack {
                    Label("Hiding engine", systemImage: "eye.slash")
                    Spacer()
                    Text(visibility.backendAvailable ? "Available" : "Not available on this macOS")
                        .foregroundStyle(visibility.backendAvailable ? .green : .secondary)
                }
                HStack {
                    Label("Bartender", systemImage: "exclamationmark.shield")
                    Spacer()
                    Text(visibility.hasBartender() ? "Running — Shelf paused" : "Not running")
                        .foregroundStyle(.secondary)
                }
                Text("Shelf uses a private macOS API that can change between releases. No Screen Recording permission is needed — tiles show app icons, not captured menu-bar glyphs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutPage: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: AppIconRenderer.image(size: 128))
                .resizable()
                .frame(width: 96, height: 96)
            Text("Shelf")
                .font(.title)
                .bold()
            Text("Version 0.1 — a companion to Pinny.")
                .foregroundStyle(.secondary)
            Text("On macOS 27, menu-bar items from the same app move together. Items inside macOS overflow can't always be reached directly, and Shelf doesn't promise full parity with dedicated hiders.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
