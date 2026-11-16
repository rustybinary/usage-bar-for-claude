#!/bin/bash
# Builds Usage Bar for Claude, installs it in ~/Applications and starts it.
# Usage:  bash build.sh
set -euo pipefail
cd "$(dirname "$0")"

NAME="UsageBarForClaude"
APP="build/$NAME.app"
DEST="$HOME/Applications"

if ! xcrun -f swiftc >/dev/null 2>&1; then
    echo "The Swift compiler was not found."
    echo "Install Apple's Command Line Tools with:  xcode-select --install"
    echo "Then run this script again."
    exit 1
fi

echo "Compiling…"
rm -rf "$APP"
if [ -f Sources/main.swift ]; then
    echo "Sources/main.swift is left over from the first version; delete it and run this again."
    exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macos13.0" \
    Sources/App.swift Sources/Entry.swift \
    -o "$APP/Contents/MacOS/$NAME"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Signing (ad hoc, for this Mac only)…"
codesign --force --sign - "$APP"

echo "Installing to ${DEST} ..."
# Stop the running copy and wait until it has really gone; starting the new one
# while the old one is still shutting down makes macOS refuse with error -600.
if pgrep -x "$NAME" >/dev/null 2>&1; then
    pkill -x "$NAME" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$NAME" >/dev/null 2>&1 || break
        sleep 0.5
    done
fi
mkdir -p "$DEST"
rm -rf "$DEST/$NAME.app"
cp -R "$APP" "$DEST/"
rm -rf build   # keep a single copy of the app on disk

started=0
for _ in 1 2 3 4 5; do
    if open "$DEST/$NAME.app" 2>/dev/null; then
        started=1
        break
    fi
    sleep 1
done
if [ "$started" = 1 ]; then
    echo "Done. Look for the item in the menu bar."
else
    echo "Installed, but macOS did not start it. Start it with:"
    echo "  open \"$DEST/$NAME.app\""
fi
