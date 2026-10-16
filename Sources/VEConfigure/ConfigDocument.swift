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
        guard let info = config.info.info(id) else { return }
        setRaw(id, info.raw(for: value), actionName: actionName)
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

    /// Restores one setting (or flag) to its loaded value — VE Configure's "Restore unmodified value".
    func revert(_ change: Change) {
        switch change.target {
        case .setting(let id): setRaw(id, baseline.raw(id), actionName: L("Restore %@", change.label))
        case .flag(let n): setFlag(n, baseline.flag(n), actionName: L("Restore %@", change.label))
        case .assistants: break
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
        enum Target: Hashable { case setting(Int), flag(Int), assistants }
        var target: Target
        var label: String
        var before: String
        var after: String
        var id: Target { target }
    }

    var changes: [Change] {
        var out: [Change] = []
        let flagWords = Set(SettingNames.flagWords)
        for id in 0..<config.data.values.count where config.raw(id) != baseline.raw(id) && !flagWords.contains(id) {
            out.append(Change(target: .setting(id), label: Labels.setting(id, in: config),
                              before: Labels.format(baseline, id), after: Labels.format(config, id)))
        }
        for n in 0..<SettingNames.flags.count where config.flag(n) != baseline.flag(n) {
            out.append(Change(target: .flag(n), label: Labels.flag(n),
                              before: Catalog.shared.formatFlag(n, baseline.flag(n)), after: Catalog.shared.formatFlag(n, config.flag(n))))
        }
        if config.data.assistantMemory != baseline.data.assistantMemory {
            out.append(Change(target: .assistants, label: L("Assistants"), before: "", after: L("Reprogrammed")))
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
        let unit = Catalog.shared.unit(forSetting: id).map { " " + L10n.catalog($0) } ?? ""
        return number(info.display(c.raw(id)), step: info.step) + unit
    }

    static func number(_ v: Double, step: Double) -> String {
        let decimals = step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : 3
        return v.formatted(.number.precision(.fractionLength(decimals)))
    }
}

enum GridCodes {
    /// Display names for the firmware grid-code enum (VE Configure's grid code combo box).
    static func name(_ index: Int) -> String {
        Catalog.shared.gridCodeName(index) ?? SettingNames.gridCodes[index]
    }
}
