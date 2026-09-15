import AppKit
import ShelfCore
import SwiftUI

private final class ClickSurface: NSView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onDrag: ((CGFloat, Bool) -> Void)?
    private var downX: CGFloat = 0
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downX = event.locationInWindow.x
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let onDrag else { return }
        let dx = event.locationInWindow.x - downX
        if !dragging, abs(dx) > 5 { dragging = true }
        if dragging { onDrag(dx, false) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            onDrag?(event.locationInWindow.x - downX, true)
            dragging = false
        } else {
            onLeft?()
        }
    }

    override func rightMouseDown(with event: NSEvent) { onRight?() }
}

private struct ClickSurfaceRepresentable: NSViewRepresentable {
    var onLeft: () -> Void
    var onRight: () -> Void
    var onDrag: ((CGFloat, Bool) -> Void)? = nil

    func makeNSView(context: Context) -> ClickSurface {
        let view = ClickSurface()
        view.onLeft = onLeft
        view.onRight = onRight
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ nsView: ClickSurface, context: Context) {
        nsView.onLeft = onLeft
        nsView.onRight = onRight
        nsView.onDrag = onDrag
    }
}

final class ShelfBarState: ObservableObject {
    @Published var search = ""
    @Published var includeAlwaysHidden = false
    @Published var message: String?
    @Published var dragOrder: [String] = []
    @Published var dragStartIndex: Int?
}

struct ShelfBarView: View {
    enum Mode {
        case shelf
        case search
    }

    @ObservedObject var inventory: MenuBarInventory
    @ObservedObject var visibility: VisibilityManager
    @ObservedObject var icons: ItemIconCache
    let mode: Mode
    var onClose: () -> Void
    var openSettings: () -> Void = {}

    @StateObject private var state = ShelfBarState()
    @FocusState private var searchFocused: Bool

    private var candidates: [ManagedItem] {
        let ownPID = getpid()
        return inventory.items.filter { item in
            guard item.isPresent, item.ownerPID != ownPID else { return false }
            let section = visibility.layout.section(for: item.scope)
            switch mode {
            case .shelf:
                return section == .onShelf
            case .search:
                return section != .alwaysHide || state.includeAlwaysHidden
            }
        }
    }

    private var shownItems: [ManagedItem] {
        guard !state.search.isEmpty else { return candidates }
        return candidates.filter {
            $0.name.localizedCaseInsensitiveContains(state.search)
        }
    }

    private var alwaysHiddenItems: [ManagedItem] {
        inventory.items
            .filter {
                $0.isPresent && $0.ownerPID != getpid()
                    && visibility.layout.section(for: $0.scope) == .alwaysHide
            }
            .sorted {
                let lo = visibility.layout.rules[$0.scope]?.order ?? .max
                let ro = visibility.layout.rules[$1.scope]?.order ?? .max
                if lo != ro { return lo < ro }
                if $0.frame.width > 0, $1.frame.width > 0 { return $0.frame.minX < $1.frame.minX }
                return $0.name < $1.name
            }
    }

    private var hiddenScopeOrder: [String] {
        state.dragOrder.isEmpty ? alwaysHiddenItems.map(\.scope) : state.dragOrder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode == .search {
                TextField("Search menu bar items", text: $state.search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
            }
            if shownItems.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 6)], spacing: 6) {
                        ForEach(shownItems) { item in
                            tile(for: item)
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 380)
            }
            if mode == .shelf && !alwaysHiddenItems.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("Always Hide", systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(hiddenScopeOrder, id: \.self) { scope in
                            if let item = alwaysHiddenItems.first(where: { $0.scope == scope }) {
                                hiddenTile(for: item)
                            }
                        }
                    }
                    .animation(.default, value: hiddenScopeOrder)
                    Text("Drag to rearrange their menu bar order.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if mode == .search {
                Toggle("Include Always Hidden", isOn: $state.includeAlwaysHidden)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
            if let message = state.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(minWidth: 240)
        .onAppear {
            if mode == .search { searchFocused = true }
        }
    }

    private var emptyMessage: String {
        switch mode {
        case .shelf:
            return state.search.isEmpty
                ? "Nothing on the shelf. Drag items to On Shelf in Settings."
                : "No shelf items match your search."
        case .search:
            return "No menu bar items match your search."
        }
    }

    private func tile(for item: ManagedItem) -> some View {
        tileBody(for: item)
            .overlay(ClickSurfaceRepresentable(
                onLeft: { activate(item, button: .left) },
                onRight: { activate(item, button: .right) }
            ))
    }

    private func hiddenTile(for item: ManagedItem) -> some View {
        tileBody(for: item)
            .opacity(0.75)
            .overlay(ClickSurfaceRepresentable(
                onLeft: { activate(item, button: .left) },
                onRight: { activate(item, button: .right) },
                onDrag: { dx, ended in handleHiddenDrag(item, dx: dx, ended: ended) }
            ))
            .help("\(item.name) — drag to rearrange, click to open")
    }

    private func tileBody(for item: ManagedItem) -> some View {
        VStack(spacing: 5) {
            Image(nsImage: icons.icon(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
            Text(item.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .frame(width: 68, height: 60)
        .contentShape(Rectangle())
        .help("\(item.name) — left-click to open, right-click for its menu")
        .accessibilityLabel("Open \(item.name)")
    }

    private func handleHiddenDrag(_ item: ManagedItem, dx: CGFloat, ended: Bool) {
        if state.dragStartIndex == nil {
            state.dragOrder = alwaysHiddenItems.map(\.scope)
            state.dragStartIndex = state.dragOrder.firstIndex(of: item.scope)
        }
        guard let start = state.dragStartIndex else { return }
        let delta = Int((dx / 74).rounded())
        let to = max(0, min(state.dragOrder.count - 1, start + delta))
        if let from = state.dragOrder.firstIndex(of: item.scope), to != from {
            state.dragOrder.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        if ended {
            let finalOrder = state.dragOrder
            state.dragOrder = []
            state.dragStartIndex = nil
            if finalOrder != alwaysHiddenItems.map(\.scope) {
                visibility.reorderAlwaysHidden(finalOrder)
            }
        }
    }

    private func activate(_ item: ManagedItem, button: MenuBarClickButton) {
        onClose()
        Task { @MainActor in
            let result = await visibility.activateItem(item, button: button)
            switch result {
            case .success:
                break
            case .needsOverflowReveal:
                _ = await visibility.revealNativeOverflow()
                visibility.actionMessage = "\(item.name) is inside macOS overflow — the overflow area was opened for you."
                openSettings()
            case .failure(let error):
                visibility.actionMessage = error
                openSettings()
            }
        }
    }
}
