import AppKit

final class TableViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuItemValidation, NSMenuDelegate, GridDelegate, NSTextViewDelegate {

    private let doc: CSVDocument
    private let tableView = GridTableView()
    private let scrollView = NSScrollView()
    private let textScrollView = NSScrollView()
    private let textView = NSTextView(usingTextLayoutManager: false)
    private let modeSwitch = NSSegmentedControl(labels: ["Tabela", "Tekst"], trackingMode: .selectOne, target: nil, action: nil)
    private let delimiterPopup = NSPopUpButton()
    private let headerCheckbox = NSButton(checkboxWithTitle: "Pierwszy wiersz jako nagłówek", target: nil, action: nil)
    private let clearFiltersButton = NSButton(title: "Wyczyść filtry", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let cellRefLabel = NSTextField(labelWithString: "")
    private let inputField = NSTextField()
    private var inputLine: NSStackView!
    private let statusLabel = NSTextField(labelWithString: "")

    /// Allowed values per column index. A missing key means the column is not filtered.
    private var filters: [Int: Set<String>] = [:]
    private var searchText = ""
    /// Indexes into `doc.rows` of the rows currently shown, always ascending.
    private var visible: [Int] = []
    private var pendingVisibleRow: Int?

    private var textMode = false
    /// Text last loaded into the text view, to detect whether the user changed it.
    private var loadedText = ""

    private let cellFont = NSFont.systemFont(ofSize: 12)
    /// Like a spreadsheet, the grid always extends past the data with empty cells;
    /// typing into them grows the document (trailing empties are not saved).
    private static let maxRows = 1_048_576, minColumns = 26, maxColumns = 16_384
    private var extraColumns = 10
    private var displayRowCount: Int { max(Self.maxRows, doc.rows.count + 1000) }
    private var displayColumnCount: Int { min(max(doc.columnCount + extraColumns, Self.minColumns), max(Self.maxColumns, doc.columnCount)) }
    private static let rowNumberID = NSUserInterfaceItemIdentifier("rownum")

    init(document: CSVDocument) {
        doc = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: View

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))

        modeSwitch.selectedSegment = 0
        modeSwitch.target = self
        modeSwitch.action = #selector(modeChanged(_:))
        modeSwitch.setToolTip("Widok tabeli (⌘1)", forSegment: 0)
        modeSwitch.setToolTip("Widok tekstowy (⌘2)", forSegment: 1)

        for (name, byte) in CSV.standardDelimiters {
            delimiterPopup.addItem(withTitle: name)
            delimiterPopup.lastItem?.tag = Int(byte)
        }
        delimiterPopup.menu?.addItem(.separator())
        delimiterPopup.addItem(withTitle: "Inny…")
        delimiterPopup.lastItem?.tag = -1
        delimiterPopup.target = self
        delimiterPopup.action = #selector(delimiterChanged(_:))

        headerCheckbox.target = self
        headerCheckbox.action = #selector(toggleHeaderRow(_:))
        clearFiltersButton.target = self
        clearFiltersButton.action = #selector(clearAllFilters(_:))

        searchField.placeholderString = "Szukaj we wszystkich kolumnach"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [modeSwitch, NSTextField(labelWithString: "Separator:"), delimiterPopup,
                                      headerCheckbox, spacer, clearFiltersButton, searchField])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 10
        bar.setCustomSpacing(18, after: modeSwitch)

        // Input line (like LibreOffice's formula bar): cell reference + full content of the current cell.
        cellRefLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        cellRefLabel.alignment = .center
        cellRefLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
        inputField.font = cellFont
        inputField.placeholderString = "Zawartość komórki"
        inputField.target = self
        inputField.action = #selector(inputCommitted(_:))
        inputField.lineBreakMode = .byTruncatingTail
        inputField.usesSingleLineMode = true
        inputLine = NSStackView(views: [cellRefLabel, inputField])
        inputLine.orientation = .horizontal
        inputLine.spacing = 6

        tableView.dataSource = self
        tableView.delegate = self
        tableView.grid = self
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 18
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder

        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.delegate = self
        // No line wrapping, horizontal scrolling like a code editor.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textScrollView.documentView = textView
        textScrollView.hasVerticalScroller = true
        textScrollView.hasHorizontalScroller = true
        textScrollView.borderType = .noBorder
        textScrollView.isHidden = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let topLine = NSBox(), midLine = NSBox(), bottomLine = NSBox()
        for box in [topLine, midLine, bottomLine] { box.boxType = .separator }

        for v in [bar, topLine, inputLine!, midLine, scrollView, textScrollView, bottomLine, statusLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        var constraints = [
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            topLine.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            inputLine.topAnchor.constraint(equalTo: topLine.bottomAnchor, constant: 5),
            inputLine.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            inputLine.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            midLine.topAnchor.constraint(equalTo: inputLine.bottomAnchor, constant: 5),
            scrollView.topAnchor.constraint(equalTo: midLine.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            textScrollView.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            textScrollView.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            statusLabel.topAnchor.constraint(equalTo: bottomLine.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
        ]
        for v in [topLine, midLine, scrollView, textScrollView, bottomLine] as [NSView] {
            constraints += [v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                            v.trailingAnchor.constraint(equalTo: root.trailingAnchor)]
        }
        NSLayoutConstraint.activate(constraints)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        doc.onChange = { [weak self] in self?.documentChanged($0) }
        doc.onBeforeSave = { [weak self] in self?.commitText() }
        rebuildColumns()
        recomputeVisible()
        syncControls()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(tableView)
        tableView.select(CellPos(row: 0, col: 1))
    }


    // MARK: Columns

    private func columnIndex(_ column: NSTableColumn?) -> Int? {
        column.flatMap { Int($0.identifier.rawValue) }
    }

    private func rebuildColumns(keepWidths: Bool = false) {
        let oldWidths = keepWidths ? tableView.tableColumns.dropFirst().map(\.width) : []
        for col in tableView.tableColumns { tableView.removeTableColumn(col) }

        let digits = String(displayRowCount).count
        let rn = NSTableColumn(identifier: Self.rowNumberID)
        rn.title = ""
        rn.width = CGFloat(digits * 8 + 12)
        rn.minWidth = 24
        rn.isEditable = false
        rn.headerToolTip = "Zaznacz wszystko"
        let rnCell = NSTextFieldCell()
        rnCell.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rnCell.textColor = .secondaryLabelColor
        rnCell.alignment = .right
        rn.dataCell = rnCell
        tableView.addTableColumn(rn)

        let widths = measureColumnWidths()
        for c in 0..<displayColumnCount {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(c)))
            col.width = c < oldWidths.count ? oldWidths[c] : c < widths.count ? widths[c] : 80
            col.minWidth = 30
            col.maxWidth = 5000
            col.isEditable = true
            col.headerToolTip = "Kliknij, aby zmienić nazwę, filtrować lub sortować"
            let cell = NSTextFieldCell()
            cell.font = cellFont
            cell.lineBreakMode = .byTruncatingTail
            cell.truncatesLastVisibleLine = true
            cell.isEditable = true
            col.dataCell = cell
            tableView.addTableColumn(col)
        }
        updateHeaderTitles()
    }

    private func measureColumnWidths() -> [CGFloat] {
        let attrs: [NSAttributedString.Key: Any] = [.font: cellFont]
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        var widths = [CGFloat](repeating: 60, count: doc.columnCount)
        for (i, row) in doc.rows.prefix(150).enumerated() {
            let a = (i == 0 && doc.hasHeader) ? headerAttrs : attrs
            for (c, value) in row.enumerated() where !value.isEmpty {
                let w = (value.prefix(80) as NSString).size(withAttributes: a).width + (i == 0 ? 34 : 16)
                widths[c] = max(widths[c], w)
            }
        }
        return widths.map { min($0, 360) }
    }

    private func headerName(_ c: Int) -> String {
        doc.hasHeader && !doc.rows.isEmpty && c < doc.rows[0].count ? doc.rows[0][c] : ""
    }

    private func updateHeaderTitles() {
        for col in tableView.tableColumns {
            guard let c = columnIndex(col) else { continue }
            var title = headerName(c).replacingOccurrences(of: "\n", with: " ")
            if title.isEmpty { title = CSV.columnLetter(c) }
            col.title = title + (filters[c] != nil ? "  ▼" : "  ▾")
        }
        tableView.headerView?.needsDisplay = true
    }


    // MARK: Filtering

    private func passes(_ row: [String], except: Int?) -> Bool {
        for (c, allowed) in filters where c != except {
            if c < row.count && !allowed.contains(row[c]) { return false }
        }
        if !searchText.isEmpty {
            return row.contains { $0.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return true
    }

    private func recomputeVisible() {
        let rows = doc.rows
        let start = doc.dataStart
        if rows.count <= start {
            visible = []
        } else if filters.isEmpty && searchText.isEmpty {
            visible = Array(start..<displayRowCount)
        } else {
            visible = (start..<rows.count).filter { passes(rows[$0], except: nil) }
        }
        if let extra = pendingVisibleRow, extra >= start, extra < rows.count {
            let pos = insertionIndex(extra)
            if pos == visible.count || visible[pos] != extra { visible.insert(extra, at: pos) }
        }
        tableView.reloadData()
        tableView.clampSelection()
        updateStatus()
    }

    /// Binary search in `visible`.
    private func insertionIndex(_ row: Int) -> Int {
        var lo = 0, hi = visible.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if visible[mid] < row { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func visibleIndex(of row: Int) -> Int? {
        let i = insertionIndex(row)
        return i < visible.count && visible[i] == row ? i : nil
    }

    private func showFilter(for column: NSTableColumn, focusName: Bool = false) {
        guard let c = columnIndex(column), let header = tableView.headerView else { return }
        var counts: [String: Int] = [:]
        let rows = doc.rows
        if rows.count > doc.dataStart && c < doc.columnCount {
            for r in doc.dataStart..<rows.count where passes(rows[r], except: c) {
                counts[rows[r][c], default: 0] += 1
            }
        }
        let values = counts.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return b.isEmpty }
            return CSV.compare(a, b) == .orderedAscending
        }
        let vc = FilterPopoverController(columnName: headerName(c), columnLetter: CSV.columnLetter(c),
                                         values: values, counts: counts, selected: filters[c])
        vc.focusName = focusName
        vc.onRename = { [weak self] name in self?.doc.renameColumn(c, to: name) }
        vc.onApply = { [weak self] allowed in
            guard let self else { return }
            self.filters[c] = allowed
            self.updateHeaderTitles()
            self.recomputeVisible()
            self.syncControls()
        }
        vc.onSort = { [weak self] ascending in
            self?.doc.sort(column: c, ascending: ascending)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        vc.popover = popover
        let rect = header.headerRect(ofColumn: tableView.column(withIdentifier: column.identifier))
        popover.show(relativeTo: rect, of: header, preferredEdge: .maxY)
    }

    // MARK: Document changes

    private func documentChanged(_ change: DocChange) {
        if textMode {
            if case .meta = change {} else { loadText() }
            syncControls()
            return
        }
        switch change {
        case let .cell(row, column):
            if doc.hasHeader && row == 0 { updateHeaderTitles() }
            if let v = visibleIndex(of: row) {
                tableView.reloadData(forRowIndexes: [v], columnIndexes: [column + 1])
            }
            updateInputLine()
        case .cells:
            updateHeaderTitles()
            tableView.reloadData()
            updateInputLine()
        case let .structure(columnsChanged):
            if columnsChanged {
                if tableView.numberOfColumns - 1 != displayColumnCount { rebuildColumns(keepWidths: true) } else { updateHeaderTitles() }
            } else {
                updateHeaderTitles()
            }
            recomputeVisible()
            if let r = pendingVisibleRow, let v = visibleIndex(of: r) {
                tableView.select(CellPos(row: v, col: tableView.cursor.col))
            }
            pendingVisibleRow = nil
            syncControls()
        case .reloaded:
            filters = [:]
            rebuildColumns()
            recomputeVisible()
            syncControls()
        case .meta:
            syncControls()
        }
    }

    private func syncControls() {
        headerCheckbox.state = doc.hasHeader ? .on : .off
        headerCheckbox.isEnabled = !textMode
        searchField.isEnabled = !textMode
        clearFiltersButton.isEnabled = !textMode && (!filters.isEmpty || !searchText.isEmpty)
        modeSwitch.selectedSegment = textMode ? 1 : 0

        let standard = Set(CSV.standardDelimiters.map { Int($0.byte) })
        for item in delimiterPopup.itemArray where item.tag >= 0 && !standard.contains(item.tag) {
            delimiterPopup.removeItem(at: delimiterPopup.index(of: item))
        }
        let tag = Int(doc.delimiter)
        if delimiterPopup.indexOfItem(withTag: tag) < 0 {
            delimiterPopup.insertItem(withTitle: "Inny: \(CSV.name(of: doc.delimiter))",
                                      at: CSV.standardDelimiters.count)
            delimiterPopup.item(at: CSV.standardDelimiters.count)?.tag = tag
        }
        delimiterPopup.selectItem(withTag: tag)
        updateStatus()
    }

    private func updateStatus() {
        var parts: [String]
        if textMode {
            parts = ["Widok tekstowy — zmiany zostaną wczytane do tabeli po przełączeniu"]
        } else {
            let total = max(doc.rows.count - doc.dataStart, 0)
            let filtered = !filters.isEmpty || !searchText.isEmpty
            parts = [filtered ? "Wiersze: \(visible.count) z \(total) (filtr)" : "Wiersze: \(total)"]
            let sel = tableView.selection
            if tableView.hasCells && sel.cellCount > 1 {
                let nums = selectedValues().compactMap(CSV.number)
                var info = "Zaznaczono: \(sel.rows.count) × \(sel.cols.count)"
                if !nums.isEmpty {
                    let sum = nums.reduce(0, +)
                    info += "   Suma: \(format(sum))   Średnia: \(format(sum / Double(nums.count)))"
                }
                parts.append(info)
            }
        }
        parts += ["Kolumny: \(doc.columnCount)", "Separator: \(CSV.name(of: doc.delimiter))",
                  "Kodowanie: \(doc.encoding.shortName)"]
        statusLabel.stringValue = parts.joined(separator: "   ·   ")
    }

    private func format(_ x: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 4
        return f.string(from: NSNumber(value: x)) ?? "\(x)"
    }

    // MARK: Cell access (visible row, table column) ↔ document

    private func absRow(_ v: Int) -> Int? { v >= 0 && v < visible.count ? visible[v] : nil }

    private func value(_ v: Int, _ tableCol: Int) -> String {
        guard let r = absRow(v), tableCol >= 1 else { return "" }
        return cellValue(r, tableCol - 1)
    }

    private func cellValue(_ r: Int, _ c: Int) -> String {
        r < doc.rows.count && c < doc.columnCount ? doc.rows[r][c] : ""
    }

    /// Selection limited to cells that hold data (select-all spans a million empty rows).
    private func usedPart(of sel: GridRange) -> GridRange? {
        let lastRow = min(sel.rows.upperBound, insertionIndex(doc.rows.count) - 1)
        let lastCol = min(sel.cols.upperBound, doc.columnCount)
        guard lastRow >= sel.rows.lowerBound, lastCol >= sel.cols.lowerBound else { return nil }
        return GridRange(rows: sel.rows.lowerBound...lastRow, cols: sel.cols.lowerBound...lastCol)
    }

    private func selectedValues() -> [String] {
        guard let sel = usedPart(of: tableView.selection) else { return [] }
        return sel.rows.flatMap { v in sel.cols.map { value(v, $0) } }
    }

    private func cellReference(_ pos: CellPos) -> String {
        guard let r = absRow(pos.row) else { return "" }
        return CSV.columnLetter(pos.col - 1) + String(r + 1)
    }

    private func updateInputLine() {
        guard tableView.hasCells else {
            cellRefLabel.stringValue = ""
            inputField.stringValue = ""
            return
        }
        let sel = tableView.selection
        cellRefLabel.stringValue = sel.cellCount > 1
            ? cellReference(CellPos(row: sel.rows.lowerBound, col: sel.cols.lowerBound)) + ":" +
              cellReference(CellPos(row: sel.rows.upperBound, col: sel.cols.upperBound))
            : cellReference(tableView.cursor)
        if inputField.currentEditor() == nil {
            inputField.stringValue = value(tableView.cursor.row, tableView.cursor.col)
        }
    }

    @objc private func inputCommitted(_ sender: NSTextField) {
        let pos = tableView.cursor
        guard let r = absRow(pos.row), pos.col >= 1 else { return }
        doc.setCells([CellChange(row: r, column: pos.col - 1, value: sender.stringValue)], actionName: "Edycja komórki")
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: GridDelegate

    func gridSelectionChanged() {
        // Reaching the right edge adds more empty columns, like an endless sheet.
        if tableView.cursor.col >= tableView.numberOfColumns - 2 && displayColumnCount < Self.maxColumns {
            extraColumns += 26
            rebuildColumns(keepWidths: true)
            tableView.needsDisplay = true
        }
        updateInputLine()
        updateStatus()
    }

    func gridClear(_ range: GridRange) {
        guard let range = usedPart(of: range) else { return }
        var changes: [CellChange] = []
        for v in range.rows {
            guard let r = absRow(v) else { continue }
            for c in range.cols where c >= 1 { changes.append(CellChange(row: r, column: c - 1, value: "")) }
        }
        doc.setCells(changes, actionName: "Wyczyść zawartość")
    }

    func gridFill(source: GridRange, target: GridRange, vertical: Bool, forward: Bool, copyOnly: Bool) {
        var changes: [CellChange] = []
        if vertical {
            let targets = forward ? Array(target.rows) : target.rows.reversed()
            for c in source.cols {
                var src = source.rows.map { value($0, c) }
                if !forward { src.reverse() }
                for (v, val) in zip(targets, Series.extend(src, count: targets.count, copyOnly: copyOnly)) {
                    if let r = absRow(v) { changes.append(CellChange(row: r, column: c - 1, value: val)) }
                }
            }
        } else {
            let targets = forward ? Array(target.cols) : target.cols.reversed()
            for v in source.rows {
                guard let r = absRow(v) else { continue }
                var src = source.cols.map { value(v, $0) }
                if !forward { src.reverse() }
                for (c, val) in zip(targets, Series.extend(src, count: targets.count, copyOnly: copyOnly)) {
                    changes.append(CellChange(row: r, column: c - 1, value: val))
                }
            }
        }
        doc.setCells(changes, actionName: "Wypełnij")
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < visible.count else { return nil }
        let r = visible[row]
        guard let c = columnIndex(tableColumn) else { return String(r + 1) }
        return cellValue(r, c)
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard row < visible.count, let c = columnIndex(tableColumn) else { return }
        doc.setCells([CellChange(row: visible[row], column: c, value: object as? String ?? "")], actionName: "Edycja komórki")
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard columnIndex(tableColumn) != nil, let cell = cell as? NSTextFieldCell else { return }
        cell.alignment = CSV.number(cell.stringValue) != nil ? .right : .natural
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        columnIndex(tableColumn) != nil
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard columnIndex(tableColumn) != nil else {
            self.tableView.selectAll(nil)
            return
        }
        showFilter(for: tableColumn)
    }

    // MARK: Toolbar actions

    @objc private func delimiterChanged(_ sender: NSPopUpButton) {
        let tag = sender.selectedTag()
        commitText()
        if tag >= 0 {
            doc.changeDelimiter(UInt8(tag))
            return
        }
        let alert = NSAlert()
        alert.messageText = "Własny separator"
        alert.informativeText = "Wpisz jeden znak, np.  :  ~  #"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Anuluj")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn,
           let ch = field.stringValue.unicodeScalars.first, ch.isASCII,
           !["\"", "\n", "\r"].contains(ch) {
            doc.changeDelimiter(UInt8(ch.value))
        }
        syncControls()
    }

    @objc func toggleHeaderRow(_ sender: Any?) {
        guard !textMode else { return }
        doc.setHasHeader(!doc.hasHeader)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchText = sender.stringValue
        recomputeVisible()
        syncControls()
    }

    @objc func clearAllFilters(_ sender: Any?) {
        filters = [:]
        searchText = ""
        searchField.stringValue = ""
        updateHeaderTitles()
        recomputeVisible()
        syncControls()
    }

    @objc func focusSearch(_ sender: Any?) {
        if textMode {
            textView.performFindPanelAction(NSMenuItem().then { $0.tag = Int(NSFindPanelAction.showFindPanel.rawValue) })
        } else {
            view.window?.makeFirstResponder(searchField)
        }
    }

    // MARK: Table / text mode

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        setTextMode(sender.selectedSegment == 1)
    }

    @objc func showTableView(_ sender: Any?) { setTextMode(false) }
    @objc func showTextView(_ sender: Any?) { setTextMode(true) }

    private func setTextMode(_ on: Bool) {
        guard on != textMode else { return }
        if on {
            view.window?.makeFirstResponder(nil)   // commit any cell being edited
            textMode = true
            loadText()
        } else {
            commitText()
            textMode = false
            filters = [:]
            rebuildColumns()
            recomputeVisible()
        }
        scrollView.isHidden = on
        inputLine.isHidden = on
        textScrollView.isHidden = !on
        view.window?.makeFirstResponder(on ? textView : tableView)
        syncControls()
    }

    private func loadText() {
        loadedText = doc.text
        textView.string = loadedText
        textView.undoManager?.removeAllActions(withTarget: textView.textStorage as Any)
    }

    /// Applies text-view edits to the document (no-op if nothing changed).
    private func commitText() {
        guard textMode, textView.string != loadedText else { return }
        loadedText = textView.string
        doc.replaceText(loadedText)
    }

    func textDidChange(_ notification: Notification) {
        if !doc.isDocumentEdited { doc.updateChangeCount(.changeDone) }
    }

    // MARK: Row / column editing

    private var targetRows: IndexSet {
        let sel = tableView.selection
        return IndexSet(sel.rows.compactMap(absRow))
    }

    private var targetColumn: Int? {
        tableView.hasCells ? tableView.cursor.col - 1 : nil
    }

    @objc func insertRowAbove(_ sender: Any?) {
        let r = absRow(tableView.selection.rows.lowerBound) ?? doc.dataStart
        pendingVisibleRow = r
        doc.insertRow(at: r)
    }

    @objc func insertRowBelow(_ sender: Any?) {
        let r = absRow(tableView.selection.rows.upperBound).map { $0 + 1 } ?? doc.rows.count
        pendingVisibleRow = r
        doc.insertRow(at: r)
    }

    @objc func appendRow(_ sender: Any?) {
        pendingVisibleRow = doc.rows.count
        doc.insertRow(at: doc.rows.count)
    }

    @objc func deleteSelectedRows(_ sender: Any?) {
        doc.deleteRows(targetRows)
    }

    @objc func insertColumnLeft(_ sender: Any?) {
        doc.insertColumn(at: targetColumn ?? 0)
        resetColumns()
    }

    @objc func insertColumnRight(_ sender: Any?) {
        doc.insertColumn(at: (targetColumn ?? doc.columnCount - 1) + 1)
        resetColumns()
    }

    @objc func deleteCurrentColumn(_ sender: Any?) {
        if let c = targetColumn, c < doc.columnCount {
            doc.deleteColumn(c)
            resetColumns()
        }
    }

    /// Column indexes shifted: filters and widths no longer line up.
    private func resetColumns() {
        filters = [:]
        rebuildColumns()
        recomputeVisible()
        syncControls()
    }

    @objc func filterCurrentColumn(_ sender: Any?) {
        if let c = targetColumn, c + 1 < tableView.numberOfColumns {
            showFilter(for: tableView.tableColumns[c + 1])
        }
    }

    @objc func renameCurrentColumn(_ sender: Any?) {
        if let c = targetColumn, c + 1 < tableView.numberOfColumns {
            showFilter(for: tableView.tableColumns[c + 1], focusName: true)
        }
    }

    // MARK: Clipboard

    @objc func copy(_ sender: Any?) {
        let sel = usedPart(of: tableView.selection) ?? GridRange(rows: tableView.cursor.row...tableView.cursor.row,
                                                                 cols: tableView.cursor.col...tableView.cursor.col)
        let text = sel.rows.map { v in
            sel.cols.map { c -> String in
                let f = value(v, c)
                return f.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\"" })
                    ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
            }.joined(separator: "\t")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        gridClear(tableView.selection)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), tableView.hasCells else { return }
        var clip = CSV.parse(text, delimiter: 9)
        if clip.count > 1, clip.last == [""] { clip.removeLast() }
        guard !clip.isEmpty else { return }
        let sel = tableView.selection
        var changes: [CellChange] = []

        if clip.count == 1 && clip[0].count == 1 && sel.cellCount > 1 {
            // A single value pasted into a range fills the whole range (its used part if it is huge).
            let fill = sel.cellCount > 1_000_000 ? (usedPart(of: sel) ?? sel) : sel
            for v in fill.rows { if let r = absRow(v) { for c in fill.cols { changes.append(CellChange(row: r, column: c - 1, value: clip[0][0])) } } }
        } else {
            var extra = 0
            for (i, line) in clip.enumerated() {
                let v = sel.rows.lowerBound + i
                let r: Int
                if let abs = absRow(v) { r = abs } else { r = doc.rows.count + extra; extra += 1 }
                for (j, val) in line.enumerated() {
                    changes.append(CellChange(row: r, column: sel.cols.lowerBound - 1 + j, value: val))
                }
            }
        }
        doc.setCells(changes, actionName: "Wklej")
        let h = clip.count - 1, w = (clip.map(\.count).max() ?? 1) - 1
        if !(clip.count == 1 && clip[0].count == 1) {
            tableView.selectRange(from: CellPos(row: sel.rows.lowerBound, col: sel.cols.lowerBound),
                                  to: CellPos(row: sel.rows.lowerBound + h, col: sel.cols.lowerBound + w))
        }
    }

    private var isEditingText: Bool { view.window?.firstResponder is NSText }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showTableView(_:)):
            menuItem.state = textMode ? .off : .on
            return true
        case #selector(showTextView(_:)):
            menuItem.state = textMode ? .on : .off
            return true
        case #selector(toggleHeaderRow(_:)):
            menuItem.state = doc.hasHeader ? .on : .off
            return !textMode
        case #selector(clearAllFilters(_:)):
            return !textMode && (!filters.isEmpty || !searchText.isEmpty)
        case #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)):
            return !textMode && tableView.hasCells
        case #selector(deleteSelectedRows(_:)):
            // Keep ⌘⌫ working normally while a text field is being edited.
            return !textMode && !isEditingText && !targetRows.isEmpty
        case #selector(deleteCurrentColumn(_:)):
            return !textMode && !isEditingText && doc.columnCount > 1 && (targetColumn ?? .max) < doc.columnCount
        case #selector(insertRowAbove(_:)), #selector(insertRowBelow(_:)), #selector(appendRow(_:)),
             #selector(insertColumnLeft(_:)), #selector(insertColumnRight(_:)),
             #selector(filterCurrentColumn(_:)), #selector(renameCurrentColumn(_:)):
            return !textMode
        default:
            return true
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = tableView.clickedRow, c = tableView.clickedColumn
        if r >= 0 && c >= 1 {
            let sel = tableView.selection
            if !sel.rows.contains(r) || !sel.cols.contains(c) { tableView.select(CellPos(row: r, col: c)) }
        }
        let colName = targetColumn.map { "„\(CSV.columnLetter($0))”" } ?? ""

        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Wytnij", #selector(cut(_:)))
        add("Kopiuj", #selector(copy(_:)))
        add("Wklej", #selector(paste(_:)))
        menu.addItem(.separator())
        add("Wstaw wiersz powyżej", #selector(insertRowAbove(_:)))
        add("Wstaw wiersz poniżej", #selector(insertRowBelow(_:)))
        add(targetRows.count > 1 ? "Usuń wiersze (\(targetRows.count))" : "Usuń wiersz", #selector(deleteSelectedRows(_:)))
        menu.addItem(.separator())
        add("Wstaw kolumnę po lewej", #selector(insertColumnLeft(_:)))
        add("Wstaw kolumnę po prawej", #selector(insertColumnRight(_:)))
        add("Usuń kolumnę \(colName)", #selector(deleteCurrentColumn(_:)))
        add("Zmień nazwę kolumny \(colName)…", #selector(renameCurrentColumn(_:)))
        menu.addItem(.separator())
        add("Filtruj kolumnę \(colName)…", #selector(filterCurrentColumn(_:)))
    }
}

private extension NSMenuItem {
    func then(_ f: (NSMenuItem) -> Void) -> NSMenuItem { f(self); return self }
}
