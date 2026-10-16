import AppKit
import Combine
import VEKit

/// One open configuration file. Edits go through here so undo and the change list stay exact.
final class ConfigDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var config: DeviceConfiguration
    /// The configuration as loaded (or as last saved): the reference for the change list.
    @Published private(set) var baseline: DeviceConfiguration
    @Published var url: URL?
    /// Session-only state (grid password entered, charger parameters unhidden…).
    @Published var session = SessionState()
    /// Messages from the last edit (VE Configure's info boxes), shown by the page.
    @Published var notices: [Notice] = []
    let undoManager = UndoManager()

    var ruleContext: RuleContext { RuleContext(config: config, baseline: baseline, session: session) }

    init(url: URL) throws {
        let c = try DeviceConfiguration(contentsOf: url)
        config = c
        baseline = c
        self.url = url
    }

    var title: String { url?.lastPathComponent ?? L("Configuration") }

    /// Assistants programmed in this configuration (reconstructed lazily on first use).
    lazy var assistants = AssistantsModel(document: self)
    var isEdited: Bool { config != baseline }

    // MARK: Editing

    func setRaw(_ id: Int, _ value: UInt16, actionName: String) {
        let old = config.raw(id)
        guard old != value, apply({ $0.setRaw(id, value) }) else { return }
        registerUndo(actionName) { $0.setRaw(id, old, actionName: actionName) }
    }

    func setValue(_ id: Int, _ value: Double, actionName: String) {
        guard let info = config.info.info(id), let raw = info.rawValue(for: value) else { return }
        setRaw(id, raw, actionName: actionName)
    }

    func setFlag(_ n: Int, _ on: Bool, actionName: String) {
        let old = config.flag(n)
        guard old != on, apply({ $0.setFlag(n, on) }) else { return }
        registerUndo(actionName) { $0.setFlag(n, old, actionName: actionName) }
    }

    /// One user edit: the change itself plus VE Configure's consequences (coupled values, side effects),
    /// undone as a single step.
    ///
    /// An edit that would change a grid-code protected value (other than back to its loaded value) is refused as a
    /// whole: this app cannot verify the grid-code password, so protected settings can never be changed by mistake.
    func edit(_ actionName: String, control: String? = nil, _ change: (inout DeviceConfiguration) -> Void) {
        let old = config
        var c = config
        change(&c)
        guard c != old else { return }
        if let refused = Validation.rejection(old: old, new: c, control: control, ruleContext) {
            notices.append(refused)
            return
        }
        let found = Consequences.apply(old: old, new: &c, control: control)
        let forbidden = Access.forbiddenEdits(old: old, new: c, ruleContext)
        guard forbidden.isEmpty else {
            notices.append(Notice(title: L("Protected by the grid code password"), message: Self.protectedMessage(forbidden, c)))
            return
        }
        replace(with: c, actionName: actionName)
        if !found.isEmpty { notices.append(contentsOf: found) }
    }

    static func protectedMessage(_ refs: [VariableRef], _ c: DeviceConfiguration) -> String {
        let names = refs.prefix(4).map { r in
            (r.kind == .flag ? Labels.flag(r.index) : Labels.setting(r.index, in: c))
        }.joined(separator: ", ") + (refs.count > 4 ? "…" : "")
        return L("It is not allowed to make this change in the settings without providing the grid code password! VE Configure for Mac cannot verify that password, so this change was not made: %@.", names)
    }

    /// Replaces the whole configuration (used by `edit`, presets and grid-code changes) with undo.
    func replace(with new: DeviceConfiguration, actionName: String) {
        let old = config
        guard old != new else { return }
        config = new
        registerUndo(actionName) { $0.replace(with: old, actionName: actionName) }
    }

    /// "Restore unmodified value": puts a change back to its loaded value through `edit`, so VE Configure's follow-up
    /// corrections run. A control spanning several words is restored as a whole; a grid-code change is restored
    /// together with its parameter and checker words.
    func revert(_ change: Change) {
        let base = baseline
        let action = L("Restore %@", change.label)
        switch change.target {
        case .setting(let id):
            edit(action, control: Catalog.shared.settingControls[id]?.name) { $0.setRaw(id, base.raw(id)) }
        case .flag(let n):
            edit(action, control: Catalog.shared.flagControls[n]?.name) { $0.setFlag(n, base.flag(n)) }
        case .control(let name):
            if let ctl = Catalog.shared.controls[name] { restore(control: ctl, actionName: action) }
        case .gridCode:
            edit(action, control: "GridCodeComboBox") { c in
                for id in [81] + Array(128...191) { c.setRaw(id, base.raw(id)) }
            }
        case .assistants:
            break
        }
    }

    /// Restores everything one control writes (its bits of shared grid words, all of its words, or the settings a
    /// local checkbox sets) to the loaded values.
    func restore(control ctl: CatalogControl, actionName: String) {
        let base = baseline
        edit(actionName, control: ctl.name) { c in
            if let v = ctl.variable, v.kind == .flag, let n = v.index { c.setFlag(n, base.flag(n)); return }
            if ctl.peer != nil, let k = ValueCodec(control: ctl), let r = k.raw(base) { k.restoreRaw(r, in: &c); return }
            for id in ctl.settingTargets { c.setRaw(id, base.raw(id)) }
        }
    }

    /// Applies a raw change unless it touches a protected value; returns whether it was applied.
    private func apply(_ edit: (inout DeviceConfiguration) -> Void) -> Bool {
        var c = config
        edit(&c)
        let forbidden = Access.forbiddenEdits(old: config, new: c, ruleContext)
        guard forbidden.isEmpty else {
            notices.append(Notice(title: L("Protected by the grid code password"), message: Self.protectedMessage(forbidden, c)))
            return false
        }
        config = c
        return true
    }

    private func registerUndo(_ name: String, _ undo: @escaping (ConfigDocument) -> Void) {
        undoManager.registerUndo(withTarget: self) { undo($0) }
        undoManager.setActionName(name)
    }

    // MARK: Saving

    struct SaveError: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    /// Whether ⌘S may save: something changed, the grid parameters are consistent and no protected setting changed.
    var canSave: Bool { saveBlockReason == nil }

    /// Why saving is not possible right now (nil when it is).
    var saveBlockReason: String? {
        if changes.isEmpty { return L("There are no changes to save.") }
        return integrityProblem
    }

    /// Problems that make the current configuration unfit to be uploaded to an inverter.
    var integrityProblem: String? {
        if !GridPages.paramsValid(config) {
            return L("The grid code parameters do not match the selected grid code or belong to another firmware version. Select the grid code again to load its defaults before saving.")
        }
        let forbidden = Access.forbiddenChanges(ruleContext)
        if !forbidden.isEmpty {
            return L("Settings protected by the grid code password were changed: %@. Restore them before saving.",
                     forbidden.prefix(4).map { $0.kind == .flag ? Labels.flag($0.index) : Labels.setting($0.index, in: config) }
                        .joined(separator: ", ") + (forbidden.count > 4 ? "…" : ""))
        }
        return nil
    }

    /// VE Configure drops the unlock tokens of a file once they are more than 7200 s old (BareSettingData reader
    /// FUN_004be27c). They are checked again at save time, so a stale token is never carried into a new file.
    static let tokenLifetime: Int64 = 7200

    static func dropStaleTokens(_ c: inout DeviceConfiguration, now: Int64 = Int64(Date().timeIntervalSince1970)) {
        guard !c.data.tokens.isEmpty else { return }
        let age = now - c.data.tokenTime
        if age < 0 || age > tokenLifetime { c.data.tokens = [] }
    }

    func save(to url: URL) throws {
        if let problem = integrityProblem { throw SaveError(reason: problem) }
        var out = config
        Self.dropStaleTokens(&out)
        try out.settingFile().write(to: url)
        self.url = url
        config = out
        baseline = out
    }

    // MARK: Change list

    struct Change: Identifiable, Equatable {
        enum Target: Hashable { case setting(Int), flag(Int), assistants, control(String), gridCode }
        var target: Target
        var label: String
        var before: String
        var after: String
        var id: Target { target }
    }

    var changes: [Change] {
        var out: [Change] = []
        let skip = Set(SettingNames.flagWords).union([81]).union(128...191)
        for id in 0..<config.data.values.count where config.raw(id) != baseline.raw(id) && !skip.contains(id) {
            let (b, a) = Labels.formatPair(baseline, config, id)
            out.append(Change(target: .setting(id), label: Labels.setting(id, in: config), before: b, after: a))
        }
        out += gridChanges
        for n in 0..<SettingNames.flags.count where config.flag(n) != baseline.flag(n) {
            out.append(Change(target: .flag(n), label: Labels.flag(n),
                              before: Catalog.shared.formatFlag(n, baseline.flag(n)), after: Catalog.shared.formatFlag(n, config.flag(n))))
        }
        if config.data.assistantMemory != baseline.data.assistantMemory {
            out.append(Change(target: .assistants, label: L("Assistants"), before: "", after: L("Reprogrammed")))
        }
        return out
    }

    /// Grid changes as the user made them: the grid code (one unit with its parameters), else one entry per control
    /// of the grid pages in physical units, and raw words only for what no control explains.
    private var gridChanges: [Change] {
        if config.raw(81) != baseline.raw(81) {
            let words = (128...191).filter { config.raw($0) != baseline.raw($0) }.count
            return [Change(target: .gridCode, label: Labels.setting(81, in: config), before: Labels.format(baseline, 81),
                           after: Labels.format(config, 81) + (words > 0 ? " " + L("(with %d grid parameter words)", words) : ""))]
        }
        let changed = (128...191).filter { config.raw($0) != baseline.raw($0) }
        guard !changed.isEmpty else { return [] }
        var pages: Set<String> = [GridPages.selectionPage]
        if let p = GridPages.page(for: config) { pages.insert(p) }
        if GridPages.showsMicrogrid(config) { pages.insert("MicroGridPage") }
        var out: [Change] = []
        var rest = config   // the controls listed put back: what still differs is explained by no control
        var seen = Set<String>()
        for id in changed {
            for ctl in Catalog.shared.peerControlsBySetting[id] ?? [] where !seen.contains(ctl.name) {
                guard let page = Catalog.shared.pageOfControl[ctl.name], pages.contains(page) || page.hasPrefix("VDE") && pages.contains("VDEGridCodePage") else { continue }
                seen.insert(ctl.name)
                guard let k = ValueCodec(control: ctl), k.isSupported(config), let rb = k.raw(baseline), let ra = k.raw(config), rb != ra,
                      k.display(config) != nil, k.display(baseline) != nil else { continue }
                let (b, a) = Labels.formatPair(k, baseline, config)
                out.append(Change(target: .control(ctl.name), label: Validation.label(ctl), before: b, after: a))
                k.restoreRaw(rb, in: &rest)
            }
        }
        for id in changed where rest.raw(id) != baseline.raw(id) {
            out.append(Change(target: .setting(id), label: Labels.setting(id), before: Labels.format(baseline, id), after: Labels.format(config, id)))
        }
        return out
    }
}

/// Human names and value formatting, used wherever the catalog has no richer label.
enum Labels {
    static func setting(_ id: Int) -> String {
        Catalog.shared.label(forSetting: id) ?? fallback(SettingNames.settings[id])
    }

    static func setting(_ id: Int, in config: DeviceConfiguration) -> String {
        Catalog.shared.label(forSetting: id, in: config) ?? setting(id)
    }

    static func flag(_ n: Int) -> String {
        Catalog.shared.label(forFlag: n) ?? fallback(SettingNames.flags[n])
    }

    static func fallback(_ name: String) -> String {
        var n = name
        if n.hasPrefix("@") { n.removeFirst() }
        for p in ["eest", "eecv", "eevs", "eefs", "_"] where n.hasPrefix(p) { n.removeFirst(p.count) }
        return n
    }

    static func format(_ c: DeviceConfiguration, _ id: Int) -> String {
        if id == 81 {
            let g = Int(c.raw(id))
            return SettingNames.gridCodes.indices.contains(g) ? GridCodes.name(g) : "\(g)"
        }
        if (128...191).contains(id) { return String(format: "0x%04X", c.raw(id)) }
        if let codec = ValueCodec(setting: id), codec.isSupported(c) { return codec.formatted(c) }
        guard let info = c.info.info(id), info.isSupported else { return "\(c.raw(id))" }
        return number(info.display(c.raw(id)), step: info.step) + unitSuffix(id)
    }

    private static func unitSuffix(_ id: Int) -> String {
        Units.display(Catalog.shared.unit(forSetting: id)).map { " " + $0 } ?? ""
    }

    static func number(_ v: Double, step: Double, extraDecimals: Int = 0) -> String {
        let decimals = (step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : 3) + extraDecimals
        return v.formatted(.number.precision(.fractionLength(decimals)))
    }

    /// Before/after texts for the change list, with as many extra decimals as it takes to tell them apart.
    static func formatPair(_ b: DeviceConfiguration, _ c: DeviceConfiguration, _ id: Int) -> (String, String) {
        if let k = ValueCodec(setting: id), k.isSupported(c) { return formatPair(k, b, c) }
        let x = format(b, id), y = format(c, id)
        guard x == y, let info = c.info.info(id), info.isSupported else { return (x, y) }
        for extra in 1...6 {
            let p = number(info.display(b.raw(id)), step: info.step, extraDecimals: extra) + unitSuffix(id)
            let q = number(info.display(c.raw(id)), step: info.step, extraDecimals: extra) + unitSuffix(id)
            if p != q { return (p, q) }
        }
        return (x, y)
    }

    static func formatPair(_ k: ValueCodec, _ b: DeviceConfiguration, _ c: DeviceConfiguration) -> (String, String) {
        let x = k.formatted(b), y = k.formatted(c)
        guard x == y, let vb = k.display(b), let vc = k.display(c) else { return (x, y) }
        for extra in 1...6 {
            let p = k.format(vb, b, extraDecimals: extra) + k.unitSuffix, q = k.format(vc, c, extraDecimals: extra) + k.unitSuffix
            if p != q { return (p, q) }
        }
        return (x, y)
    }
}

enum GridCodes {
    /// Display names for the firmware grid-code enum (VE Configure's grid code combo box).
    static func name(_ index: Int) -> String {
        Catalog.shared.gridCodeName(index) ?? SettingNames.gridCodes[safe: index] ?? L("Grid code %d", index)
    }
}
