import SwiftUI
import VEKit

// MARK: - Page structure

/// A form section built from the catalog: a captioned group box, or a run of loose controls.
struct LayoutSection: Identifiable {
    let id: String
    var title: CatalogText?
    var rows: [LayoutRow] = []
}

struct LayoutRow: Identifiable {
    let control: CatalogControl
    /// Containers between the page and the control; their visibility and enable rules apply to it.
    let ancestors: [CatalogGroup]
    var id: String { control.name }
}

enum PageLayout {
    private static var cache: [String: [LayoutSection]] = [:]

    static func sections(_ page: CatalogPage) -> [LayoutSection] {
        if let hit = cache[page.name] { return hit }
        var b = Builder()
        b.process(columnPages.contains(page.name) ? sortedTopLevel(page.children) : page.children, ancestors: [])
        b.flush()
        let result = b.sections.filter { !$0.rows.isEmpty }
        cache[page.name] = result
        return result
    }

    /// Pages whose two Delphi columns read better column by column (frames are in page coordinates there).
    private static let columnPages: Set<String> = ["InverterSheet"]

    /// Two-column Delphi pages read column by column, then top to bottom.
    private static func sortedTopLevel(_ nodes: [CatalogNode]) -> [CatalogNode] {
        let lefts = nodes.compactMap { $0.frame?.first }
        guard lefts.contains(where: { $0 < 150 }), lefts.contains(where: { $0 >= 196 }) else { return nodes }
        return nodes.enumerated().sorted { a, b in
            let ca = (a.element.frame?.first ?? 0) >= 196 ? 1 : 0, cb = (b.element.frame?.first ?? 0) >= 196 ? 1 : 0
            if ca != cb { return ca < cb }
            let ta = a.element.frame?[safe: 1] ?? 0, tb = b.element.frame?[safe: 1] ?? 0
            return ta != tb ? ta < tb : a.offset < b.offset
        }.map(\.element)
    }

    static func isRow(_ c: CatalogControl) -> Bool {
        switch c.kind {
        case .number, .toggle, .choice, .localToggle, .localChoice: return true
        case .button: return ["BatteryTypeButton", "HideInverterWarningButton"].contains(c.name)
        case .canvas: return c.name == "ChargeCurvePaintBox"
        case .text:
            let skip = ["LocationFor", "Dummy", "Helper", "SizeLabel", "BoxWidth", "StaticText", "HintLabel"]
            if skip.contains(where: { c.name.contains($0) }) || c.name == "Label3" { return false }
            if c.class == "TMemo" { return (c.text ?? "").count > 20 }
            if !(c.visibleWhen ?? []).isEmpty || c.name.localizedCaseInsensitiveContains("warning") { return true }
            let t = c.label?.fallback ?? c.caption?.fallback ?? ""
            return t.count > 60 && c.class != "TRelatedLabel"
        default: return false
        }
    }

    private struct Builder {
        var sections: [LayoutSection] = []
        var current = LayoutSection(id: "loose-0")
        var counter = 0

        mutating func flush() {
            if !current.rows.isEmpty { sections.append(current) }
            counter += 1
            current = LayoutSection(id: "loose-\(counter)")
        }

        mutating func process(_ nodes: [CatalogNode], ancestors: [CatalogGroup]) {
            // A checkbox drawn on an uncaptioned group box's border is that group's header (PowerAssist, AES…).
            var headers: [String: CatalogControl] = [:]
            var consumed: Set<String> = []
            for case .group(let g) in nodes where g.kind == .groupBox {
                let caption = g.caption.map { $0.fallback.trimmingCharacters(in: .whitespaces) } ?? ""
                guard caption.isEmpty, g.caption?.variants == nil, let gf = g.frame, gf.count == 4 else { continue }
                for case .control(let c) in nodes where (c.kind == .toggle || c.kind == .localToggle) && !consumed.contains(c.name) {
                    if let f = c.frame, f.count == 4, abs(f[1] - gf[1]) <= 8, f[0] >= gf[0] - 4, f[0] <= gf[0] + gf[2] {
                        headers[g.name] = c; consumed.insert(c.name); break
                    }
                }
            }
            for node in nodes where !consumed.contains(node.name) {
                switch node {
                case .control(let c):
                    if PageLayout.isRow(c) { current.rows.append(LayoutRow(control: c, ancestors: ancestors)) }
                case .group(let g):
                    let caption = g.caption.map { $0.fallback.trimmingCharacters(in: .whitespaces) } ?? ""
                    let titled = g.kind == .groupBox && (!caption.isEmpty || g.caption?.variants != nil)
                    let header = headers[g.name]
                    if titled || header != nil {
                        flush()
                        current = LayoutSection(id: g.name, title: titled ? g.caption : nil)
                        if let header { current.rows.append(LayoutRow(control: header, ancestors: ancestors)) }
                        process(g.children, ancestors: ancestors + [g])
                        flush()
                    } else {
                        process(g.children, ancestors: ancestors + [g])
                    }
                default:
                    break
                }
            }
        }
    }
}

/// The sub-pages of a sidebar section, as VE Configure would show them for this file.
enum SectionPages {
    struct Entry: Identifiable { let id: String; let title: String; let page: CatalogPage }

    static let sheet: [Section: String] = [
        .general: "GeneralSheet", .grid: "GridSheet", .inverter: "InverterSheet", .charger: "ChargerSheet",
        .virtualSwitch: "VirtualSwitchsheet", .assistants: "DDCSheet", .advanced: "AdvancedSheet",
    ]

    static func entries(_ section: Section, _ ctx: RuleContext) -> [Entry] {
        let cat = Catalog.shared
        guard let name = sheet[section], let page = cat.pages[name] else { return [] }
        switch section {
        case .grid:
            var out: [Entry] = []
            if let p = cat.pages[GridPages.selectionPage] { out.append(Entry(id: p.name, title: "Grid Code", page: p)) }
            if let n = GridPages.page(for: ctx.config), let p = cat.pages[n] {
                out.append(Entry(id: n, title: GridPages.title(page: n, ctx.config, fallback: resolveText(p.caption, ctx) ?? n), page: p))
            }
            if GridPages.showsMicrogrid(ctx.config), let p = cat.pages["MicroGridPage"] {
                out.append(Entry(id: p.name, title: "Microgrid", page: p))
            }
            return out
        case .virtualSwitch:
            var pages: [CatalogPage] = []
            for case .pageControl(let pc) in page.children { pages = pc.pages }
            return pages.filter { Visibility.isVisible(page: $0.name, ctx) && hasVisibleRows($0, ctx) }.map { p in
                let short = ["VirtualSwitchUsageSheet": "Usage", "VirtualSwitchOnSheet": "A: Set VS On",
                             "VirtualSwitchOffSheet": "B: Set VS Off", "VirtualSwitchOptionsSheet": "Options"][p.name]
                return Entry(id: p.name, title: short ?? resolveText(p.caption, ctx) ?? p.name, page: p)
            }
        default:
            return [Entry(id: page.name, title: section.title, page: page)]
        }
    }

    static func hasVisibleRows(_ page: CatalogPage, _ ctx: RuleContext) -> Bool {
        PageLayout.sections(page).contains { s in s.rows.contains { isVisible($0, ctx) && $0.control.kind != .text } }
    }

    static func isVisible(_ row: LayoutRow, _ ctx: RuleContext) -> Bool {
        row.ancestors.allSatisfy { Visibility.isVisible($0, ctx) } && Visibility.isVisible(row.control, ctx)
    }

    static func isEnabled(_ row: LayoutRow, page: String, _ ctx: RuleContext) -> Bool {
        row.ancestors.allSatisfy { ctx.all($0.enabledWhen) } && ctx.all(row.control.enabledWhen)
            && Visibility.extraEnabled(row.control, page: Catalog.shared.pageOfControl[row.control.name] == "ChargerSheet" ? "ChargerSheet" : page, ctx)
    }
}

// MARK: - Section view

/// UI state of the open page (sheets), kept outside the configuration.
final class PageUIState: ObservableObject {
    @Published var askingPassword = false
    @Published var password = ""
    @Published var showingPresets = false
    @Published var presetID: String?
}

/// One sidebar tab rendered from the catalog: sub-page picker, then a grouped form of its group boxes.
struct SectionView: View {
    let section: Section
    @ObservedObject var document: ConfigDocument
    @ObservedObject var state: WindowState
    @StateObject private var ui = PageUIState()

    var body: some View {
        let ctx = document.ruleContext
        let entries = SectionPages.entries(section, ctx)
        let selected = entries.first { $0.id == state.subpage[section] } ?? entries.first
        VStack(spacing: 0) {
            if section == .assistants {
                AssistantsPage(document: document)
            } else if let selected {
                if entries.count > 1 {
                    Picker("Page", selection: Binding(get: { selected.id }, set: { state.subpage[section] = $0 })) {
                        ForEach(entries) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    Divider()
                }
                CatalogPageView(document: document, page: selected.page, section: section, ctx: ctx, ui: ui, focus: state.focus)
                    .id(selected.id)
            } else {
                emptyPage
            }
        }
        .sheet(isPresented: $ui.askingPassword) { PasswordSheet(document: document, ui: ui) }
        .sheet(isPresented: $ui.showingPresets) { BatteryPresetSheet(document: document, ui: ui) }
        .alert(document.notices.first?.title ?? "", isPresented: Binding(
            get: { !document.notices.isEmpty },
            set: { if !$0, !document.notices.isEmpty { document.notices.removeFirst() } }
        ), presenting: document.notices.first) { notice in
            if let title = notice.actionTitle, notice.action == .openBatteryPresets {
                Button(title) { ui.showingPresets = true }
            }
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    private var emptyPage: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No settings on this page").font(.callout.weight(.medium))
            Text("The firmware in this device does not support any of the settings on this page.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct CatalogPageView: View {
    @ObservedObject var document: ConfigDocument
    let page: CatalogPage
    let section: Section
    let ctx: RuleContext
    @ObservedObject var ui: PageUIState
    let focus: DiagramFocus

    struct Visible: Identifiable {
        let section: LayoutSection
        let rows: [LayoutRow]
        let lit: Set<DiagramPart>
        var id: String { section.id }
    }

    var body: some View {
        let visible = visibleSections
        Form {
            if section == .grid, page.name == GridPages.selectionPage || visible.contains(where: { $0.rows.contains { Access.isLocked($0.control, ctx) } }) {
                passwordBanner
            }
            if section == .grid, !GridPages.paramsValid(ctx.config), page.name == GridPages.selectionPage {
                SwiftUI.Section {
                    Label("The grid code parameters do not match the selected grid code or belong to another firmware version. Select the grid code again to load its defaults (password required).",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
            }
            ForEach(visible) { v in
                SwiftUI.Section {
                    ForEach(v.rows) { r in
                        CatalogRow(document: document,
                                   row: RowState(control: r.control, ctx: ctx, enabled: SectionPages.isEnabled(r, page: page.name, ctx), page: page.name),
                                   openPresets: { ui.showingPresets = true })
                            .onHover { inside in
                                if inside { focus.hovered = v.lit } else if focus.hovered == v.lit { focus.hovered = nil }
                            }
                    }
                } header: {
                    if let t = resolveText(v.section.title, ctx) { Text(t) }
                }
            }
            if visible.isEmpty {
                Text("The firmware in this device does not support any of the settings on this page.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { focus.page = visible.reduce(into: Set<DiagramPart>()) { $0.formUnion($1.lit) }; focus.hovered = nil }
    }

    private var visibleSections: [Visible] {
        PageLayout.sections(page).compactMap { s in
            let rows = s.rows.filter { SectionPages.isVisible($0, ctx) }
            // A section of notes only (all its settings hidden) is dropped, like VE Configure's empty group boxes.
            guard rows.contains(where: { $0.control.kind != .text }) || rows.contains(where: { !($0.control.visibleWhen ?? []).isEmpty }) else { return nil }
            return Visible(section: s, rows: rows, lit: Lighting.parts(for: rows.map(\.control), page: page.name, ctx.config))
        }
    }

    @ViewBuilder private var passwordBanner: some View {
        SwiftUI.Section {
            if document.session.gridPasswordEntered {
                Label("Grid code password entered. It is checked by the device when you upload the file.", systemImage: "lock.open")
                    .foregroundStyle(.secondary)
            } else if Access.gridCodeNeedsPassword(ctx) {
                HStack {
                    Label("Grid code settings are protected. As in VE Configure, changing them requires the grid code password from your installer or Victron.",
                          systemImage: "lock.fill")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Unlock with Password…") { ui.askingPassword = true }
                }
            }
        }
    }
}

// MARK: - Sheets

struct PasswordSheet: View {
    @ObservedObject var document: ConfigDocument
    @ObservedObject var ui: PageUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Grid Code Password", systemImage: "lock.fill").font(.headline)
            Text("Changing the grid code or its parameters requires the grid code password. This app cannot verify it offline: the device checks it when the file is uploaded, and rejects protected changes if it is wrong.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $ui.password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(unlock)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { ui.password = ""; ui.askingPassword = false }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ui.password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func unlock() {
        guard !ui.password.isEmpty else { return }
        document.enterGridPassword(ui.password)
        ui.password = ""
        ui.askingPassword = false
    }
}

/// VE Configure's battery type dialog (TBatteryDefaultForm): presets in this system's voltage.
struct BatteryPresetSheet: View {
    @ObservedObject var document: ConfigDocument
    @ObservedObject var ui: PageUIState

    var body: some View {
        let c = document.config
        let presets = Catalog.shared.batteryPresets
        let current = BatteryPresets.matching(c)
        let selected = presets.first { $0.id == (ui.presetID ?? current?.id) } ?? presets.first
        VStack(alignment: .leading, spacing: 12) {
            Text("Battery Presets").font(.headline)
            Text("Sets the charger for a battery type in one step. Values are shown for this \(c.dcVoltageClass) V system. A preset is not stored in the device: afterwards every value stays editable.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                List(presets, selection: Binding(get: { selected?.id }, set: { ui.presetID = $0 })) { p in
                    HStack {
                        Text(p.name).lineLimit(2)
                        Spacer()
                        if p.id == current?.id { Text("current").font(.caption).foregroundStyle(Theme.changed) }
                    }
                    .tag(p.id)
                }
                .frame(width: 280, height: 300)
                if let selected { table(selected, c) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { ui.showingPresets = false }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard let selected else { return }
                    var note: Notice?
                    document.edit("Apply Battery Preset") { cfg in note = BatteryPresets.apply(selected, to: &cfg) }
                    ui.showingPresets = false
                    if let note { document.notices.append(note) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 680)
    }

    private func table(_ p: BatteryPreset, _ c: DeviceConfiguration) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(BatteryPresets.order, id: \.self) { name in
                if let ref = Catalog.shared.variables[name], c.supports(ref) {
                    let label = (ref.kind == .flag ? Catalog.shared.label(forFlag: ref.index) : Catalog.shared.label(forSetting: ref.index)) ?? name
                    GridRow {
                        Text(label).foregroundStyle(.secondary)
                        Text(valueText(p, name, ref, c)).font(.value)
                    }
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func valueText(_ p: BatteryPreset, _ name: String, _ ref: VariableRef, _ c: DeviceConfiguration) -> String {
        guard let v = BatteryPresets.value(p, name, c) else { return "unchanged" }
        if ref.kind == .flag { return v != 0 ? "On" : "Off" }
        if name == "EPROM_ChargeCharacteristic" { return [1: "Fixed", 2: "Adaptive", 3: "Adaptive + BatterySafe"][Int(v)] ?? "\(v)" }
        if name == "EPROM_TBatStopCharge", v <= -20.5 { return "Off" }
        let k = ValueCodec(setting: ref.index)
        let unit = Catalog.shared.settingControls[ref.index]?.unit.map { $0 == "Hr" ? " h" : " " + $0 } ?? ""
        return (k?.format(v, c) ?? "\(v)") + unit
    }
}

