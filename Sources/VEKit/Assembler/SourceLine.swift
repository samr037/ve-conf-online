// Line structure of VLL sources.

struct SourceLine: Equatable {
    var label: String
    var opcode: String
    /// Raw parameter texts, trimmed of TAB/SPACE; evaluated later by the directive or macro binding.
    var params: [[UInt8]]
    var error: String?

    static let empty = SourceLine(label: "", opcode: "", params: [])

    init(label: String, opcode: String, params: [[UInt8]], error: String? = nil) {
        self.label = label
        self.opcode = opcode
        self.params = params
        self.error = error
    }

    init(_ raw: [UInt8]) {
        let line = Self.stripComment(raw)
        var i = 0
        var label = ""
        func isBlank(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }
        if let first = line.first, !isBlank(first) {
            while i < line.count && !isBlank(line[i]) { i += 1 }
            label = String(decoding: line[0..<i], as: Latin1.self)
        }
        while i < line.count && isBlank(line[i]) { i += 1 }
        let opStart = i
        while i < line.count && !isBlank(line[i]) { i += 1 }
        let opcode = String(decoding: line[opStart..<i], as: Latin1.self)
        let (params, error) = Self.splitParams(Array(line[i...]))
        self.init(label: label, opcode: opcode, params: params, error: error)
    }

    /// Cut at the first `;` outside `"…"`, `'…'` and nested `(…)` (inside parentheses only parentheses count).
    static func stripComment(_ s: [UInt8]) -> [UInt8] {
        var quote: UInt8? = nil
        var depth = 0
        for (k, c) in s.enumerated() {
            if depth > 0 {
                if c == 0x28 { depth += 1 } else if c == 0x29 { depth -= 1 }
                continue
            }
            if let q = quote {
                if c == q { quote = nil }
                continue
            }
            switch c {
            case 0x22, 0x27: quote = c
            case 0x28: depth = 1
            case 0x3B: return Array(s[..<k])
            default: break
            }
        }
        return s
    }

    /// Split on `,` honouring the same pairs. Leading separators are skipped; a trailing empty token is an error.
    static func splitParams(_ s: [UInt8]) -> ([[UInt8]], String?) {
        var out: [[UInt8]] = []
        var current: [UInt8] = []
        var quote: UInt8? = nil
        var depth = 0
        var sawSeparator = false
        func flush() {
            let t = trim(current)
            if !t.isEmpty { out.append(t) }
            current = []
        }
        for c in s {
            if depth > 0 {
                if c == 0x28 { depth += 1 } else if c == 0x29 { depth -= 1 }
                current.append(c); continue
            }
            if let q = quote {
                if c == q { quote = nil }
                current.append(c); continue
            }
            switch c {
            case 0x22, 0x27: quote = c; current.append(c)
            case 0x28: depth = 1; current.append(c)
            case 0x2C: flush(); sawSeparator = true
            default: current.append(c)
            }
        }
        let last = trim(current)
        if !last.isEmpty {
            out.append(last)
        } else if sawSeparator {
            return (out, "Improper parameter list")   // trailing "a,"
        }
        if out.count > 10 { return (out, "Maximum nr of parameters for this assembler is 10!") }
        return (out, nil)
    }

    static func trim(_ s: [UInt8]) -> [UInt8] {
        var a = 0, b = s.count
        while a < b && (s[a] == 0x20 || s[a] == 0x09) { a += 1 }
        while b > a && (s[b - 1] == 0x20 || s[b - 1] == 0x09) { b -= 1 }
        return Array(s[a..<b])
    }
}

/// Line splitting of Delphi `TStrings.Text`, used for sources and wizard texts: CR, LF and CRLF each end a line
/// (so do LF CR: that is two breaks), a NUL ends the text, and a final line break adds no empty line.
enum TextLines {
    static func split(_ text: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var i = 0
        while i < text.count, text[i] != 0 {
            let start = i
            while i < text.count, text[i] != 0, text[i] != 0x0A, text[i] != 0x0D { i += 1 }
            lines.append(Array(text[start..<i]))
            if i < text.count, text[i] == 0x0D { i += 1 }
            if i < text.count, text[i] == 0x0A { i += 1 }
        }
        return lines
    }
}

/// A list of lines with a header at index 0 (never assembled).
final class LineList {
    let header: String
    private let raw: [[UInt8]]
    private var parsed: [SourceLine?]

    init(header: String, text: [UInt8]) {
        self.header = header
        let lines = [[]] + TextLines.split(text)
        raw = lines
        parsed = Array(repeating: nil, count: lines.count)
    }

    init(header: String, lines: [SourceLine]) {
        self.header = header
        raw = Array(repeating: [], count: lines.count + 1)
        parsed = [SourceLine.empty] + lines.map { Optional($0) }
    }

    var count: Int { parsed.count }

    func line(_ i: Int) -> SourceLine {
        if let p = parsed[i] { return p }
        let p = SourceLine(raw[i])
        parsed[i] = p
        return p
    }
}
