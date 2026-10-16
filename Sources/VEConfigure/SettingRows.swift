import SwiftUI
import VEKit

/// A numeric setting: physical value in a fixed tabular cell, unit, device range and default on hover.
struct NumberSettingRow: View {
    @ObservedObject var document: ConfigDocument
    let id: Int
    var label: String
    var unit: String?
    var help: String?

    @StateObject private var field = FieldState()

    var body: some View {
        let c = document.config
        if let info = c.info.info(id), info.isSupported {
            LabeledContent {
                HStack(spacing: 6) {
                    TextField(label, text: field.binding(current: Labels.number(info.display(c.raw(id)), step: info.step)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .font(.value)
                        .foregroundStyle(isChanged ? Theme.changed : .primary)
                        .frame(width: 84)
                        .onSubmit { commit(info) }
                        .accessibilityLabel(label)
                    Stepper(label, onIncrement: { step(info, +1) }, onDecrement: { step(info, -1) })
                        .labelsHidden()
                    Text(unit ?? "")
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                }
            } label: {
                SettingLabel(text: label, changed: isChanged, help: help,
                             detail: L("Range %@ – %@, default %@", Labels.number(info.display(info.minRaw), step: info.step), Labels.number(info.display(info.maxRaw), step: info.step) + (unit.map { " " + $0 } ?? ""), Labels.number(info.display(info.defaultRaw), step: info.step)))
            }
            .contextMenu { RestoreMenu(document: document, target: .setting(id), label: label) }
        }
    }

    private var isChanged: Bool { document.config.raw(id) != document.baseline.raw(id) }

    private func commit(_ info: SettingInfo) {
        defer { field.text = nil }
        guard let text = field.text else { return }
        let normalized = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(normalized) else { NSSound.beep(); return }
        document.setValue(id, v, actionName: L("Change %@", label))
    }

    private func step(_ info: SettingInfo, _ delta: Int) {
        let raw = Int(document.config.raw(id)) + delta
        guard raw >= Int(info.minRaw), raw <= Int(info.maxRaw) else { NSSound.beep(); return }
        document.setRaw(id, UInt16(raw), actionName: L("Change %@", label))
    }
}

/// Text being typed in a numeric field; nil while the field shows the stored value.
final class FieldState: ObservableObject {
    @Published var text: String?
    func binding(current: String) -> Binding<String> {
        Binding(get: { self.text ?? current }, set: { self.text = $0 })
    }
}

/// A flag bit shown as a checkbox (VE Configure's TSettingCheckBox).
struct FlagToggleRow: View {
    @ObservedObject var document: ConfigDocument
    let bit: Int
    var label: String
    var inverted = false
    var help: String?

    var body: some View {
        if document.config.supportsFlag(bit) {
            Toggle(isOn: Binding(
                get: { document.config.flag(bit) != inverted },
                set: { document.setFlag(bit, $0 != inverted, actionName: L("Change %@", label)) }
            )) {
                SettingLabel(text: label, changed: isChanged, help: help, detail: nil)
            }
            .toggleStyle(.switch)
            .contextMenu { RestoreMenu(document: document, target: .flag(bit), label: label) }
        }
    }

    private var isChanged: Bool { document.config.flag(bit) != document.baseline.flag(bit) }
}

/// A setting with named values (VE Configure's TSettingComboBox / TSettingRadioGroup).
struct ChoiceSettingRow: View {
    @ObservedObject var document: ConfigDocument
    let id: Int
    var label: String
    var options: [(value: UInt16, title: String)]
    var help: String?

    var body: some View {
        if document.config.info.info(id)?.isSupported == true {
            Picker(selection: Binding(
                get: { document.config.raw(id) },
                set: { document.setRaw(id, $0, actionName: L("Change %@", label)) }
            )) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            } label: {
                SettingLabel(text: label, changed: document.config.raw(id) != document.baseline.raw(id), help: help, detail: nil)
            }
            .contextMenu { RestoreMenu(document: document, target: .setting(id), label: label) }
        }
    }
}

struct SettingLabel: View {
    var text: String
    var changed: Bool
    var help: String?
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            if changed { Text(L("changed")).font(.caption2).foregroundStyle(Theme.changed).accessibilityHidden(false) }
        }
        .help([help, detail].compactMap { $0 }.joined(separator: "\n\n"))
    }
}

struct RestoreMenu: View {
    @ObservedObject var document: ConfigDocument
    let target: ConfigDocument.Change.Target
    let label: String

    var body: some View {
        if let change = document.changes.first(where: { $0.target == target }) {
            Button(L("Restore Loaded Value (%@)", change.before)) { document.revert(change) }
        } else {
            Button(L("Restore Loaded Value")) {}.disabled(true)
        }
    }
}

// MARK: - Catalog-driven rows

/// A runtime caption as displayed, in the interface language.
func resolveText(_ t: CatalogText?, _ ctx: RuleContext) -> String? {
    resolveRawText(t, ctx).map { L10n.catalog($0) }
}

/// Resolves a runtime caption (English): the first variant whose `when` holds, else the literal.
func resolveRawText(_ t: CatalogText?, _ ctx: RuleContext) -> String? {
    guard let t else { return nil }
    if let variants = t.variants, !variants.isEmpty {
        for v in variants {
            guard let when = v.when else { continue }
            if when == "otherwise" || when == "always" { continue }
            if ctx.evaluate(when) == true, let text = v.text { return Catalog.cleanCaption(text) }
        }
        if let other = variants.first(where: { $0.when == "otherwise" || $0.when == "always" })?.text { return Catalog.cleanCaption(other) }
    }
    let s = Catalog.cleanCaption(t.fallback)
    return s.isEmpty ? nil : s
}

/// Victron writes some labels in lower case ("waiting time", "enable AES"); keep the wording, capitalise the first letter.
func capitalizedFirst(_ s: String) -> String {
    guard let f = s.first, f.isLowercase else { return s }
    return f.uppercased() + s.dropFirst()
}

/// Removes VE Configure's THandyLabel markup (\FS:1\, \IS\, \IL:url\ …).
func stripMarkup(_ s: String) -> String {
    s.replacingOccurrences(of: #"\\[A-Z]{2}(:[^\\]*)?\\"#, with: "", options: .regularExpression)
}

/// Everything a row needs to decide how it looks right now.
struct RowState {
    let control: CatalogControl
    let ctx: RuleContext
    let enabled: Bool
    let page: String?
    /// False on pages that already carry the password banner.
    var showsLock = true
    /// False when the whole section requires a reset (said once in the section footer instead).
    var showsResetMark = true

    var codec: ValueCodec? { ValueCodec(control: control) }
    var config: DeviceConfiguration { ctx.config }

    var label: String { capitalizedFirst(rawLabel) }

    private var rawLabel: String {
        if control.name == "StopChargeBelowTBatSettingEdit" { return L("Battery temperature limit") }
        let l = resolveRawText(control.label ?? control.caption, ctx)
        if let l, l.count > 3, l != "for" { return L10n.catalog(l) }
        if l == "for" { return control.cleanDescription.map { L("Delay — %@", $0) } ?? L("Delay") }
        return control.cleanDescription ?? L10n.catalog(control.help?.title) ?? l.map(L10n.catalog) ?? control.name
    }

    var locked: Bool { Access.isLocked(control, ctx) }
    var resetRequired: Bool { Access.requiresReset(control, config) }

    var changed: Bool {
        if let v = control.variable, v.kind == .flag, let n = v.index { return config.flag(n) != ctx.baseline.flag(n) }
        return control.settingTargets.contains { config.raw($0) != ctx.baseline.raw($0) }
    }

    var unit: String? {
        guard var u = control.unit, !u.isEmpty else { return nil }
        if u == "Hr" { u = "h" } else if u == "seconds" { u = "s" } else if u == "deg C" || u == "degC" { u = "°C" }
        return L10n.catalog(u)
    }

    /// Range, default and step line for the tooltip and the info popover.
    var rangeDetail: String? {
        guard let k = codec, control.kind == .number, let r = k.range(config) else { return nil }
        let u = unit.map { " " + $0 } ?? ""
        var parts = [L("Range %@ – %@", k.format(r.min, config), k.format(r.max, config) + u)]
        if let d = r.defaultValue { parts.append(L("default %@", k.format(d, config) + u)) }
        if r.step > 0 { parts.append(L("step %@", k.format(r.step, config))) }
        return parts.joined(separator: ", ")
    }

    var helpText: String? { control.help?.text.map { L10n.catalog(Catalog.reflow($0)) } }

    var tooltip: String {
        var parts: [String] = []
        if let d = control.cleanDescription, d != label { parts.append(d) }
        if let r = rangeDetail { parts.append(r) }
        if let h = helpText { parts.append(String(h.prefix(400)) + (h.count > 400 ? "…" : "")) }
        return parts.joined(separator: "\n\n")
    }
}

/// Label column: changed stub, text, and the reset / password markers.
struct CatalogLabel: View {
    let row: RowState

    var body: some View {
        HStack(spacing: 6) {
            Text(row.label)
                .fixedSize(horizontal: false, vertical: true)
            if row.locked && row.showsLock {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(L("Protected by the grid code password"))
                    .accessibilityLabel(L("Locked, grid code password required"))
            }
            if row.resetRequired && row.showsResetMark {
                Image(systemName: "arrow.clockwise")
                    .font(.callout)
                    .foregroundStyle(Theme.nonDefault)
                    .help(L("A change requires a device reset after upload"))
                    .accessibilityLabel(L("Requires reset"))
            }
            if row.changed { Text(L("changed")).font(.caption2).foregroundStyle(Theme.changed) }
        }
        .help(row.tooltip)
    }
}

/// The ⓘ button: explains the setting (CHM help), its range, default and what a change implies.
struct InfoButton: View {
    let row: RowState
    @StateObject private var popover = Flag()

    var body: some View {
        Button { popover.on.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(L("About this setting"))
        .accessibilityLabel(L("About %@", row.label))
        .popover(isPresented: $popover.on, arrowEdge: .trailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.catalog(row.control.help?.title) ?? row.label).font(.headline)
                    if let d = row.control.cleanDescription, d != row.label {
                        Text(d).font(.callout).foregroundStyle(.secondary)
                    }
                    if let r = row.rangeDetail {
                        Label(r, systemImage: "ruler").font(.callout.monospacedDigit())
                    }
                    if let h = row.helpText {
                        Text(h).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    if row.resetRequired {
                        Label(Access.infoText["reset"]!, systemImage: "arrow.clockwise.circle").font(.callout)
                    }
                    if Access.passwordAreas(row.control, row.config) & 1 != 0 || row.control.name == "GridCodeComboBox" {
                        Label(Access.infoText["password"]!, systemImage: "lock").font(.callout)
                    }
                    if let codec = row.codec, !codec.isEditable {
                        Label(L("This value is derived from several grid words by a VE Configure handler that this app does not reproduce yet. It is shown read-only."), systemImage: "eye")
                            .font(.callout)
                    }
                    let names = Access.refs(of: row.control).map(\.name).filter { !$0.isEmpty }
                    if !names.isEmpty {
                        Text(L("Stored in %@", names.joined(separator: ", ")))
                            .font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
                .padding(16)
                .frame(width: 380, alignment: .leading)
            }
            .frame(maxHeight: 460)
        }
    }
}

/// One catalog control as a form row.
struct CatalogRow: View {
    @ObservedObject var document: ConfigDocument
    let row: RowState
    var openPresets: () -> Void = {}

    var body: some View {
        Group {
            switch row.control.kind {
            case .number: CatalogNumberRow(document: document, row: row)
            case .toggle: toggle
            case .choice: CatalogChoiceRow(document: document, row: row)
            case .localToggle: localToggle
            case .localChoice: localChoice
            case .button: button
            case .text: note
            case .canvas: ChargeCurveView(config: row.config)
            default: EmptyView()
            }
        }
        .contextMenu {
            if !row.control.settingTargets.isEmpty || row.control.variable?.kind == .flag {
                Button(L("Restore Loaded Value")) { restore() }.disabled(!row.changed)
            }
        }
    }

    private func restore() {
        let base = row.ctx.baseline
        document.edit(L("Restore %@", row.label), control: row.control.name) { c in
            if let v = row.control.variable, v.kind == .flag, let n = v.index { c.setFlag(n, base.flag(n)) }
            for id in row.control.settingTargets { c.setRaw(id, base.raw(id)) }
        }
    }

    private var editable: Bool { row.enabled && !row.locked }

    private var toggle: some View {
        let codec = row.codec
        let on = (codec?.raw(row.config) ?? 0) != 0
        return LabeledContent {
            HStack(spacing: 8) {
                Toggle(row.label, isOn: Binding(
                    get: { on != row.control.isInverted },
                    set: { new in
                        if row.control.name == "MicroGridModeCheckBox", new, !Confirmations.allowMicrogrid() { return }
                        document.edit(L("Change %@", row.label), control: row.control.name) { c in
                            codec?.setRaw((new != row.control.isInverted) ? 1 : 0, in: &c)
                        }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!editable || codec?.isEditable == false)
                InfoButton(row: row)
            }
        } label: { CatalogLabel(row: row) }
        .opacity(row.enabled ? 1 : 0.55)
    }

    private var localToggle: some View {
        let on = LocalControls.isChecked(row.control.name, row.config) ?? false
        return LabeledContent {
            HStack(spacing: 8) {
                Toggle(row.label, isOn: Binding(
                    get: { on },
                    set: { new in
                        document.edit(L("Change %@", row.label), control: row.control.name) { c in
                            LocalControls.setChecked(row.control.name, new, in: &c)
                        }
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!editable)
                InfoButton(row: row)
            }
        } label: { CatalogLabel(row: row) }
    }

    private var localChoice: some View {
        let items = row.control.items ?? []
        return LabeledContent {
            Picker(row.label, selection: Binding(
                get: { LocalControls.vs2OffAction(row.config) },
                set: { i in document.edit(L("Change stop condition"), control: row.control.name) { LocalControls.setVs2OffAction(i, in: &$0) } }
            )) {
                ForEach(items.indices, id: \.self) { i in Text(L10n.catalog(items[i].text.fallback)).tag(i) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!editable)
        } label: { Text(L("Stop condition")) }
    }

    @ViewBuilder private var button: some View {
        switch row.control.name {
        case "BatteryTypeButton":
            LabeledContent {
                HStack(spacing: 8) {
                    Button(L("Battery Presets…"), action: openPresets).disabled(!row.enabled)
                    InfoButton(row: row)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Battery type"))
                    Text(BatteryPresets.matching(row.config).map { L10n.catalog($0.name) } ?? L("No corresponding preset"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case "HideInverterWarningButton":
            Button(row.label) { document.session.chargerUnhidden = true }
        default:
            EmptyView()
        }
    }

    private var note: some View {
        let text = stripMarkup(resolveRawText(row.control.label ?? row.control.caption, row.ctx) ?? row.control.text ?? "")
        let warning = row.control.name.localizedCaseInsensitiveContains("warning") || row.control.name.contains("Error")
            || text.localizedCaseInsensitiveContains("not ") && text.count < 80
        return Label {
            Text(L10n.catalog(Catalog.cleanCaption(text))).font(.callout).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(warning ? Theme.warning : .secondary)
        }
        .foregroundStyle(warning ? .primary : .secondary)
    }
}

struct CatalogNumberRow: View {
    @ObservedObject var document: ConfigDocument
    let row: RowState
    @StateObject private var field = FieldState()

    var body: some View {
        let c = row.config
        let codec = row.codec
        let value = codec?.display(c)
        let editable = row.enabled && !row.locked && codec?.isEditable == true
        LabeledContent {
            HStack(spacing: 6) {
                TextField(row.label, text: field.binding(current: value.map { codec!.format($0, c) } ?? "—"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .font(.value)
                    .foregroundStyle(row.changed ? Theme.changed : .primary)
                    .frame(width: 84)
                    .onSubmit(commit)
                    .accessibilityLabel(row.label)
                    .disabled(!editable)
                Stepper(row.label, onIncrement: { step(+1) }, onDecrement: { step(-1) })
                    .labelsHidden()
                    .disabled(!editable)
                Text(row.unit ?? "")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                InfoButton(row: row)
            }
        } label: { CatalogLabel(row: row) }
        .opacity(row.enabled ? 1 : 0.55)
    }

    private func commit() {
        defer { field.text = nil }
        guard let text = field.text, let codec = row.codec else { return }
        let normalized = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(normalized) else { NSSound.beep(); return }
        var ok = true
        document.edit(L("Change %@", row.label), control: row.control.name) { c in ok = codec.setDisplay(v, in: &c) }
        if !ok { NSSound.beep() }
    }

    private func step(_ direction: Int) {
        guard let codec = row.codec, let raw = codec.raw(row.config), let now = codec.display(row.config) else { return }
        // Step the raw value in whichever direction raises (or lowers) the displayed value.
        let up = (codec.display(raw: raw + 1, row.config) ?? now) > now
        let next = raw + (up == (direction > 0) ? 1 : -1)
        guard let v = codec.display(raw: next, row.config) else { return }
        if let r = codec.range(row.config), v < r.min - 1e-9 || v > r.max + 1e-9 { NSSound.beep(); return }
        document.edit(L("Change %@", row.label), control: row.control.name) { c in codec.setRaw(next, in: &c) }
    }
}

struct CatalogChoiceRow: View {
    @ObservedObject var document: ConfigDocument
    let row: RowState

    struct Option: Hashable { var value: Int; var title: String; var enabled: Bool }

    private var options: [Option] {
        let c = row.config
        let current = row.codec?.raw(c)
        let lithium = Catalog.shared.variables["EBIT_LithiumBattery"].map { c.flag($0.index) } ?? false
        return (row.control.items ?? []).compactMap { item in
            guard let value = item.value else { return nil }
            let selected = current.map { item.matches($0) } ?? false
            if !selected {
                if item.hidden == true || item.plusMarked == true { return nil }
                if row.control.name == "ChargeCharacteristicComboBox", lithium, value == 3 { return nil }
            }
            var title = item.displayText(context: row.ctx)
            var enabled = true
            if row.control.name == "GridCodeComboBox" {
                title = GridCodes.clean(title)
                enabled = c.gridTable?.entries[value] != nil
            }
            if row.control.name == "VirtualSwitchActionSelectRadioGroup", let u = Catalog.shared.vsUsage[value] {
                let inverted = Catalog.shared.variables["EBIT_vsInvert"].map { c.flag($0.index) } ?? false
                title = (inverted ? u.labelInverted : nil) ?? u.label
            }
            return Option(value: value, title: L10n.catalog(Catalog.cleanCaption(title)), enabled: enabled)
        }
    }

    var body: some View {
        let c = row.config
        let codec = row.codec
        let raw = codec?.raw(c) ?? -1
        let opts = options
        let selection = (row.control.items ?? []).first(where: { $0.matches(raw) })?.value ?? raw
        let editable = row.enabled && !row.locked && codec?.isEditable == true
        let style = pickerStyle(opts)
        if style == .radio {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CatalogLabel(row: row)
                    Spacer()
                    InfoButton(row: row)
                }
                picker(opts, selection: selection, style: style)
                    .disabled(!editable)
                    .padding(.leading, 9)
            }
            .opacity(row.enabled ? 1 : 0.55)
        } else {
        LabeledContent {
            HStack(spacing: 6) {
                picker(opts, selection: selection, style: style)
                    .disabled(!editable)
                // Same trailing edge as numeric rows: their unit column sits between stepper and ⓘ.
                Color.clear.frame(width: 44, height: 1)
                InfoButton(row: row)
            }
        } label: { CatalogLabel(row: row) }
        .opacity(row.enabled ? 1 : 0.55)
        }
    }

    private enum Style { case menu, segmented, radio }

    private func pickerStyle(_ opts: [Option]) -> Style {
        guard row.control.class == "TSettingRadioGroup" else { return .menu }
        if opts.count <= 3, opts.allSatisfy({ $0.title.count < 14 }) { return .segmented }
        return .radio
    }

    @ViewBuilder
    private func picker(_ opts: [Option], selection: Int, style: Style) -> some View {
        let binding = Binding<Int>(get: { selection }, set: { choose($0) })
        let p = Picker(row.label, selection: binding) {
            ForEach(opts, id: \.self) { o in
                Text(o.title).tag(o.value).disabled(!o.enabled)
            }
        }
        .labelsHidden()
        switch style {
        case .menu:
            if row.control.name == "GridCodeComboBox" { p.pickerStyle(.menu).frame(maxWidth: 420, alignment: .trailing) } else { p.pickerStyle(.menu).fixedSize() }
        case .segmented: p.pickerStyle(.segmented).fixedSize()
        case .radio: p.pickerStyle(.radioGroup).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose(_ value: Int) {
        guard let codec = row.codec else { return }
        guard Confirmations.allowLOM(control: row.control.name, newRaw: value, config: row.config) else { return }
        if row.control.name == "VirtualSwitchActionSelectRadioGroup", value != 0, (codec.raw(row.config) ?? 0) == 0 {
            let count = document.assistants.installed.count
            guard Confirmations.allowVirtualSwitch(assistantCount: count) else { return }
            document.edit(L("Change %@", row.label), control: row.control.name) { codec.setRaw(value, in: &$0) }
            if count > 0 { document.assistants.removeAll() }
            return
        }
        if row.control.name == "GridCodeComboBox" {
            document.edit(L("Change Grid Code"), control: row.control.name) { GridPages.apply(gridCode: value, to: &$0) }
            return
        }
        document.edit(L("Change %@", row.label), control: row.control.name) { codec.setRaw(value, in: &$0) }
    }
}

/// The charge curve (ChargeCurvePaintBox): bulk, absorption and float with the configured voltages.
struct ChargeCurveView: View {
    let config: DeviceConfiguration

    var body: some View {
        let abs = Catalog.shared.variables["EPROM_UBatAbs"].flatMap { ValueCodec(setting: $0.index)?.display(config) }
        let float = Catalog.shared.variables["EPROM_UBatFloat"].flatMap { ValueCodec(setting: $0.index)?.display(config) }
        let hours = Catalog.shared.variables["EPROM_AbsorptionHours"].flatMap { ValueCodec(setting: $0.index)?.display(config) }
        let fixed = config.raw(10) == 1
        if let abs, let float {
            VStack(alignment: .leading, spacing: 4) {
                Canvas { ctx, size in
                    let top = 14.0, bottom = size.height - 16
                    let lo = min(float, abs) * 0.9, hi = max(abs, float) * 1.01
                    func y(_ v: Double) -> CGFloat { bottom - CGFloat((v - lo) / (hi - lo)) * (bottom - top) }
                    let x1 = size.width * 0.28, x2 = size.width * 0.62
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: y(lo + (abs - lo) * 0.35)))
                    p.addCurve(to: CGPoint(x: x1, y: y(abs)), control1: CGPoint(x: x1 * 0.5, y: y(lo + (abs - lo) * 0.7)),
                               control2: CGPoint(x: x1 * 0.8, y: y(abs)))
                    p.addLine(to: CGPoint(x: x2, y: y(abs)))
                    p.addLine(to: CGPoint(x: x2 + 10, y: y(float)))
                    p.addLine(to: CGPoint(x: size.width, y: y(float)))
                    ctx.stroke(p, with: .color(Theme.dcPositive), lineWidth: 2)
                    var grid = Path()
                    for x in [x1, x2] { grid.move(to: CGPoint(x: x, y: top)); grid.addLine(to: CGPoint(x: x, y: bottom)) }
                    ctx.stroke(grid, with: .color(Theme.wire), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    let f = { (v: Double) in v.formatted(.number.precision(.fractionLength(2))) + " V" }
                    ctx.draw(Text(L("Bulk")).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: x1 / 2, y: bottom + 8))
                    ctx.draw(Text(fixed ? L("Absorption") : L("Absorption (adaptive)")).font(.caption2).foregroundColor(.secondary),
                             at: CGPoint(x: (x1 + x2) / 2, y: bottom + 8))
                    ctx.draw(Text(L("Float")).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: (x2 + size.width) / 2, y: bottom + 8))
                    ctx.draw(Text(f(abs)).font(.caption.monospacedDigit()), at: CGPoint(x: (x1 + x2) / 2, y: y(abs) - 8))
                    ctx.draw(Text(f(float)).font(.caption.monospacedDigit()), at: CGPoint(x: (x2 + size.width) / 2, y: y(float) - 8))
                    if let hours {
                        ctx.draw(Text(fixed ? L("%@ h", hours.formatted()) : L("max %@ h", hours.formatted())).font(.caption2.monospacedDigit()).foregroundColor(.secondary),
                                 at: CGPoint(x: (x1 + x2) / 2, y: y(abs) + 9))
                    }
                }
                .frame(height: 96)
                .accessibilityLabel(L("Charge curve: absorption %@ volt, float %@ volt", abs.formatted(.number.precision(.fractionLength(2))), float.formatted(.number.precision(.fractionLength(2)))))
            }
        }
    }
}

/// A Bool view state (the SwiftUI `@State` macro needs Xcode's plugins).
final class Flag: ObservableObject {
    @Published var on = false
}
