import ShelfCore
import SwiftUI

final class ShelfBarState: ObservableObject {
    @Published var search = ""
    @Published var includeAlwaysHidden = false
    @Published var message: String?
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
        Button {
            activate(item)
        } label: {
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
        }
        .buttonStyle(.plain)
        .help(item.name)
        .accessibilityLabel("Open \(item.name)")
    }

    private func activate(_ item: ManagedItem) {
        onClose()
        Task { @MainActor in
            let result = await visibility.activateItem(item)
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
