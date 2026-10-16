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
    let undoManager = UndoManager()

    init(url: URL) throws {
        let c = try DeviceConfiguration(contentsOf: url)
        config = c
        baseline = c
        self.url = url
    }

    var title: String { url?.lastPathComponent ?? "Configuration" }
    var isEdited: Bool { config != baseline }

    // MARK: Editing

    func setRaw(_ id: Int, _ value: UInt16, actionName: String) {
        let old = config.raw(id)
        guard old != value else { return }
        apply { $0.setRaw(id, value) }
        registerUndo(actionName) { $0.setRaw(id, old, actionName: actionName) }
    }

    func setValue(_ id: Int, _ value: Double, actionName: String) {
        guard let info = config.info.info(id) else { return }
        setRaw(id, info.raw(for: value), actionName: actionName)
    }

    func setFlag(_ n: Int, _ on: Bool, actionName: String) {
        let old = config.flag(n)
        guard old != on else { return }
        apply { $0.setFlag(n, on) }
        registerUndo(actionName) { $0.setFlag(n, old, actionName: actionName) }
    }

    /// Restores one setting (or flag) to its loaded value — VE Configure's "Restore unmodified value".
    func revert(_ change: Change) {
        switch change.target {
        case .setting(let id): setRaw(id, baseline.raw(id), actionName: "Restore \(change.label)")
        case .flag(let n): setFlag(n, baseline.flag(n), actionName: "Restore \(change.label)")
        case .assistants: break
        }
    }

    private func apply(_ edit: (inout DeviceConfiguration) -> Void) {
        var c = config
        edit(&c)
        config = c
    }

    private func registerUndo(_ name: String, _ undo: @escaping (ConfigDocument) -> Void) {
        undoManager.registerUndo(withTarget: self) { undo($0) }
        undoManager.setActionName(name)
    }

    // MARK: Saving

    func save(to url: URL) throws {
        try config.settingFile().write(to: url)
        self.url = url
        baseline = config
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
            out.append(Change(target: .setting(id), label: Labels.setting(id),
                              before: Labels.format(baseline, id), after: Labels.format(config, id)))
        }
        for n in 0..<SettingNames.flags.count where config.flag(n) != baseline.flag(n) {
            out.append(Change(target: .flag(n), label: Labels.flag(n),
                              before: baseline.flag(n) ? "On" : "Off", after: config.flag(n) ? "On" : "Off"))
        }
        if config.data.assistantMemory != baseline.data.assistantMemory {
            out.append(Change(target: .assistants, label: "Assistants", before: "", after: "Reprogrammed"))
        }
        return out
    }
}

/// Human names and value formatting, used wherever the catalog has no richer label.
enum Labels {
    static func setting(_ id: Int) -> String {
        Catalog.shared.label(forSetting: id) ?? fallback(SettingNames.settings[id])
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
        guard let info = c.info.info(id), info.isSupported else { return "\(c.raw(id))" }
        let unit = Catalog.shared.unit(forSetting: id).map { " " + $0 } ?? ""
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
