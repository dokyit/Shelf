# Shelf

A native menu bar manager for macOS 27. Keep the items you use in the menu bar, put the rest on the shelf, and open any shelved item's real menu in one click.

Built in Swift with AppKit and SwiftUI. A companion to [Pinny](https://github.com/dokyit/Pinny).

## Why Shelf

Most menu bar managers hide items by pushing them off-screen with spacer items, or by injecting into other processes. Shelf uses macOS 27's own menu-bar restriction mechanism instead:

- Hidden items are actually removed from the bar by the system, so the bar never flickers or shows duplicates.
- Clicking a shelved item opens that app's real menu, not a mirrored copy.
- No SIP changes, no code injection, no MDM profiles, and nothing gets terminated.

## Features

- **Three sections:** Always Show, Shelved, and Always Hide, assigned per app.
- **Shelf panel:** a quick, keyboard-searchable place to reach everything you've tucked away.
- **Reordering:** change the real menu-bar order of your Always Show items from Settings.
- **Live preview:** optional Screen Recording permission shows a live preview of your bar while you arrange it.
- **Plays nicely:** pauses automatically while Bartender is running.

## Requirements

- macOS 27 or later, Apple silicon (earlier versions report unsupported and hide nothing)
- Accessibility permission (required); Screen Recording (optional, for the live preview)

## Build from source

Requires Swift 6 tooling.

```sh
swift build                 # build the app and core library
swift test                  # run ShelfCoreTests
Scripts/build-local.sh      # build, bundle, and sign Shelf.app locally
```

## Project layout

| Path | What |
|---|---|
| `Shelf/` | The app: menu bar item, panel, settings, onboarding |
| `ShelfCore/` | Item model, section assignment, and ordering logic |
| `ShelfNative/` | Objective-C/C bridge to the system menu-bar APIs |
| `ShelfCoreTests/` | Unit tests for the core logic |
| `Tools/` | Icon generation and SwiftUI preview harness |
