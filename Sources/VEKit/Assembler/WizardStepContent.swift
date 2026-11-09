import Foundation

// Turns a wizard step (its text section + the .AUE format list) into displayable content:
// Delphi Format (`%0:s`, `%1:d`, `%s`), inline codes (`\FS:1\`, `\IS\…\IL:url\`, `\TI\`…) and entry fields (`|n`).
// docs/re/03-assembler.md §12.

public struct WizardRun: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var emphasis = false
    public var link: String? = nil
}

/// One displayed line: a sequence of styled runs. An empty line is a blank spacer.
public struct WizardLine: Equatable, Sendable {
    public var runs: [WizardRun]
    public var isBlank: Bool { runs.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
}

public enum WizardEntryPiece: Equatable, Sendable {
    case text([WizardRun])
    /// Input field bound to the `index`-th label of the step.
    case field(index: Int, items: [String]?)
}

public struct WizardStepContent: Equatable, Sendable {
    public var title: String
    public var description: [WizardLine]
    /// Radio / check button texts (one entry per button, each possibly multi-line).
    public var options: [[WizardLine]]
    /// Entry steps: the single option line with its input fields, split into lines.
    public var entry: [[WizardEntryPiece]]

    public init(step: AssistantStepDefinition, text: WizardText?, format: [Value]) {
        var section: WizardStepText?
        if step.stepName.caseInsensitiveCompare("Generic") == .orderedSame, let last = format.last {
            // Generic steps carry their whole text as the last format argument, inserted as is
            // (`Format('%<last>:s', args)`, §12.3); its lines are then formatted once like any section's.
            let raw = last.plainText
            section = WizardStepText(lines: raw.components(separatedBy: CharacterSet.newlines).filter { !$0.isEmpty })
        } else {
            section = text?.step(step.stepName)
        }
        let s = section ?? WizardStepText(lines: [step.stepName])
        title = Self.plain(Self.format(s.title, format))
        description = s.description.map { Self.line(Self.format($0, format)) }
        if step.kind == .entry {
            options = []
            let lines = (s.options.first ?? []).map { Self.format($0, format) }
            entry = lines.map { Self.entryPieces($0, fields: step.fields) }
        } else {
            options = s.options.map { $0.map { Self.line(Self.format($0, format)) } }
            entry = []
        }
    }

    // MARK: Delphi Format

    /// Delphi `Format`: `%[index:][-][width][.prec]type` (index, width and prec may be `*`), for d u x s f n and
    /// the sources' unknown `k` (shown like `s`). Delphi raises on a bad specifier, a missing argument or a type
    /// mismatch; a wizard text must still display, so a bad specifier is copied as is, a missing argument is
    /// empty, and a mismatched argument is shown as text.
    static func format(_ s: String, _ args: [Value]) -> String {
        let c = Array(s)
        var out = ""
        var i = 0
        var next = 0   // sequential argument index
        /// Digits or `*` at `j`; nil when the number does not fit an Int32 (Delphi's integer) or `*` has no int.
        func number(_ j: inout Int) -> Int?? {
            if j < c.count, c[j] == "*" {
                j += 1
                defer { next += 1 }
                guard next < args.count, case .int(let v) = args[next] else { return .some(nil) }
                return .some(Int(v))
            }
            var v = 0, any = false
            while j < c.count, let d = c[j].asciiDigit {
                v = v * 10 + d
                any = true
                j += 1
                if v > Int(Int32.max) { return .some(nil) }
            }
            return any ? .some(v) : nil
        }
        while i < c.count {
            guard c[i] == "%" else { out.append(c[i]); i += 1; continue }
            if i + 1 < c.count, c[i + 1] == "%" { out.append("%"); i += 2; continue }
            var j = i + 1
            var valid = true
            var index: Int? = nil
            var width: Int? = nil
            var precision: Int? = nil
            var leftAlign = false
            var first = number(&j)
            if j < c.count, c[j] == ":" {
                j += 1
                if case .some(let n) = first { if let n { index = n } else { valid = false } } else { index = 0 }
                first = nil
            }
            if case .some = first {} else if j < c.count, c[j] == "-" { leftAlign = true; j += 1 }
            if case .some(let n) = first { if let n { width = n } else { valid = false } } else if case .some(let n) = number(&j) {
                if let n { width = n } else { valid = false }
            }
            if j < c.count, c[j] == "." {
                j += 1
                if case .some(let n) = number(&j) { if let n { precision = n } else { valid = false } } else { precision = 0 }
            }
            guard valid, j < c.count, let type = c[j].lowercased().first, "duxsfnk".contains(type) else {
                out.append("%"); i += 1; continue
            }
            if let index { next = index }
            let arg = next < args.count ? args[next] : nil
            next += 1
            var text = arg.map { formatted($0, type: type, precision: precision) } ?? ""
            // Delphi pads to any width; a hostile text must not allocate gigabytes.
            let w = min(width ?? 0, 4096)
            if text.count < w {
                let pad = String(repeating: " ", count: w - text.count)
                text = leftAlign ? text + pad : pad + text
            }
            out += text
            i = j + 1
        }
        return out
    }

    private static func formatted(_ v: Value, type: Character, precision: Int?) -> String {
        let p = precision.map { min($0, 64) }
        switch (type, v) {
        case ("d", .int(let n)):
            let digits = String(Int(n).magnitude)
            return (n < 0 ? "-" : "") + String(repeating: "0", count: max(0, (p ?? 0) - digits.count)) + digits
        case ("u", .int(let n)):
            let digits = String(UInt32(bitPattern: n))
            return String(repeating: "0", count: max(0, (p ?? 0) - digits.count)) + digits
        case ("x", .int(let n)):
            let digits = String(UInt32(bitPattern: n), radix: 16, uppercase: true)
            return String(repeating: "0", count: max(0, (p ?? 0) - digits.count)) + digits
        case ("f", .int(let n)), ("n", .int(let n)):
            var style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(p ?? 2))
            if type == "f" { style = style.grouping(.never) }
            return Double(n).formatted(style)
        case ("s", _), ("k", _):
            let t = v.plainText
            return p.map { String(t.prefix($0)) } ?? t
        default:
            return v.plainText
        }
    }

    // MARK: Inline codes

    /// Splits `\CODE[,CODE…]\` sequences from text.
    static func line(_ s: String) -> WizardLine {
        WizardLine(runs: runs(s == "_" ? "" : s))
    }

    public static func plain(_ s: String) -> String { runs(s).map(\.text).joined() }

    static func runs(_ s: String) -> [WizardRun] {
        var out: [WizardRun] = []
        var bold = false, emphasis = false
        var linkStart: Int? = nil
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { out.append(WizardRun(text: buffer.windows1252, bold: bold, emphasis: emphasis)) }
            buffer = ""
        }
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "\\") {
            buffer += rest[..<open]
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "\\") else { buffer += rest[open...]; rest = ""; break }
            let codes = after[..<close].split(separator: ",").map(String.init)
            guard !codes.isEmpty, codes.allSatisfy(isCode) else {
                buffer.append("\\")
                rest = after
                continue
            }
            flush()
            for code in codes {
                let parts = code.split(separator: ":", maxSplits: 1).map(String.init)
                switch parts[0] {
                case "FS":
                    let n = Int(parts.count > 1 ? parts[1] : "0") ?? 0
                    bold = n & 1 != 0
                    emphasis = n & 4 != 0 || n & 2 != 0
                case "IS": linkStart = out.count
                case "IL":
                    let url = parts.count > 1 ? parts[1] : ""
                    for k in (linkStart ?? out.count)..<out.count { out[k].link = url }
                    linkStart = nil
                case "TI": buffer += "\t"
                default: break   // DY, DX, DXI, SP, FC, X, Y, FN, FH, FI, ABT, DXFW: layout hints
                }
            }
            rest = after[after.index(after: close)...]
        }
        buffer += rest
        flush()
        return out
    }

    private static func isCode(_ c: String) -> Bool {
        let name = c.split(separator: ":", maxSplits: 1).first.map(String.init) ?? c
        return !name.isEmpty && name.count <= 4 && name.allSatisfy { $0.isUppercase && $0.isLetter }
    }

    // MARK: Entry fields

    static func entryPieces(_ s: String, fields: [AssistantStepDefinition.Field]) -> [WizardEntryPiece] {
        var pieces: [WizardEntryPiece] = []
        var text = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            if c == "|", next < s.endIndex, let n = s[next].wholeNumberValue, n <= 3 {
                if !text.isEmpty { pieces.append(.text(runs(text))); text = "" }
                var j = s.index(after: next)
                // Combobox: |nItem0@Item1@…|
                if n < fields.count, fields[n].precision == .list, let end = s[j...].firstIndex(of: "|") {
                    let items = s[j..<end].split(separator: "@", omittingEmptySubsequences: false).map { plain(String($0)) }
                    pieces.append(.field(index: n, items: items))
                    j = s.index(after: end)
                } else {
                    pieces.append(.field(index: n, items: nil))
                }
                i = j
                continue
            }
            text.append(c)
            i = next
        }
        if !text.isEmpty { pieces.append(.text(runs(text))) }
        return pieces
    }
}

extension Value {
    /// Text for display (strings unquoted, unlike `asText`).
    public var plainText: String {
        switch self {
        case .string(let s): String(decoding: s, as: Latin1.self)
        case .int(let i): String(i)
        case .bool(let b): b ? "TRUE" : "FALSE"
        case .list: text
        }
    }
}

extension AssistantStepDefinition.Field {
    /// Display text of a raw answer for this field (decimals scaled by 10^P, times as [-]hh:mm). No grouping
    /// separator, so the text reads back with `parse`.
    public func display(_ raw: Int32) -> String {
        switch precision {
        case .decimals(let d):
            guard d > 0 else { return String(raw) }
            let p = pow(10.0, Double(d))
            return (Double(raw) / p).formatted(.number.precision(.fractionLength(d)).grouping(.never))
        case .time:
            let r = Int(raw)
            return (r < 0 ? "-" : "") + String(format: "%02d:%02d", abs(r) / 60, abs(r) % 60)
        case .list: return String(raw)
        }
    }

    /// Parses user input back to a raw value, clamped to the field range; nil when not a plain number (or time).
    /// Accepts `,` or `.` as the decimal mark and ignores grouping (spaces, no-break spaces, `'`, or the other mark).
    public func parse(_ text: String) -> Int32? {
        var raw: Double
        switch precision {
        case .time:
            let t = text.trimmingCharacters(in: .whitespaces)
            let parts = t.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let h = Self.plainNumber(String(parts[0]), signed: true),
                  let m = Self.plainNumber(String(parts[1]), signed: false) else { return nil }
            // The sign applies to the whole time: -1:30 is -90 minutes.
            let negative = parts[0].hasPrefix("-")
            raw = (h.magnitude * 60 + m) * (negative ? -1 : 1)
        case .decimals(let d):
            guard let v = Self.number(text) else { return nil }
            raw = (v * pow(10.0, Double(d))).rounded()
        case .list:
            guard let v = Self.number(text) else { return nil }
            raw = v.rounded()
        }
        guard raw.isFinite else { return nil }
        return Int32(Swift.min(Swift.max(raw, Double(min)), Double(max)))
    }

    /// A decimal number with an optional sign, tolerant of grouping; nil for anything else (nan, inf, hex, exponents).
    static func number(_ text: String) -> Double? {
        var t = String(text.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) && $0 != "'" && $0 != "\u{2019}" })
        let comma = t.lastIndex(of: ","), dot = t.lastIndex(of: ".")
        let commas = t.filter { $0 == "," }.count, dots = t.filter { $0 == "." }.count
        switch (comma, dot) {
        case let (c?, d?):   // both: the last one is the decimal mark, the other groups
            let (group, mark): (Character, Character) = c > d ? (".", ",") : (",", ".")
            if t.filter({ $0 == mark }).count > 1 { return nil }
            t.removeAll { $0 == group }
            t = t.replacingOccurrences(of: String(mark), with: ".")
        case (_?, nil):
            t = commas > 1 ? t.replacingOccurrences(of: ",", with: "") : t.replacingOccurrences(of: ",", with: ".")
        case (nil, _?):
            if dots > 1 { t = t.replacingOccurrences(of: ".", with: "") }
        case (nil, nil): break
        }
        return plainNumber(t, signed: true, fraction: true)
    }

    /// `[sign]digits[.digits]` only; nil otherwise or when not finite.
    static func plainNumber(_ t: String, signed: Bool, fraction: Bool = false) -> Double? {
        var body = Substring(t)
        if signed, let f = body.first, f == "-" || f == "+" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !body.isEmpty, parts.count <= (fraction ? 2 : 1),
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.contains(where: { !$0.isEmpty }) else { return nil }
        guard let v = Double(t), v.isFinite else { return nil }
        return v
    }

    public var step: Double {
        if case .decimals(let d) = precision { return pow(10.0, -Double(d)) }
        return 1
    }
}

extension Character {
    var asciiDigit: Int? { isASCII ? wholeNumberValue : nil }
}

extension String {
    /// Assistant texts are Windows-1252; they are decoded byte-for-byte (Latin-1) so the assembler sees the exact
    /// bytes. For display, map the C1 range to the characters Windows-1252 puts there (’ “ ” – — € …).
    public var windows1252: String {
        guard unicodeScalars.contains(where: { (0x80...0x9F).contains($0.value) }) else { return self }
        let map: [UInt32: UInt32] = [
            0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
            0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018,
            0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC,
            0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
        ]
        var out = String.UnicodeScalarView()
        for u in unicodeScalars { out.append(map[u.value].flatMap(Unicode.Scalar.init) ?? u) }
        return String(out)
    }
}
