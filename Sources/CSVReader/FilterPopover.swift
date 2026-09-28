import AppKit

/// AutoFilter-style popover: sort buttons, value search and a checkbox list of unique values.
final class FilterPopoverController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let columnName: String
    private let columnLetter: String
    private let nameField = NSTextField()
    var focusName = false
    private let values: [String]
    private let counts: [String: Int]
    private var checked: Set<String>
    private var shown: [Int]

    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let summary = NSTextField(labelWithString: "")

    var onApply: ((Set<String>?) -> Void)?
    var onSort: ((Bool) -> Void)?
    var onRename: ((String) -> Void)?
    weak var popover: NSPopover?

    init(columnName: String, columnLetter: String, values: [String], counts: [String: Int], selected: Set<String>?) {
        self.columnName = columnName
        self.columnLetter = columnLetter
        self.values = values
        self.counts = counts
        self.checked = selected.map { $0.intersection(values) } ?? Set(values)
        self.shown = Array(values.indices)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let nameLabel = NSTextField(labelWithString: "Kolumna \(columnLetter):")
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameField.stringValue = columnName
        nameField.placeholderString = "Nazwa nagłówka"
        nameField.font = .boldSystemFont(ofSize: 13)
        nameField.target = self
        nameField.action = #selector(apply)
        let title = NSStackView(views: [nameLabel, nameField])

        let asc = NSButton(title: "Sortuj rosnąco", target: self, action: #selector(sortAscending))
        asc.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        asc.imagePosition = .imageLeading
        let desc = NSButton(title: "Sortuj malejąco", target: self, action: #selector(sortDescending))
        desc.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        desc.imagePosition = .imageLeading
        let sortRow = NSStackView(views: [asc, desc])
        sortRow.distribution = .fillEqually

        searchField.placeholderString = "Szukaj wartości"
        searchField.target = self
        searchField.action = #selector(searchChanged)

        let cell = NSButtonCell()
        cell.setButtonType(.switch)
        cell.lineBreakMode = .byTruncatingTail
        cell.font = .systemFont(ofSize: 12)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        col.dataCell = cell
        col.isEditable = true
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 20
        table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true

        let all = NSButton(title: "Zaznacz wszystkie", target: self, action: #selector(checkAllValues))
        let none = NSButton(title: "Odznacz wszystkie", target: self, action: #selector(uncheckAllValues))
        let selRow = NSStackView(views: [all, none])
        selRow.distribution = .fillEqually

        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor

        let clear = NSButton(title: "Usuń filtr", target: self, action: #selector(clearFilter))
        let cancel = NSButton(title: "Anuluj", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(apply))
        ok.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [clear, spacer, cancel, ok])

        let stack = NSStackView(views: [title, sortRow, searchField, scroll, selRow, summary, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for v in [title, sortRow, searchField, scroll, selRow, bottom] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 320).isActive = true
        view = stack
        updateSummary()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(focusName ? nameField : searchField)
    }

    private func label(for value: String) -> String {
        let text = value.isEmpty ? "(puste)" : value.replacingOccurrences(of: "\n", with: " ")
        return "\(text)   (\(counts[value] ?? 0))"
    }

    private func updateSummary() {
        summary.stringValue = "Zaznaczono \(checked.count) z \(values.count) wartości"
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        NSNumber(value: checked.contains(values[shown[row]]) ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        (cell as? NSButtonCell)?.title = label(for: values[shown[row]])
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        let value = values[shown[row]]
        if (object as? NSNumber)?.intValue == 1 { checked.insert(value) } else { checked.remove(value) }
        updateSummary()
    }

    // MARK: Actions

    @objc private func searchChanged() {
        let q = searchField.stringValue
        shown = q.isEmpty ? Array(values.indices) : values.indices.filter {
            values[$0].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        table.reloadData()
    }

    @objc private func checkAllValues() {
        for i in shown { checked.insert(values[i]) }
        table.reloadData()
        updateSummary()
    }

    @objc private func uncheckAllValues() {
        for i in shown { checked.remove(values[i]) }
        table.reloadData()
        updateSummary()
    }

    private func commitName() {
        let name = nameField.stringValue.replacingOccurrences(of: "\n", with: " ")
        if name != columnName { onRename?(name) }
    }

    @objc private func apply() {
        commitName()
        var result = checked
        // Like LibreOffice: with a search term, only the matching checked values are kept.
        if !searchField.stringValue.isEmpty {
            result.formIntersection(shown.map { values[$0] })
        }
        onApply?(result.count == values.count ? nil : result)
        popover?.close()
    }


    @objc private func clearFilter() {
        commitName()
        onApply?(nil)
        popover?.close()
    }

    @objc private func cancel() {
        popover?.close()
    }

    @objc private func sortAscending() {
        popover?.close()
        onSort?(true)
    }

    @objc private func sortDescending() {
        popover?.close()
        onSort?(false)
    }
}
