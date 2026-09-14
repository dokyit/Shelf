#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="/tmp/shelf-spm-build"
ICON="$REPO_ROOT/Shelf/Resources/Shelf.icns"

if [ ! -f "$ICON" ]; then
    swift run --scratch-path "$SCRATCH" ShelfIconTool "$REPO_ROOT/Shelf/Resources"
fi

swift build --scratch-path "$SCRATCH" -c release --product Shelf

OUT_DIR="$(mktemp -d /tmp/Shelf-app-XXXXXXXX)"
APP="$OUT_DIR/Shelf.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/Shelf" "$APP/Contents/MacOS/Shelf"
cp "$REPO_ROOT/Shelf/Info.plist" "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/Shelf.icns"

xattr -rc "$APP" 2>/dev/null || true
if security find-certificate -c "Shelf Dev" login.keychain >/dev/null 2>&1; then
    codesign --force --sign "Shelf Dev" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "Built: $APP"
