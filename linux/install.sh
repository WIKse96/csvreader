#!/bin/bash
# Instaluje CSV Reader dla bieżącego użytkownika (bez sudo).
#   ./install.sh            -> instalacja do ~/.local
#   ./install.sh --default  -> dodatkowo ustawia jako domyślny program dla plików .csv
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v python3 >/dev/null; then
    echo "Brak python3. Zainstaluj:  sudo apt install python3 python3-tk"; exit 1
fi
if ! python3 -c "import tkinter" 2>/dev/null; then
    echo "Brak modułu Tk dla Pythona. Zainstaluj:  sudo apt install python3-tk"; exit 1
fi

APPDIR="$HOME/.local/share/csvreader"
BINDIR="$HOME/.local/bin"
mkdir -p "$APPDIR" "$BINDIR" "$HOME/.local/share/applications" \
         "$HOME/.local/share/icons/hicolor/scalable/apps" "$HOME/.local/share/icons/hicolor/512x512/apps"

install -m 755 csvreader.py "$APPDIR/csvreader.py"
install -m 644 csvreader.png "$APPDIR/csvreader.png"
install -m 644 csvreader.svg "$HOME/.local/share/icons/hicolor/scalable/apps/csvreader.svg"
install -m 644 csvreader.png "$HOME/.local/share/icons/hicolor/512x512/apps/csvreader.png"
printf '#!/bin/sh\nexec python3 "%s/csvreader.py" "$@"\n' "$APPDIR" > "$BINDIR/csvreader"
chmod 755 "$BINDIR/csvreader"
sed "s|^Exec=csvreader|Exec=$BINDIR/csvreader|" csvreader.desktop > "$HOME/.local/share/applications/csvreader.desktop"

update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache -q "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

if [ "${1:-}" = "--default" ]; then
    xdg-mime default csvreader.desktop text/csv text/tab-separated-values
    echo "Ustawiono CSV Reader jako domyślny program dla plików CSV/TSV."
fi

echo "Zainstalowano CSV Reader."
echo "Uruchom z menu aplikacji albo poleceniem:  csvreader [plik.csv]"
case ":$PATH:" in *":$BINDIR:"*) ;; *) echo "Uwaga: dodaj $BINDIR do PATH (albo wyloguj się i zaloguj ponownie).";; esac
