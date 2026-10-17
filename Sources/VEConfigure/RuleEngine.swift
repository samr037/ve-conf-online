import Foundation
import VEKit

// MARK: - Expressions

/// The catalog's `enabledWhen` / `visibleWhen` / rule expression language (docs/re/04-ui-rules.md):
/// identifiers `EPROM_*`, `EBIT_*`, `ctl.X`, `device.x`, `app.x`, `original.X`; operators
/// `! && || == != < <= > >= + - * / &`, `x in [a, b]`, parentheses; numbers, strings, true/false.
/// Anything the engine cannot know evaluates to nil ("unknown"); callers choose the safe default.
indirect enum Expr {
    case number(Double)
    case string(String)
    case ident(String)
    case call(String, [Expr])
    case list([Expr])
    case not(Expr)
    case negate(Expr)
    case binary(String, Expr, Expr)
}

enum EValue: Equatable {
    case number(Double)
    case string(String)
    case list([EValue])

    var number: Double? { if case .number(let n) = self { n } else { nil } }
    var truthy: Bool {
        switch self {
        case .number(let n): n != 0
        case .string(let s): !s.isEmpty
        case .list(let l): !l.isEmpty
        }
    }
    static func bool(_ b: Bool) -> EValue { .number(b ? 1 : 0) }
}

enum ExprParser {
    private static var cache: [String: Expr?] = [:]
    private static let lock = NSLock()

    static func parse(_ source: String) -> Expr? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[source] { return hit }
        var p = Parser(tokens: tokenize(source))
        let e = p.parseExpression()
        let result = (e != nil && p.atEnd) ? e : nil
        cache[source] = result
        return result
    }

    enum Token: Equatable { case num(Double), str(String), ident(String), op(String) }

    static func tokenize(_ s: String) -> [Token] {
        var out: [Token] = []
        let chars = Array(s)
        var i = 0
        func peek(_ o: Int = 0) -> Character? { i + o < chars.count ? chars[i + o] : nil }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && peek(1)?.isNumber == true) {
                var j = i
                if c == "0", peek(1) == "x" || peek(1) == "X" {
                    j = i + 2
                    while j < chars.count, chars[j].isHexDigit { j += 1 }
                    out.append(.num(Double(Int(String(chars[(i + 2)..<j]), radix: 16) ?? 0)))
                } else {
                    while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "e" { j += 1 }
                    out.append(.num(Double(String(chars[i..<j])) ?? .nan))
                }
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." { j += 1 }
                out.append(.ident(String(chars[i..<j])))
                i = j
                continue
            }
            if c == "\"" {
                var j = i + 1
                while j < chars.count, chars[j] != "\"" { j += 1 }
                out.append(.str(String(chars[(i + 1)..<min(j, chars.count)])))
                i = j + 1
                continue
            }
            let two = peek(1).map { String([c, $0]) } ?? ""
            if ["&&", "||", "==", "!=", "<=", ">=", "->"].contains(two) { out.append(.op(two)); i += 2; continue }
            out.append(.op(String(c)))
            i += 1
        }
        return out
    }

    struct Parser {
        var tokens: [Token]
        var pos = 0
        var atEnd: Bool { pos == tokens.count }

        mutating func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }
        mutating func eat(_ op: String) -> Bool {
            if peek() == .op(op) { pos += 1; return true }
            return false
        }

        mutating func parseExpression() -> Expr? { parseOr() }

        mutating func parseOr() -> Expr? {
            guard var l = parseAnd() else { return nil }
            while eat("||") { guard let r = parseAnd() else { return nil }; l = .binary("||", l, r) }
            return l
        }
        mutating func parseAnd() -> Expr? {
            guard var l = parseEquality() else { return nil }
            while eat("&&") { guard let r = parseEquality() else { return nil }; l = .binary("&&", l, r) }
            return l
        }
        mutating func parseEquality() -> Expr? {
            guard var l = parseRelational() else { return nil }
            while true {
                if eat("==") { guard let r = parseRelational() else { return nil }; l = .binary("==", l, r) }
                else if eat("!=") { guard let r = parseRelational() else { return nil }; l = .binary("!=", l, r) }
                else { return l }
            }
        }
        mutating func parseRelational() -> Expr? {
            guard var l = parseBitAnd() else { return nil }
            while true {
                var matched = false
                for op in ["<=", ">=", "<", ">"] where eat(op) {
                    guard let r = parseBitAnd() else { return nil }
                    l = .binary(op, l, r); matched = true; break
                }
                if !matched, peek() == .ident("in") {
                    pos += 1
                    guard let r = parseBitAnd() else { return nil }
                    l = .binary("in", l, r); matched = true
                }
                if !matched { return l }
            }
        }
        mutating func parseBitAnd() -> Expr? {
            guard var l = parseAdditive() else { return nil }
            while peek() == .op("&") { pos += 1; guard let r = parseAdditive() else { return nil }; l = .binary("&", l, r) }
            return l
        }
        mutating func parseAdditive() -> Expr? {
            guard var l = parseMultiplicative() else { return nil }
            while true {
                if eat("+") { guard let r = parseMultiplicative() else { return nil }; l = .binary("+", l, r) }
                else if eat("-") { guard let r = parseMultiplicative() else { return nil }; l = .binary("-", l, r) }
                else { return l }
            }
        }
        mutating func parseMultiplicative() -> Expr? {
            guard var l = parseUnary() else { return nil }
            while true {
                if eat("*") { guard let r = parseUnary() else { return nil }; l = .binary("*", l, r) }
                else if eat("/") { guard let r = parseUnary() else { return nil }; l = .binary("/", l, r) }
                else { return l }
            }
        }
        mutating func parseUnary() -> Expr? {
            if eat("!") { return parseUnary().map { .not($0) } }
            if eat("-") { return parseUnary().map { .negate($0) } }
            return parsePrimary()
        }
        mutating func parsePrimary() -> Expr? {
            guard let t = peek() else { return nil }
            pos += 1
            switch t {
            case .num(let n): return .number(n)
            case .str(let s): return .string(s)
            case .ident(let name):
                if name == "true" { return .number(1) }
                if name == "false" { return .number(0) }
                if eat("(") {
                    var args: [Expr] = []
                    if !eat(")") {
                        repeat { guard let a = parseExpression() else { return nil }; args.append(a) } while eat(",")
                        guard eat(")") else { return nil }
                    }
                    return .call(name, args)
                }
                return .ident(name)
            case .op("("):
                guard let e = parseExpression(), eat(")") else { return nil }
                return e
            case .op("["):
                var items: [Expr] = []
                if !eat("]") {
                    repeat { guard let a = parseExpression() else { return nil }; items.append(a) } while eat(",")
                    guard eat("]") else { return nil }
                }
                return .list(items)
            default: return nil
            }
        }
    }
}

// MARK: - Context

/// Per-document state that is not stored in the file (VE Configure keeps it in form flags).
///
/// There is deliberately no "grid password entered" state. VE Configure checks the grid-code password against a
/// secret built into VEConfig.exe (FUN_005410b4 → FUN_004d5c30); this app does not embed that secret, so it cannot
/// verify a password and never unlocks grid-code protected settings (fail safe, docs/re/04-ui-rules.md §3.3).
struct SessionState: Equatable {
    /// "Unhide charge parameters" was pressed on an inverter-only device.
    var chargerUnhidden = false
}

/// Everything an expression may look at: the live configuration, the loaded one, and session state.
struct RuleContext {
    let config: DeviceConfiguration
    let baseline: DeviceConfiguration
    let session: SessionState
    var catalog: Catalog { .shared }

    /// nil = cannot be decided offline.
    func evaluate(_ source: String) -> Bool? {
        guard let e = ExprParser.parse(source) else { return nil }
        return eval(e)?.truthy
    }

    /// All expressions true; unknown counts as `unknownIs`.
    func all(_ exprs: [String]?, unknownIs: Bool = true) -> Bool {
        (exprs ?? []).allSatisfy { evaluate($0) ?? unknownIs }
    }

    func eval(_ e: Expr) -> EValue? {
        switch e {
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .list(let items):
            let v = items.compactMap(eval)
            return v.count == items.count ? .list(v) : nil
        case .ident(let name): return resolve(name)
        case .call(let name, let args): return call(name, args)
        case .not(let x): return eval(x).map { .bool(!$0.truthy) }
        case .negate(let x): return eval(x)?.number.map { .number(-$0) }
        case .binary(let op, let a, let b):
            if op == "&&" {
                let l = eval(a)
                if l?.truthy == false { return .bool(false) }
                let r = eval(b)
                if r?.truthy == false { return .bool(false) }
                guard l != nil, r != nil else { return nil }
                return .bool(true)
            }
            if op == "||" {
                let l = eval(a)
                if l?.truthy == true { return .bool(true) }
                let r = eval(b)
                if r?.truthy == true { return .bool(true) }
                guard l != nil, r != nil else { return nil }
                return .bool(false)
            }
            guard let l = eval(a), let r = eval(b) else { return nil }
            switch op {
            case "==": return .bool(equal(l, r))
            case "!=": return .bool(!equal(l, r))
            case "in":
                guard case .list(let items) = r else { return nil }
                return .bool(items.contains { equal(l, $0) })
            default:
                guard let x = l.number, let y = r.number else { return nil }
                switch op {
                case "<": return .bool(x < y)
                case "<=": return .bool(x <= y)
                case ">": return .bool(x > y)
                case ">=": return .bool(x >= y)
                case "+": return .number(x + y)
                case "-": return .number(x - y)
                case "*": return .number(x * y)
                case "/": return y == 0 ? nil : .number(x / y)
                case "&": return .number(Double(Int(x) & Int(y)))
                default: return nil
                }
            }
        }
    }

    private func equal(_ a: EValue, _ b: EValue) -> Bool {
        if let x = a.number, let y = b.number { return abs(x - y) < 1e-9 }
        return a == b
    }

    // MARK: Identifiers

    private func resolve(_ name: String) -> EValue? {
        if name.hasPrefix("original.") { return variableValue(String(name.dropFirst(9)), in: baseline) }
        if let v = variableValue(name, in: config) { return v }
        if name.hasPrefix("ctl.") { return controlValue(String(name.dropFirst(4))) }
        if name.hasPrefix("device.") { return deviceFact(String(name.dropFirst(7))) }
        if name.hasPrefix("app.") {
            switch name.dropFirst(4) {
            case "gridPasswordEntered": return .bool(false)   // never: see SessionState
            case "assistantFilesOk", "assistantsUnlocked", "remoteFile": return .bool(true)
            case "assistantCount": return .number(Double(AssistantDirectory(config).ids.count))
            default: return nil
            }
        }
        if name == "session.gridSelectionWasFree" { return .bool(!Access.gridCodeNeedsPassword(self)) }
        return nil
    }

    func variableValue(_ name: String, in c: DeviceConfiguration) -> EValue? {
        guard let ref = catalog.variables[name] else { return nil }
        switch ref.kind {
        case .flag: return c.supportsFlag(ref.index) || ref.index >= 64 ? .bool(c.flag(ref.index)) : .bool(c.flag(ref.index))
        case .setting:
            if let control = catalog.settingControls[ref.index], let v = ValueCodec(control: control)?.display(c) { return .number(v) }
            return c.value(ref.index).map(EValue.number) ?? .number(Double(c.raw(ref.index)))
        default: return nil
        }
    }

    private func controlValue(_ path: String) -> EValue? {
        var parts = path.split(separator: ".").map(String.init)
        let name = parts.removeFirst()
        let prop = parts.first
        switch (name, prop) {
        case ("gridParamsValid", _): return .bool(GridPages.paramsValid(config))
        case ("InverterWarningPanel", "visible"): return .bool(config.isInverterOnly && !session.chargerUnhidden)
        case ("EnableBatteryMonitorCheckBox", "checked"): return .bool(config.raw(64) != 0)
        case ("EnableBatteryMonitorCheckBox", "visible"):
            return .bool(config.info.info(64)?.isSupported == true && config.info.info(64)?.minRaw == 0)
        case ("VirtualSwitchPageControl", "visible"): return .bool(config.info.info(15)?.isSupported == true)
        case ("ManualChargeCharacteristicComboBox", _):
            return .string(config.raw(10) == 1 ? "Fixed" : config.raw(10) == 2 ? "Adaptive" : "Adaptive + BatterySafe")
        default: break
        }
        guard let control = catalog.controls[name] else { return nil }
        if prop == "visible" { return .bool(Visibility.isVisible(control, self)) }
        if control.kind == .localToggle { return LocalControls.isChecked(control.name, config).map(EValue.bool) }
        guard let codec = ValueCodec(control: control) else { return nil }
        if prop == "raw" || control.kind != .number { return codec.raw(config).map { .number(Double($0)) } }
        return codec.display(config).map(EValue.number)
    }

    private func deviceFact(_ name: String) -> EValue? {
        switch name {
        case "firmwareVersion": return .number(Double(config.firmware.version))
        case "firmwareType", "productType": return .number(Double(config.firmware.type))
        case "firmwareNumber": return .number(Double(config.firmware.number))
        case "dcVoltageClass": return .number(Double(config.dcVoltageClass))
        case "acVoltageClass": return .number(Double(config.acVoltageClass))
        case "hasCharger": return .bool(!config.isInverterOnly)
        case "acInputCount": return .number(config.info.info(49)?.isSupported == true ? 2 : 1)
        case "isInverterOnly": return .bool(config.isInverterOnly)
        case "configResponseChar": return .number(Double(config.info.configResponseChar))
        default: return nil   // isGen2, hasDipSwitches, hasInternalInterfaceProtection… need the device table
        }
    }

    private func call(_ name: String, _ args: [Expr]) -> EValue? {
        func varRef(_ i: Int) -> VariableRef? {
            if case .ident(let n) = args[safe: i] { return catalog.variables[n] }
            return nil
        }
        func number(_ i: Int) -> Int? { args[safe: i].flatMap(eval)?.number.map { Int($0) } }
        switch name {
        case "device.supports":
            guard let r = varRef(0) else { return nil }
            return .bool(config.supports(r))
        case "device.min":
            guard let r = varRef(0), r.kind == .setting else { return nil }
            return config.info.info(r.index).map { .number(Double($0.minRaw)) }
        case "device.access":
            guard let r = varRef(0) else { return nil }
            return .number(Double(Access.attribute(r, config)))
        case "raw":
            if case .ident(let n) = args[safe: 0] {
                if let r = catalog.variables[n] {
                    return r.kind == .flag ? .bool(config.flag(r.index)) : .number(Double(config.raw(r.index)))
                }
                if n.hasPrefix("ctl."), let c = catalog.controls[String(n.dropFirst(4)).components(separatedBy: ".")[0]] {
                    return ValueCodec(control: c)?.raw(config).map { .number(Double($0)) }
                }
            }
            return nil
        case "device.gridCodeSupported":
            guard let n = number(0) else { return nil }
            return .bool(config.gridTable?.entries[n] != nil)
        case "device.gridVariant":
            guard let n = number(0) else { return nil }
            return config.gridTable?.entries[n].map { .number(Double($0.variant)) }
        case "device.gridTableWord":
            guard let n = number(0) else { return nil }
            return config.gridTable?.entries[n].map { .number(Double($0.word)) }
        default: return nil
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Device facts

extension DeviceConfiguration {
    func supports(_ ref: VariableRef) -> Bool {
        switch ref.kind {
        case .setting: return info.info(ref.index)?.isSupported == true
        case .flag: return ref.index < 80 ? supportsFlag(ref.index) : false
        default: return false
        }
    }

    /// 12, 24 or 48 V, from the default of the DC low shut-down (FUN_004cc294).
    var dcVoltageClass: Int {
        var v = info.info(11).map { $0.display($0.defaultRaw) } ?? 0
        if v <= 0 { v = info.info(3).map { $0.display($0.defaultRaw) } ?? 0 }
        if v <= 0 { v = 12 }
        return v > 24 ? 48 : v > 12 ? 24 : 12
    }

    /// Battery cells (6 per 12 V).
    var cells: Int { dcVoltageClass / 2 }

    /// 120, 230 or 277 V, nearest to the default inverter output voltage.
    var acVoltageClass: Int {
        let v = info.info(5).map { $0.display($0.defaultRaw) } ?? 230
        return [120, 230, 277].min { abs(Double($0) - v) < abs(Double($1) - v) } ?? 230
    }

    /// A pure inverter: no AC-input current limit (FUN_0053cf8c; product type 14 excluded).
    var isInverterOnly: Bool { firmware.type != 14 && info.info(6)?.isSupported != true }

    var gridTable: GridTable? { GridTable.cached(info.gridTable) }
}

/// Firmware grid-code table (BareSettingInfo v≥3 trailer, docs/re/02-settings.md §2.3).
struct GridTable {
    struct Entry {
        var variant: Int
        var word: Int
        var editable: [UInt8]
        var present: [UInt8]
        /// Default value per setting index (129…190) for the bits set in `present`.
        var defaults: [Int: UInt16]
        func isPresent(setting id: Int) -> Bool {
            let bit = id - 128
            return bit >= 0 && bit / 8 < present.count && present[bit / 8] >> (bit % 8) & 1 == 1
        }
    }
    var entries: [Int: Entry]

    private static var cache: (bytes: [UInt8], table: GridTable?)?
    private static let lock = NSLock()

    static func cached(_ bytes: [UInt8]?) -> GridTable? {
        guard let bytes, bytes.count > 5 else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let c = cache, c.bytes == bytes { return c.table }
        let t = GridTable(bytes)
        cache = (bytes, t)
        return t
    }

    init?(_ b: [UInt8]) {
        func u16(_ p: Int) -> Int? { p + 1 < b.count ? Int(b[p]) | Int(b[p + 1]) << 8 : nil }
        guard b.count > 5 else { return nil }
        let version = Int(b[2]), n = Int(b[3]), k = Int(b[4])
        var entries: [Int: Entry] = [:]
        for g in 0..<n {
            guard var p = u16(5 + 2 * g), p < b.count else { continue }
            let variant = Int(b[p]); p += 1
            var word = 0
            if version > 2 { word = u16(p) ?? 0; p += 2 }
            guard p + 2 * k <= b.count else { continue }
            let editable = Array(b[p..<(p + k)]), present = Array(b[(p + k)..<(p + 2 * k)])
            var defaults: [Int: UInt16] = [:]
            if present.first != 0 {
                p += 2 * k
                let bits = (0..<(8 * k)).filter { present[$0 / 8] >> ($0 % 8) & 1 == 1 }
                let count = bits.count - 2
                for (i, bit) in bits.dropFirst().prefix(max(0, count)).enumerated() {
                    if let v = u16(p + 2 * i) { defaults[128 + bit] = UInt16(v) }
                }
            }
            entries[g] = Entry(variant: variant, word: word, editable: editable, present: present, defaults: defaults)
        }
        self.entries = entries
    }
}

// MARK: - Access bytes (reset / password)

enum Access {
    /// Attribute byte of a setting or flag, with VE Configure's firmware patch (FUN_0049efdc).
    static func attribute(_ ref: VariableRef, _ c: DeviceConfiguration) -> UInt8 {
        var a: UInt8 = 0
        switch ref.kind {
        case .setting: a = c.info.settingAttributes[safe: ref.index] ?? 0
        case .flag: a = c.info.flagAttributes[safe: ref.index] ?? 0
        default: return 0
        }
        let fw = c.firmware.version
        let name = ref.name
        if fw == 308, ["EPROM_GridCode", "EBIT_AllowEnableFeedIn"].contains(name) { a |= 0x80 }
        if fw < 309, ["EPROM_IInv2AES", "EPROM_IInvAESHysterese", "EPROM_BatteryCapacity"].contains(name) { a |= 0x80 }
        if (300..<309).contains(fw), ["EBIT_LithiumBattery", "EPROM_UBatFloat", "EPROM_UBat2Low"].contains(name) { a |= 0x80 }
        if fw < 200, name == "EPROM_ChargePercentageResetValueForBatteryMonitor" { a |= 0x80 }
        return a
    }

    static func attribute(setting id: Int, _ c: DeviceConfiguration) -> UInt8 {
        let ref = Catalog.shared.settingControls[id]?.variable?.name.flatMap { Catalog.shared.variables[$0] }
            ?? VariableRef(kind: .setting, index: id, name: "")
        return attribute(ref, c)
    }

    /// Variables a control writes, as references.
    static func refs(of control: CatalogControl) -> [VariableRef] {
        if let v = control.variable, let i = v.index, let n = v.name { return [VariableRef(kind: v.kind, index: i, name: n)] }
        if control.kind == .localToggle || control.kind == .localChoice {
            return LocalControls.writtenControls(control.name).flatMap { refs(of: $0) }
        }
        return control.peer?.peers.compactMap { p in
            p.variable.flatMap { v in v.index.map { VariableRef(kind: v.kind, index: $0, name: v.name ?? "") } }
        } ?? []
    }

    static func requiresReset(_ control: CatalogControl, _ c: DeviceConfiguration) -> Bool {
        refs(of: control).contains { attribute($0, c) & 0x80 != 0 }
    }

    /// Password areas (bits 0–6); bit 0 is the grid code ("GC").
    static func passwordAreas(_ control: CatalogControl, _ c: DeviceConfiguration) -> UInt8 {
        refs(of: control).reduce(0) { $0 | attribute($1, c) & 0x7F }
    }

    /// Changing the grid code needs the GC password unless the loaded code was a "free" one (GridCodeComboBoxGetRequiredAccess).
    /// Unknown counts as "needs the password".
    static func gridCodeNeedsPassword(_ ctx: RuleContext) -> Bool {
        if let expr = Catalog.shared.rulesByID["grid.code.password"]?.expr, let v = ctx.evaluate(expr) { return v }
        return true
    }

    /// The grid code, its parameter words and the checker words: protected whatever the attribute bytes say
    /// (a file without attribute bytes must not open the grid protection).
    static func isGridFamily(setting id: Int) -> Bool { id == 81 || (128...191).contains(id) }

    /// Grid-code password class ("GC", attribute bit 0) for a setting.
    static func isProtected(setting id: Int, _ c: DeviceConfiguration) -> Bool {
        isGridFamily(setting: id) || attribute(setting: id, c) & 1 != 0
    }

    static func isProtected(flag n: Int, _ c: DeviceConfiguration) -> Bool { c.info.isProtected(flag: n) }

    static func isProtected(_ ref: VariableRef, _ c: DeviceConfiguration) -> Bool {
        switch ref.kind {
        case .setting: return isProtected(setting: ref.index, c)
        case .flag: return isProtected(flag: ref.index, c)
        default: return false
        }
    }

    /// Whether a protected item may change without the password. Only the grid-code family, and only when the
    /// loaded grid code could be selected without a password (VE Configure: "The initial selection of the
    /// country\grid code standard will not require a password"). Anything else needs the password, which this app
    /// cannot verify: never.
    static func mayChangeWithoutPassword(_ ref: VariableRef, _ ctx: RuleContext) -> Bool {
        guard ref.kind == .setting, isGridFamily(setting: ref.index) else { return false }
        return !gridCodeNeedsPassword(ctx)
    }

    /// Whether the control is locked behind the grid-code password right now. Local controls (checkboxes without a
    /// device variable) inherit the protection of the settings they write.
    static func isLocked(_ control: CatalogControl, _ ctx: RuleContext) -> Bool {
        if control.name == "GridCodeComboBox" { return gridCodeNeedsPassword(ctx) }
        let protected = refs(of: control).filter { isProtected($0, ctx.config) }
        return protected.contains { !mayChangeWithoutPassword($0, ctx) }
    }

    /// Protected values an edit (`old` → `new`) would change to something other than the loaded value without being
    /// allowed to. Restoring a loaded value is always allowed.
    static func forbiddenEdits(old: DeviceConfiguration, new: DeviceConfiguration, _ ctx: RuleContext) -> [VariableRef] {
        var out: [VariableRef] = []
        for id in 0..<new.data.values.count where new.raw(id) != old.raw(id) && new.raw(id) != ctx.baseline.raw(id) {
            let ref = VariableRef(kind: .setting, index: id, name: SettingNames.settings[safe: id] ?? "")
            if isProtected(setting: id, new), !mayChangeWithoutPassword(ref, ctx) { out.append(ref) }
        }
        for n in 0..<SettingNames.flags.count where new.flag(n) != old.flag(n) && new.flag(n) != ctx.baseline.flag(n) {
            if isProtected(flag: n, new) { out.append(VariableRef(kind: .flag, index: n, name: SettingNames.flags[n])) }
        }
        return out
    }

    /// Protected values that differ from the loaded file without being allowed to (checked before saving).
    static func forbiddenChanges(_ ctx: RuleContext) -> [VariableRef] {
        forbiddenEdits(old: ctx.baseline, new: ctx.config, ctx)
    }

    static let infoText: [String: String] = [
        "reset": L("Changing this setting requires a reset of the device after the file has been uploaded. The GX device does this for you."),
        "password": L("The grid code password protects this setting. This app cannot verify that password, so it is read-only here. Change it in VE Configure."),
    ]
}

// MARK: - Assistant directory

/// Assistant IDs stored at the top of the 4096-byte program image, read downward (docs/re/02-settings.md §7).
struct AssistantDirectory {
    var ids: [Int]

    init(_ c: DeviceConfiguration) {
        let mem = c.data.assistantMemory
        var ids: [Int] = []
        guard mem.count >= 8, !mem.allSatisfy({ $0 == 0xFF }) else { self.ids = []; return }
        var p = mem.count - 6   // last 4 bytes: marker/checksum
        while p >= 0 {
            let id = Int(mem[p]) | Int(mem[p + 1]) << 8
            if id == 0xFFFF || id == 0 { break }
            ids.append(id)
            p -= 2
        }
        self.ids = ids
    }
}
