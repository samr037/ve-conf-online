import Foundation

// The VLL calculator: tokenizer, syntax check and evaluator.

/// A named value in one of the assembler's label lists.
final class Label {
    var value: Value?
    /// bit0 = fixed (.EQU, code labels, .ALD); bit1 = system (assignable); other bits: opaque type tag.
    var flags: Int
    /// Parameter names when this label is a user function (`Name(` key).
    var params: [String]?

    init(value: Value?, flags: Int, params: [String]? = nil) {
        self.value = value
        self.flags = flags
        self.params = params
    }

    var isFixed: Bool { flags & 1 != 0 }
    var isSystem: Bool { flags & 2 != 0 }
}

/// What the calculator needs from its environment.
protocol CalculatorHost: AnyObject {
    /// Label (or user function, key `Name(`) visible from the current scope.
    func lookup(_ name: String) -> Label?
    /// `RBn(a)`: n-byte little-endian value at offset a of the reference binary; −1 without one.
    func readBack(bytes: Int, at address: Int32) -> Result<Int32, CalcError>
    func assistantText(_ key: Value) -> [UInt8]?
    func assistantLabelValue(_ name: String) -> Int32?
    func noteReadBackUsed()
}

struct CalcError: Error, Equatable {
    var message: String
    static let dyadic = CalcError(message: "Dyadic operator not suitable for these operands")
    static let monadic = CalcError(message: "Monadic operator not suitable for this operand")
    static let paramType = CalcError(message: "The type of one (or more) of the function parameters is not correct")
    static let paramCount = CalcError(message: "Wrong number of parameters")
    static let bounds = CalcError(message: "Index out of bounds")
    static let divZero = CalcError(message: "Division by ZERO")
    /// Not in VE Configure: guards against runaway recursion (user functions, `val()`, lazy `AND`/`OR`/`XOR`,
    /// `known()`) that would otherwise overflow the stack.
    static let tooDeep = CalcError(message: "Expression nesting too deep")
    /// Not in VE Configure: an expression doing more nested evaluations than any real source needs.
    static let tooComplex = CalcError(message: "Expression too complex")
    /// Not in VE Configure: caps the memory one value may take.
    static let tooLong = CalcError(message: "Result too long")
    /// Decimal literal above 2^31-1 (unspecified in VE Configure, which ignores the conversion error).
    static let range = CalcError(message: "Range check error")
}

struct Evaluation {
    var value: Value?
    var error: String?
    var warnings: [String] = []
    var ok: Bool { value != nil && error == nil }
}

final class Calculator {
    unowned let host: CalculatorHost
    /// User-function parameter frames, innermost last; searched before every other list.
    private var frames: [[String: Label]] = []

    /// Nested evaluations (user functions, `val()`, lazy logic, `known()`) are limited in depth and in number.
    /// The whole library peaks at depth 5 and 48 nested evaluations per expression.
    static let maxDepth = 256
    static let maxNestedEvaluations = 10_000
    /// Longest string or list a calculation may produce.
    static let maxLength = 16 << 20

    fileprivate var depth = 0
    fileprivate var nestedEvaluations = 0
    /// Set once a limit is hit; sticky until the outermost evaluation returns so `known()` cannot swallow it.
    fileprivate var exhausted: CalcError?

    init(host: CalculatorHost) { self.host = host }

    /// Evaluates an expression. Errors make the result nil; warnings (Div result is zero!) do not.
    func evaluate(_ text: [UInt8]) -> Evaluation {
        let outermost = depth == 0
        if outermost { nestedEvaluations = 0; exhausted = nil }
        defer { if outermost { exhausted = nil } }
        var run = Run(calc: self)
        let v = run.evaluate(text)
        if let e = run.error { return Evaluation(value: nil, error: e, warnings: run.warnings) }
        return Evaluation(value: v, error: v == nil ? "Error interpreting expression" : nil, warnings: run.warnings)
    }

    func evaluate(_ text: String) -> Evaluation { evaluate(Latin1.encode(text)) }

    fileprivate func lookup(_ name: String) -> Label? {
        for f in frames.reversed() { if let l = f[name] { return l } }
        return host.lookup(name)
    }

    fileprivate func push(_ frame: [String: Label]) { frames.append(frame) }
    fileprivate func pop() { frames.removeLast() }
}

// MARK: - Tokens

private enum Callable {
    case paren
    case builtin(String)
    case user(Label)
    case readBack(Int)
    case assistantText
    case assistantLabelValue
}

private struct Operator {
    enum ID { case pow, mul, div, mod, shl, shr, add, sub, eq, ne, lt, gt, le, ge, and, or, xor, not, at }
    var id: ID
    var priority: Int
    var monadicAllowed: Bool

    static let table: [(text: String, op: Operator)] = [
        ("^", Operator(id: .pow, priority: 10, monadicAllowed: false)),
        ("*", Operator(id: .mul, priority: 9, monadicAllowed: false)),
        ("/", Operator(id: .div, priority: 9, monadicAllowed: false)),
        ("MOD", Operator(id: .mod, priority: 9, monadicAllowed: false)),
        ("<<", Operator(id: .shl, priority: 9, monadicAllowed: false)),
        (">>", Operator(id: .shr, priority: 9, monadicAllowed: false)),
        ("+", Operator(id: .add, priority: 8, monadicAllowed: true)),
        ("-", Operator(id: .sub, priority: 8, monadicAllowed: true)),
        ("=", Operator(id: .eq, priority: 6, monadicAllowed: false)),
        ("!=", Operator(id: .ne, priority: 6, monadicAllowed: false)),
        ("<", Operator(id: .lt, priority: 6, monadicAllowed: false)),
        (">", Operator(id: .gt, priority: 6, monadicAllowed: false)),
        ("<=", Operator(id: .le, priority: 6, monadicAllowed: false)),
        (">=", Operator(id: .ge, priority: 6, monadicAllowed: false)),
        ("AND", Operator(id: .and, priority: 5, monadicAllowed: false)),
        ("OR", Operator(id: .or, priority: 4, monadicAllowed: false)),
        ("XOR", Operator(id: .xor, priority: 3, monadicAllowed: false)),
        ("!", Operator(id: .not, priority: 9, monadicAllowed: true)),
        ("@", Operator(id: .at, priority: 255, monadicAllowed: false)),
    ]
}

private enum Token {
    case open(Callable)
    case comma
    case close
    case operand(Value)
    case op(Operator)
    /// A token that matched but cannot be used (out-of-range literal).
    case invalid(CalcError)
}

private let builtinsInt = ["int(", "abs(", "sign("]
private let builtinsString = ["copy(", "err(", "del(", "len(", "pos(", "ins(", "val(", "known(", "ord(", "str(", "hex("]

private func isLabelFirst(_ c: UInt8) -> Bool {
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24
}
private func isLabelNext(_ c: UInt8) -> Bool {
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || (c >= 0x30 && c <= 0x39) || c == 0x23
}
private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
private func hexValue(_ c: UInt8) -> Int? {
    switch c {
    case 0x30...0x39: Int(c - 0x30)
    case 0x41...0x46: Int(c - 0x41 + 10)
    case 0x61...0x66: Int(c - 0x61 + 10)
    default: nil
    }
}

private func matchesCI(_ s: [UInt8], _ i: Int, _ word: String) -> Bool {
    let w = Array(word.utf8)
    guard i + w.count <= s.count else { return false }
    for k in 0..<w.count {
        var a = s[i + k], b = w[k]
        if a >= 0x61 && a <= 0x7A { a -= 32 }
        if b >= 0x61 && b <= 0x7A { b -= 32 }
        if a != b { return false }
    }
    return true
}

private func matchesExact(_ s: [UInt8], _ i: Int, _ word: String) -> Bool {
    let w = Array(word.utf8)
    return i + w.count <= s.count && Array(s[i..<i + w.count]) == w
}

// MARK: - One evaluation

private struct Run {
    unowned let calc: Calculator
    var error: String?
    var warnings: [String] = []

    init(calc: Calculator) { self.calc = calc }

    mutating func fail(_ e: CalcError) { if error == nil { error = e.message } }
    mutating func fail(_ m: String) { if error == nil { error = m } }

    // MARK: Tokenizer (longest match; ties go to the class registered first)

    mutating func tokenize(_ s: [UInt8]) -> [Token]? {
        var tokens: [Token] = []
        var i = 0
        while i < s.count {
            if s[i] == 0x20 { i += 1; continue }
            var best: (len: Int, make: () -> Token?)? = nil
            func offer(_ len: Int, _ make: @escaping () -> Token?) {
                if len > 0 && len > (best?.len ?? 0) { best = (len, make) }
            }
            let c = s[i]
            // 1. ( , )
            if c == 0x28 { offer(1) { .open(.paren) } }
            if c == 0x2C { offer(1) { .comma } }
            if c == 0x29 { offer(1) { .close } }
            // 2. operators, integer literal, boolean literal, int( abs( sign(
            for (text, op) in Operator.table {
                let isWord = text.first!.isLetter
                if isWord ? matchesCI(s, i, text) : matchesExact(s, i, text) { offer(text.utf8.count) { .op(op) } }
            }
            if let (len, v) = intLiteral(s, i) { offer(len) { v.map { .operand(.int($0)) } ?? .invalid(.range) } }
            if matchesCI(s, i, "true") { offer(4) { .operand(.bool(true)) } }
            if matchesCI(s, i, "false") { offer(5) { .operand(.bool(false)) } }
            for b in builtinsInt where matchesCI(s, i, b) { offer(b.utf8.count) { .open(.builtin(b)) } }
            // 3. string literal, [], string/list builtins
            if let (len, v) = stringLiteral(s, i) { offer(len) { .operand(.string(v)) } }
            if matchesExact(s, i, "[]") { offer(2) { .operand(.list([])) } }
            for b in builtinsString where matchesCI(s, i, b) { offer(b.utf8.count) { .open(.builtin(b)) } }
            // 4. label reference or user-function call (resolved now: unknown names do not match)
            if isLabelFirst(c) {
                var j = i + 1
                while j < s.count && isLabelNext(s[j]) { j += 1 }
                let name = String(decoding: s[i..<j], as: UTF8.self)
                if j < s.count && s[j] == 0x28, let f = calc.lookup(name + "("), f.params != nil {
                    offer(j + 1 - i) { .open(.user(f)) }
                } else if let l = calc.lookup(name) {
                    let len = j - i
                    offer(len) { [l] in l.value.map { .operand($0) } }
                }
            }
            // 5. assistant functions
            for n in 1...4 where matchesExact(s, i, "RB\(n)(") { offer(4) { .open(.readBack(n)) } }
            if matchesCI(s, i, "AssistantText(") { offer(14) { .open(.assistantText) } }
            if matchesCI(s, i, "AssistantLabelValue(") { offer(20) { .open(.assistantLabelValue) } }

            guard let (len, make) = best else {
                let rest = String(decoding: s[i..<min(s.count, i + 50)], as: Latin1.self)
                fail("cannot interpret \"\(rest)...\"")
                return nil
            }
            guard let t = make() else { fail("label has no value"); return nil }
            if case .invalid(let e) = t { fail(e); return nil }
            tokens.append(t)
            i += len
        }
        return tokens
    }

    /// Length and value of an integer literal; the value is nil for a decimal literal above 2^31-1.
    func intLiteral(_ s: [UInt8], _ i: Int) -> (Int, Int32?)? {
        guard i < s.count, isDigit(s[i]) else { return nil }
        if s[i] == 0x30, i + 1 < s.count, s[i + 1] == 0x78 {   // 0x (case-sensitive)
            var j = i + 2, v: UInt64 = 0
            while j < s.count, let h = hexValue(s[j]) { v = (v << 4 | UInt64(h)) & 0xFFFF_FFFF; j += 1 }
            if j > i + 2 { return (j - i, Int32(bitPattern: UInt32(v))) }
        }
        if s[i] == 0x30, i + 1 < s.count, s[i + 1] == 0x62 {   // 0b
            var j = i + 2, v: UInt64 = 0
            while j < s.count, s[j] == 0x30 || s[j] == 0x31 { v = (v << 1 | UInt64(s[j] - 0x30)) & 0xFFFF_FFFF; j += 1 }
            if j > i + 2 { return (j - i, Int32(bitPattern: UInt32(v))) }
        }
        // Delphi Val reports an overflow that VE Configure ignores (the value is then unspecified, and no
        // shipped source has such a literal): treat it as a range error rather than silently wrapping.
        var j = i, v: Int64 = 0
        while j < s.count, isDigit(s[j]) {
            if v <= Int64(Int32.max) { v = v * 10 + Int64(s[j] - 0x30) }
            j += 1
        }
        return (j - i, v <= Int64(Int32.max) ? Int32(v) : nil)
    }

    func stringLiteral(_ s: [UInt8], _ start: Int) -> (Int, [UInt8])? {
        var i = start
        var out: [UInt8] = []
        var pieces = 0
        while i < s.count {
            if s[i] == 0x27 {
                var j = i + 1
                var closed = false
                while j < s.count {
                    if s[j] == 0x27 {
                        if j + 1 < s.count && s[j + 1] == 0x27 { out.append(0x27); j += 2; continue }
                        closed = true; j += 1; break
                    }
                    out.append(s[j]); j += 1
                }
                guard closed else { break }
                i = j; pieces += 1
            } else if s[i] == 0x23 {
                // #n (≤3 digits, <256), #0xH[H], #$hex…
                if i + 2 < s.count && s[i + 1] == 0x30 && s[i + 2] == 0x78 {
                    var j = i + 3, v = 0, n = 0
                    while j < s.count, n < 2, let h = hexValue(s[j]) { v = v * 16 + h; j += 1; n += 1 }
                    guard n > 0 else { break }
                    out.append(UInt8(v)); i = j; pieces += 1
                } else if i + 1 < s.count && s[i + 1] == 0x24 {
                    var j = i + 2
                    var digits: [Int] = []
                    while j < s.count, let h = hexValue(s[j]) { digits.append(h); j += 1 }
                    guard !digits.isEmpty else { break }
                    if digits.count % 2 == 1 { digits.insert(0, at: 0) }
                    for k in stride(from: 0, to: digits.count, by: 2) { out.append(UInt8(digits[k] * 16 + digits[k + 1])) }
                    i = j; pieces += 1
                } else if i + 1 < s.count && isDigit(s[i + 1]) {
                    var j = i + 1, v = 0, n = 0
                    while j < s.count, n < 3, isDigit(s[j]) {
                        let nv = v * 10 + Int(s[j] - 0x30)
                        if nv >= 256 { break }
                        v = nv; j += 1; n += 1
                    }
                    out.append(UInt8(v)); i = j; pieces += 1
                } else { break }
            } else { break }
        }
        return pieces > 0 ? (i - start, out) : nil
    }

    // MARK: Syntax check + evaluation (operator precedence)

    private enum Kind { case open, close, comma, operand, monadic, dyadic }

    private struct OpenFrame { var callable: Callable; var args: [Value]; var operandBase: Int; var opBase: Int }

    mutating func evaluate(_ text: [UInt8]) -> Value? {
        guard let tokens = tokenize(text), error == nil else { return nil }
        // Wrap in an implicit ( … ).
        let all: [Token] = [.open(.paren)] + tokens + [.close]
        var operands: [Value] = []
        var ops: [(op: Operator, monadic: Bool)] = []
        var opens: [OpenFrame] = []
        var prev: Kind = .comma

        func reduceOne() -> Bool {
            let (op, monadic) = ops.removeLast()
            if monadic {
                guard let a = operands.popLast() else { fail("Internal error: operand/operator stack underflow"); return false }
                guard let r = applyMonadic(op, a) else { return false }
                operands.append(r)
            } else {
                guard operands.count >= 2 else { fail("Internal error: operand/operator stack underflow"); return false }
                let b = operands.removeLast(), a = operands.removeLast()
                guard let r = applyDyadic(op, a, b) else { return false }
                operands.append(r)
            }
            return true
        }

        var index = 0
        while index < all.count {
            let t = all[index]
            index += 1
            switch t {
            case .open(let c):
                guard prev == .open || prev == .comma || prev == .monadic || prev == .dyadic else {
                    fail("\"(\" is not allowed on that place"); return nil
                }
                opens.append(OpenFrame(callable: c, args: [], operandBase: operands.count, opBase: ops.count))
                prev = .open
            case .comma, .close:
                guard prev == .operand || prev == .close else { fail("expression not comlete"); return nil }
                guard var frame = opens.popLast() else { fail("bracket open/close mismatch"); return nil }
                while ops.count > frame.opBase { if !reduceOne() { return nil } }
                guard operands.count == frame.operandBase + 1 else { fail("Nr of parameters on stack not OK"); return nil }
                frame.args.append(operands.removeLast())
                if case .comma = t {
                    opens.append(frame)
                    prev = .comma
                } else {
                    guard let r = call(frame.callable, frame.args) else { return nil }
                    operands.append(r)
                    prev = .close
                }
            case .operand(let v):
                guard prev == .open || prev == .comma || prev == .monadic || prev == .dyadic else {
                    fail("\"\(String(decoding: v.asText.prefix(10), as: Latin1.self))...\" is not allowed on that place"); return nil
                }
                operands.append(v)
                prev = .operand
            case .op(let op):
                if prev == .operand || prev == .close {
                    while let top = ops.last, ops.count > (opens.last?.opBase ?? 0), top.op.priority >= op.priority {
                        if !reduceOne() { return nil }
                    }
                    ops.append((op, false))
                    prev = .dyadic
                } else {
                    guard op.monadicAllowed else { fail("operator is not allowed on that place"); return nil }
                    ops.append((op, true))
                    prev = .monadic
                }
            case .invalid(let e):
                fail(e); return nil
            }
        }
        guard opens.isEmpty, operands.count == 1 else { fail("bracket open/close mismatch"); return nil }
        return operands[0]
    }

    // MARK: Operators

    mutating func applyMonadic(_ op: Operator, _ a: Value) -> Value? {
        switch (op.id, a) {
        case (.sub, .int(let x)): return .int(0 &- x)
        case (.add, .int(let x)): return .int(x)
        case (.not, .int(let x)): return .int(~x)
        case (.not, .bool(let x)): return .bool(!x)
        default: fail(.monadic); return nil
        }
    }

    mutating func applyDyadic(_ op: Operator, _ a: Value, _ b: Value) -> Value? {
        if op.id == .at {
            guard case .int(let i) = b else { fail(.dyadic); return nil }
            switch a {
            case .string(let s):
                guard i >= 1, Int(i) <= s.count else { fail(.bounds); return nil }
                return .string([s[Int(i) - 1]])
            case .list(let l):
                guard i >= 0, Int(i) < l.count else { fail(.bounds); return nil }
                return l[Int(i)]
            default: fail(.dyadic); return nil
            }
        }
        // Lazy logical operators on strings.
        if [.and, .or, .xor].contains(op.id), a.isString || b.isString {
            return lazyLogic(op.id, a, b)
        }
        switch (a, b) {
        case (.int(let x), .int(let y)): return intOp(op.id, x, y)
        case (.bool(let x), .bool(let y)):
            switch op.id {
            case .and: return .bool(x && y)
            case .or: return .bool(x || y)
            case .xor: return .bool(x != y)
            case .eq: return .bool(x == y)
            case .ne: return .bool(x != y)
            default: fail(.dyadic); return nil
            }
        case (.string(let x), .string(let y)):
            switch op.id {
            case .add:
                guard x.count + y.count <= Calculator.maxLength else { fail(.tooLong); return nil }
                return .string(x + y)
            case .eq: return .bool(x == y)
            case .ne: return .bool(x != y)
            case .lt: return .bool(x.lexicographicallyPrecedes(y))
            case .gt: return .bool(y.lexicographicallyPrecedes(x))
            case .le: return .bool(!y.lexicographicallyPrecedes(x))
            case .ge: return .bool(!x.lexicographicallyPrecedes(y))
            default: fail(.dyadic); return nil
            }
        case (.list(let x), _) where op.id == .add:
            guard x.count < Calculator.maxLength else { fail(.tooLong); return nil }
            return .list(x + [b])
        case (.list(let x), .list(let y)):
            switch op.id {
            case .and:
                guard x.count + y.count <= Calculator.maxLength else { fail(.tooLong); return nil }
                return .list(x + y)
            case .eq: return .bool(x == y)
            case .ne: return .bool(x != y)
            default: fail(.dyadic); return nil
            }
        default:
            fail(.dyadic); return nil
        }
    }

    mutating func intOp(_ id: Operator.ID, _ x: Int32, _ y: Int32) -> Value? {
        switch id {
        case .pow:
            let r = pow(Double(x), Double(y)).rounded(.toNearestOrAwayFromZero)
            guard r >= Double(Int32.min), r <= Double(Int32.max) else { fail("Range check error"); return nil }
            return .int(Int32(r))
        case .mul: return .int(x &* y)
        case .div:
            guard y != 0 else { fail(.divZero); return nil }
            if x == Int32.min && y == -1 { return .int(x) }
            let r = x / y
            if r == 0 && x != 0 { warnings.append("Div result is zero!") }
            return .int(r)
        case .mod:
            guard y != 0 else { fail(.divZero); return nil }
            if y == -1 { return .int(0) }
            return .int(x % y)
        case .shl: return .int(Int32(bitPattern: UInt32(bitPattern: x) << UInt32(y & 31)))
        case .shr: return .int(Int32(bitPattern: UInt32(bitPattern: x) >> UInt32(y & 31)))
        case .add: return .int(x &+ y)
        case .sub: return .int(x &- y)
        case .eq: return .bool(x == y)
        case .ne: return .bool(x != y)
        case .lt: return .bool(x < y)
        case .gt: return .bool(x > y)
        case .le: return .bool(x <= y)
        case .ge: return .bool(x >= y)
        case .and: return .int(x & y)
        case .or: return .int(x | y)
        case .xor: return .int(x ^ y)
        case .not, .at: fail(.dyadic); return nil
        }
    }

    mutating func lazyLogic(_ id: Operator.ID, _ a: Value, _ b: Value) -> Value? {
        func text(_ v: Value) -> [UInt8]? {
            switch v {
            case .string(let s): return s
            case .bool: return v.asText
            default: return nil
            }
        }
        guard let lt = text(a), let rt = text(b) else { fail(.dyadic); return nil }
        guard case .bool(let l)? = sub(lt) else { fail(.dyadic); return nil }
        switch id {
        case .and:
            if !l { return .bool(false) }
            guard case .bool(let r)? = sub(rt) else { fail(.dyadic); return nil }
            return .bool(r)
        case .or:
            if l { return .bool(true) }
            guard case .bool(let r)? = sub(rt) else { fail(.dyadic); return nil }
            return .bool(r)
        default:
            guard case .bool(let r)? = sub(rt) else { fail(.dyadic); return nil }
            return .bool(r != l)
        }
    }

    /// Evaluates a nested expression in the same scope; its errors propagate.
    mutating func sub(_ text: [UInt8]) -> Value? {
        guard let (v, inner) = nested(text) else { return nil }
        warnings += inner.warnings
        if let e = inner.error { fail(e); return nil }
        return v
    }

    /// Runs a nested evaluation within the depth and count limits; nil (with the limit error) when one is hit.
    mutating func nested(_ text: [UInt8]) -> (Value?, Run)? {
        if let e = calc.exhausted { fail(e); return nil }
        calc.nestedEvaluations += 1
        if calc.depth >= Calculator.maxDepth { calc.exhausted = .tooDeep }
        if calc.nestedEvaluations > Calculator.maxNestedEvaluations { calc.exhausted = .tooComplex }
        if let e = calc.exhausted { fail(e); return nil }
        calc.depth += 1
        defer { calc.depth -= 1 }
        var inner = Run(calc: calc)
        let v = inner.evaluate(text)
        if let e = calc.exhausted { fail(e); return nil }
        return (v, inner)
    }

    // MARK: Functions

    mutating func call(_ c: Callable, _ args: [Value]) -> Value? {
        switch c {
        case .paren:
            guard args.count == 1 else { fail(.paramCount); return nil }
            return args[0]
        case .builtin(let name): return builtin(name.lowercased(), args)
        case .user(let label):
            guard let params = label.params, case .string(let body)? = label.value else { fail(.paramType); return nil }
            guard args.count == params.count else { fail(.paramCount); return nil }
            var frame: [String: Label] = [:]
            for (p, v) in zip(params, args) { frame[p] = Label(value: v, flags: 0) }
            calc.push(frame)
            defer { calc.pop() }
            return sub(body)
        case .readBack(let n):
            guard args.count == 1 else { fail(.paramCount); return nil }
            guard case .int(let a) = args[0] else { fail(.paramType); return nil }
            calc.host.noteReadBackUsed()
            switch calc.host.readBack(bytes: n, at: a) {
            case .success(let v): return .int(v)
            case .failure(let e): fail(e); return nil
            }
        case .assistantText:
            guard args.count == 1 else { fail(.paramCount); return nil }
            guard let t = calc.host.assistantText(args[0]), !t.isEmpty else {
                fail("AssistantText function returned empty string"); return nil
            }
            return .string(t)
        case .assistantLabelValue:
            guard args.count == 1 else { fail(.paramCount); return nil }
            guard case .string(let s) = args[0] else { fail(.paramType); return nil }
            guard let v = calc.host.assistantLabelValue(String(decoding: s, as: Latin1.self)) else {
                fail("Unknown assistant label"); return nil
            }
            return .int(v)
        }
    }

    mutating func builtin(_ name: String, _ a: [Value]) -> Value? {
        func arity(_ n: Int...) -> Bool {
            if n.contains(a.count) { return true }
            fail(.paramCount); return false
        }
        switch name {
        case "int(":
            guard arity(1) else { return nil }
            switch a[0] {
            case .int(let i): return .int(i)
            case .bool(let b): return .int(b ? 1 : 0)
            default: fail(.paramType); return nil
            }
        case "abs(":
            guard arity(1) else { return nil }
            guard case .int(let i) = a[0] else { fail(.paramType); return nil }
            return .int(i < 0 ? 0 &- i : i)
        case "sign(":
            guard arity(1) else { return nil }
            guard case .int(let i) = a[0] else { fail(.paramType); return nil }
            return .int(i < 0 ? -1 : 1)
        case "len(":
            guard arity(1) else { return nil }
            switch a[0] {
            case .string(let s): return .int(Int32(s.count))
            case .list(let l): return .int(Int32(l.count))
            default: fail(.paramType); return nil
            }
        case "copy(":
            guard arity(3) else { return nil }
            guard case .int(let i32) = a[1], case .int(let n32) = a[2] else { fail(.paramType); return nil }
            var i = Int(i32), n = Int(n32)   // Int: the clipping below cannot overflow
            switch a[0] {
            case .string(let s):
                if i < 1 { n -= 1 - i; i = 1 }
                let start = i - 1
                guard n > 0, start < s.count else { return .string([]) }
                return .string(Array(s[start..<min(s.count, start + n)]))
            case .list(let l):
                let lo = max(0, i), hi = min(l.count, i + n)
                return .list(lo < hi ? Array(l[lo..<hi]) : [])
            default: fail(.paramType); return nil
            }
        case "del(":
            guard arity(3) else { return nil }
            guard case .int(let i32) = a[1], case .int(let n32) = a[2] else { fail(.paramType); return nil }
            var i = Int(i32), n = Int(n32)
            switch a[0] {
            case .string(var s):
                if i < 1 { n -= 1 - i; i = 1 }
                let start = i - 1
                if n > 0 && start < s.count { s.removeSubrange(start..<min(s.count, start + n)) }
                return .string(s)
            case .list(var l):
                let lo = max(0, i), hi = min(l.count, i + n)
                if lo < hi { l.removeSubrange(lo..<hi) }
                return .list(l)
            default: fail(.paramType); return nil
            }
        case "ins(":
            guard arity(3) else { return nil }
            guard case .int(let i) = a[2] else { fail(.paramType); return nil }
            switch (a[0], a[1]) {
            case (.string(var s), .string(let y)):
                guard i >= 1, Int(i) <= s.count + 1 else { fail(.bounds); return nil }
                guard s.count + y.count <= Calculator.maxLength else { fail(.tooLong); return nil }
                s.insert(contentsOf: y, at: Int(i) - 1)
                return .string(s)
            case (.list(var l), let y):
                guard i >= 0, Int(i) <= l.count else { fail(.bounds); return nil }
                guard l.count < Calculator.maxLength else { fail(.tooLong); return nil }
                l.insert(y, at: Int(i))
                return .list(l)
            default: fail(.paramType); return nil
            }
        case "pos(":
            guard arity(2) else { return nil }
            switch (a[0], a[1]) {
            case (.string(let y), .string(let x)):
                guard !y.isEmpty, y.count <= x.count else { return .int(0) }
                for k in 0...(x.count - y.count) where Array(x[k..<k + y.count]) == y { return .int(Int32(k + 1)) }
                return .int(0)
            case (let y, .list(let l)):
                if let k = l.lastIndex(where: { $0.sameClass(y) && $0 == y }) { return .int(Int32(k)) }
                return .int(-1)
            default: fail(.paramType); return nil
            }
        case "ord(":
            guard arity(1) else { return nil }
            guard case .string(let s) = a[0], s.count == 1 else { fail(.paramType); return nil }
            return .int(Int32(s[0]))
        case "str(":
            guard arity(1) else { return nil }
            // Lists can share sub-lists, so their text can be exponentially longer than their memory.
            guard let t = a[0].asText(limit: Calculator.maxLength) else { fail(.tooLong); return nil }
            return .string(t)
        case "val(":
            guard arity(1, 2) else { return nil }
            guard case .string(let s) = a[0] else { fail(.paramType); return nil }
            if a.count == 2 {
                guard case .bool(let signed) = a[1] else { fail(.paramType); return nil }
                var v: UInt32 = 0
                let bytes = Array(s.prefix(4))
                for (k, b) in bytes.enumerated() { v |= UInt32(b) << (8 * UInt32(k)) }
                if signed, bytes.count < 4, let last = bytes.last, last & 0x80 != 0 {
                    v |= UInt32.max << (8 * UInt32(bytes.count))
                }
                return .int(Int32(bitPattern: v))
            }
            return sub(s)
        case "known(":
            guard arity(1) else { return nil }
            guard case .string(let s) = a[0] else { fail(.paramType); return nil }
            guard let (v, inner) = nested(s) else { return nil }
            return .bool(v != nil && inner.error == nil)
        case "err(":
            guard arity(2) else { return nil }
            guard case .bool(let c) = a[0], case .string(let m) = a[1] else { fail(.paramType); return nil }
            if c { fail("User error: " + String(decoding: m, as: Latin1.self)); return nil }
            return .int(0)
        case "hex(":
            guard arity(1, 2) else { return nil }
            var digits = 1
            if a.count == 2 { guard case .int(let n) = a[1] else { fail(.paramType); return nil }; digits = Int(n) }
            // IntToHex pads to `digits`; a 32-bit value never needs more than 8, so a huge count only wastes memory.
            // Delphi's Format caps integer precision at 32 (hex( is unused in the shipped sources).
            digits = min(digits, 32)
            switch a[0] {
            case .int(let x):
                var h = String(UInt32(bitPattern: x), radix: 16, uppercase: true)
                if h.count < digits { h = String(repeating: "0", count: digits - h.count) + h }
                return .str(h)
            case .string(let s): return .str(s.map { String(format: "%02X", $0) }.joined())
            default: fail(.paramType); return nil
            }
        default:
            fail("Cannot handle this element"); return nil
        }
    }
}
