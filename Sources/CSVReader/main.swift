import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

private func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    return item
}

private func submenu(_ title: String, _ items: [NSMenuItem]) -> (NSMenuItem, NSMenu) {
    let menu = NSMenu(title: title)
    items.forEach(menu.addItem)
    let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    top.submenu = menu
    return (top, menu)
}

private func buildMainMenu() -> NSMenu {
    let appName = "CSV Reader"
    let main = NSMenu()

    main.addItem(submenu(appName, [
        item("O programie \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
        .separator(),
        item("Ukryj \(appName)", #selector(NSApplication.hide(_:)), "h"),
        item("Ukryj pozostałe", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
        item("Pokaż wszystkie", #selector(NSApplication.unhideAllApplications(_:))),
        .separator(),
        item("Zakończ \(appName)", #selector(NSApplication.terminate(_:)), "q"),
    ]).0)

    let (recentItem, recentMenu) = submenu("Otwórz ostatnie", [
        item("Wyczyść menu", #selector(NSDocumentController.clearRecentDocuments(_:))),
    ])
    // Lets NSDocumentController fill this menu, as it does for nib-based apps.
    let setMenuName = NSSelectorFromString("_setMenuName:")
    if recentMenu.responds(to: setMenuName) { recentMenu.perform(setMenuName, with: "NSRecentDocumentsMenu") }

    main.addItem(submenu("Plik", [
        item("Nowy", #selector(NSDocumentController.newDocument(_:)), "n"),
        item("Otwórz…", #selector(NSDocumentController.openDocument(_:)), "o"),
        recentItem,
        .separator(),
        item("Zamknij", #selector(NSWindow.performClose(_:)), "w"),
        item("Zapisz", #selector(NSDocument.save(_:)), "s"),
        item("Zapisz jako…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
        item("Przywróć zapisaną wersję", #selector(NSDocument.revertToSaved(_:))),
    ]).0)

    main.addItem(submenu("Edycja", [
        item("Cofnij", Selector(("undo:")), "z"),
        item("Ponów", Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item("Wytnij", #selector(NSText.cut(_:)), "x"),
        item("Kopiuj", #selector(NSText.copy(_:)), "c"),
        item("Wklej", #selector(NSText.paste(_:)), "v"),
        item("Zaznacz wszystko", #selector(NSText.selectAll(_:)), "a"),
        .separator(),
        item("Znajdź…", #selector(TableViewController.focusSearch(_:)), "f"),
        .separator(),
        item("Wstaw wiersz powyżej", #selector(TableViewController.insertRowAbove(_:))),
        item("Wstaw wiersz poniżej", #selector(TableViewController.insertRowBelow(_:))),
        item("Dodaj wiersz na końcu", #selector(TableViewController.appendRow(_:)), "\r", [.command, .shift]),
        item("Usuń zaznaczone wiersze", #selector(TableViewController.deleteSelectedRows(_:)), "\u{8}"),
        .separator(),
        item("Wstaw kolumnę po lewej", #selector(TableViewController.insertColumnLeft(_:))),
        item("Wstaw kolumnę po prawej", #selector(TableViewController.insertColumnRight(_:))),
        item("Usuń kolumnę", #selector(TableViewController.deleteCurrentColumn(_:))),
        item("Zmień nazwę kolumny…", #selector(TableViewController.renameCurrentColumn(_:))),
    ]).0)

    main.addItem(submenu("Widok", [
        item("Tabela", #selector(TableViewController.showTableView(_:)), "1"),
        item("Tekst", #selector(TableViewController.showTextView(_:)), "2"),
        .separator(),
        item("Pierwszy wiersz jako nagłówek", #selector(TableViewController.toggleHeaderRow(_:)), "h", [.command, .shift]),
        item("Filtruj bieżącą kolumnę…", #selector(TableViewController.filterCurrentColumn(_:)), "l", [.command, .shift]),
        item("Wyczyść filtry", #selector(TableViewController.clearAllFilters(_:)), "f", [.command, .option]),
        .separator(),
        item("Pełny ekran", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
    ]).0)

    let (windowItem, windowMenu) = submenu("Okno", [
        item("Minimalizuj", #selector(NSWindow.performMiniaturize(_:)), "m"),
        item("Powiększ", #selector(NSWindow.performZoom(_:))),
        .separator(),
        item("Wszystkie na wierzch", #selector(NSApplication.arrangeInFront(_:))),
    ])
    main.addItem(windowItem)
    NSApplication.shared.windowsMenu = windowMenu

    return main
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.mainMenu = buildMainMenu()
app.run()
