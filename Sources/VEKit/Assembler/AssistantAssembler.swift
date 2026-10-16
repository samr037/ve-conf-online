import Foundation

// Assistant extension of the assembler (docs/re/03-assembler.md §11): wizard steps (.AID), answers (.AUE/.ALS),
// readback-defined labels (.ALD), messages and stepback.

/// Assembler state per assistant (`$AssemblerState`, §11.1).
public enum AssemblerState: Int32, Sendable {
    case developerBuild = 0, translatorBuild, backReadBuild, defaultBuild, build, userEntry, summary, buildUnknown
    var keepsAnswers: Bool { rawValue >= 4 }
}

/// A wizard step declared by `.AID`.
public struct AssistantStepDefinition: Sendable, Equatable {
    public enum Kind: Character, Sendable { case entry = "E", radio = "R", check = "C" }
    public struct Field: Sendable, Equatable {
        public enum Precision: Sendable, Equatable { case decimals(Int), list, time }
        public var precision: Precision
        public var unitCode: Character
        public var min: Int32
        public var max: Int32
        public var defaultValue: Int32
    }
    public var id: String
    public var stepName: String
    public var kind: Kind
    public var inSummary: Bool
    public var fields: [Field]          // entry: 1…4 fields; radio/check: one synthetic field
    public var buttons: Int             // radio/check button count
}

/// One assistant answer (§11.4).
public struct AssistantAnswer: Sendable, Equatable {
    public var value: Int32
    public var previous: Int32
    public var hasALD = false
    public var confirmed = false
    var pending: Pending? = nil
    var pendingAlsoPrevious = false
    enum Pending: Sendable, Equatable { case literal(Int32), defaultValue, minimum, maximum, previous }
}

/// Answers of one assistant, keyed by label name. Persist across builds: these are the user's choices.
public struct AnswerTable: Sendable, Equatable {
    public var answers: [String: AssistantAnswer] = [:]
    public var steps: [String: AssistantStepDefinition] = [:]
    public var order: [String] = []   // step ids in .AID order
    public init() {}
}

/// What the wizard UI is asked to show (states 5/6).
public struct AssistantStepPresentation: Sendable {
    public enum Buttons: Sendable { case normal, cancelOnly, previousOnly, nextOnly }
    public var assistant: String
    public var step: AssistantStepDefinition
    public var labels: [String]
    public var values: [Int32]
    public var format: [Value]
    public var buttons: Buttons
    public var isFirst: Bool
}

public enum AssistantDecision: Sendable {
    case next([Int32]), previous, cancel
    /// The UI has not answered yet: stop this run, show the step, and re-run once answered.
    case suspend
}

final class AssistantAssembler: Assembler {
    /// Per-assistant answers, keyed by assistant name; kept between builds.
    var tables: [String: AnswerTable] = [:]
    var states: [String: AssemblerState] = [:]
    var texts: [String: (localized: WizardText?, english: WizardText?)] = [:]
    /// Reference binary for RBn (reconstruction or pass-3 verification).
    var referenceBinary: [UInt8]?
    /// Called for the step to display in states 5/6.
    var presentStep: ((AssistantStepPresentation) -> AssistantDecision)?

    private(set) var currentAssistant: String?
    private var readBackUsed = false
    private var usedBeforeDefinition: Set<String> = []

    var state: AssemblerState { currentAssistant.flatMap { states[$0] } ?? .build }

    // MARK: Passes

    /// Wizard driver state; survives restarts (stepback) and is mirrored into the `$Assistant…` labels.
    var displayStep: Int32 = 0
    var backStepList: [Value] = []
    var cancelled = false

    override func reset(firstPass: Bool) {
        // Read back what the sources may have changed (AUEStepBack, RemoveFromStepBack) before clearing.
        if case .int(let d)? = global["$AssistantDisplayStep"]?.value { displayStep = d }
        if case .list(let l)? = global["$AssistantBackStepList"]?.value { backStepList = l }
        if case .bool(let c)? = global["$AssistantCancelled"]?.value { cancelled = c }
        let keep = firstPass ? nil : snapshotAssistantLabels()
        super.reset(firstPass: firstPass)
        if firstPass {
            global["$AssistantStep"] = Label(value: .int(0), flags: 2)
            global["$AutoNext"] = Label(value: .bool(false), flags: 2)
            global["$ForceDefaultOnAutoNext"] = Label(value: .bool(false), flags: 2)
            for name in tables.keys where !(states[name]?.keepsAnswers ?? true) {
                tables[name] = AnswerTable()
            }
            for name in tables.keys { tables[name]?.steps = [:]; tables[name]?.order = [] }
        } else if let keep {
            for (k, v) in keep { global[k] = v }
        }
        global["$AssistantCancelled"] = Label(value: .bool(cancelled), flags: 1)
        global["$AssistantDisplayStep"] = Label(value: .int(displayStep), flags: 6)
        global["$AssistantBackStepList"] = Label(value: .list(backStepList), flags: 6)
        global["$AUEHandled"] = Label(value: .bool(false), flags: 1)
        global["$HandledAUEStep"] = Label(value: .string([]), flags: 1)
        global["$AssemblerState"] = Label(value: .int(0), flags: 1)
        global["$AssemblerPass"] = Label(value: .int(0), flags: 1)
    }

    /// Syncs the driver state from the labels after an assembly run.
    func captureDriverState() {
        if case .int(let d)? = global["$AssistantDisplayStep"]?.value { displayStep = d }
        if case .list(let l)? = global["$AssistantBackStepList"]?.value { backStepList = l }
        if case .bool(let c)? = global["$AssistantCancelled"]?.value { cancelled = c }
    }

    private func snapshotAssistantLabels() -> [String: Label] {
        var out: [String: Label] = [:]
        for k in ["$AssistantStep", "$AutoNext", "$ForceDefaultOnAutoNext"] {
            if let l = global[k] { out[k] = l }
        }
        return out
    }

    override func willStartPass(_ pass: Int) {
        global["$AssemblerPass"]?.value = .int(Int32(pass))
        if pass == 1 { global["$AssistantStep"]?.value = .int(0) }
    }

    override func willEnterSource(_ name: String) {
        currentAssistant = name
        usedBeforeDefinition = []
        if tables[name] == nil { tables[name] = AnswerTable() }
        global["$AssemblerState"]?.value = .int(state.rawValue)
    }

    override func didLeaveSource(_ name: String) {
        currentAssistant = nil
        global["$AssemblerState"]?.value = .int(0)
    }

    // MARK: Calculator host

    override func lookup(_ name: String) -> Label? {
        let l = super.lookup(name)
        if l == nil, frameLabels?[name] == nil { usedBeforeDefinition.insert(name) }
        return l
    }

    override func readBack(bytes: Int, at address: Int32) -> Result<Int32, CalcError> {
        guard let ref = referenceBinary else { return .success(-1) }
        let a = Int(address)
        guard a >= 0, a + bytes <= ref.count else { return .failure(CalcError(message: "Readback index out of bounds")) }
        var v: UInt32 = 0
        for k in 0..<bytes { v |= UInt32(ref[a + k]) << (8 * UInt32(k)) }
        return .success(Int32(bitPattern: v))
    }

    override func noteReadBackUsed() { readBackUsed = true }

    override func assistantText(_ key: Value) -> [UInt8]? {
        guard let a = currentAssistant, let t = texts[a] else { return nil }
        let raw = t.localized?.assistantText(key) ?? t.english?.assistantText(key)
        return raw.map(WizardText.unescape)
    }

    override func assistantLabelValue(_ name: String) -> Int32? {
        guard let a = currentAssistant else { return nil }
        return tables[a]?.answers[name]?.value
    }

    // MARK: Directives

    override func directive(_ op: String) -> Handler? {
        switch op {
        case ".aid": return aid
        case ".aue": return { l, f in self.aue(l, f, buttons: .normal) }
        case ".aer": return { l, f in self.aue(l, f, buttons: self.state == .translatorBuild ? .nextOnly : .cancelOnly) }
        case ".aip": return { l, f in self.aue(l, f, buttons: self.state == .translatorBuild ? .nextOnly : .previousOnly) }
        case ".ain": return { l, f in self.aue(l, f, buttons: .nextOnly) }
        case ".ald": return ald
        case ".als": return als
        case ".amessg": return { l, _ in
            guard let p = l.params.first else { return }
            let text = self.evaluate(p).map { String(decoding: $0.asText, as: Latin1.self) } ?? ""
            self.report(text, kind: .message)
        }
        case ".aerror": return { l, _ in
            guard let p = l.params.first else { return }
            let text = self.evaluate(p, report: false).map { String(decoding: $0.asText, as: Latin1.self) } ?? String(decoding: p, as: Latin1.self)
            self.report("Assistant: \(self.currentAssistant ?? "") generated the following error: \(text)", kind: .fatal, fatal: true)
        }
        case ".restart": return { _, _ in self.report(Self.restartMessage, kind: .fatal, fatal: true) }
        default: return super.directive(op)
        }
    }

    private func intLabel(_ name: String) -> Int32 {
        if case .int(let i)? = global[name]?.value { return i }
        return 0
    }

    static let restartMessage = "Assembly must be restarted for stepback"
    static let suspendMessage = "Waiting for the user"

    /// Errors of assistant pseudo-ops are fatal (§10.3).
    private func fatal(_ text: String) { report(text, kind: .fatal, fatal: true) }

    private var table: AnswerTable {
        get { tables[currentAssistant ?? ""] ?? AnswerTable() }
        set { tables[currentAssistant ?? ""] = newValue }
    }

    /// Delphi `Val`: decimal, `$hex`, `0x` hex, optional sign.
    static func delphiVal(_ s: Substring) -> Int32? {
        var t = s.trimmingCharacters(in: .whitespaces)
        var neg = false
        if t.hasPrefix("-") { neg = true; t.removeFirst() } else if t.hasPrefix("+") { t.removeFirst() }
        var v: Int64?
        if t.hasPrefix("$") { v = Int64(t.dropFirst(), radix: 16) } else if t.lowercased().hasPrefix("0x") { v = Int64(t.dropFirst(2), radix: 16) } else { v = Int64(t) }
        guard let x = v else { return nil }
        return Int32(truncatingIfNeeded: neg ? -x : x)
    }

    private func aid(_ line: SourceLine, _ frame: Frame) {
        guard pass == 1 else { return }
        guard !line.label.isEmpty, Self.isLegalName(line.label) else { fatal("illegal label name"); return }
        guard line.params.count >= 2 else { fatal("too few parameters"); return }
        let id = line.label
        guard table.steps[id] == nil else { fatal("This assistant ID is already in use!"); return }
        let stepName = String(decoding: line.params[0], as: Latin1.self)
        guard case .string(let typeBytes)? = evaluate(line.params[1], report: false) ?? .str(String(decoding: line.params[1], as: Latin1.self)) as Value?,
              let first = typeBytes.first.map({ Character(UnicodeScalar($0)) }),
              let kind = AssistantStepDefinition.Kind(rawValue: Character(first.uppercased())),
              typeBytes.count <= 2, typeBytes.count == 1 || typeBytes[1] | 0x20 == 0x6C
        else { fatal("Type must be {E|R|C}[L]"); return }
        let inSummary = typeBytes.count == 2
        var values: [Value] = []
        for p in line.params.dropFirst(2) {
            guard let v = evaluate(p, report: false) else { fatal("The value of assistant entry info must be calculatable the 1st pass!"); return }
            values.append(v)
        }
        var fields: [AssistantStepDefinition.Field] = []
        var buttons = 0
        switch kind {
        case .entry:
            for v in values {
                guard case .string(let b) = v else { fatal("Error in parameter"); return }
                guard !b.isEmpty else { fatal("The parameter is an empty string"); return }
                let s = String(decoding: b, as: Latin1.self)
                let parts = s.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count == 4, parts[0].count == 2,
                      let mn = Self.delphiVal(parts[1]), let mx = Self.delphiVal(parts[2]), let df = Self.delphiVal(parts[3])
                else { fatal("Error in: \(s)"); return }
                let p = parts[0].first!, k = parts[0].last!
                let precision: AssistantStepDefinition.Field.Precision
                switch p {
                case "L", "l": precision = .list
                case "T", "t": precision = .time
                default:
                    guard let d = p.wholeNumberValue else { fatal("Error in: \(s)"); return }
                    precision = .decimals(d)
                }
                guard mn <= df, df <= mx else { fatal("Error in: \(s) default value not within limits."); return }
                fields.append(.init(precision: precision, unitCode: k, min: mn, max: mx, defaultValue: df))
            }
        case .radio, .check:
            guard values.count >= 1, case .int(let n) = values[0] else { fatal("Nr of buttons missing!"); return }
            guard values.count >= 2, case .int(let d) = values[1] else { fatal("Default value missing!"); return }
            if kind == .check && n > 32 { fatal("Number of CheckBox buttons greater than 32."); return }
            let max: Int32 = kind == .radio ? n - 1 : (n >= 32 ? Int32.max : Int32((1 << Int(n)) - 1))
            guard d >= 0, d <= max else { fatal("illegal default value"); return }
            buttons = Int(n)
            fields = [.init(precision: .decimals(0), unitCode: "N", min: 0, max: max, defaultValue: d)]
        }
        var t = table
        t.steps[id] = AssistantStepDefinition(id: id, stepName: stepName, kind: kind, inSummary: inSummary, fields: fields, buttons: buttons)
        t.order.append(id)
        table = t
    }

    private func aue(_ line: SourceLine, _ frame: Frame, buttons: AssistantStepPresentation.Buttons) {
        guard pass == 1 else { return }
        global["$AUEHandled"]?.value = .bool(false)
        global["$HandledAUEStep"]?.value = .string([])
        guard let idBytes = line.params.first else { fatal("too few parameters"); return }
        let id = String(decoding: idBytes, as: Latin1.self)
        guard let step = table.steps[id] else { fatal("Unknown assistant ID"); return }
        let n = step.fields.count
        guard line.params.count == n + 1 || line.params.count == n + 2 else {
            fatal("The nr of labels does not match with the defintion in the assistant ID"); return
        }
        var format: [Value] = []
        if line.params.count == n + 2 {
            guard let v = evaluate(line.params[n + 1], report: false) else {
                fatal("The value of assistant entry info must be calculatable the 1st pass!"); return
            }
            guard case .list(let l) = v, l.allSatisfy({ if case .int = $0 { true } else if case .string = $0 { true } else { false } }) else {
                fatal("Assistant entry info must be a List containing format parameters"); return
            }
            format = l
        }
        var t = table
        var labels: [String] = []
        var prevs: [Int32] = [], before: [Int32] = []
        let autoNext = global["$AutoNext"]?.value == .bool(true)
        let forceDefault = global["$ForceDefaultOnAutoNext"]?.value == .bool(true)
        for (k, field) in step.fields.enumerated() {
            let name = String(decoding: line.params[k + 1], as: Latin1.self)
            guard Self.isLegalName(name) else { fatal("illegal label name"); return }
            labels.append(name)
            var rec: AssistantAnswer
            if var existing = t.answers[name] {
                if !state.keepsAnswers && existing.pending == nil && existing.hasALD {
                    fatal("This assistant label is already used at another .AUE defintion."); return
                }
                switch existing.pending {
                case nil:
                    if state == .userEntry && autoNext && forceDefault { existing.value = field.defaultValue }
                case .defaultValue?: existing.value = field.defaultValue
                case .minimum?: existing.value = field.min
                case .maximum?: existing.value = field.max
                case .previous?: existing.value = existing.previous
                case .literal(let v)?: existing.value = v
                }
                if existing.pendingAlsoPrevious { existing.previous = existing.value }
                existing.pending = nil
                existing.pendingAlsoPrevious = false
                if existing.previous == Int32.max { existing.previous = field.defaultValue }
                rec = existing
            } else {
                rec = AssistantAnswer(value: field.defaultValue, previous: field.defaultValue)
            }
            rec.value = Swift.min(Swift.max(rec.value, field.min), field.max)
            rec.previous = Swift.min(Swift.max(rec.previous, field.min), field.max)
            t.answers[name] = rec
            prevs.append(rec.previous)
            before.append(rec.value)
        }
        table = t

        var handled = false
        if state == .userEntry || state == .summary || state == .translatorBuild {
            let stepNo = intLabel("$AssistantStep")
            global["$AssistantStep"]?.value = .int(stepNo + 1)
            let display = intLabel("$AssistantDisplayStep")
            if stepNo + 1 == display {
                handled = true
                var decision: AssistantDecision
                if autoNext && (buttons == .cancelOnly || buttons == .previousOnly) {
                    global["$AutoNext"]?.value = .bool(false)
                }
                if global["$AutoNext"]?.value == .bool(true) {
                    decision = .next(before)
                } else {
                    if case .list(let back)? = global["$AssistantBackStepList"]?.value {
                        global["$AssistantBackStepList"]?.value = .list(back + [.int(display)])
                    }
                    let presentation = AssistantStepPresentation(assistant: currentAssistant ?? "", step: step, labels: labels,
                                                                 values: before, format: format, buttons: buttons, isFirst: display == 1)
                    decision = presentStep?(presentation) ?? .next(before)
                }
                switch decision {
                case .next(let values):
                    var t = table
                    for (k, name) in labels.enumerated() where k < values.count {
                        let f = step.fields[k]
                        t.answers[name]?.value = Swift.min(Swift.max(values[k], f.min), f.max)
                    }
                    table = t
                    global["$AssistantDisplayStep"]?.value = .int(display + 1)
                case .previous:
                    if case .list(var back)? = global["$AssistantBackStepList"]?.value {
                        if !back.isEmpty { back.removeLast() }
                        let target = back.popLast() ?? .int(1)
                        global["$AssistantBackStepList"]?.value = .list(back)
                        global["$AssistantDisplayStep"]?.value = target
                    }
                    report(Self.restartMessage, kind: .fatal, fatal: true)
                    return
                case .cancel:
                    global["$AssistantCancelled"]?.value = .bool(true)
                    report("Assembly cancelled by user", kind: .fatal, fatal: true)
                    return
                case .suspend:
                    if case .list(var back)? = global["$AssistantBackStepList"]?.value, !back.isEmpty {
                        back.removeLast()
                        global["$AssistantBackStepList"]?.value = .list(back)
                    }
                    report(Self.suspendMessage, kind: .fatal, fatal: true)
                    return
                }
            }
        }
        let after = labels.compactMap { table.answers[$0]?.value }
        let result: Value = .list([.list(prevs.map(Value.int)), .list(before.map(Value.int)), .list(after.map(Value.int))])
        if let existing = scope.labels[id] { existing.value = result } else { scope.labels[id] = Label(value: result, flags: 0) }
        if handled {
            global["$AUEHandled"]?.value = .bool(true)
            global["$HandledAUEStep"]?.value = .str(id)
        }
    }

    private func ald(_ line: SourceLine, _ frame: Frame) {
        let name = line.label
        guard !name.isEmpty else { fatal("label expected"); return }
        guard line.params.count == 1 else { fatal(line.params.isEmpty ? "too few parameters" : "too many parameters"); return }
        if pass == 3 {
            guard let l = lookup(name) else { fatal("Cannot find label during 2nd pass readback check"); return }
            readBackUsed = false
            guard case .int(let v)? = evaluate(line.params[0], report: false) else {
                fatal("Unexpected result of expression during 2nd pass readback check"); return
            }
            if l.value != .int(v) { fatal("readback after assembly returns a different value!") }
            return
        }
        guard pass == 1 else { return }
        guard var rec = table.answers[name] else { fatal("No corresponding .AUE found before this defintion"); return }
        guard frameLabels == nil, !localNames.contains(name), globalDepth == 0 else {
            fatal("An assistant label must be a local label and cannot be an \"external\", global or macro local"); return
        }
        if scope.labels[name] != nil { fatal("This label is already defined!"); return }
        if usedBeforeDefinition.contains(name) { fatal("This label is already used! (An assistant label must be defined before use!)"); return }
        readBackUsed = false
        let e = calculator.evaluate(line.params[0])
        guard readBackUsed else { fatal("The expression in the .ALD must make use of a readback function!"); return }
        guard e.ok, let v = e.value else { fatal("The value of an assistant label must be calculatable the 1st pass! (and all other passes)"); return }
        guard case .int(let x) = v else { fatal("Assistant label expression must be an integer!"); return }
        rec.hasALD = true
        if state == .backReadBuild {
            rec.value = x
            rec.previous = x
            rec.confirmed = true
        }
        var t = table
        t.answers[name] = rec
        table = t
        scope.labels[name] = Label(value: .int(rec.value), flags: 1)
    }

    private func als(_ line: SourceLine, _ frame: Frame) {
        guard pass == 1 else { return }
        let name = line.label
        guard !name.isEmpty, Self.isLegalName(name) else { fatal("illegal label name"); return }
        guard (1...2).contains(line.params.count) else { fatal("too many parameters"); return }
        if scope.labels[name] != nil { fatal("This label is already defined!"); return }
        guard let v = evaluate(line.params[0], report: false) else {
            fatal("The value of assistant entry info must be calculatable the 1st pass!"); return
        }
        let pending: AssistantAnswer.Pending
        switch v {
        case .int(let i): pending = .literal(i)
        case .string([0x44]), .string([0x64]): pending = .defaultValue
        case .string([0x4E]), .string([0x6E]): pending = .minimum
        case .string([0x58]), .string([0x78]): pending = .maximum
        case .string([0x50]), .string([0x70]): pending = .previous
        default: fatal("Assistant label value must be an integer or 'D','N','P','X'"); return
        }
        var alsoPrevious = false
        if line.params.count == 2 {
            guard let b = evaluate(line.params[1], report: false), b == .str("B") || b == .str("b") else {
                fatal("Assistant label value must be an integer or 'D','N','P','X'"); return
            }
            alsoPrevious = true
        }
        var t = table
        var rec = t.answers[name] ?? AssistantAnswer(value: 0, previous: Int32.max)
        rec.pending = pending
        rec.pendingAlsoPrevious = alsoPrevious
        t.answers[name] = rec
        table = t
    }
}
