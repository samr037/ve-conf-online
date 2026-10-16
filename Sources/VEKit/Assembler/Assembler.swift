import Foundation

// The VLL macro assembler (docs/re/03-assembler.md §1, §5–§10). The CPU instruction set is not here:
// it is defined as macros in asfStart.vll that emit bytes through DATA.

public struct AssemblerMessage: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Sendable { case message, warning, error, fatal }
    public var kind: Kind
    public var text: String
    public var position: String
    public var description: String { "\(kind) \(position): \(text)" }
}

final class LabelTable {
    var items: [String: Label] = [:]
    subscript(name: String) -> Label? {
        get { items[name] }
        set { items[name] = newValue }
    }
}

struct Macro: Equatable {
    var name: String
    var minParams: Int
    var params: [(name: String, isString: Bool)]
    var body: [SourceLine]

    static func == (a: Macro, b: Macro) -> Bool {
        a.name == b.name && a.minParams == b.minParams && a.body == b.body
            && a.params.map(\.name) == b.params.map(\.name) && a.params.map(\.isString) == b.params.map(\.isString)
    }
}

/// One executing line list: a `.SOURCE` file, a macro body or the root.
final class Frame {
    let list: LineList
    let path: String
    var index = 0
    var conditions: [Character] = []
    var whiles: [(line: Int, k: Int)] = []
    var pendingWhile: [Int: Int] = [:]

    init(list: LineList, path: String) {
        self.list = list
        self.path = path
    }

    /// Unique, deterministic id of the line being executed (call-site path; includes `.WHILE` iterations).
    var site: String {
        path + "|" + String(index) + whiles.map { "w\($0.line).\($0.k)" }.joined()
    }
}

final class Scope {
    let path: String
    let labels: LabelTable
    var macros: [String: Macro] = [:]
    var pub: Set<String> = []
    var ext: Set<String> = []
    init(path: String, labels: LabelTable) {
        self.path = path
        self.labels = labels
    }
}

class Assembler: CalculatorHost {
    // Label lists (§5.2).
    var global = LabelTable()
    var publics = LabelTable()
    var scopeRegistry: [String: LabelTable] = [:]
    var localRegistry: [String: LabelTable] = [:]
    var scope: Scope
    var frameLabels: LabelTable?       // F: macro parameters
    var macroLocals: LabelTable?       // K: .LOCAL space of the current expansion
    var localNames: Set<String> = []   // .LOCAL list
    var globalDepth = 0
    var globalMacros: [String: Macro] = [:]
    var macroDepth = 0

    private(set) var pass = 0
    var stopped = false
    var success = true
    var messages: [AssemblerMessage] = []
    var currentFrame: Frame?

    lazy var calculator = Calculator(host: self)

    /// Supplies the text of a `.SOURCE` / `.INSERT` file.
    var sourceProvider: (String) -> [UInt8]? = { _ in nil }

    init() {
        scope = Scope(path: "root", labels: LabelTable())
    }

    // MARK: Driver (§10.1)

    /// Two passes over the root list. Returns the emitted bytes ($CODE) of the last pass.
    @discardableResult
    func assemble(root: LineList, passes: Int = 2) -> Bool {
        for p in 1...passes {
            reset(firstPass: p == 1)
            pass = p
            willStartPass(p)
            run(root, path: "root", newScope: true)
            if stopped { break }
        }
        return success && !stopped
    }

    func willStartPass(_ pass: Int) {}

    func reset(firstPass: Bool) {
        if firstPass {
            global = LabelTable()
            publics = LabelTable()
            scopeRegistry = [:]
            localRegistry = [:]
            stopped = false
        }
        global["$"] = Label(value: .int(0), flags: 2)
        global["$CODE"] = Label(value: .string([]), flags: 2)
        global["$LISTING"] = Label(value: .string([]), flags: 2)
        globalDepth = 0
        globalMacros = [:]
        macroDepth = 0
        frameLabels = nil
        macroLocals = nil
        localNames = []
        if !stopped { messages = []; success = true }
    }

    public var code: [UInt8] {
        if case .string(let s)? = global["$CODE"]?.value { return s }
        return []
    }

    // MARK: Executing line lists

    func run(_ list: LineList, path: String, newScope: Bool) {
        let frame = Frame(list: list, path: path)
        let savedScope = scope
        if newScope {
            let labels = scopeRegistry[path] ?? LabelTable()
            scopeRegistry[path] = labels
            scope = Scope(path: path, labels: labels)
        }
        let savedFrame = currentFrame
        currentFrame = frame
        while !stopped {
            frame.index += 1
            guard frame.index < list.count else { break }
            process(list.line(frame.index), in: frame)
        }
        if !stopped {
            if frame.conditions.contains("w") { report("expected .ENDW") } else if !frame.conditions.isEmpty { report("expected .ENDIF") }
        }
        currentFrame = savedFrame
        if newScope { scope = savedScope }
    }

    func process(_ line: SourceLine, in frame: Frame) {
        if let e = line.error { report(e); return }
        let op = line.opcode.lowercased()
        if let handler = directive(op) {
            handler(line, frame)
            return
        }
        if !line.label.isEmpty {
            guard line.label.hasSuffix(":") else { report("expected \":\" after label name"); return }
            let name = String(line.label.dropLast())
            guard !name.isEmpty else { report("no labelname specified"); return }
            define(name, .int(location), force: false, flags: 1)
        }
        guard !line.opcode.isEmpty else { return }
        if let m = scope.macros[op] ?? globalMacros[op] {
            expand(m, line, in: frame)
        } else {
            report("cannot interpret opcode field")
        }
    }

    // MARK: Errors (§10.3)

    func report(_ text: String, kind: AssemblerMessage.Kind = .error, fatal: Bool = false) {
        if stopped { return }
        if pass == 1 && !fatal { return }
        if fatal { stopped = true }
        if kind == .error || kind == .fatal || fatal { success = false }
        messages.append(AssemblerMessage(kind: fatal ? .fatal : kind, text: text, position: currentFrame.map { "\($0.list.header):\($0.index)" } ?? ""))
    }

    /// Evaluates a parameter; failures are reported as *calculation error* (pass 2) unless `report` is false.
    func evaluate(_ text: [UInt8], report shouldReport: Bool = true) -> Value? {
        let e = calculator.evaluate(text)
        for w in e.warnings where shouldReport { report(w, kind: .warning) }
        if !e.ok {
            if shouldReport { report("calculation error: \(e.error ?? "")") }
            return nil
        }
        return e.value
    }

    func evaluate(_ text: String) -> Value? { evaluate(Latin1.encode(text)) }

    // MARK: Labels (§5.3, §5.4)

    func lookup(_ name: String) -> Label? {
        if localNames.contains(name) { return macroLocals?[name] }
        if let f = frameLabels, let l = f[name] { return l }
        if scope.pub.contains(name) || scope.ext.contains(name) { return publics[name] }
        return scope.labels[name] ?? global[name]
    }

    static func isLegalName(_ name: String) -> Bool {
        guard let first = name.utf8.first else { return false }
        let lower = name.lowercased()
        if lower == "true" || lower == "false" { return false }
        func letter(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }
        guard letter(first) else { return false }
        return name.utf8.dropFirst().allSatisfy { letter($0) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x23 }
    }

    func define(_ rawName: String, _ value: Value?, force: Bool, flags: Int) {
        guard let value else { return }
        if let sys = global[rawName], sys.isSystem {
            guard sys.value.map({ $0.sameClass(value) }) ?? true else { report("Expression returns wrong type"); return }
            sys.value = value
            return
        }
        // User function definition: Name(p1,p2,…) with a string body.
        var name = rawName
        var params: [String]? = nil
        if let open = rawName.firstIndex(of: "(") {
            guard rawName.hasSuffix(")") else { report("Not a legal function defintion (parameter list not correct or expression is not a string)"); return }
            let base = String(rawName[..<open])
            let list = rawName[rawName.index(after: open)..<rawName.index(before: rawName.endIndex)]
            let ps = list.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            guard Self.isLegalName(base), !ps.isEmpty, ps.allSatisfy(Self.isLegalName) else {
                report("Not a legal function defintion (parameter list not correct or expression is not a string)"); return
            }
            guard value.isString else { report("string expression expected"); return }
            name = base + "("
            params = ps
        } else if !Self.isLegalName(rawName) {
            report("illegal label name"); return
        }

        let target: LabelTable
        if globalDepth > 0 {
            target = global
        } else if flags & 1 == 0, let g = global[name], !g.isFixed {
            target = global
        } else {
            if let f = frameLabels, f[name] != nil { report("Cannot redefine a macro parameter"); return }
            if localNames.contains(name) {
                if macroLocals == nil { macroLocals = LabelTable() }
                target = macroLocals!
            } else if scope.pub.contains(name) || scope.ext.contains(name) {
                target = publics
            } else {
                target = scope.labels
            }
        }
        guard let old = target[name] else {
            if scope.ext.contains(name) {
                report(flags & 1 == 0 ? "trying to re-define a non-defined external" : "It is not allowed to define the value of an external")
                return
            }
            target[name] = Label(value: value, flags: flags, params: params)
            return
        }
        if force { return }
        if (flags == 0 && old.isFixed) || (flags != 0 && flags != old.flags) {
            report("Labeltype (fixed/variable) different from previous pass"); return
        }
        if !old.isFixed {
            old.value = value
            if params != nil { old.params = params }
        } else if old.value != value || (params != nil && old.params != params) {
            report("label value different from first assignment. Cannot re-define the value for this type of label")
        }
    }

    // MARK: Code generation (§9)

    var location: Int32 {
        if case .int(let i)? = global["$"]?.value { return i }
        return 0
    }

    func emit(_ byte: UInt8) {
        guard let codeLabel = global["$CODE"], let locLabel = global["$"],
              case .string(var code)? = codeLabel.value, case .int(let loc)? = locLabel.value else { return }
        codeLabel.value = nil   // release the buffer so the append below does not copy it
        let at = Int(loc)
        if at >= 0 {
            if code.count <= at { code += [UInt8](repeating: 0xFF, count: at + 1 - code.count) }
            code[at] = byte
        }
        codeLabel.value = .string(code)
        locLabel.value = .int(loc &+ 1)
    }

    // MARK: Directives (§6)

    typealias Handler = (SourceLine, Frame) -> Void

    func directive(_ op: String) -> Handler? {
        switch op {
        case ".equ": return equ
        case ".set": return set
        case ".unset": return unset
        case ".macro": return macroDefinition
        case ".endm": return { _, _ in self.report("unexpected .ENDM") }
        case ".if", ".ifnot", ".ifdef", ".ifndef": return conditional
        case ".else": return elseDirective
        case ".endif": return endif
        case ".while": return whileDirective
        case ".endw": return endw
        case ".local": return local
        case ".nop", ".list", ".nolist", ".defer", ".nodefer": return { _, _ in }
        case "data": return data
        case ".renmacro": return renameMacro
        case ".ext": return { l, _ in l.params.forEach { self.scope.ext.insert(String(decoding: $0, as: Latin1.self)) } }
        case ".pub": return { l, _ in l.params.forEach { self.scope.pub.insert(String(decoding: $0, as: Latin1.self)) } }
        case ".messg": return { l, _ in self.message(l, kind: .message, fatal: false) }
        case ".error": return { l, _ in self.message(l, kind: .error, fatal: false) }
        case ".ferror": return { l, _ in self.message(l, kind: .fatal, fatal: true) }
        case ".assemble": return assembleDirective
        case ".source": return { l, f in self.include(l, f, newScope: true) }
        case ".insert": return { l, f in self.include(l, f, newScope: false) }
        case ".global": return globalDirective
        default: return nil
        }
    }

    func codeLabel(_ line: SourceLine) {
        guard !line.label.isEmpty else { return }
        guard line.label.hasSuffix(":") else { report("expected \":\" after label name"); return }
        define(String(line.label.dropLast()), .int(location), force: false, flags: 1)
    }

    func needsLabel(_ line: SourceLine) -> Bool {
        if line.label.isEmpty { report("label expected"); return false }
        return true
    }

    func params(_ line: SourceLine, _ min: Int, _ max: Int) -> Bool {
        if line.params.count > max { report("too many parameters"); return false }
        if line.params.count < min { report("too few parameters"); return false }
        return true
    }

    private func equ(_ line: SourceLine, _ frame: Frame) {
        guard needsLabel(line), params(line, 1, 1) else { return }
        define(line.label, evaluate(line.params[0]), force: false, flags: 1)
    }

    private func set(_ line: SourceLine, _ frame: Frame) {
        guard needsLabel(line), params(line, 1, 3) else { return }
        var flags = 0
        var force = false
        if line.params.count >= 2 {
            switch evaluate(line.params[1]) {
            case .int(let f)? where line.params.count == 3 || true: flags = Int(f)
            case .bool(let b)? where line.params.count == 2: force = b
            case .some: report(line.params.count == 3 ? "result of expression must be integer" : "result of expression must be boolean or integer"); return
            case nil: return
            }
        }
        if line.params.count == 3 {
            guard case .bool(let b)? = evaluate(line.params[2]) else { report("result of expression must be boolean"); return }
            force = b
        }
        define(line.label, evaluate(line.params[0]), force: force, flags: flags)
    }

    private func unset(_ line: SourceLine, _ frame: Frame) {
        guard needsLabel(line) else { return }
        if let g = global[line.label], g.isSystem { report("Cannot remove a system label"); return }
        if let l = lookup(line.label), !l.isFixed {
            if localNames.contains(line.label) { macroLocals?[line.label] = nil } else if scope.labels[line.label] != nil {
                scope.labels[line.label] = nil
            } else { global[line.label] = nil }
        }
    }

    private func local(_ line: SourceLine, _ frame: Frame) {
        guard macroDepth > 0 else { report("only allowed inside a MACRO"); return }
        for p in line.params {
            var name = String(decoding: p, as: Latin1.self)
            if name.hasSuffix("(") { name.removeLast() ; localNames.insert(name + "(") ; continue }
            guard Self.isLegalName(name) else { report("illegal label name"); continue }
            localNames.insert(name)
        }
        if macroLocals == nil { macroLocals = LabelTable() }
    }

    private func data(_ line: SourceLine, _ frame: Frame) {
        codeLabel(line)
        guard params(line, 1, 1) else { return }
        switch evaluate(line.params[0], report: pass > 1) {
        case .int(let v)?: emit(UInt8(truncatingIfNeeded: v))
        case .some: report("result of expression must be integer"); emit(0)
        case nil:
            if pass > 1 { report("result of expression still undefined in last pass") }
            emit(0)
        }
    }

    private func message(_ line: SourceLine, kind: AssemblerMessage.Kind, fatal: Bool) {
        guard let p = line.params.first else { return }
        let text = evaluate(p).map { String(decoding: $0.asText, as: Latin1.self) } ?? String(decoding: p, as: Latin1.self)
        report(text, kind: kind, fatal: fatal)
    }

    private func globalDirective(_ line: SourceLine, _ frame: Frame) {
        guard params(line, 1, 1), case .bool(let on)? = evaluate(line.params[0]) else { return }
        if on { globalDepth += 1 } else if globalDepth > 0 { globalDepth -= 1 } else { report(".GLOBAL not properly nested") }
    }

    private func assembleDirective(_ line: SourceLine, _ frame: Frame) {
        codeLabel(line)
        guard params(line, 1, 1) else { return }
        guard case .string(let text)? = evaluate(line.params[0]) else { report("string expression expected"); return }
        process(SourceLine(text), in: frame)
    }

    func include(_ line: SourceLine, _ frame: Frame, newScope: Bool) {
        codeLabel(line)
        guard params(line, 1, 1), case .string(let nameBytes)? = evaluate(line.params[0]) else { return }
        let name = String(decoding: nameBytes, as: Latin1.self)
        guard let text = sourceProvider(name) else { report("Cannot open file"); return }
        let list = LineList(header: name, text: text)
        if newScope {
            let saved = (frameLabels, macroLocals, localNames, scope)
            frameLabels = nil; macroLocals = nil; localNames = []
            willEnterSource(name)
            run(list, path: frame.site + "#" + name, newScope: true)
            didLeaveSource(name)
            (frameLabels, macroLocals, localNames, scope) = saved
        } else {
            // .INSERT shares the current scope; conditionals are tracked by the inserted list itself.
            let inserted = Frame(list: list, path: frame.site + "+" + name)
            let saved = currentFrame
            currentFrame = inserted
            while !stopped {
                inserted.index += 1
                guard inserted.index < list.count else { break }
                process(list.line(inserted.index), in: inserted)
            }
            currentFrame = saved
        }
    }

    func willEnterSource(_ name: String) {}
    func didLeaveSource(_ name: String) {}

    // MARK: Conditionals and loops (§8)

    private static let ifOps: Set<String> = [".IF", ".IFDEF", ".IFNDEF", ".IFNOT"]

    enum SkipEnd { case elseLine, endif, endw }

    /// Skip mode: find the matching .ELSE/.ENDIF (for an .IF) or .ENDW (for a .WHILE). Opcode compares are exact.
    func skip(_ frame: Frame, forWhile: Bool, acceptElse: Bool) -> (SkipEnd, Int)? {
        var nested: [Character] = []
        var j = frame.index + 1
        while j < frame.list.count {
            let op = frame.list.line(j).opcode
            if Self.ifOps.contains(op) { nested.append("i") } else if op == ".WHILE" { nested.append("w") } else if op == ".ENDIF" {
                if nested.isEmpty { if !forWhile { return (.endif, j) } } else { nested.removeLast() }
            } else if op == ".ENDW" {
                if nested.isEmpty { if forWhile { return (.endw, j) } } else { nested.removeLast() }
            } else if op == ".ELSE" && nested.isEmpty && !forWhile && acceptElse {
                return (.elseLine, j)
            }
            j += 1
        }
        report(forWhile ? "expected .ENDW" : "expected .ENDIF")
        return nil
    }

    private func conditional(_ line: SourceLine, _ frame: Frame) {
        guard params(line, 1, 1) else { return }
        let op = line.opcode.lowercased()
        var truth: Bool
        switch op {
        case ".ifdef", ".ifndef":
            let ok = calculator.evaluate(line.params[0]).ok
            truth = op == ".ifdef" ? ok : !ok
        default:
            switch evaluate(line.params[0]) {
            case .bool(let b)?: truth = op == ".if" ? b : !b
            case .some: report("result of expression must be boolean"); truth = false
            case nil: truth = false
            }
        }
        if truth {
            frame.conditions.append("i")
        } else if let (end, j) = skip(frame, forWhile: false, acceptElse: true) {
            if end == .elseLine { frame.conditions.append("e") }
            frame.index = j
        } else {
            frame.index = frame.list.count
        }
    }

    private func elseDirective(_ line: SourceLine, _ frame: Frame) {
        guard frame.conditions.last == "i" else { report("unexpected .ELSE"); return }
        frame.conditions.removeLast()
        if let (_, j) = skip(frame, forWhile: false, acceptElse: false) { frame.index = j } else { frame.index = frame.list.count }
    }

    private func endif(_ line: SourceLine, _ frame: Frame) {
        guard let top = frame.conditions.last, top == "i" || top == "e" else { report("unexpected .ENDIF"); return }
        frame.conditions.removeLast()
    }

    private func whileDirective(_ line: SourceLine, _ frame: Frame) {
        guard params(line, 1, 1) else { return }
        let k = frame.pendingWhile.removeValue(forKey: frame.index) ?? 1
        var truth = false
        switch evaluate(line.params[0]) {
        case .bool(let b)?: truth = b
        case .some: report("result of expression must be boolean")
        case nil: break
        }
        if truth {
            frame.conditions.append("w")
            frame.whiles.append((frame.index, k))
        } else if let (_, j) = skip(frame, forWhile: true, acceptElse: false) {
            frame.index = j
        } else {
            frame.index = frame.list.count
        }
    }

    private func endw(_ line: SourceLine, _ frame: Frame) {
        guard frame.conditions.last == "w", let w = frame.whiles.popLast() else { report("unexpected .ENDW"); return }
        frame.conditions.removeLast()
        if w.k <= 1024 {
            frame.pendingWhile[w.line] = w.k + 1
            frame.index = w.line - 1
        } else {
            report("while loop must stop within 1024 iterations")
        }
    }

    // MARK: Macros (§7)

    static func isLegalMacroName(_ name: String) -> Bool {
        guard let first = name.utf8.first else { return false }
        func letter(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }
        guard letter(first) else { return false }
        return name.utf8.dropFirst().allSatisfy {
            letter($0) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x23 || [0x2B, 0x2D, 0x40, 0x5B, 0x5D].contains($0)
        }
    }

    private func macroDefinition(_ line: SourceLine, _ frame: Frame) {
        // Record the body first so the stream always moves past .ENDM.
        var body: [SourceLine] = []
        var j = frame.index + 1
        var closed = false
        while j < frame.list.count {
            let l = frame.list.line(j)
            if l.opcode == ".ENDM" { closed = true; break }
            body.append(l)
            j += 1
        }
        frame.index = j
        guard closed else { report("expected .ENDM"); return }
        guard needsLabel(line) else { return }
        let name = line.label
        guard directive(name.lowercased()) == nil, Self.isLegalMacroName(name) else { report("illegal macro name"); return }
        var ps = line.params.map { String(decoding: $0, as: Latin1.self) }
        var minimum: Int? = nil
        if let first = ps.first, let c = first.utf8.first, c >= 0x30 && c <= 0x39 {
            guard case .int(let n)? = evaluate(line.params[0]) else { report("illegal label name"); return }
            minimum = Int(n)
            ps.removeFirst()
        }
        var params: [(String, Bool)] = []
        for p in ps {
            let isString = p.hasPrefix("s:")
            let n = isString ? String(p.dropFirst(2)) : p
            guard Self.isLegalName(n) else { report("illegal label name"); return }
            guard n != "Params", !params.contains(where: { $0.0 == n }) else {
                report("A parameter name is used twice (mind the implicit 'Params' parameter"); return
            }
            params.append((n, isString))
        }
        if let m = minimum, m > params.count {
            report("Specified a minimum nr of parameters higher than the nr of parameters in the list"); return
        }
        let macro = Macro(name: name, minParams: minimum ?? params.count, params: params, body: body)
        let key = name.lowercased()
        if globalDepth > 0 {
            if let old = globalMacros[key], old != macro { report("MACRO exists already and defintion differs from previous!"); return }
            globalMacros[key] = macro
        } else {
            if let old = scope.macros[key], old != macro { report("MACRO exists already and defintion differs from previous!"); return }
            scope.macros[key] = macro
        }
    }

    private func renameMacro(_ line: SourceLine, _ frame: Frame) {
        guard params(line, 2, 2) else { return }
        let old = String(decoding: line.params[0], as: Latin1.self).lowercased()
        let new = String(decoding: line.params[1], as: Latin1.self)
        let rename: (inout [String: Macro]) -> Void = { table in
            guard var m = table.removeValue(forKey: old) else { self.report("cannot rename a non-existing macro"); return }
            if new.lowercased() != old { m.name = new; table[new.lowercased()] = m }
        }
        if globalDepth > 0 { rename(&globalMacros) } else { rename(&scope.macros) }
    }

    func expand(_ macro: Macro, _ line: SourceLine, in frame: Frame) {
        guard macroDepth < 255 else { report("Macro nesting not allowed deeper than 255"); return }
        let actual = line.params.count
        guard actual >= macro.minParams, actual <= macro.params.count else {
            report("nr of parameters in macro call less than required minimum or more than specifed during macro defintion")
            return
        }
        var newFrame: LabelTable? = nil
        if actual > 0 || !macro.params.isEmpty {
            let f = LabelTable()
            f["Params"] = Label(value: .int(Int32(actual)), flags: 0)
            for (i, p) in macro.params.enumerated() {
                if i < actual {
                    let raw = line.params[i]
                    f[p.name] = Label(value: p.isString ? .string(raw) : evaluate(raw), flags: 0)
                } else {
                    f[p.name] = Label(value: nil, flags: 0)
                }
            }
            var joined: [UInt8] = []
            for (i, p) in line.params.enumerated() { if i > 0 { joined.append(0x2C) }; joined += p }
            f["$ParamString"] = Label(value: .string(joined), flags: 0)
            newFrame = f
        }
        let site = frame.site + "@" + macro.name
        let saved = (frameLabels, macroLocals, localNames)
        frameLabels = newFrame
        macroLocals = localRegistry[site]
        localNames = []
        macroDepth += 1
        let body = LineList(header: macro.name, lines: macro.body)
        let inner = Frame(list: body, path: site)
        let savedFrame = currentFrame
        currentFrame = inner
        while !stopped {
            inner.index += 1
            guard inner.index < body.count else { break }
            process(body.line(inner.index), in: inner)
        }
        if !stopped && !inner.conditions.isEmpty {
            report(inner.conditions.contains("w") ? "expected .ENDW" : "expected .ENDIF")
        }
        currentFrame = savedFrame
        macroDepth -= 1
        if let k = macroLocals { localRegistry[site] = k }
        (frameLabels, macroLocals, localNames) = saved
    }

    // MARK: CalculatorHost

    func readBack(bytes: Int, at address: Int32) -> Result<Int32, CalcError> { .success(-1) }
    func assistantText(_ key: Value) -> [UInt8]? { nil }
    func assistantLabelValue(_ name: String) -> Int32? { nil }
    func noteReadBackUsed() {}
}
