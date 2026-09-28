import AppKit

struct CellChange {
    var row: Int
    var column: Int
    var value: String
}

enum DocChange {
    case cell(row: Int, column: Int)
    case cells
    case structure(columnsChanged: Bool)
    case reloaded
    case meta
}

@objc(CSVDocument)
final class CSVDocument: NSDocument {
    private(set) var rows: [[String]] = []
    private(set) var columnCount = 0
    private(set) var hasHeader = false
    var delimiter = UInt8(ascii: ",")
    var encoding = TextEncoding.utf8
    var lineEnding = "\n"
    var onChange: ((DocChange) -> Void)?
    /// Called before writing so the text view can commit pending edits.
    var onBeforeSave: (() -> Void)?

    /// Text as read from disk; kept until the first edit so that re-interpreting with
    /// another delimiter is exact.
    private var rawText: String?

    private weak var saveDelimiterPopup: NSPopUpButton?
    private weak var saveEncodingPopup: NSPopUpButton?

    var dataStart: Int { hasHeader ? 1 : 0 }

    override init() {
        super.init()
        setRows([[""]])
    }

    override class var autosavesInPlace: Bool { false }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    // MARK: Reading & writing

    override func read(from data: Data, ofType typeName: String) throws {
        let (text, enc) = TextEncoding.decode(data)
        encoding = enc
        lineEnding = text.utf8.prefix(1 << 16).contains(CSV.cr) ? "\r\n" : "\n"
        delimiter = CSV.detectDelimiter(text)
        rawText = text
        setRows(CSV.parse(text, delimiter: delimiter))
        hasHeader = CSV.guessHeader(rows)
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        onChange?(.reloaded)
    }

    override func data(ofType typeName: String) throws -> Data {
        onBeforeSave?()
        let text = CSV.serialize(rows, delimiter: delimiter, lineEnding: lineEnding, trim: true)
        guard let data = encoding.encode(text) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInapplicableStringEncodingError, userInfo: [
                NSLocalizedDescriptionKey: "Nie można zapisać pliku w kodowaniu \(encoding.shortName).",
                NSLocalizedRecoverySuggestionErrorKey: "Plik zawiera znaki spoza tego kodowania. Użyj „Zapisz jako…” i wybierz UTF-8.",
            ])
        }
        return data
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowsOtherFileTypes = true
        savePanel.isExtensionHidden = false

        let delim = NSPopUpButton()
        for (name, byte) in CSV.standardDelimiters {
            delim.addItem(withTitle: name)
            delim.lastItem?.tag = Int(byte)
        }
        if delim.indexOfItem(withTag: Int(delimiter)) < 0 {
            delim.addItem(withTitle: "Inny: \(CSV.name(of: delimiter))")
            delim.lastItem?.tag = Int(delimiter)
        }
        delim.selectItem(withTag: Int(delimiter))

        let enc = NSPopUpButton()
        for e in TextEncoding.allCases {
            enc.addItem(withTitle: e.name)
            enc.lastItem?.tag = e.rawValue
        }
        enc.selectItem(withTag: encoding.rawValue)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Separator pól:"), delim],
            [NSTextField(labelWithString: "Kodowanie znaków:"), enc],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 80))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        savePanel.accessoryView = container
        saveDelimiterPopup = delim
        saveEncodingPopup = enc
        return true
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        if saveOperation == .saveAsOperation || saveOperation == .saveToOperation,
           let delim = saveDelimiterPopup, let enc = saveEncodingPopup {
            let newDelimiter = UInt8(delim.selectedTag())
            if newDelimiter != delimiter { rawText = nil }
            delimiter = newDelimiter
            encoding = TextEncoding(rawValue: enc.selectedTag()) ?? .utf8
            onChange?(.meta)
        }
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
    }

    // MARK: Interpretation

    func changeDelimiter(_ newDelimiter: UInt8) {
        guard newDelimiter != delimiter else { return }
        let source = rawText ?? CSV.serialize(rows, delimiter: delimiter, lineEnding: "\n", trim: false)
        delimiter = newDelimiter
        setRows(CSV.parse(source, delimiter: newDelimiter))
        if rawText != nil { hasHeader = CSV.guessHeader(rows) }
        undoManager?.removeAllActions()
        onChange?(.reloaded)
    }

    func setHasHeader(_ value: Bool) {
        guard value != hasHeader else { return }
        hasHeader = value
        onChange?(.structure(columnsChanged: false))
    }

    private func setRows(_ parsed: [[String]]) {
        let width = max(parsed.lazy.map(\.count).max() ?? 0, 1)
        rows = parsed.isEmpty ? [[String](repeating: "", count: width)] : parsed.map {
            $0.count < width ? $0 + [String](repeating: "", count: width - $0.count) : $0
        }
        columnCount = width
    }

    // MARK: Editing (undoable)

    func setCell(row r: Int, column c: Int, to value: String) {
        guard r < rows.count, c < columnCount, rows[r][c] != value else { return }
        let old = rows[r][c]
        undoManager?.registerUndo(withTarget: self) { $0.setCell(row: r, column: c, to: old) }
        undoManager?.setActionName("Edycja komórki")
        rows[r][c] = value
        rawText = nil
        onChange?(.cell(row: r, column: c))
    }

    /// Batch edit as a single undo step. Grows the table when a change lies outside it.
    func setCells(_ changes: [CellChange], actionName: String) {
        // Clearing a cell outside the data is a no-op, not a reason to grow.
        let changes = changes.filter { !$0.value.isEmpty || ($0.row < rows.count && $0.column < columnCount) }
        guard let maxRow = changes.map(\.row).max(), let maxCol = changes.map(\.column).max() else { return }
        if maxRow >= rows.count || maxCol >= columnCount {
            let width = max(columnCount, maxCol + 1)
            var r = rows.map { $0.count < width ? $0 + [String](repeating: "", count: width - $0.count) : $0 }
            while r.count <= maxRow { r.append([String](repeating: "", count: width)) }
            for ch in changes { r[ch.row][ch.column] = ch.value }
            replaceAll(r, columnCount: width, actionName: actionName)
            return
        }
        var old: [CellChange] = []
        for ch in changes where rows[ch.row][ch.column] != ch.value {
            old.append(CellChange(row: ch.row, column: ch.column, value: rows[ch.row][ch.column]))
            rows[ch.row][ch.column] = ch.value
        }
        guard !old.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { $0.setCells(old, actionName: actionName) }
        undoManager?.setActionName(actionName)
        rawText = nil
        onChange?(.cells)
    }

    /// Text as shown in the text view (the same as what gets saved, but always "\n" line endings).
    var text: String { CSV.serialize(rows, delimiter: delimiter, lineEnding: "\n", trim: true) }

    /// Replaces the whole content with edited text, as one undo step.
    func replaceText(_ newText: String) {
        let parsed = CSV.parse(newText, delimiter: delimiter)
        let width = max(parsed.lazy.map(\.count).max() ?? 0, 1)
        let padded = parsed.isEmpty ? [[String](repeating: "", count: width)] : parsed.map {
            $0.count < width ? $0 + [String](repeating: "", count: width - $0.count) : $0
        }
        replaceAll(padded, columnCount: width, header: hasHeader && padded.count > 1, actionName: "Edycja tekstu")
        rawText = newText
    }

    /// Renames a column; creates a header row first if the file has none.
    func renameColumn(_ c: Int, to name: String) {
        if hasHeader {
            if c >= columnCount || rows[0][c] != name { setCells([CellChange(row: 0, column: c, value: name)], actionName: "Zmień nazwę kolumny") }
            return
        }
        guard !name.isEmpty else { return }
        let width = max(columnCount, c + 1)
        var header = (0..<width).map(CSV.columnLetter)
        header[c] = name
        let body = rows.map { $0.count < width ? $0 + [String](repeating: "", count: width - $0.count) : $0 }
        replaceAll([header] + body, columnCount: width, header: true, actionName: "Zmień nazwę kolumny")
    }

    private func replaceAll(_ newRows: [[String]], columnCount newCount: Int, header: Bool? = nil, actionName: String) {
        let oldRows = rows, oldCount = columnCount, oldHeader = hasHeader
        undoManager?.registerUndo(withTarget: self) {
            $0.replaceAll(oldRows, columnCount: oldCount, header: oldHeader, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        if let header { hasHeader = header }
        rows = newRows
        rawText = nil
        let changed = newCount != columnCount
        columnCount = newCount
        onChange?(.structure(columnsChanged: changed))
    }

    func insertRow(at index: Int) {
        var r = rows
        r.insert([String](repeating: "", count: columnCount), at: min(max(index, 0), r.count))
        replaceAll(r, columnCount: columnCount, actionName: "Wstaw wiersz")
    }

    func deleteRows(_ indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        var r = rows.enumerated().filter { !indexes.contains($0.offset) }.map(\.element)
        if r.isEmpty { r = [[String](repeating: "", count: columnCount)] }
        replaceAll(r, columnCount: columnCount, actionName: indexes.count == 1 ? "Usuń wiersz" : "Usuń wiersze")
    }

    func insertColumn(at index: Int) {
        let c = min(max(index, 0), columnCount)
        let r = rows.map { row -> [String] in
            var row = row
            row.insert("", at: c)
            return row
        }
        replaceAll(r, columnCount: columnCount + 1, actionName: "Wstaw kolumnę")
    }

    func deleteColumn(_ c: Int) {
        guard columnCount > 1, c < columnCount else { return }
        let r = rows.map { row -> [String] in
            var row = row
            row.remove(at: c)
            return row
        }
        replaceAll(r, columnCount: columnCount - 1, actionName: "Usuń kolumnę")
    }

    /// Sorts data rows (the header row stays in place). Empty cells always go last.
    func sort(column c: Int, ascending: Bool) {
        let start = dataStart
        guard rows.count - start > 1, c < columnCount else { return }
        let body = Array(rows[start...])
        let keys = body.map { $0[c] }
        let order = body.indices.sorted { a, b in
            let ka = keys[a], kb = keys[b]
            if ka.isEmpty != kb.isEmpty { return kb.isEmpty }
            let r = CSV.compare(ka, kb)
            if r == .orderedSame { return a < b }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
        var r = Array(rows[..<start])
        r.append(contentsOf: order.map { body[$0] })
        replaceAll(r, columnCount: columnCount, actionName: "Sortowanie")
    }
}

final class DocumentWindowController: NSWindowController {
    init(document: CSVDocument) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 320)
        super.init(window: window)
        window.contentViewController = TableViewController(document: document)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        shouldCascadeWindows = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
