# CSV Reader

Lekki edytor plików CSV dla **macOS** i **Ubuntu/Linux**. Tabela działa jak w LibreOffice Calc.

- otwieranie plików z automatycznym rozpoznaniem separatora (`,` `;` Tab `|` spacja albo własny) i kodowania (UTF-8, UTF-8 z BOM, UTF-16, Windows-1250, ISO-8859-2, …)
- siatka „bez końca” (1 048 576 wierszy, kolumny dokładają się przy prawej krawędzi). Do pliku zapisuje się tylko użyty zakres.
- edycja pojedynczych komórek, zaznaczanie zakresów myszą i klawiaturą
- **uchwyt wypełniania** (kwadracik w rogu zaznaczenia): przeciągnij w dół, w górę albo w bok. Liczby, daty i teksty z numerem (`Poz 1`) tworzą serię, reszta jest kopiowana.
- filtrowanie jak AutoFiltr: kliknij nagłówek kolumny, zaznacz wartości, posortuj rosnąco lub malejąco
- **edycja nagłówków**: pole z nazwą kolumny w tym samym panelu. Jeśli plik nie ma nagłówka, zostanie utworzony.
- wyszukiwanie we wszystkich kolumnach, pasek zawartości komórki, suma i średnia zaznaczenia w stopce
- przełącznik **Tabela | Tekst**: podgląd i edycja surowego pliku
- wstawianie i usuwanie wierszy oraz kolumn, kopiuj/wklej (także z Excela/Libre), cofanie/ponawianie
- zapis z wyborem separatora i kodowania („Zapisz jako…”)

---

## macOS

Wymagania: macOS 13 lub nowszy oraz narzędzia Xcode Command Line Tools
(jeśli ich nie masz, zainstaluj poleceniem `xcode-select --install`).

### Budowanie

```bash
cd csvreader
./build.sh
```

Gotowa aplikacja trafi do `build/CSV Reader.app` (ok. 450 KB).

### Instalacja

```bash
./build.sh install
```

Polecenie kopiuje aplikację do `/Applications`, więc pojawi się w Launchpadzie i w menu „Otwórz za pomocą”.
Możesz też po prostu przeciągnąć `build/CSV Reader.app` do folderu Aplikacje.

Aplikacja jest podpisana lokalnie (ad-hoc), a nie certyfikatem Apple. Jeśli skopiujesz ją na **inny** Mac,
za pierwszym razem otwórz ją przez prawy przycisk → **Otwórz** (albo zezwól na nią w Ustawieniach → Prywatność i ochrona).

Aby CSV Reader otwierał pliki `.csv` po dwukliku: kliknij plik w Finderze → ⌘I → „Otwórz za pomocą” → CSV Reader → **Zmień wszystkie…**

---

## Ubuntu / Linux

Wymagania: Python 3.8+ i Tk. Na Ubuntu doinstaluj Tk:

```bash
sudo apt install python3 python3-tk
```

### Instalacja dla użytkownika (bez sudo)

```bash
cd csvreader/linux
./install.sh
```

Program pojawi się w menu aplikacji jako **CSV Reader**. Z terminala uruchomisz go poleceniem `csvreader plik.csv`.
Aby był domyślnym programem dla plików CSV, użyj `./install.sh --default`.
Odinstalowanie: `./uninstall.sh`.

### Pakiet .deb (instalacja systemowa)

```bash
cd csvreader/linux
./build-deb.sh
sudo apt install ./csvreader_1.0_all.deb
```

Usunięcie pakietu: `sudo apt remove csvreader`.

### Uruchomienie bez instalacji

```bash
python3 linux/csvreader.py plik.csv
```

---

## Skróty klawiszowe

Na Macu używaj ⌘, na Linuksie Ctrl.

| Akcja | Klawisze |
|---|---|
| Edycja komórki | pisz od razu, **F2** lub dwuklik |
| Zatwierdź i przejdź w dół / w prawo | **Enter** / **Tab** (Shift odwraca kierunek) |
| Anuluj edycję | **Esc** |
| Poruszanie, zaznaczanie zakresu | strzałki, **Shift**+strzałki, ⌘/Ctrl+strzałki (skok do krawędzi) |
| Wyczyść zaznaczone komórki | **Delete** / **Backspace** |
| Kopiuj / wytnij / wklej | ⌘/Ctrl + **C** / **X** / **V** |
| Cofnij / ponów | ⌘/Ctrl+**Z** / ⌘⇧Z (Linux: Ctrl+**Y**) |
| Szukaj | ⌘/Ctrl+**F** |
| Widok tabeli / tekstu | ⌘/Ctrl+**1** / ⌘/Ctrl+**2** |
| Pierwszy wiersz jako nagłówek | ⌘⇧H / Ctrl+Shift+H |
| Filtr bieżącej kolumny | ⌘⇧L / Ctrl+Shift+L |
| Usuń zaznaczone wiersze | ⌘⌫ (Linux: Ctrl+−) |
| Wypełnianie uchwytem bez tworzenia serii | przeciągaj z wciśniętym **⌥** (Linux: **Ctrl**) |

Kliknięcie numeru wiersza zaznacza cały wiersz, a kliknięcie lewego górnego rogu zaznacza wszystko.
Prawy przycisk otwiera menu z operacjami na wierszach i kolumnach.

---

## Struktura projektu

```
Package.swift, Info.plist, build.sh   macOS (Swift + AppKit)
Sources/CSVReader/                    kod aplikacji macOS
Resources/AppIcon.icns                ikona macOS
linux/csvreader.py                    aplikacja dla Linuksa (jeden plik, Python + Tk)
linux/install.sh, uninstall.sh        instalacja dla użytkownika
linux/build-deb.sh                    budowanie pakietu .deb
```
