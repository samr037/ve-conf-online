import Foundation
import Testing
import VEKit
@testable import VEConfigure

// Golden fixtures for the TypeScript port of the editing rules (web/src/lib/rules). The Swift app is the reference:
// for every private sample this records the pages and rows the app shows, what the rule engine evaluates, and what
// each edit does (accepted or refused, notices, change list, values), and the web tests must reproduce it exactly.
//
// Run:  VE_RULES_GOLDEN=web/fixtures/golden/rules swift test --filter RulesGoldenExport
// The output derives from the private samples: it stays out of Git (web/fixtures/.gitignore).

private let rulesGoldenOut = ProcessInfo.processInfo.environment["VE_RULES_GOLDEN"]
private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let gridKey = "XXXXXXXXXXXX"

@MainActor @Suite(.serialized, .enabled(if: rulesGoldenOut != nil, "set VE_RULES_GOLDEN"))
struct RulesGoldenExport {
    var out: URL {
        let u = URL(fileURLWithPath: rulesGoldenOut!, relativeTo: repoRoot)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func write(_ obj: Any, _ name: String) throws {
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try d.write(to: out.appendingPathComponent(name))
    }

    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    func opt(_ v: Any?) -> Any { v ?? NSNull() }

    @Test func catalogWide() throws {
        let cat = Catalog.shared
        var doc: [String: Any] = ["language": L10n.language, "locale": Locale.current.identifier]
        doc["cleanCaption"] = ["&File", "A&&B", "  Two  spaces:  ", "Line\r\nbreak:", "x &y& z :"].map { [$0, Catalog.cleanCaption($0)] }
        doc["gridClean"] = (cat.controls["GridCodeComboBox"]?.items ?? []).map { [$0.text.fallback, GridCodes.clean($0.text.fallback)] }
        doc["gridCodeNames"] = (0..<40).map { GridCodes.name($0) }
        doc["parseNumber"] = ["12", "-0.5", "48,2", " 7 ", "+3.", ".5", "1e3", "0x10", "nan", "inf", "", "1.2.3", "--1"].map { [$0, opt(ValueCodec.parseNumber($0))] }
        doc["units"] = ["Hr", "seconds", "sec", "Seconds", "deg C", "degC", "V", " A ", ""].map { [$0, opt(Units.display($0))] }
        doc["reflow"] = cat.controls.values.compactMap { $0.help?.text }.sorted().prefix(25).map { [$0, Catalog.reflow($0)] }
        doc["stripMarkup"] = ["\\FS:1\\Hello\\IS\\ world", "\\IL:http://x\\link", "plain"].map { [$0, stripMarkup($0)] }
        var controls: [[String: Any]] = []
        for name in cat.controls.keys.sorted() {
            let c = cat.controls[name]!
            controls.append(["name": name, "page": opt(cat.pageOfControl[name]), "staticLabel": opt(c.staticLabel),
                             "cleanDescription": opt(c.cleanDescription), "changeListLabel": opt(c.changeListLabel),
                             "settingTargets": c.settingTargets, "isRow": PageLayout.isRow(c), "hasCodec": ValueCodec(control: c) != nil])
        }
        doc["controls"] = controls
        doc["variables"] = cat.variables.keys.sorted().map { k in let v = cat.variables[k]!; return [k, v.kind.rawValue, v.index] as [Any] }
        doc["settingControls"] = cat.settingControls.keys.sorted().map { [$0, cat.settingControls[$0]!.name] as [Any] }
        doc["flagControls"] = cat.flagControls.keys.sorted().map { [$0, cat.flagControls[$0]!.name] as [Any] }
        doc["peerControlsBySetting"] = cat.peerControlsBySetting.keys.sorted().map { [$0, cat.peerControlsBySetting[$0]!.map(\.name)] as [Any] }
        doc["layouts"] = cat.pages.keys.sorted().map { name -> [String: Any] in
            ["page": name, "sections": PageLayout.sections(cat.pages[name]!).map { s in
                ["id": s.id, "title": opt(s.title?.fallback), "rows": s.rows.map { ["control": $0.control.name, "ancestors": $0.ancestors.map(\.name)] }]
            }]
        }
        doc["expressions"] = allExpressions().map { [$0, ExprParser.parse($0) != nil] as [Any] }
        doc["gridPageChoice"] = cat.gridCodePages.keys.sorted().map { k in [k, (0..<4).map { cat.gridCodePages[k]!.page(variant: $0) }] as [Any] }
        try write(doc, "catalog.json")
    }

    func allExpressions() -> [String] {
        let cat = Catalog.shared
        var set = Set<String>()
        for r in cat.rules { if let e = r.expr { set.insert(e) } }
        for c in cat.controls.values {
            for e in (c.enabledWhen ?? []) + (c.visibleWhen ?? []) { set.insert(e) }
            for t in [c.caption, c.label] + (c.labels ?? []).map(\.text) { for v in t?.variants ?? [] { if let w = v.when { set.insert(w) } } }
            for i in c.items ?? [] { for v in i.runtimeText ?? [] { if let w = v.when { set.insert(w) } } }
        }
        for g in cat.groups.values { for e in (g.enabledWhen ?? []) + (g.visibleWhen ?? []) { set.insert(e) } }
        set.insert(ReactivePanels.typeExpr)
        return set.sorted()
    }

    @Test func samples() throws {
        for name in ["s1", "s2", "s3", "s4", "s5"] {
            let url = repoRoot.appendingPathComponent("samples/\(name).rvsc")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try write(try sample(url, name), "\(name).json")
        }
    }

    // MARK: One sample

    func sample(_ url: URL, _ name: String) throws -> [String: Any] {
        let document = try ConfigDocument(url: url)
        let c = document.config
        var doc: [String: Any] = ["sample": name, "language": L10n.language, "locale": Locale.current.identifier]
        let ratings = MetaGenerator.ratings(c)
        doc["facts"] = ["dcVoltageClass": c.dcVoltageClass, "acVoltageClass": c.acVoltageClass, "isInverterOnly": c.isInverterOnly,
                        "cells": c.cells, "modelName": c.modelName, "ratings": [ratings.dc, ratings.ac, ratings.power],
                        "assistantIDs": AssistantDirectory(c).ids, "batteryPreset": opt(BatteryPresets.matching(c)?.id),
                        "gridPage": opt(GridPages.page(for: c)), "showsMicrogrid": GridPages.showsMicrogrid(c),
                        "paramsValid": GridPages.paramsValid(c), "gridCodeNeedsPassword": Access.gridCodeNeedsPassword(document.ruleContext)]
        doc["gridTable"] = c.gridTable.map { t in
            t.entries.keys.sorted().map { k -> [String: Any] in
                let e = t.entries[k]!
                return ["code": k, "variant": e.variant, "word": e.word, "editable": hex(e.editable), "present": hex(e.present),
                        "defaults": e.defaults.keys.sorted().map { [$0, Int(e.defaults[$0]!)] }]
            }
        } ?? NSNull()
        let ctx = document.ruleContext
        doc["expressions"] = allExpressions().map { e -> [Any] in [e, opt(ctx.evaluate(e))] }
        doc["values"] = allExpressions().compactMap { e -> [Any]? in
            guard let x = ExprParser.parse(e) else { return nil }
            return [e, value(ctx.eval(x))]
        }
        doc["variables"] = Catalog.shared.variables.keys.sorted().map { [$0, value(ctx.variableValue($0, in: c))] as [Any] }
        doc["labels"] = (0..<c.data.values.count).map { id -> [Any] in
            [Labels.setting(id, in: c), Labels.format(c, id), opt(Catalog.shared.label(forSetting: id)), opt(Catalog.shared.unit(forSetting: id))]
        }
        doc["flagLabels"] = (0..<SettingNames.flags.count).map { n -> [Any] in
            [Labels.flag(n), Catalog.shared.formatFlag(n, false), Catalog.shared.formatFlag(n, true)]
        }
        doc["access"] = (0..<c.data.values.count).map { id -> [Any] in
            [Int(Access.attribute(setting: id, c)), Access.isProtected(setting: id, c)]
        }
        doc["pages"] = pages(document)
        if c.isInverterOnly {
            let d2 = try ConfigDocument(url: url)
            d2.session.chargerUnhidden = true
            doc["pagesChargerUnhidden"] = pages(d2)
        }
        let unlocked = try ConfigDocument(url: url)
        _ = unlocked.unlockGrid(with: gridKey)
        doc["pagesUnlocked"] = pages(unlocked)
        doc["edits"] = try edits(url)
        doc["gridChoices"] = try gridChoices(url)
        doc["presets"] = try presets(url)
        doc["script"] = try script(url)
        doc["report"] = report(document)
        doc["save"] = try save(url)
        return doc
    }

    func value(_ v: EValue?) -> Any {
        switch v {
        case nil: return NSNull()
        case .number(let n)?: return n.isFinite ? ["n": n] : ["n": "\(n)"]
        case .string(let s)?: return ["s": s]
        case .list(let l)?: return ["l": l.map { value($0) }]
        }
    }

    func pages(_ document: ConfigDocument) -> [[String: Any]] {
        let ctx = document.ruleContext
        let c = ctx.config
        var out: [[String: Any]] = []
        for section in Section.allCases where section != .assistants {
            for entry in SectionPages.entries(section, ctx) {
                let visible = CatalogPageView.visibleSections(entry.page, ctx)
                out.append([
                    "section": section.rawValue, "sectionTitle": section.title, "id": entry.id, "title": entry.title,
                    "hasVisibleRows": SectionPages.hasVisibleRows(entry.page, ctx),
                    "sections": visible.map { v -> [String: Any] in
                        let settings = v.rows.filter { $0.control.kind != .text && $0.control.kind != .button }
                        let resetCount = settings.filter { Access.requiresReset($0.control, c) }.count
                        let allReset = resetCount > 0 && resetCount == settings.count
                        return ["id": v.section.id, "title": opt(resolveText(v.section.title, ctx)), "lit": v.lit.map(\.rawValue).sorted(),
                                "resetCount": resetCount,
                                "rows": v.rows.map { r -> [String: Any] in
                                    let row = RowState(control: r.control, ctx: ctx, enabled: SectionPages.isEnabled(r, page: entry.page.name, ctx),
                                                       page: entry.page.name, showsLock: section != .grid, showsResetMark: !allReset)
                                    return rowState(row)
                                }]
                    },
                ])
            }
        }
        return out
    }

    func rowState(_ row: RowState) -> [String: Any] {
        let c = row.config
        let ctl = row.control
        var d: [String: Any] = ["control": ctl.name, "kind": ctl.kind.rawValue, "enabled": row.enabled, "label": row.label,
                                "locked": row.locked, "resetRequired": row.resetRequired, "changed": row.changed,
                                "unit": opt(row.unit), "rangeDetail": opt(row.rangeDetail), "tooltip": row.tooltip,
                                "passwordAreas": Int(Access.passwordAreas(ctl, c))]
        if let k = row.codec {
            d["codec"] = ["supported": k.isSupported(c), "editable": k.isEditable, "raw": opt(k.raw(c)), "display": opt(k.display(c)),
                          "formatted": k.formatted(c, context: row.ctx), "precision": k.precision(c), "scale": k.scale(c), "offset": k.offset(c),
                          "range": k.range(c).map { ["min": $0.min, "max": $0.max, "default": opt($0.defaultValue), "step": $0.step] } ?? NSNull(),
                          "valueText": k.display(c).map { k.format($0, c) } ?? "—"]
        }
        switch ctl.kind {
        case .choice: d["options"] = CatalogChoiceRow.options(row).map { ["value": $0.value, "title": $0.title, "enabled": $0.enabled] }
        case .localToggle: d["checked"] = opt(LocalControls.isChecked(ctl.name, c))
        case .localChoice: d["selection"] = LocalControls.vs2OffAction(c)
        case .button where ctl.name == "BatteryTypeButton": d["preset"] = opt(BatteryPresets.matching(c).map { L10n.catalog($0.name) })
        case .text:
            d["text"] = stripMarkup(resolveRawText(ctl.label ?? ctl.caption, row.ctx) ?? ctl.text ?? "")
        default: break
        }
        return d
    }

    // MARK: Edits

    func record(_ document: ConfigDocument, _ extra: [String: Any] = [:]) -> [String: Any] {
        let c = document.config, b = document.baseline
        var d = extra
        d["notices"] = document.notices.map { [$0.title, $0.message, opt($0.actionTitle)] }
        d["changes"] = document.changes.map { [target($0.target), $0.label, $0.before, $0.after] }
        d["values"] = (0..<c.data.values.count).filter { c.raw($0) != b.raw($0) }.map { [$0, Int(c.raw($0))] }
        d["saveBlockReason"] = opt(document.saveBlockReason)
        // Restore every change through the change list, the way the user would.
        var reverted = 0
        while let ch = document.changes.first(where: { $0.target != .assistants }), reverted < 40 {
            document.notices = []
            document.revert(ch)
            reverted += 1
            if document.changes.first?.target == ch.target, document.changes.first?.after == ch.after { break }
        }
        d["afterRevert"] = ["changes": document.changes.map { [target($0.target), $0.label, $0.before, $0.after] },
                            "values": (0..<c.data.values.count).filter { document.config.raw($0) != b.raw($0) }.map { [$0, Int(document.config.raw($0))] },
                            "notices": document.notices.map { [$0.title, $0.message] }]
        return d
    }

    func target(_ t: ConfigDocument.Change.Target) -> String {
        switch t {
        case .setting(let i): "setting:\(i)"
        case .flag(let n): "flag:\(n)"
        case .assistants: "assistants"
        case .control(let s): "control:\(s)"
        case .gridCode: "gridCode"
        }
    }

    /// Every row of every visible page, edited the way its control edits (fresh document per edit).
    func edits(_ url: URL) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for unlocked in [false, true] {
            let probe = try ConfigDocument(url: url)
            if unlocked { _ = probe.unlockGrid(with: gridKey) }
            let ctx = probe.ruleContext
            var seen = Set<String>()
            for section in Section.allCases where section != .assistants {
                for entry in SectionPages.entries(section, ctx) {
                    for v in CatalogPageView.visibleSections(entry.page, ctx) {
                        for r in v.rows where !seen.contains(r.control.name) {
                            seen.insert(r.control.name)
                            let row = RowState(control: r.control, ctx: ctx, enabled: SectionPages.isEnabled(r, page: entry.page.name, ctx), page: entry.page.name)
                            // Locked rows are tried both ways; the others once, unlocked.
                            if !unlocked && !row.locked { continue }
                            for e in try editsFor(row, url: url, unlocked: unlocked) { out.append(e) }
                        }
                    }
                }
            }
        }
        return out
    }

    func fresh(_ url: URL, _ unlocked: Bool) throws -> ConfigDocument {
        let d = try ConfigDocument(url: url)
        if unlocked { _ = d.unlockGrid(with: gridKey) }
        return d
    }

    func editsFor(_ row: RowState, url: URL, unlocked: Bool) throws -> [[String: Any]] {
        let ctl = row.control
        var out: [[String: Any]] = []
        let base: [String: Any] = ["control": ctl.name, "unlocked": unlocked]
        func run(_ op: [String: Any], _ body: (ConfigDocument) -> [String: Any]) throws {
            let d = try fresh(url, unlocked)
            var e = base.merging(op) { a, _ in a }
            e.merge(body(d)) { a, _ in a }
            out.append(record(d, e))
        }
        switch ctl.kind {
        case .number:
            guard let k = row.codec, let r = k.range(row.config) else { return [] }
            let step = max(r.step, 1)
            for v in [r.min, r.max, (r.min + r.max) / 2, r.max + 10 * step, r.min - 10 * step, r.min + r.step / 3] {
                try run(["op": "setDisplay", "value": v]) { d in
                    var ok = true
                    d.edit("Change", control: ctl.name) { c in ok = k.setDisplay(v, in: &c) }
                    return ["ok": ok]
                }
            }
        case .toggle:
            guard let k = row.codec else { return [] }
            let on = (k.raw(row.config) ?? 0) != 0
            let new = !(on != ctl.isInverted)
            try run(["op": "toggle", "value": new, "confirm": ctl.name == "MicroGridModeCheckBox" && new]) { d in
                d.edit("Change", control: ctl.name) { c in k.setRaw((new != ctl.isInverted) ? 1 : 0, in: &c) }
                return [:]
            }
        case .localToggle:
            let new = !(LocalControls.isChecked(ctl.name, row.config) ?? false)
            try run(["op": "localToggle", "value": new, "confirm": ctl.name == "StopChargeDueToTempCheckBox" && new]) { d in
                d.edit("Change", control: ctl.name) { c in LocalControls.setChecked(ctl.name, new, in: &c) }
                return [:]
            }
        case .localChoice:
            for i in (ctl.items ?? []).indices {
                try run(["op": "localChoice", "value": i]) { d in
                    d.edit("Change", control: ctl.name) { LocalControls.setVs2OffAction(i, in: &$0) }
                    return [:]
                }
            }
        case .choice:
            guard let k = row.codec else { return [] }
            for o in CatalogChoiceRow.options(row) {
                try run(["op": "choose", "value": o.value]) { d in
                    var e: [String: Any] = ["lom": Confirmations.needsLOMConfirmation(control: ctl.name, newRaw: o.value, config: d.config)]
                    if ctl.name == "GridCodeComboBox" {
                        guard o.value != Int(d.config.raw(81)), !Access.isLocked(ctl, d.ruleContext) else { e["skipped"] = true; return e }
                        let choice = GridPages.choose(o.value, d.ruleContext)
                        e["choice"] = describe(choice)
                        if let n = autoResolve(choice) {
                            d.edit("Change Grid Code", control: ctl.name) { GridPages.apply(gridCode: n, to: &$0) }
                        }
                        return e
                    }
                    if ctl.name == "VirtualSwitchActionSelectRadioGroup" {
                        e["vsConfirm"] = o.value != 0 && (k.raw(d.config) ?? 0) == 0
                    }
                    d.edit("Change", control: ctl.name) { k.setRaw(o.value, in: &$0) }
                    return e
                }
            }
        default:
            break
        }
        return out
    }

    func describe(_ c: GridPages.Choice) -> [String: Any] {
        switch c {
        case .accept(let n): ["accept": n]
        case .reject(let m): ["reject": m]
        case .propose(let m, let a, let b, let k): ["propose": m, "alternative": a, "button": b, "keep": opt(k)]
        case .confirm(let m, let b, let t): ["confirm": m, "button": b, "then": describe(t)]
        }
    }

    func autoResolve(_ c: GridPages.Choice) -> Int? {
        switch c {
        case .accept(let n): n
        case .reject: nil
        case .propose(_, let a, _, _): a
        case .confirm(_, _, let t): autoResolve(t)
        }
    }

    func gridChoices(_ url: URL) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for unlocked in [false, true] {
            for n in 0..<34 {
                let d = try fresh(url, unlocked)
                let choice = GridPages.choose(n, d.ruleContext)
                var e: [String: Any] = ["code": n, "unlocked": unlocked, "choice": describe(choice)]
                d.edit("Change Grid Code", control: "GridCodeComboBox") { GridPages.apply(gridCode: n, to: &$0) }
                e["paramsValid"] = GridPages.paramsValid(d.config)
                e["page"] = opt(GridPages.page(for: d.config))
                out.append(record(d, e))
            }
        }
        return out
    }

    func presets(_ url: URL) throws -> [[String: Any]] {
        try Catalog.shared.batteryPresets.map { p in
            let d = try fresh(url, false)
            let values = BatteryPresets.order.map { [$0, opt(BatteryPresets.value(p, $0, d.config))] as [Any] }
            var note: Notice?
            d.edit("Apply Battery Preset") { cfg in note = BatteryPresets.apply(p, to: &cfg) }
            if let note { d.notices.append(note) }
            return record(d, ["preset": p.id, "presetValues": values, "matchingAfter": opt(BatteryPresets.matching(d.config)?.id)])
        }
    }

    /// A sequence of edits on one document: change list after each, then save-block state.
    func script(_ url: URL) throws -> [[String: Any]] {
        let d = try fresh(url, false)
        var steps: [[String: Any]] = []
        let names = ["AbsorptionVoltageEdit", "FloatVoltageEdit", "ChargeCurrentEdit", "DCLowShutDownEdit", "DCLowRestartEdit",
                     "InverterOutputVoltageEdit", "ACInputCurrentLimitEdit", "LithiumCheckBox", "EnableBatteryMonitorCheckBox"]
        for name in names {
            guard let ctl = Catalog.shared.controls[name], let k = ValueCodec(control: ctl), k.isSupported(d.config) else { continue }
            d.notices = []
            if ctl.kind == .number, let r = k.range(d.config) {
                let v = r.min + (r.max - r.min) * 0.37
                d.edit("Change", control: name) { _ = k.setDisplay(v, in: &$0) }
                steps.append(["control": name, "value": v, "notices": d.notices.map { [$0.title, $0.message] },
                              "changes": d.changes.map { [target($0.target), $0.label, $0.before, $0.after] }])
            } else if ctl.kind == .toggle {
                d.edit("Change", control: name) { c in k.setRaw((k.raw(c) ?? 0) == 0 ? 1 : 0, in: &c) }
                steps.append(["control": name, "notices": d.notices.map { [$0.title, $0.message] },
                              "changes": d.changes.map { [target($0.target), $0.label, $0.before, $0.after] }])
            }
        }
        return steps
    }

    func report(_ document: ConfigDocument) -> [String: Any] {
        let t0 = Date()
        let (header, blocks) = SettingsReport.blocks(for: document)
        let text = SettingsReport.plainText(for: document)
        let assistants = blocks.filter { $0.title.hasPrefix(Section.assistants.title + " › ") }
        return ["exportedAt": t0.timeIntervalSince1970, "header": header.map { [$0.0, $0.1] },
                "blocks": blocks.map { ["title": $0.title, "rows": $0.rows.map { [$0.0, $0.1] }] },
                "assistantBlocks": assistants.map { ["title": $0.title, "rows": $0.rows.map { [$0.0, $0.1] }] },
                "plainText": text]
    }

    func save(_ url: URL) throws -> [String: Any] {
        let d = try fresh(url, true)
        let before = d.config.raw(142)
        d.setRaw(142, before ^ 1, actionName: "Test")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("rules-golden-\(UUID()).rvsc")
        defer { try? FileManager.default.removeItem(at: output) }
        let now = Int64(Date().timeIntervalSince1970)
        do {
            try d.save(to: output)
        } catch {
            return ["error": "\(error)", "now": now]
        }
        let bytes = [UInt8](try Data(contentsOf: output))
        let saved = try DeviceConfiguration(contentsOf: output)
        return ["now": now, "tokenTime": saved.data.tokenTime, "bytes": hex(bytes), "changesAfter": d.changes.count]
    }
}
