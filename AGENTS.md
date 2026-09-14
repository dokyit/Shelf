# Shelf agent notes

## Environment

- Toolchain is Command Line Tools only (no Xcode); `xcode-select -p` → `/Library/Developer/CommandLineTools`.
- The repo lives in a synced Documents folder. The fileprovider daemon re-adds
  `com.apple.FinderInfo`/`com.apple.fileprovider.fpfs` xattrs to build outputs, which makes
  codesign fail with "resource fork, Finder information, or similar detritus not allowed".
  Build SwiftPM products outside the synced tree with `--scratch-path /tmp/shelf-spm-build`.
- SwiftPM does not auto-resolve the swift-testing macro plugin from the CLT
  `usr/lib/swift/host/plugins/testing/` subdirectory. `swift test` needs:
  `-Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`

## Verification commands (from repo root)

```sh
swift build --scratch-path /tmp/shelf-spm-build -Xswiftc -warnings-as-errors
swift test --scratch-path /tmp/shelf-spm-build \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift run --scratch-path /tmp/shelf-spm-build ShelfIconTool "$(pwd)/Shelf/Resources"
bash Scripts/build-local.sh   # prints the staged Shelf.app path (fresh mktemp dir)
```

## Architecture

- `ShelfCore` (library): pure state and geometry — `ShelfState` (`ItemSection`
  alwaysShow/onShelf/alwaysHide, `ItemRule`, `ShelfLayout` persisted as versioned JSON
  under `shelf.layout.v1` in UserDefaults, book-count icon mapping),
  `MenuBarItemDiscovery` (AX snapshot parsing into `ManagedItem`s, scope assignment,
  native-overflow detection), `VisibilityController` (injectable assertion factory,
  verify-then-commit with rollback, temporary per-scope reveal),
  `MenuBarIconRenderer` / `AppIconRenderer` (template menu-bar glyph and app icon).
- `ShelfNative` (Objective-C): `SHVisibilityAssertion` dynamically loads
  `MenuBarClientCore` (`dlopen` + `NSClassFromString`/`respondsToSelector:` guards) and
  wraps `MBAssessmentModeAssertion`/`MBAssessmentModeConfiguration`. This is a private
  macOS 27 API — guarded by `+isAvailable`; earlier OS versions report unsupported and
  never hide anything.
- `Shelf` (executable): `ShelfMain` (`@main`, `NSApplication`, `.accessory`),
  `ShelfController` (one retained `NSStatusItem` bookshelf icon, context menu, ShelfBar
  panel toggle), `MenuBarAgentBridge` (AX queries against MenuBarAgent only — never app
  menu contents), `MenuBarInventory` (5 s poll + workspace launch/terminate debounce on a
  serial queue, concealed-item cache during active restrictions), `VisibilityManager`
  (conflict/permission gating, applies rules via `VisibilityController`),
  `IconPlacement` (explicit "Keep Shelf Visible" Command-drag of Shelf's own icon only),
  `ItemIconCache`, `ShelfBarPanel`/`ShelfBarView` (nonactivating `NSPanel` + SwiftUI
  search/tiles, activates real items via AX press), `SettingsView`
  (NavigationSplitView: Menu Bar Layout, Behavior, Permissions, About).
- Sections: Always Show | On Shelf | Always Hide. Assignments are durable per *scope*
  (`app:<bundleID>`, `system:<menuextra id>`, `proc:<pid>` fallback) — not per physical
  item — because macOS 27 restricts third-party items by bundle, so same-app items are
  linked. Shelf's own scope is forced Always Show.
- Hiding uses the native `MenuBarClientCore` assessment-mode assertion: excluded bundles
  lose their menu-bar items, allowed bundles stay. No SIP changes, injection, MDM, or
  security-setting changes; the source app is never terminated or hidden.
- Reveal model: opening Shelf temporarily allows On Shelf scopes; Always Hide stays
  hidden unless the user explicitly searches with "Include Always Hidden" or triggers a
  single-scope temporary reveal. Activating a real item presses its AX status element
  after a fresh-frame match.
- Bartender conflict: while `com.surteesstudios.Bartender` runs, Shelf pauses all
  mutation and shows a paused banner; it never fights another controller.
- `ShelfIconTool` regenerates `Shelf/Resources/Shelf.icns`, `AppIcon.png`, and
  `MenuBarIconContactSheet.png` using the same renderers; it stages the iconset in a
  unique `NSTemporaryDirectory` subdirectory and never deletes pre-existing output.

## Known constraints (macOS 27)

- Private `MenuBarClientCore` API may change; availability is checked at runtime.
- Restrictions group third-party items by bundle, not arbitrary per-item; the UI labels
  linked same-app items.
- The backend suppresses macOS's own native overflow regardless of the allowlist;
  overflowed items are detected (overlapping frames / chevron overlap) and labeled
  rather than counted as visible.
- Tile previews are the owning app's icon — not a captured menu-bar glyph. No Screen
  Recording permission is required for hide/show or layout.
- Actual native menu-bar ordering is not managed; tile order applies to the Shelf popup.
- No fixture status items, no divider registrations, no `--self-test` mode in the
  normal app.
