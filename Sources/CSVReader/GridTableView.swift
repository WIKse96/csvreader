import AppKit

struct CellPos: Equatable {
    var row: Int
    var col: Int   // table column index; 0 is the row-number column
}

struct GridRange: Equatable {
    var rows: ClosedRange<Int>
    var cols: ClosedRange<Int>
    var cellCount: Int { rows.count * cols.count }
}

protocol GridDelegate: AnyObject {
    func gridSelectionChanged()
    func gridClear(_ range: GridRange)
    func gridFill(source: GridRange, target: GridRange, vertical: Bool, forward: Bool, copyOnly: Bool)
}

/// NSTableView with spreadsheet-style cell selection, keyboard navigation and a fill handle.
final class GridTableView: NSTableView {
    weak var grid: GridDelegate?

    private(set) var anchor = CellPos(row: 0, col: 1)
    private(set) var cursor = CellPos(row: 0, col: 1)
    private var fillPreview: GridRange?

    private var lastRow: Int { numberOfRows - 1 }
    private var lastCol: Int { numberOfColumns - 1 }

    var selection: GridRange {
        GridRange(rows: min(anchor.row, cursor.row)...max(anchor.row, cursor.row),
                  cols: min(anchor.col, cursor.col)...max(anchor.col, cursor.col))
    }

    var hasCells: Bool { numberOfRows > 0 && numberOfColumns > 1 }

    // MARK: Selection

    func select(_ pos: CellPos, extend: Bool = false) {
        guard hasCells else { return }
        let p = CellPos(row: min(max(pos.row, 0), lastRow), col: min(max(pos.col, 1), lastCol))
        cursor = p
        if !extend { anchor = p }
        if selectedRow != p.row { selectRowIndexes([p.row], byExtendingSelection: false) }
        scrollRowToVisible(p.row)
        scrollColumnToVisible(p.col)
        needsDisplay = true
        grid?.gridSelectionChanged()
    }

    func selectRange(from a: CellPos, to b: CellPos) {
        guard hasCells else { return }
        anchor = CellPos(row: min(max(a.row, 0), lastRow), col: min(max(a.col, 1), lastCol))
        select(b, extend: true)
    }

    func clampSelection() {
        guard hasCells else { return }
        anchor = CellPos(row: min(max(anchor.row, 0), lastRow), col: min(max(anchor.col, 1), lastCol))
        select(cursor, extend: true)
    }

    override func selectAll(_ sender: Any?) {
        selectRange(from: CellPos(row: 0, col: 1), to: CellPos(row: lastRow, col: lastCol))
    }

    private func move(_ dr: Int, _ dc: Int, extend: Bool) {
        select(CellPos(row: cursor.row + dr, col: cursor.col + dc), extend: extend)
    }

    // MARK: Geometry

    private func cellRect(_ row: Int, _ col: Int) -> NSRect {
        rect(ofColumn: col).intersection(rect(ofRow: row))
    }

    private func rect(of range: GridRange) -> NSRect {
        cellRect(range.rows.lowerBound, range.cols.lowerBound)
            .union(cellRect(range.rows.upperBound, range.cols.upperBound))
    }

    private var fillHandleRect: NSRect {
        let r = rect(of: selection)
        return NSRect(x: r.maxX - 4, y: r.maxY - 4, width: 8, height: 8)
    }

    /// Cell under a point, clamped to the grid.
    private func clampedCell(at p: NSPoint) -> CellPos {
        var r = row(at: p)
        if r < 0 { r = p.y < 0 ? 0 : lastRow }
        var c = column(at: p)
        if c < 0 { c = p.x < 0 ? 1 : lastCol }
        return CellPos(row: r, col: max(c, 1))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard hasCells, cursor.row <= lastRow, cursor.col <= lastCol, anchor.row <= lastRow, anchor.col <= lastCol else { return }
        let accent = NSColor.controlAccentColor
        let sel = selection
        let r = rect(of: sel)

        if sel.cellCount > 1 {
            let path = NSBezierPath(rect: r)
            path.append(NSBezierPath(rect: cellRect(cursor.row, cursor.col)))
            path.windingRule = .evenOdd
            accent.withAlphaComponent(0.16).setFill()
            path.fill()
        }
        let border = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 2
        accent.setStroke()
        border.stroke()

        let handle = fillHandleRect.insetBy(dx: 1, dy: 1)
        NSColor.textBackgroundColor.setFill()
        handle.insetBy(dx: -1, dy: -1).fill()
        accent.setFill()
        handle.fill()

        if let preview = fillPreview {
            let p = NSBezierPath(rect: rect(of: preview).insetBy(dx: 1, dy: 1))
            p.lineWidth = 1.5
            p.setLineDash([4, 3], count: 2, phase: 0)
            accent.setStroke()
            p.stroke()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard hasCells else { return }
        let p = convert(event.locationInWindow, from: nil)

        if fillHandleRect.insetBy(dx: -2, dy: -2).contains(p) {
            trackFill(event)
            return
        }
        let hitRow = row(at: p), hitCol = column(at: p)
        guard hitRow >= 0 else { return }

        if hitCol == 0 {   // row-number column selects whole rows
            if event.modifierFlags.contains(.shift) {
                selectRange(from: CellPos(row: anchor.row, col: 1), to: CellPos(row: hitRow, col: lastCol))
            } else {
                selectRange(from: CellPos(row: hitRow, col: 1), to: CellPos(row: hitRow, col: lastCol))
            }
            let startRow = anchor.row
            trackDrag { pos in
                self.selectRange(from: CellPos(row: startRow, col: 1), to: CellPos(row: pos.row, col: self.lastCol))
            }
            return
        }

        let pos = CellPos(row: hitRow, col: hitCol)
        if event.clickCount >= 2 {
            select(pos)
            editCursorCell(typing: nil)
            return
        }
        select(pos, extend: event.modifierFlags.contains(.shift))
        trackDrag { self.select($0, extend: true) }
    }

    private func trackDrag(_ update: (CellPos) -> Void) {
        while let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if ev.type == .leftMouseUp { break }
            autoscroll(with: ev)
            let pos = clampedCell(at: convert(ev.locationInWindow, from: nil))
            if pos != cursor { update(pos) }
        }
    }

    private func trackFill(_ event: NSEvent) {
        let source = selection
        var target: (range: GridRange, vertical: Bool, forward: Bool)?
        while let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if ev.type == .leftMouseUp { break }
            autoscroll(with: ev)
            let pos = clampedCell(at: convert(ev.locationInWindow, from: nil))
            let down = pos.row - source.rows.upperBound, up = source.rows.lowerBound - pos.row
            let right = pos.col - source.cols.upperBound, left = source.cols.lowerBound - pos.col
            let best = max(down, up, right, left)
            if best <= 0 {
                target = nil
            } else if best == down {
                target = (GridRange(rows: source.rows.upperBound + 1...pos.row, cols: source.cols), true, true)
            } else if best == up {
                target = (GridRange(rows: pos.row...source.rows.lowerBound - 1, cols: source.cols), true, false)
            } else if best == right {
                target = (GridRange(rows: source.rows, cols: source.cols.upperBound + 1...pos.col), false, true)
            } else {
                target = (GridRange(rows: source.rows, cols: pos.col...source.cols.lowerBound - 1), false, false)
            }
            fillPreview = target.map { t in
                GridRange(rows: min(t.range.rows.lowerBound, source.rows.lowerBound)...max(t.range.rows.upperBound, source.rows.upperBound),
                          cols: min(t.range.cols.lowerBound, source.cols.lowerBound)...max(t.range.cols.upperBound, source.cols.upperBound))
            }
            needsDisplay = true
        }
        let preview = fillPreview
        fillPreview = nil
        needsDisplay = true
        guard let t = target, let full = preview else { return }
        grid?.gridFill(source: source, target: t.range, vertical: t.vertical, forward: t.forward,
                       copyOnly: NSEvent.modifierFlags.contains(.option))
        selectRange(from: CellPos(row: full.rows.lowerBound, col: full.cols.lowerBound),
                    to: CellPos(row: full.rows.upperBound, col: full.cols.upperBound))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if hasCells { addCursorRect(fillHandleRect.insetBy(dx: -2, dy: -2), cursor: .crosshair) }
    }

    // MARK: Keyboard

    func editCursorCell(typing text: String?) {
        guard hasCells else { return }
        if selectedRow != cursor.row { selectRowIndexes([cursor.row], byExtendingSelection: false) }
        editColumn(cursor.col, row: cursor.row, with: nil, select: true)
        if let text, let editor = currentEditor() as? NSTextView {
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
    }

    override func keyDown(with event: NSEvent) {
        guard hasCells else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let jump = flags.contains(.command)
        let page = max(Int(visibleRect.height / (rowHeight + intercellSpacing.height)) - 1, 1)

        switch event.keyCode {
        case 123: jump ? select(CellPos(row: cursor.row, col: 1), extend: shift) : move(0, -1, extend: shift)
        case 124: jump ? select(CellPos(row: cursor.row, col: lastCol), extend: shift) : move(0, 1, extend: shift)
        case 125: jump ? select(CellPos(row: lastRow, col: cursor.col), extend: shift) : move(1, 0, extend: shift)
        case 126: jump ? select(CellPos(row: 0, col: cursor.col), extend: shift) : move(-1, 0, extend: shift)
        case 36, 76: move(shift ? -1 : 1, 0, extend: false)            // Return / Enter
        case 48: move(0, shift ? -1 : 1, extend: false)                // Tab
        case 116: move(-page, 0, extend: shift)                        // Page Up
        case 121: move(page, 0, extend: shift)                         // Page Down
        case 115: select(CellPos(row: jump ? 0 : cursor.row, col: 1), extend: shift)          // Home
        case 119: select(CellPos(row: jump ? lastRow : cursor.row, col: lastCol), extend: shift) // End
        case 120: editCursorCell(typing: nil)                          // F2
        case 51, 117: grid?.gridClear(selection)                       // Backspace / Delete
        case 53: select(cursor)                                        // Esc collapses the selection
        default:
            if flags.isDisjoint(with: [.command, .control]),
               let chars = event.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
                editCursorCell(typing: chars)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// Commit the edit, then move like a spreadsheet (Return → down, Tab → right).
    override func textDidEndEditing(_ notification: Notification) {
        let movement = (notification.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        var info = notification.userInfo ?? [:]
        info["NSTextMovement"] = NSTextMovement.other.rawValue
        super.textDidEndEditing(Notification(name: notification.name, object: notification.object, userInfo: info))
        window?.makeFirstResponder(self)
        switch movement {
        case .return?: move(NSEvent.modifierFlags.contains(.shift) ? -1 : 1, 0, extend: false)
        case .tab?: move(0, 1, extend: false)
        case .backtab?: move(0, -1, extend: false)
        default: grid?.gridSelectionChanged()
        }
    }
}

/// Continues a series the way LibreOffice's fill handle does.
enum Series {
    static func extend(_ source: [String], count: Int, copyOnly: Bool) -> [String] {
        guard !source.isEmpty, count > 0 else { return [] }
        if !copyOnly {
            if let s = numbers(source, count) { return s }
            if let s = dates(source, count) { return s }
            if let s = numberedText(source, count) { return s }
        }
        return (0..<count).map { source[$0 % source.count] }
    }

    private static func decimals(_ s: String) -> Int {
        guard let i = s.lastIndex(where: { $0 == "." || $0 == "," }) else { return 0 }
        return s.distance(from: s.index(after: i), to: s.endIndex)
    }

    private static func numbers(_ src: [String], _ count: Int) -> [String]? {
        let nums = src.compactMap(CSV.number)
        guard nums.count == src.count else { return nil }
        let step = nums.count == 1 ? 1 : (nums.last! - nums.first!) / Double(nums.count - 1)
        let places = src.map(decimals).max() ?? 0
        let comma = src.contains { $0.contains(",") }
        return (1...count).map { j in
            var s = String(format: "%.\(places)f", nums.last! + step * Double(j))
            if comma { s = s.replacingOccurrences(of: ".", with: ",") }
            return s
        }
    }

    private static let dateFormats = ["yyyy-MM-dd", "dd.MM.yyyy", "dd/MM/yyyy", "dd-MM-yyyy"]

    private static func dates(_ src: [String], _ count: Int) -> [String]? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        guard let format = dateFormats.first(where: { fmt in
            f.dateFormat = fmt
            return src.allSatisfy { $0.count == fmt.count && f.date(from: $0) != nil }
        }) else { return nil }
        f.dateFormat = format
        let ds = src.compactMap { f.date(from: $0) }
        let days = ds.count == 1 ? 1 : Int(((ds.last!.timeIntervalSince(ds.first!) / 86400) / Double(ds.count - 1)).rounded())
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = f.timeZone
        return (1...count).map { j in f.string(from: cal.date(byAdding: .day, value: days * j, to: ds.last!)!) }
    }

    /// "Pozycja 7" → "Pozycja 8", "A-009" → "A-010".
    private static func numberedText(_ src: [String], _ count: Int) -> [String]? {
        var prefix: Substring?
        var values: [Int] = []
        var width = 0
        for s in src {
            let digits = s.reversed().prefix(while: \.isASCII).prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count < s.count, digits.count < 18 else { return nil }
            let p = s.dropLast(digits.count)
            if let prefix, prefix != p { return nil }
            prefix = p
            values.append(Int(String(digits.reversed()))!)
            width = digits.count
        }
        guard let prefix else { return nil }
        let step = values.count == 1 ? 1 : (values.last! - values.first!) / (values.count - 1)
        return (1...count).map { j in
            let n = max(values.last! + step * j, 0)
            let digits = String(n)
            return prefix + String(repeating: "0", count: max(width - digits.count, 0)) + digits
        }
    }
}
