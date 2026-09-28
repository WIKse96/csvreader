#!/bin/bash
# Usuwa CSV Reader zainstalowany przez install.sh.
set -eu
rm -rf "$HOME/.local/share/csvreader"
rm -f "$HOME/.local/bin/csvreader" \
      "$HOME/.local/share/applications/csvreader.desktop" \
      "$HOME/.local/share/icons/hicolor/scalable/apps/csvreader.svg" \
      "$HOME/.local/share/icons/hicolor/512x512/apps/csvreader.png"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
echo "Odinstalowano CSV Reader."
