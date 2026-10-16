import Foundation
import VEKit

// MARK: - Visibility and enablement

enum Visibility {
    /// VE Configure's generic rules: unsupported ⇒ hidden; Tag bit 0 ⇒ hidden helper; then `visibleWhen`.
    static func isVisible(_ c: CatalogControl, _ ctx: RuleContext) -> Bool {
        if (c.tag ?? 0) & 1 != 0 { return false }
        if c.visibleAtDesign == false && (c.visibleWhen ?? []).isEmpty { return false }
        if let codec = ValueCodec(control: c), !codec.isSupported(ctx.config) { return false }
        if c.handler("OnScaleSet") == "RenewableEnergyCheckBoxScaleSet",
           let id = LocalControls.setting("UBatDontChargeSettingEdit"), ctx.config.info.info(id)?.isSupported != true { return false }
        if c.name == "LOMAC1SettingComboBox", ctx.config.info.info(49)?.isSupported != true { return false }
        if c.kind == .text {
            // Warning labels are shown by their `warning` / `visibleWhen` rules only.
            for kind in ["visibleWhen", "warning"] {
                if let rules = Catalog.shared.conditions(for: c.name, kind: kind), !ctx.all(rules, unknownIs: false) { return false }
            }
            if c.name.localizedCaseInsensitiveContains("warning"), (c.visibleWhen ?? []).isEmpty,
               Catalog.shared.conditions(for: c.name, kind: "warning") == nil { return false }
        }
        return ctx.all(c.visibleWhen)
    }

    static func isVisible(_ g: CatalogGroup, _ ctx: RuleContext) -> Bool {
        if (g.tag ?? 0) & 16 != 0 { return false }
        if g.visibleAtDesign == false && (g.visibleWhen ?? []).isEmpty { return false }
        if let rules = Catalog.shared.conditions(for: g.name, kind: "visibleWhen"), !ctx.all(rules) { return false }
        return ctx.all(g.visibleWhen)
    }

    static func isVisible(page name: String, _ ctx: RuleContext) -> Bool {
        if name == "DDCSheetUnderDevelopment" { return false }
        if let rules = Catalog.shared.conditions(for: name, kind: "visibleWhen") { return ctx.all(rules) }
        return true
    }

    /// Extra enable conditions VE Configure applies from event handlers rather than from copied rules.
    static func extraEnabled(_ c: CatalogControl, page: String?, _ ctx: RuleContext) -> Bool {
        let cfg = ctx.config
        switch c.name {
        case "SoCWhenBulkFinishedEdit", "BatteryCapacityEdit", "ChargeEfficiencyEdit":
            // Battery monitor off (capacity 0) greys the group; the checkbox stays live.
            if Catalog.shared.controls["EnableBatteryMonitorCheckBox"].map({ isVisible($0, ctx) }) == true,
               LocalControls.isChecked("EnableBatteryMonitorCheckBox", cfg) == false { return false }
        case "LOWSOCStopSettingEdit", "LOWSOCStartSettingEdit":
            if LocalControls.isChecked("EnableLowSOCShutDownCheckBox", cfg) == false { return false }
        case "vs2UBatOffEdit":
            if LocalControls.vs2OffAction(cfg) < 2 { return false }
        case "AllowRushCurrentCheckBox":
            return false   // slaved to the UPS function
        default: break
        }
        if page == "ChargerSheet" {
            let warning = cfg.isInverterOnly && !ctx.session.chargerUnhidden
            switch c.name {
            case "EnableChargerCheckBox": return !warning
            case "Memo1", "HideInverterWarningButton": return true
            default:
                let disabled = Catalog.shared.variables["EBIT_DisableCharge"].map { cfg.flag($0.index) } ?? false
                if disabled || warning { return false }
            }
        }
        return true
    }
}

extension Catalog {
    /// Rule expressions of one kind whose target list names this node exactly.
    func conditions(for name: String, kind: String) -> [String]? {
        let exprs = rules.filter { $0.kind == kind && $0.targets.contains(name) }.compactMap(\.expr)
            .filter { ExprParser.parse($0) != nil }
        return exprs.isEmpty ? nil : exprs
    }
}

// MARK: - Grid pages

enum GridPages {
    static var selectionPage: String { "StandardTransferSwitchPage" }

    /// Which grid-code page VE Configure shows (FUN_00545f4c + caller FUN_00547548).
    static func page(for c: DeviceConfiguration) -> String? {
        let code = Int(c.raw(81))
        let noFeed = code < 2 || code == 21
        if noFeed { return nil }
        guard let entry = c.gridTable?.entries[code], let choice = Catalog.shared.gridCodePages[code] else { return nil }
        return choice.page(variant: entry.variant)
    }

    static func showsMicrogrid(_ c: DeviceConfiguration) -> Bool {
        Int(c.raw(81)) == 0 && (c.gridTable?.entries[0]?.variant ?? 0) != 0
    }

    /// Runtime page titles (FUN_00545f4c).
    static func title(page: String, _ c: DeviceConfiguration, fallback: String) -> String {
        let code = Int(c.raw(81))
        let variant = c.gridTable?.entries[code]?.variant ?? 0
        switch code {
        case 20: return L("Northern Ireland")
        case 31: return "UK G98"
        case 2: return c.gridTable?.entries[31] != nil ? "UK G99" : "UK"
        case 9: return variant > 1 ? "VFR 2019" : "UTE C15"
        case 11 where variant != 0: return "C10/11"
        case 12 where variant != 0: return "TOR Erzeuger Typ A"
        case 17: return L("European")
        case 18: return L("DK1 (Western Denmark)")
        case 19: return L("DK2 (Eastern Denmark)")
        case 30: return "Czech 2023"
        case 22...29: return [L("Australia A"), L("Australia B"), L("Australia C"), L("New Zealand")][(code > 25 ? code - 4 : code) - 22]
        default: return L10n.catalog(fallback.replacingOccurrences(of: " grid code settings", with: ""))
        }
    }

    /// §3.4: checker words A/B consistent with the grid code and the firmware's parameter-set version.
    static func paramsValid(_ c: DeviceConfiguration) -> Bool {
        let code = Int(c.raw(81)), a = Int(c.raw(128)), b = Int(c.raw(191))
        let ok = (code == 0 && a == 0xFFFF) || (a >> 8 == b >> 8 && a & 0xFF == code)
        guard ok else { return false }
        guard code != 0 || a != 0xFFFF else { return true }
        let ver = ((b & 0xFF) - (a & 0xFF)) & 0xFF
        return ver == (c.gridTable?.entries[code]?.variant ?? ver)
    }

    /// GridCodeComboBoxDataSet + AfterDataSet: the code, its default parameter words from the firmware table,
    /// and the checker words A = code, B = (code + variant) & 0xFF.
    /// Codes not in the device's table are not applied at all (their parameters are unknown).
    static func apply(gridCode n: Int, to c: inout DeviceConfiguration) {
        guard let entry = c.gridTable?.entries[n] else { return }
        c.setRaw(81, UInt16(n))
        for id in 129...190 where c.info.info(id)?.isSupported == true {
            c.setRaw(id, entry.isPresent(setting: id) ? (entry.defaults[id] ?? 0xFFFF) : 0xFFFF)
        }
        c.setRaw(128, UInt16(n))
        c.setRaw(191, UInt16((n + entry.variant) & 0xFF))
    }
}

// MARK: - Grid-code selection (GridCodeComboBoxDataSet @00545140)

extension GridPages {
    /// What happens when the user picks grid code `n`.
    indirect enum Choice: Equatable {
        case accept(Int)
        case reject(String)
        /// VE Configure proposes another code: the button applies `alternative`, cancelling keeps the current code.
        /// With `keep` set, declining applies `keep` instead (VE Configure's Yes/No).
        case propose(message: String, alternative: Int, button: String, keep: Int?)
        /// A rule depends on a device fact this app cannot read from the file: the user must confirm, then `then`.
        case confirm(message: String, button: String, then: Choice)
    }

    private static func rule(_ id: String, newValue n: Int, _ ctx: RuleContext) -> Bool? {
        guard let expr = Catalog.shared.rulesByID[id]?.expr else { return nil }
        return ctx.evaluate(expr.replacingOccurrences(of: "newValue", with: String(n)))
    }

    static func choose(_ n: Int, _ ctx: RuleContext) -> Choice {
        let c = ctx.config
        let name = { (g: Int) in GridCodes.name(g) }
        guard c.gridTable?.entries[n] != nil else {
            return .reject(L("Grid code “%@” is not supported by the firmware in this device.", name(n)))
        }
        let codeRules = byCode(n, ctx)
        // grid.extendedVEBus.reject: a MultiPlus-II ('/') part of a VE.Bus system with extended features.
        switch rule("grid.extendedVEBus.reject", newValue: n, ctx) {
        case false?: return .reject(extendedVEBusMessage)
        case nil:
            return .confirm(message: L("VE Configure for Mac cannot tell from the file whether this device is part of a VE.Bus system with extended features. VE Configure refuses the selection in that case:") + "\n\n" + extendedVEBusMessage,
                            button: L("The System Has No Extended Features"), then: codeRules)
        default: return codeRules
        }
    }

    private static var extendedVEBusMessage: String {
        L("A MultiPlus-II/Multigrid does not allow a grid code to be selected when it is part of a VE.Bus system with extended features!!\n\nRemove the extended features with the aid of VE.Bus System Configurator:\n - Do not uncheck any 'Switch as Group' box.\n - Do not use more than 1 AC input in a system with Multi's or do not use more than 2 AC Inputs in a system with Quattro's.")
    }

    /// The per-code checks. Device facts this app cannot read (internal interface protection) fail closed: option 5
    /// (internal NS protection) is never accepted on a guess, and the pre-485 restriction applies.
    private static func byCode(_ n: Int, _ ctx: RuleContext) -> Choice {
        let name = { (g: Int) in GridCodes.name(g) }
        switch n {
        case 4:
            // grid.vde.internalIP.4to5: only proposed when the device is known to have internal protection.
            if rule("grid.vde.internalIP.4to5", newValue: n, ctx) == true {
                return .propose(message: L("This device is equipped with internal interface protection!\nYou selected option:\n\n   %@\n\nIs it OK to change to option:\n\n   %@\n\ninstead?", name(4), name(5)),
                                alternative: 5, button: L("Use Option 5"), keep: 4)
            }
            return .accept(4)
        case 5:
            switch rule("grid.vde.noIP.5to4", newValue: n, ctx) {
            case false?: return .accept(5)
            case true?:
                return .propose(message: L("This device is not equipped with internal interface protection!\nSo you cannot choose option:\n\n   %@\n\nIs it OK to use option:\n\n   %@\n\ninstead?", name(5), name(4)),
                                alternative: 4, button: L("Use Option 4"), keep: nil)
            case nil:
                return .propose(message: L("Option:\n\n   %@\n\nis only allowed on a device equipped with internal interface protection. VE Configure for Mac cannot tell from the file whether this device has it.\n\nIs it OK to use option:\n\n   %@\n\ninstead?", name(5), name(4)),
                                alternative: 4, button: L("Use Option 4"), keep: nil)
            }
        case 6...19, 22...29:
            // grid.noIP.reject: firmware < 485 without internal interface protection (unknown = not equipped).
            if rule("grid.noIP.reject", newValue: n, ctx) != true {
                return .reject(L("This device is not equipped with internal interface protection!\nSo you cannot choose option:\n\n   %@", name(n)))
            }
            return .accept(n)
        case 0, 1, 2, 3, 20, 21, 30, 31, 32:
            return .accept(n)
        default:
            return .reject(L("Grid code “%@” is not supported by VE Configure for Mac.", name(n)))
        }
    }
}

// MARK: - Notices

/// A message VE Configure shows after a change (info, warning or a question with an action).
struct Notice: Identifiable, Equatable {
    enum Action: Equatable { case openBatteryPresets }
    let id = UUID()
    var title: String
    var message: String
    var action: Action?
    var actionTitle: String?

    static func == (a: Notice, b: Notice) -> Bool { a.id == b.id }
}

// MARK: - Validation (values VE Configure refuses: the old value is kept and a message shown)

enum Validation {
    /// The message VE Configure shows when it refuses the edit of `control` (`old` → `new`), or nil if accepted.
    static func rejection(old: DeviceConfiguration, new c: DeviceConfiguration, control: String?, _ ctx: RuleContext) -> Notice? {
        guard let name = control, let ctl = Catalog.shared.controls[name] else { return nil }
        if let n = orderRule(ctl, new: c, ctx) { return n }
        if let n = sequence(ctl, old: old, new: c) { return n }
        if let n = socNeedsMonitor(ctl, old: old, new: c, ctx) { return n }
        return nil
    }

    /// inverter.socEditNeedsMonitor (LOWSOCStopSettingEditAfterInputFormCreation @00548060): the SOC shut-down levels
    /// cannot be set while the battery monitor is disabled. Also applies to switching the SOC shut-down on, which
    /// sets those levels.
    private static func socNeedsMonitor(_ ctl: CatalogControl, old: DeviceConfiguration, new c: DeviceConfiguration, _ ctx: RuleContext) -> Notice? {
        guard let rule = Catalog.shared.rulesByID["inverter.socEditNeedsMonitor"], let expr = rule.expr else { return nil }
        let turningOn = ctl.name == "EnableLowSOCShutDownCheckBox"
            && LocalControls.isChecked(ctl.name, old) == false && LocalControls.isChecked(ctl.name, c) == true
        guard rule.targets.contains(ctl.name) || turningOn else { return nil }
        let before = RuleContext(config: old, baseline: ctx.baseline, session: ctx.session)
        // The monitor can only be off when its checkbox exists (BatteryCapacity minimum 0).
        guard let monitor = Catalog.shared.controls["EnableBatteryMonitorCheckBox"], Visibility.isVisible(monitor, before),
              before.evaluate(expr) != true else { return nil }
        return Notice(title: L("Battery monitor disabled"), message: L("Please enable the battery monitor on the general page first!"))
    }

    static func label(_ ctl: CatalogControl) -> String { capitalizedFirst(ctl.changeListLabel ?? ctl.name) }

    /// grid.chile.order / grid.romania.order (ChilePUVoltage @00550ef8, RomaniaPUVoltage @0055104c): U start < U stop,
    /// message 0x55e954.
    private static func orderRule(_ ctl: CatalogControl, new c: DeviceConfiguration, _ ctx: RuleContext) -> Notice? {
        for id in ["grid.chile.order", "grid.romania.order"] {
            guard let rule = Catalog.shared.rulesByID[id], rule.targets.contains(ctl.name), let expr = rule.expr else { continue }
            let after = RuleContext(config: c, baseline: ctx.baseline, session: ctx.session)
            guard after.evaluate(expr) == false else { continue }
            let names = rule.targets.compactMap { Catalog.shared.controls[$0] }.map(label)
            guard names.count == 2 else { continue }
            return Notice(title: L("Illegal value!"), message: L("Illegal value!\n%@ should be lower than %@!", names[0], names[1]))
        }
        return nil
    }

    /// grid.sequence (GenericSequenceNoEqualsTest @005500b4 / WithEqualsTest @005500d0): the RelevantComponents values
    /// must rise strictly (NoEquals) or not fall (WithEquals). Messages 0x55f630…0x55f834.
    private static func sequence(_ ctl: CatalogControl, old: DeviceConfiguration, new c: DeviceConfiguration) -> Notice? {
        guard let handler = ctl.handler("OnPeerDataSet"), handler.hasPrefix("GenericSequence"),
              let list = ctl.semantics?.relevantComponents, list.count >= 2 else { return nil }
        let equalsAllowed = handler == "GenericSequenceWithEqualsTest"
        let items = list.compactMap { Catalog.shared.controls[$0] }
        guard items.count == list.count else { return nil }
        let codecs = items.compactMap { ValueCodec(control: $0) }
        guard codecs.count == items.count, codecs.allSatisfy({ $0.isSupported(c) }) else { return nil }
        let values = codecs.compactMap { $0.display(c) }
        guard values.count == codecs.count else { return nil }
        // Only the edited control's change is judged (VE Configure checks on its OnPeerDataSet).
        guard let me = items.firstIndex(where: { $0.name == ctl.name }), codecs[me].raw(old) != codecs[me].raw(c) else { return nil }
        let ok = zip(values, values.dropFirst()).allSatisfy { equalsAllowed ? $0 <= $1 + 1e-9 : $0 < $1 - 1e-9 }
        guard !ok else { return nil }
        let title = L("The chosen value is not allowed!")
        if items.count == 2 {
            let other = me == 0 ? 1 : 0
            let otherText = label(items[other]) + " (" + codecs[other].formatted(c) + ")"
            let message: String
            switch (me == 0, equalsAllowed) {
            case (true, true): message = L("%@ must be lower than or equal to: %@", label(ctl), otherText)
            case (true, false): message = L("%@ must be lower than: %@", label(ctl), otherText)
            case (false, true): message = L("%@ must be higher than or equal to: %@", label(ctl), otherText)
            case (false, false): message = L("%@ must be higher than: %@", label(ctl), otherText)
            }
            return Notice(title: title, message: message)
        }
        let rows = zip(items, codecs).map { "  " + label($0) + ": " + $1.formatted(c) }.joined(separator: "\n")
        return Notice(title: title, message: (equalsAllowed
            ? L("The following values must be in rising order (equal values are allowed):")
            : L("The following values must be in rising order (equal values are not allowed):")) + "\n" + rows)
    }
}

// MARK: - Consequences of an edit (SetCheckRules and the AfterDataSet handlers)

enum Consequences {
    private static func v(_ name: String) -> VariableRef? { Catalog.shared.variables[name] }
    private static func flag(_ name: String, _ c: DeviceConfiguration) -> Bool? { v(name).map { c.flag($0.index) } }
    private static func setFlag(_ name: String, _ on: Bool, _ c: inout DeviceConfiguration) {
        if let r = v(name), c.supportsFlag(r.index) { c.setFlag(r.index, on) }
    }
    private static func codec(_ name: String) -> ValueCodec? { v(name).flatMap { ValueCodec(setting: $0.index) } }
    private static func display(_ name: String, _ c: DeviceConfiguration) -> Double? {
        guard let k = codec(name), k.isSupported(c) else { return nil }
        return k.display(c)
    }
    private static func raw(_ name: String, _ c: DeviceConfiguration) -> Int? { v(name).map { Int(c.raw($0.index)) } }
    private static func setRaw(_ name: String, _ r: Int, _ c: inout DeviceConfiguration) {
        if let ref = v(name), c.info.info(ref.index)?.isSupported == true { c.setRaw(ref.index, UInt16(clamping: r)) }
    }
    private static func changed(_ name: String, _ a: DeviceConfiguration, _ b: DeviceConfiguration) -> Bool {
        guard let r = v(name) else { return false }
        return r.kind == .flag ? a.flag(r.index) != b.flag(r.index) : a.raw(r.index) != b.raw(r.index)
    }

    /// Runs after every user edit; returns the messages to show. `old` is the configuration before the edit.
    static func apply(old: DeviceConfiguration, new c: inout DeviceConfiguration, control: String?) -> [Notice] {
        var notices: [Notice] = []

        // Charge curve chosen by the user: VE Configure resets the repeated absorption defaults (ManualChargeCharacteristicComboBoxChange).
        if control == "ChargeCharacteristicComboBox", changed("EPROM_ChargeCharacteristic", old, c) {
            let fixed = raw("EPROM_ChargeCharacteristic", c) == 1
            codec("EPROM_EqualiseQuarters")?.setDisplay(fixed ? 0.5 : 1, in: &c)
            codec("EPROM_FloatDays")?.setDisplay(fixed ? 1 : 7, in: &c)
            setFlag("EBIT_EnableReducedFloat", fixed ? false : !(flag("EBIT_LithiumBattery", c) ?? false), &c)
        }

        // 1. Float above absorption → float := absorption.
        if let abs = display("EPROM_UBatAbs", c), let fl = display("EPROM_UBatFloat", c), abs < fl - 1e-9,
           let r = raw("EPROM_UBatAbs", c) {
            setRaw("EPROM_UBatFloat", r, &c)
            notices.append(Notice(title: L("Float voltage adapted"), message: L("Absorption voltage must be higher than float voltage. The float voltage was set to the absorption voltage.")))
        }
        // 3. SoC low restart below shut-down → shut-down := restart.
        if let start = raw("EPROM_SOCStartInvert", c), let stop = raw("EPROM_SOCStopInvert", c), start != 0, start < stop {
            setRaw("EPROM_SOCStopInvert", start, &c)
            notices.append(Notice(title: L("SOC low shut-down adapted"), message: L("“SOC low restart” must not be lower than “SOC low shut-down”. “SOC low shut-down” was adapted.")))
        }
        // 4. VS2 load: "higher than" below "lower than" → lower := higher.
        if let hi = display("EPROM_vs2onILoadHigh", c), let lo = display("EPROM_vs2offILoadLow", c), hi < lo,
           let r = raw("EPROM_vs2onILoadHigh", c) {
            setRaw("EPROM_vs2offILoadLow", r, &c)
            notices.append(Notice(title: L("Limit adapted"), message: L("Secondary virtual switch “Load higher than” limit must be higher than the “Load lower than” limit. “Load lower than” limit was adapted.")))
        }
        // 5. VS2 battery: "Udc higher than" below "Udc lower than" → lower := higher.
        if let offRaw = raw("EPROM_vs2offUBat", c), offRaw > 0xFF, let off = display("EPROM_vs2offUBat", c),
           let low = display("EPROM_vs2onUBatLow", c), off < low {
            codec("EPROM_vs2onUBatLow")?.setDisplay(off, in: &c)
            notices.append(Notice(title: L("Limit adapted"), message: L("Secondary virtual switch “Udc lower than” limit must be lower than the “Udc higher than” limit. “Udc lower than” limit was adapted.")))
        }
        // 9. DC input low restart minimum 10.9 / 20.6 / 41.2 V.
        if let k = Catalog.shared.controls["DCLowRestartEdit"].flatMap(ValueCodec.init(control:)), k.isSupported(c),
           let restart = k.display(c) {
            let minimum = [12: 10.9, 24: 20.6, 48: 41.2][c.dcVoltageClass] ?? 10.9
            if restart < minimum - 1e-6 {
                k.setDisplay(minimum, in: &c)
                notices.append(Notice(title: L("Restart voltage adapted"), message: L("DC input low restart voltage must be ≥ %@ V. The restart voltage acts as an offset on the DC input low shut-down, so this can happen even when its own minimum looks lower.", minimum.formatted())))
            }
        }
        // UPS function ⇒ "allow low voltage during in-rush" follows it (MakeConsitenWithWaveShapeCheck).
        if let wave = flag("EBIT_DisableMainsWaveCheck", c) { setFlag("EBIT_DisableBFLockOnLargeCurrents", !wave, &c) }

        // 14. Lithium on/off side effects.
        if let was = flag("EBIT_LithiumBattery", old), let isNow = flag("EBIT_LithiumBattery", c), was != isNow {
            if isNow {
                setFlag("EBIT_EnableReducedFloat", false, &c)
                setFlag("EBIT_TubularPlateTractionBatteryCurve", false, &c)
                if let curve = raw("EPROM_ChargeCharacteristic", c), curve > 2 { setRaw("EPROM_ChargeCharacteristic", 1, &c) }
                if control == "LithiumCheckBox" {
                    notices.append(Notice(title: L("Lithium batteries"), message: L("This is not the only relevant setting for lithium batteries. Normally more settings need to be changed: use a battery preset to set them together."),
                                          action: .openBatteryPresets, actionTitle: L("Battery Presets…")))
                }
            } else {
                setRaw("EPROM_TBatStopCharge", 0, &c)
                setFlag("EBIT_ConfiguredForVEBusBMS", false, &c)
            }
        }
        // 13. "Stop after excessive bulk" needs the battery monitor.
        if let cap = raw("EPROM_BatteryCapacity", c), cap == 0, let ref = v("EBIT_DoNotStopAfter10HrBulk"), c.supportsFlag(ref.index),
           !c.flag(ref.index), changed("EPROM_BatteryCapacity", old, c) || changed("EBIT_DoNotStopAfter10HrBulk", old, c),
           Catalog.shared.controls["EnableBatteryMonitorCheckBox"].map({ Visibility.isVisible($0, RuleContext(config: c, baseline: old, session: .init())) }) == true {
            c.setFlag(ref.index, true)
            notices.append(Notice(title: L("“Stop after excessive bulk” disabled"), message: L("The battery monitor is disabled. The firmware requires the battery monitor for the bulk protection to work. To use “Stop after excessive bulk”, enable the battery monitor first.")))
        }
        // VS options: frequency shift on VS and on Udc are mutually exclusive.
        if flag("EBIT_vsSetInverterPeriodTime", c) == true, flag("EBIT_vsSetInverterPeriodTime", old) == false {
            setFlag("EBIT_vsInverterPeriodTimeOnUBat", false, &c)
        } else if flag("EBIT_vsInverterPeriodTimeOnUBat", c) == true, flag("EBIT_vsInverterPeriodTimeOnUBat", old) == false {
            setFlag("EBIT_vsSetInverterPeriodTime", false, &c)
        }
        // 12. Inverter period time follows the system frequency while the virtual switch is unused.
        if changed("EBIT_60Hz", old, c) || changed("EPROM_vsUsage", old, c),
           let usage = raw("EPROM_vsUsage", c), usage == 0 || c.info.info(v("EPROM_vsUsage")?.index ?? 15)?.isSupported != true,
           let f = Catalog.shared.controls["PeriodToFrequencySettingEdit"].flatMap(ValueCodec.init(control:)), f.isSupported(c) {
            f.setDisplay(flag("EBIT_60Hz", c) == true ? 60 : 50, in: &c)
        }
        // VS2 start/stop delay coupling (Checkvs2…FilterTime).
        if changed("EPROM_vs2tonILoadHigh", old, c), let on = raw("EPROM_vs2tonILoadHigh", c) {
            if on == 0 { setRaw("EPROM_vs2toffILoadLow", 0, &c) } else if raw("EPROM_vs2toffILoadLow", c) == 0 { setRaw("EPROM_vs2toffILoadLow", 1, &c) }
        } else if changed("EPROM_vs2toffILoadLow", old, c), raw("EPROM_vs2toffILoadLow", c) == 0 {
            setRaw("EPROM_vs2tonILoadHigh", 0, &c)
        }
        if changed("EPROM_vs2tonUBatLow", old, c) || changed("EPROM_vs2StartOnSOC", old, c) {
            let start = (raw("EPROM_vs2tonUBatLow", c) ?? 0) != 0 || (display("EPROM_vs2StartOnSOC", c).map { $0 != 0 } ?? false)
            if !start { setRaw("EPROM_vs2toffUBat", 0, &c) } else if raw("EPROM_vs2toffUBat", c) == 0 { setRaw("EPROM_vs2toffUBat", 1, &c) }
        } else if changed("EPROM_vs2toffUBat", old, c), raw("EPROM_vs2toffUBat", c) == 0 {
            setRaw("EPROM_vs2tonUBatLow", 0, &c)
            setRaw("EPROM_vs2StartOnSOC", 0, &c)
        }
        // Enabling the virtual switch disables assistants.
        if changed("EPROM_vsUsage", old, c), raw("EPROM_vsUsage", old) == 0, (raw("EPROM_vsUsage", c) ?? 0) != 0,
           !AssistantDirectory(c).ids.isEmpty {
            notices.append(Notice(title: L("Assistants will stop working"), message: L("Enabling the virtual switch disables the assistant functionality. VE Configure removes all configured assistants in this case; remove them on the Assistants tab, or set the virtual switch back to “Do not use VS”.")))
        }
        // Informative warnings.
        if control?.hasPrefix("RepeatedAbsorption") == true, let t = display("EPROM_EqualiseQuarters", c),
           let d = display("EPROM_FloatDays", c), t >= d * 24 {
            notices.append(Notice(title: L("Continuous absorption"), message: L("Repeated absorption time ≥ repeated absorption interval time. This results in continuous absorption.")))
        }
        if control == "TPTBCheckBox", flag("EBIT_TubularPlateTractionBatteryCurve", c) == true {
            notices.append(Notice(title: L("Tubular plate traction battery curve"), message: L("Note that the system DC voltage can get as high as %@ V.", "\(c.cells / 6 * 17)")))
        }
        if control == "ACLowSwitchOnEdit" || control == "ACHighSwitchOnEdit",
           let lo = Catalog.shared.controls["ACLowSwitchOnEdit"].flatMap(ValueCodec.init(control:))?.display(c),
           let hi = Catalog.shared.controls["ACHighSwitchOnEdit"].flatMap(ValueCodec.init(control:))?.display(c), lo >= hi {
            notices.append(Notice(title: L("AC connect levels"), message: L("AC low connect is set higher than or equal to AC high connect. The grid voltage would never be accepted.")))
        }
        if control == "GridCodeComboBox", let code = raw("EPROM_GridCode", c), code == 1 || code == 21 {
            notices.append(Notice(title: L("Not compliant with any standard"), message: L("With grid code “%@” the Multi/Quattro does not comply with any standard. Installing external certified equipment might be mandatory.", GridCodes.name(code))))
        }
        return notices
    }
}

// MARK: - Battery presets

enum BatteryPresets {
    /// Settings a preset may set, in VE Configure's order.
    static let order = ["EPROM_UBatAbs", "EPROM_UBatFloat", "EPROM_AbsorptionHours", "EPROM_EqualiseQuarters", "EPROM_FloatDays",
                        "EBIT_EnableReducedFloat", "EBIT_LithiumBattery", "EPROM_ChargeCharacteristic",
                        "EPROM_ChargePercentageResetValueForBatteryMonitor", "EPROM_ChargeEfficiency",
                        "EPROM_TempCompensationSlope", "EPROM_TBatStopCharge", "EBIT_ConfiguredForVEBusBMS"]
    static let voltageScaled: Set<String> = ["EPROM_UBatAbs", "EPROM_UBatFloat", "EPROM_TempCompensationSlope"]

    /// Value in this device's units (12 V preset values × cells/6).
    static func value(_ p: BatteryPreset, _ name: String, _ c: DeviceConfiguration) -> Double? {
        guard let v = p.values[name], !(p.notSet ?? []).contains(name), v.value < 1e40 else { return nil }
        return voltageScaled.contains(name) ? v.value * Double(c.cells) / 6 : v.value
    }

    /// The preset whose every value matches within half a step (FUN_0051cb68); most compared values wins.
    static func matching(_ c: DeviceConfiguration) -> BatteryPreset? {
        var best: (BatteryPreset, Int)?
        for p in Catalog.shared.batteryPresets {
            var compared = 0, ok = true
            for name in order {
                guard let target = value(p, name, c), let ref = Catalog.shared.variables[name], c.supports(ref) else { continue }
                compared += 1
                if ref.kind == .flag {
                    if c.flag(ref.index) != (target != 0) { ok = false; break }
                } else if let k = ValueCodec(setting: ref.index), let cur = k.display(c) {
                    if abs(cur - target) > abs(k.scale(c)) / 2 + 1e-9 { ok = false; break }
                }
            }
            if ok, compared > 0, compared > (best?.1 ?? 0) { best = (p, compared) }
        }
        return best?.0
    }

    /// Applies a preset (TBatteryDefaultForm OK → FUN_0051e574). Returns the summary message.
    static func apply(_ preset: BatteryPreset, to c: inout DeviceConfiguration) -> Notice {
        var p = preset
        var extra = ""
        if p.flags?.requiresVEBusBMSSupport == true,
           Catalog.shared.variables["EBIT_ConfiguredForVEBusBMS"].map({ c.supports($0) }) != true,
           let liion = Catalog.shared.batteryPresets.first(where: { $0.id == "cbtLiIon" }) {
            p = liion
            extra = L("The firmware in the Multi/Quattro does not support a VE.Bus BMS directly. An assistant is required to handle the VE.Bus BMS. Battery type set to standard Li-Ion.") + "\n\n"
        }
        var changedNames: [String] = []
        var limited: [String] = []
        for name in order {
            guard let target = value(p, name, c), let ref = Catalog.shared.variables[name], c.supports(ref) else { continue }
            let label = (ref.kind == .flag ? Catalog.shared.label(forFlag: ref.index) : Catalog.shared.label(forSetting: ref.index)) ?? name
            if ref.kind == .flag {
                if c.flag(ref.index) != (target != 0) { c.setFlag(ref.index, target != 0); changedNames.append(label) }
            } else if let k = ValueCodec(setting: ref.index) {
                let before = c.raw(ref.index)
                if !k.setDisplay(target, in: &c), let r = k.range(c) {
                    k.setDisplay(min(max(target, r.min), r.max), in: &c)
                    limited.append(label)
                }
                if c.raw(ref.index) != before { changedNames.append(label) }
            }
        }
        if let tptb = Catalog.shared.variables["EBIT_TubularPlateTractionBatteryCurve"], c.supportsFlag(tptb.index) { c.setFlag(tptb.index, false) }
        var msg = extra + (changedNames.isEmpty ? L("No settings needed to change.") : L("Changed: %@.", changedNames.joined(separator: ", ")))
        if !limited.isEmpty { msg += "\n\n" + L("Limited by the device range: %@.", limited.joined(separator: ", ")) }
        return Notice(title: L("Battery type set to %@", L10n.catalog(p.name)), message: msg)
    }
}

// MARK: - Diagram lighting

enum Lighting {
    /// Parts of the installation a set of variables acts on (the diagram lights them for the group in focus).
    static func parts(for controls: [CatalogControl], page: String, _ c: DeviceConfiguration) -> Set<DiagramPart> {
        var lit: Set<DiagramPart> = []
        let usage = Int(c.raw(15))
        for ctl in controls {
            let names = ([ctl.variable?.name] + (ctl.peer?.peers.map { $0.variable?.name } ?? [])).compactMap { $0 }
            for n in names {
                func has(_ keys: String...) -> Bool { keys.contains { n.localizedCaseInsensitiveContains($0) } }
                if has("GridSettings", "GridCode", "FeedIn", "GeneralGrid") { lit.formUnion([.acIn, .feedIn]) }
                else if has("vs2") { lit.formUnion(usage == 4 || usage == 6 ? [.generator, .acIn2, .relay] : [.acIn, .transferSwitch]) }
                else if has("EPROM_vs", "EBIT_vs", "fsUBat") { lit.formUnion([.relay]) }
                else if has("IMainsLimitAC1") { lit.formUnion([.acIn2]) }
                else if has("IMainsLimit", "RemoteOverrules", "CurrentSensor", "AdjustMainsLimit", "AllowIMainsHigher") { lit.formUnion([.acIn]) }
                else if has("UMains", "WideInput", "MainsWave", "BFLock") { lit.formUnion([.acIn, .transferSwitch]) }
                else if has("Assist") { lit.formUnion([.acIn, .inverter, .acOut]) }
                else if has("BatteryCapacity", "ChargePercentage", "ChargeEfficiency") { lit.formUnion([.battery, .dcBus]) }
                else if has("SOC", "UBat2Low", "UBatLowMargin", "UBatPreAlarm") { lit.formUnion([.battery, .inverter, .dcBus]) }
                else if has("60Hz", "UInvSetpoint", "RequestedInv", "AES", "GndRelay", "ShortCircuit", "IInv", "MultiPhase", "NrOfSlaves") { lit.formUnion([.inverter, .acOut]) }
                else if has("UBatAbs", "UBatFloat", "IBatBulk", "Charge", "Absorption", "Lithium", "TempComp", "TBat", "ReducedFloat",
                            "Tubular", "FloatDays", "EqualiseQuarters", "VEBusBMS", "WeakAC", "Bulk", "DontCharge", "Renewable", "VSense") {
                    lit.formUnion([.charger, .battery])
                }
            }
        }
        if lit.isEmpty {
            switch page {
            case "ChargerSheet", "AdvancedSheet": lit = [.charger, .battery]
            case "InverterSheet": lit = [.inverter, .acOut]
            default: break
            }
        }
        return lit
    }
}
