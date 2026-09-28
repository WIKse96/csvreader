import Foundation

/// Parser, serializer and heuristics for delimiter-separated text.
enum CSV {
    static let quote = UInt8(ascii: "\"")
    static let lf = UInt8(ascii: "\n")
    static let cr = UInt8(ascii: "\r")

    /// Delimiters offered in the UI, in detection priority order.
    static let standardDelimiters: [(name: String, byte: UInt8)] = [
        ("Tabulator", 9),
        ("Średnik  ;", UInt8(ascii: ";")),
        ("Przecinek  ,", UInt8(ascii: ",")),
        ("Pionowa kreska  |", UInt8(ascii: "|")),
        ("Spacja", UInt8(ascii: " ")),
    ]

    static func name(of delimiter: UInt8) -> String {
        switch delimiter {
        case 9: return "Tab"
        case 32: return "Spacja"
        default: return String(UnicodeScalar(delimiter))
        }
    }

    // MARK: Parsing

    static func parse(_ text: String, delimiter: UInt8) -> [[String]] {
        var text = text
        text.makeContiguousUTF8()
        if let rows = text.utf8.withContiguousStorageIfAvailable({ parse(bytes: $0, delimiter: delimiter) }) {
            return rows
        }
        return Array(text.utf8).withUnsafeBufferPointer { parse(bytes: $0, delimiter: delimiter) }
    }

    /// RFC 4180 parser, lenient with stray quotes. Accepts \n, \r\n and \r line endings.
    static func parse(bytes b: UnsafeBufferPointer<UInt8>, delimiter d: UInt8) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        let n = b.count
        var i = 0

        while i < n {
            if b[i] == quote {
                i += 1
                field.removeAll(keepingCapacity: true)
                while i < n {
                    if b[i] == quote {
                        if i + 1 < n && b[i + 1] == quote {
                            field.append(quote)
                            i += 2
                        } else {
                            i += 1
                            break
                        }
                    } else {
                        field.append(b[i])
                        i += 1
                    }
                }
                // Anything after the closing quote up to the delimiter is kept literally.
                let s = i
                while i < n && b[i] != d && b[i] != lf && b[i] != cr { i += 1 }
                if i > s { field.append(contentsOf: UnsafeBufferPointer(rebasing: b[s..<i])) }
                row.append(String(decoding: field, as: UTF8.self))
            } else {
                let s = i
                while i < n && b[i] != d && b[i] != lf && b[i] != cr { i += 1 }
                row.append(String(decoding: UnsafeBufferPointer(rebasing: b[s..<i]), as: UTF8.self))
            }

            if i >= n {
                rows.append(row)
                row = []
                break
            }
            if b[i] == d {
                i += 1
                if i == n {
                    row.append("")
                    rows.append(row)
                    row = []
                }
                continue
            }
            if b[i] == cr {
                i += 1
                if i < n && b[i] == lf { i += 1 }
            } else {
                i += 1
            }
            rows.append(row)
            row = []
        }
        return rows
    }

    // MARK: Serialization

    /// When `trim` is set, trailing fully-empty rows and columns are dropped (like LibreOffice's "used range").
    static func serialize(_ rows: [[String]], delimiter: UInt8, lineEnding: String, trim: Bool) -> String {
        var rows = rows[...]
        var width = rows.map(\.count).max() ?? 0
        if trim {
            while let last = rows.last, last.allSatisfy(\.isEmpty) { rows = rows.dropLast() }
            width = rows.reduce(0) { acc, row in
                max(acc, (row.lastIndex(where: { !$0.isEmpty }) ?? -1) + 1)
            }
        }
        let d = String(UnicodeScalar(delimiter))
        var out = ""
        out.reserveCapacity(rows.count * max(width, 1) * 8)
        for row in rows {
            for c in 0..<width {
                if c > 0 { out += d }
                guard c < row.count else { continue }
                let f = row[c]
                if f.utf8.contains(where: { $0 == delimiter || $0 == quote || $0 == lf || $0 == cr }) {
                    out += "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                } else {
                    out += f
                }
            }
            out += lineEnding
        }
        return out
    }

    // MARK: Heuristics

    /// Picks the delimiter whose per-line count (outside quotes) is most consistent.
    static func detectDelimiter(_ text: String) -> UInt8 {
        let limit = 128 * 1024
        let bytes = Array(text.utf8.prefix(limit))
        let candidates = standardDelimiters.map(\.byte).filter { $0 != 32 }
        var lines: [[Int]] = []
        var counts = [Int](repeating: 0, count: candidates.count)
        var inQuotes = false
        var lineHasContent = false
        for byte in bytes {
            if byte == quote { inQuotes.toggle(); continue }
            if !inQuotes && (byte == lf || byte == cr) {
                if lineHasContent { lines.append(counts) }
                counts = [Int](repeating: 0, count: candidates.count)
                lineHasContent = false
                if lines.count >= 200 { break }
                continue
            }
            lineHasContent = true
            if !inQuotes, let k = candidates.firstIndex(of: byte) { counts[k] += 1 }
        }
        if lineHasContent && (bytes.count < limit || lines.isEmpty) { lines.append(counts) }
        guard !lines.isEmpty else { return UInt8(ascii: ",") }

        var best: (score: Double, byte: UInt8)? = nil
        for (k, cand) in candidates.enumerated() {
            var freq: [Int: Int] = [:]
            for line in lines { freq[line[k], default: 0] += 1 }
            guard let (mode, hits) = freq.filter({ $0.key > 0 }).max(by: { $0.value < $1.value }) else { continue }
            let consistency = Double(hits) / Double(lines.count)
            if consistency >= 0.9 { return cand }   // first consistent candidate in priority order wins
            let score = consistency * 100 + Double(min(mode, 20))
            if best == nil || score > best!.score { best = (score, cand) }
        }
        return best?.byte ?? UInt8(ascii: ",")
    }

    static func number(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.first!.isNumber || "+-.,".contains(t.first!) else { return nil }
        return Double(t.replacingOccurrences(of: ",", with: "."))
    }

    /// First row looks like a header if it is mostly filled with non-numeric text.
    static func guessHeader(_ rows: [[String]]) -> Bool {
        guard rows.count >= 2, let first = rows.first else { return false }
        let filled = first.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard filled.count * 2 >= first.count, !filled.isEmpty else { return false }
        return !filled.contains { number($0) != nil }
    }

    /// Natural ordering: numbers numerically, text with Finder-like comparison.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        if let x = number(a), let y = number(b) {
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        }
        return a.localizedStandardCompare(b)
    }

    static func columnLetter(_ index: Int) -> String {
        var n = index + 1
        var s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }
}

/// Text encodings supported for reading and writing.
enum TextEncoding: Int, CaseIterable {
    case utf8, utf8BOM, utf16, windows1250, iso88592, windows1252, macRoman

    var name: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 z BOM (Excel)"
        case .utf16: return "UTF-16"
        case .windows1250: return "Windows-1250 (środkowoeuropejskie)"
        case .iso88592: return "ISO-8859-2"
        case .windows1252: return "Windows-1252 (zachodnie)"
        case .macRoman: return "Mac Roman"
        }
    }

    var shortName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 BOM"
        case .utf16: return "UTF-16"
        case .windows1250: return "Windows-1250"
        case .iso88592: return "ISO-8859-2"
        case .windows1252: return "Windows-1252"
        case .macRoman: return "Mac Roman"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16: return .utf16
        case .windows1250: return .windowsCP1250
        case .iso88592:
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatin2.rawValue)))
        case .windows1252: return .windowsCP1252
        case .macRoman: return .macOSRoman
        }
    }

    static func decode(_ data: Data) -> (String, TextEncoding) {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return (String(decoding: data.dropFirst(3), as: UTF8.self), .utf8BOM)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) {
            return (s, .utf16)
        }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        if let s = String(data: data, encoding: .windowsCP1250) { return (s, .windows1250) }
        return (String(data: data, encoding: .isoLatin1) ?? "", .windows1252)
    }

    func encode(_ text: String) -> Data? {
        guard let body = text.data(using: stringEncoding, allowLossyConversion: false) else { return nil }
        return self == .utf8BOM ? Data([0xEF, 0xBB, 0xBF]) + body : body
    }
}
