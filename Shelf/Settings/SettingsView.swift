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
    @Published var selectedItemID: String?
    @Published var layoutSearch = ""
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
                selectedItemID: $state.selectedItemID,
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
    @Binding var selectedItemID: String?
    @Binding var search: String

    private var ownBundleID: String {
        Bundle.main.bundleIdentifier ?? "com.pinnyutility.Shelf"
    }

    private var presentItems: [ManagedItem] {
        inventory.items.filter { item in
            item.isPresent
                && (search.isEmpty || item.name.localizedCaseInsensitiveContains(search))
        }
    }

    private func items(for section: ItemSection) -> [ManagedItem] {
        presentItems
            .filter { effectiveSection(of: $0) == section }
            .sorted {
                let lx = $0.frame.width > 0 ? $0.frame.minX : .greatestFiniteMagnitude
                let rx = $1.frame.width > 0 ? $1.frame.minX : .greatestFiniteMagnitude
                if lx != rx { return lx < rx }
                let left = visibility.layout.rules[$0.scope]?.order ?? 0
                let right = visibility.layout.rules[$1.scope]?.order ?? 0
                return left == right ? $0.name < $1.name : left < right
            }
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
        item.bundleID != ownBundleID && item.isManageable && !isLocked(item)
    }

    private func linkedCount(for item: ManagedItem) -> Int {
        inventory.items.filter { $0.scope == item.scope && $0.isPresent }.count
    }

    private var selectedItem: ManagedItem? {
        inventory.items.first { $0.id == selectedItemID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your menu bar, on your terms.")
                        .font(.title2)
                        .bold()
                    Text("Choose what stays visible, what waits on the shelf, and what stays out of sight.")
                        .foregroundStyle(.secondary)
                }
                bannerArea
                ForEach(ItemSection.allCases) { section in
                    SectionCard(
                        section: section,
                        items: items(for: section),
                        icons: icons,
                        visibility: visibility,
                        selectedItemID: $selectedItemID,
                        isDraggable: isDraggable,
                        linkedCount: linkedCount,
                        lookupItem: { scope in
                            inventory.items.first { $0.scope == scope }
                        }
                    )
                }
                if let selectedItem {
                    selectedDetail(selectedItem)
                }
                Text("On macOS 27, menu-bar items from the same app move together — moving one updates its linked items. Items inside macOS overflow can't always be reached directly. Some items (like Now Playing, background helpers, and locally-signed apps) are removed by macOS while Shelf is hiding items.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private func selectedDetail(_ item: ManagedItem) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: icons.icon(for: item))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout).bold()
                HStack(spacing: 6) {
                    if linkedCount(for: item) > 1 {
                        Badge(text: "Linked app items")
                    }
                    if item.isNativeOverflow {
                        Badge(text: "In macOS overflow")
                    }
                    if item.bundleID == ownBundleID {
                        Badge(text: "Shelf")
                    } else if !item.isManageable || isLocked(item) {
                        Badge(text: "Fixed by macOS")
                    } else if !item.isPreservable {
                        Badge(text: "Removed by macOS while hiding")
                    }
                }
            }
            Spacer()
            Picker("Section", selection: Binding(
                get: { effectiveSection(of: item) },
                set: { visibility.setSection(item.scope, to: $0) }
            )) {
                ForEach(ItemSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            .disabled(!isDraggable(item))
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SectionCard: View {
    let section: ItemSection
    let items: [ManagedItem]
    @ObservedObject var icons: ItemIconCache
    @ObservedObject var visibility: VisibilityManager
    @Binding var selectedItemID: String?
    let isDraggable: (ManagedItem) -> Bool
    let linkedCount: (ManagedItem) -> Int
    let lookupItem: (String) -> ManagedItem?

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
                    .foregroundStyle(.secondary)
                Text(section.title)
                    .font(.headline)
                Spacer()
                Text("\(items.count)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("Drop items here")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 72), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(items) { item in
                        tile(for: item)
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .dropDestination(for: String.self) { scopes, _ in
            var handled = false
            for scope in scopes {
                if let item = lookupItem(scope), isDraggable(item) {
                    visibility.setSection(scope, to: section)
                    handled = true
                }
            }
            return handled
        }
    }

    @ViewBuilder
    private func tile(for item: ManagedItem) -> some View {
        let content = VStack(spacing: 5) {
            Image(nsImage: icons.icon(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
            Text(item.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            HStack(spacing: 4) {
                if linkedCount(item) > 1 {
                    Badge(text: "Linked")
                }
                if item.isNativeOverflow {
                    Badge(text: "Overflow")
                }
                if (item.systemIdentifier != nil && !item.isManageable) || !item.isPreservable {
                    Badge(text: "macOS")
                }
            }
        }
        .frame(width: 72, height: 74)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedItemID == item.id ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedItemID = item.id }
        .help(item.name)
        .accessibilityLabel(item.name)

        if isDraggable(item) {
            content
                .draggable(item.scope)
                .contextMenu { moveToMenu(for: item) }
        } else {
            content.contextMenu { moveToMenu(for: item) }
        }
    }

    @ViewBuilder
    private func moveToMenu(for item: ManagedItem) -> some View {
        Menu("Move to") {
            ForEach(ItemSection.allCases) { destination in
                Button(destination.title) {
                    visibility.setSection(item.scope, to: destination)
                }
                .disabled(!isDraggable(item))
            }
        }
    }
}

private struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
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
