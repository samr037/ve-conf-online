// Wizard text files inside a .vap (`<name>.en/.fr/.de/.es`), docs/re/03-assembler.md §11.10, §12.

/// One language's wizard texts: sections `#Name` → raw lines.
public struct WizardText: Sendable {
    /// Section name (lowercased) → raw lines, in order. Comments (`;` at column 1) and empty lines removed.
    public private(set) var sections: [String: [String]] = [:]
    /// Original-case section names in file order.
    public private(set) var order: [String] = []

    public init(_ bytes: [UInt8]) {
        var current: String? = nil
        // Split on bytes: in Swift "\r\n" is a single Character, so String splitting on "\n" would miss it.
        for rawLine in bytes.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var lineBytes = Array(rawLine)
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            let line = String(decoding: lineBytes, as: Latin1.self)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("#") {
                let name = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                current = name.lowercased()
                if sections[current!] == nil { sections[current!] = []; order.append(name) }
                continue
            }
            if let c = current { sections[c, default: []].append(line) }
        }
    }

    public func lines(_ section: String) -> [String]? { sections[section.lowercased()] }

    /// A normal section normalised into title, description and option entries (§12.1).
    public func step(_ name: String) -> WizardStepText? {
        guard let lines = lines(name), !lines.isEmpty else { return nil }
        return WizardStepText(lines: lines)
    }
}

public struct WizardStepText: Sendable, Equatable {
    public var title: String
    public var description: [String]
    /// Option entries (radio/check button texts, or the single input line of an entry step).
    public var options: [[String]]

    init(lines: [String]) {
        title = lines.first ?? ""
        var desc: [String] = []
        var opts: [[String]] = []
        for line in lines.dropFirst() {
            if line.hasPrefix(".") {
                opts.append([String(line.dropFirst())])
            } else if opts.isEmpty {
                desc.append(line)
            } else {
                opts[opts.count - 1].append(line)
            }
        }
        description = desc
        options = opts
    }

    /// Lines joined with the internal break char, after `_` placeholders become empty lines.
    public static func join(_ lines: [String]) -> String {
        lines.map { $0 == "_" ? "" : $0 }.joined(separator: "\n")
    }
}

extension WizardText {
    /// `AssistantText(k)` lookup in one language (§11.10), before unescaping.
    func assistantText(_ key: Value) -> String? {
        switch key {
        case .string(let s):
            let k = String(decoding: s, as: Latin1.self)
            if k.hasPrefix("#") {
                guard let lines = lines(String(k.dropFirst())) else { return nil }
                return lines.joined(separator: "\n")
            }
            guard let array = lines("StringArray") else { return nil }
            for line in array {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let name = line[..<eq].trimmingCharacters(in: .whitespaces)
                if name.caseInsensitiveCompare(k) == .orderedSame {
                    return String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        case .int(let i):
            guard let array = lines("StringArray"), i >= 0, Int(i) < array.count else { return nil }
            return array[Int(i)]
        default:
            return nil
        }
    }

    /// `|n` line break, `|t` tab, `|xHH` char, `||` pipe; any other `|c` is dropped.
    static func unescape(_ s: String) -> [UInt8] {
        let b = Latin1.encode(s)
        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            if b[i] == 0x7C, i + 1 < b.count {
                let c = b[i + 1]
                switch c {
                case 0x6E: out += [13, 10]; i += 2
                case 0x74: out.append(9); i += 2
                case 0x7C: out.append(0x7C); i += 2
                case 0x78 where i + 3 < b.count:
                    out.append(UInt8(String(decoding: b[i + 2...i + 3], as: UTF8.self), radix: 16) ?? 0x3F); i += 4
                default: i += 2
                }
            } else {
                out.append(b[i]); i += 1
            }
        }
        return out
    }
}

import Foundation
