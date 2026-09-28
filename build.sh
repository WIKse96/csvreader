#!/bin/bash
# Buduje "CSV Reader.app". Użycie:  ./build.sh           -> build/CSV Reader.app
#                                   ./build.sh install   -> dodatkowo kopiuje do /Applications
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/CSVReader"

APP="build/CSV Reader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CSVReader"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
strip -x "$APP/Contents/MacOS/CSVReader" 2>/dev/null || true
codesign --force --sign - "$APP" >/dev/null

echo "Zbudowano: $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "install" ]; then
    rm -rf "/Applications/CSV Reader.app"
    cp -R "$APP" /Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/CSV Reader.app"
    echo "Zainstalowano w /Applications"
fi
