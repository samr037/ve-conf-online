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
            // Generic steps carry their whole text as the last format argument.
            let raw = Self.format(last.plainText, format)
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

    static func format(_ s: String, _ args: [Value]) -> String {
        var out = ""
        var i = s.startIndex
        var sequential = 0
        while i < s.endIndex {
            let c = s[i]
            guard c == "%" else { out.append(c); i = s.index(after: i); continue }
            var j = s.index(after: i)
            if j < s.endIndex, s[j] == "%" { out.append("%"); i = s.index(after: j); continue }
            var digits = ""
            while j < s.endIndex, s[j].isNumber { digits.append(s[j]); j = s.index(after: j) }
            var index = sequential
            if j < s.endIndex, s[j] == ":", let n = Int(digits) {
                index = n
                j = s.index(after: j)
            } else if !digits.isEmpty {
                // width without index (rare): ignore it
            }
            guard j < s.endIndex, "sdkxSDKX".contains(s[j]) else { out.append(c); i = s.index(after: i); continue }
            out += index < args.count ? args[index].plainText : ""
            sequential = index + 1
            i = s.index(after: j)
        }
        return out
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
            if !buffer.isEmpty { out.append(WizardRun(text: buffer, bold: bold, emphasis: emphasis)) }
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
    /// Display text of a raw answer for this field (decimals scaled by 10^P, times as hh:mm).
    public func display(_ raw: Int32) -> String {
        switch precision {
        case .decimals(let d):
            guard d > 0 else { return String(raw) }
            let p = pow(10.0, Double(d))
            return (Double(raw) / p).formatted(.number.precision(.fractionLength(d)))
        case .time: return String(format: "%02d:%02d", raw / 60, raw % 60)
        case .list: return String(raw)
        }
    }

    /// Parses user input back to a raw value (nil when not a number), clamped to the field range.
    public func parse(_ text: String) -> Int32? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        var raw: Double
        switch precision {
        case .time:
            let parts = t.split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
            raw = Double(h * 60 + m)
        case .decimals(let d):
            guard let v = Double(t) else { return nil }
            raw = (v * pow(10.0, Double(d))).rounded()
        case .list:
            guard let v = Double(t) else { return nil }
            raw = v
        }
        return Int32(Swift.min(Swift.max(raw, Double(min)), Double(max)))
    }

    public var step: Double {
        if case .decimals(let d) = precision { return pow(10.0, -Double(d)) }
        return 1
    }
}
