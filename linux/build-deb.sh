#!/bin/bash
# Buduje pakiet .deb (instalacja systemowa):  ./build-deb.sh
# Instalacja:  sudo apt install ./csvreader_1.0_all.deb
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(python3 -c 'import re;print(re.search(r"VERSION = \"(.+?)\"", open("csvreader.py").read()).group(1))')
PKG="csvreader_${VERSION}_all"
ROOT="build/$PKG"
rm -rf "$ROOT"
mkdir -p "$ROOT/DEBIAN" "$ROOT/usr/bin" "$ROOT/usr/share/csvreader" "$ROOT/usr/share/applications" \
         "$ROOT/usr/share/icons/hicolor/scalable/apps" "$ROOT/usr/share/icons/hicolor/512x512/apps"

install -m 755 csvreader.py "$ROOT/usr/share/csvreader/csvreader.py"
install -m 644 csvreader.png "$ROOT/usr/share/csvreader/csvreader.png"
install -m 644 csvreader.desktop "$ROOT/usr/share/applications/csvreader.desktop"
install -m 644 csvreader.svg "$ROOT/usr/share/icons/hicolor/scalable/apps/csvreader.svg"
install -m 644 csvreader.png "$ROOT/usr/share/icons/hicolor/512x512/apps/csvreader.png"
printf '#!/bin/sh\nexec python3 /usr/share/csvreader/csvreader.py "$@"\n' > "$ROOT/usr/bin/csvreader"
chmod 755 "$ROOT/usr/bin/csvreader"

cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: csvreader
Version: $VERSION
Section: editors
Priority: optional
Architecture: all
Depends: python3 (>= 3.8), python3-tk
Maintainer: CSV Reader <noreply@localhost>
Description: Lekki edytor plików CSV
 Tabela jak w LibreOffice: edycja komórek, uchwyt wypełniania, filtrowanie
 kolumn, sortowanie, różne separatory i kodowania, widok tekstowy.
CONTROL

dpkg-deb --build --root-owner-group "$ROOT" "$PKG.deb"
echo "Gotowe: $(pwd)/$PKG.deb"
echo "Instalacja:  sudo apt install ./$PKG.deb"
