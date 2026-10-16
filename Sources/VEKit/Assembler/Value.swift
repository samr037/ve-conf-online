// Values of the VLL assembler's calculator (docs/re/03-assembler.md §2).

public enum Value: Equatable, Sendable {
    /// 32-bit signed, wrapping arithmetic.
    case int(Int32)
    case bool(Bool)
    /// Byte string (Latin-1); indexing is 1-based.
    case string([UInt8])
    /// Heterogeneous list; indexing is 0-based.
    case list([Value])

    public static func str(_ s: String) -> Value { .string(Latin1.encode(s)) }

    /// Re-parseable text form (Delphi AsText): ints decimal, TRUE/FALSE, Pascal-quoted strings, `([]+a+b)` lists.
    public var asText: [UInt8] {
        switch self {
        case .int(let i): return Array(String(i).utf8)
        case .bool(let b): return Array((b ? "TRUE" : "FALSE").utf8)
        case .string(let s):
            var out: [UInt8] = [0x27]
            for c in s { out.append(c); if c == 0x27 { out.append(0x27) } }
            out.append(0x27)
            return out
        case .list(let l):
            var out = Array("([]".utf8)
            for e in l { out.append(UInt8(ascii: "+")); out += e.asText }
            out.append(UInt8(ascii: ")"))
            return out
        }
    }

    public var text: String { String(decoding: asText, as: Latin1.self) }

    var isString: Bool { if case .string = self { true } else { false } }

    func sameClass(_ other: Value) -> Bool {
        switch (self, other) {
        case (.int, .int), (.bool, .bool), (.string, .string), (.list, .list): true
        default: false
        }
    }
}
