import Foundation
import VEKit

/// How a catalog control reads and writes the device configuration:
/// a direct setting (with VE Configure's scale/offset hooks), a flag bit, or a peer view of grid words.
struct ValueCodec {
    enum Binding {
        case setting(Int)
        case flag(Int)
        case peer(CatalogControl.PeerSpec, PeerHandler)
    }

    /// The `OnPeerDataSet` handlers this app reproduces. `.readOnly` ones are shown but not editable.
    enum PeerHandler {
        case plain, readOnlyPlain, unreadable
        case twoWords32, newMovingAverage, euFLowStage1, euFHighStage1, euWaitingTime
        case polandFStart, minCosPhi, torD4Delay, lom, vdeCosPhi

        init(_ name: String?) {
            switch name {
            case nil: self = .plain
            case "UMainsMovingAveragePeerDataSet": self = .twoWords32
            case "NewUMainsMovingAveragePeerDataSet": self = .newMovingAverage
            case "EU_FLowStage1DelaySettingEditPeerDataSet": self = .euFLowStage1
            case "EU_FHighStage1DelaySettingEditPeerDataSet": self = .euFHighStage1
            case "EU_WaitingTimeSettingEditPeerDataSet": self = .euWaitingTime
            case "PolandFStartPeerDataSet": self = .polandFStart
            case "MinCosPhiPeerDataSet": self = .minCosPhi
            case "TOR_D4_DisconnectDelayPeerDataSet": self = .torD4Delay
            case "LOMAC0SettingComboBoxPeerDataSet": self = .lom
            case "VDECosPhiValuePeerDataSet": self = .vdeCosPhi
            case "GenericSequenceNoEqualsTest", "GenericSequenceWithEqualsTest", "MicroGridModeCheckBoxPeerDataSet",
                 "ReactivePowerTypeSettingComboBoxPeerDataSet", "EnableLockInOnUSettingCheckBoxPeerDataSet",
                 "EU_PFHighFStartStopSettingEditPeerDataSet", "AS4777PowerRampPeeringEditPeerDataSet",
                 "NRS097PowerRampPeeringEditPeerDataSet", "CEI_PxMaxSettingEditPeerDataSet",
                 "CEI_NSStartStopDelaySettingEditPeerDataSet", "ChilePUVoltageSettingEditPeerDataSet",
                 "RomaniaPUVoltageEditPeerDataSet":
                self = .plain
            case "CEI_NSHFStartFreqSettingEditPeerDataSet", "CEI_NSLFStartFreqSettingEditPeerDataSet",
                 "CEI_NSLFStopFreqSettingEditPeerDataSet", "CEI_NSHFStopFreqSettingEditPeerDataSet",
                 "AS4777VoltageAPeeringEditPeerDataSet", "AS4777VoltageBPeeringEditPeerDataSet",
                 "AS4777VoltageCPeeringEditPeerDataSet", "AS4777VoltageDPeeringEditPeerDataSet",
                 "AS4777OffsetAPeeringEditPeerDataSet", "AS4777OffsetBPeeringEditPeerDataSet",
                 "AS4777OffsetCPeeringEditPeerDataSet", "AS4777OffsetDPeeringEditPeerDataSet":
                self = .readOnlyPlain   // writing regenerates curve words (slopes, droop lines): not reproduced yet
            default:
                self = .unreadable      // CEI droop, AS4777 FStop, f/P and U/Q droop: derived values
            }
        }
    }

    let control: CatalogControl
    let binding: Binding

    init?(control: CatalogControl) {
        self.control = control
        if let peer = control.peer, !peer.peers.isEmpty {
            binding = .peer(peer, PeerHandler(control.handler("OnPeerDataSet")))
        } else if let v = control.variable, let i = v.index, v.kind == .setting {
            binding = .setting(i)
        } else if let v = control.variable, let i = v.index, v.kind == .flag {
            binding = .flag(i)
        } else {
            return nil
        }
    }

    init?(setting id: Int) {
        guard let c = Catalog.shared.settingControls[id] else { return nil }
        self.init(control: c)
    }

    // MARK: Support

    func isSupported(_ c: DeviceConfiguration) -> Bool {
        switch binding {
        case .setting(let i): return c.info.info(i)?.isSupported == true
        case .flag(let n): return n < 80 && c.supportsFlag(n)
        case .peer(let spec, _): return spec.peers.allSatisfy { p in p.variable?.index.map { c.info.info($0)?.isSupported == true } ?? false }
        }
    }

    var isEditable: Bool {
        if case .peer(_, let h) = binding { return h != .readOnlyPlain && h != .unreadable }
        return true
    }

    // MARK: Scale and offset (direct settings)

    /// Effective display scale: device scale × OnScaleSet hooks (AdaptScaleTo…, InvertScale, power, mV).
    func scale(_ c: DeviceConfiguration) -> Double {
        switch binding {
        case .setting(let i):
            var s = c.info.info(i)?.scale ?? 1
            switch control.handler("OnScaleSet") {
            case "AdaptScaleToSeconds": s *= 60
            case "AdaptScaleToHours": s /= 60
            case "AdaptScaleToDays": s /= 1440
            case "InvertScale": s = -s
            case "TempCompensationSettingEditScaleSet": s *= -1000
            case "ConvertIInvLimitToPowerLimit":
                if let inv = c.info.info(5), inv.isSupported { s *= inv.display(inv.defaultRaw) }
            default: break
            }
            return s
        case .flag: return 1
        case .peer(let spec, _): return spec.codec.scale
        }
    }

    /// Effective offset, including the coupled offsets VE Configure sets at runtime (§3 of Part C).
    func offset(_ c: DeviceConfiguration) -> Double {
        guard case .setting(let i) = binding else {
            if case .peer(let spec, _) = binding { return spec.codec.offset }
            return 0
        }
        func idx(_ name: String) -> Int? { Catalog.shared.controls[name]?.variable?.index }
        func off(_ id: Int?) -> Double { id.flatMap { c.info.info($0) }.map { Double($0.offset) } ?? 0 }
        func raw(_ id: Int?) -> Double { id.map { Double(c.raw($0)) } ?? 0 }
        switch control.name {
        case "DCLowRestartEdit":
            let sd = idx("DCLowShutDownEdit")
            return off(sd) + raw(sd)
        case "UBatPreAlarmOffsetEdit":
            let sd = idx("DCLowShutDownEdit"), rs = idx("DCLowRestartEdit")
            return off(sd) + raw(sd) + raw(rs) - 32768
        case "ACLowSwitchOnEdit":
            let lo = idx("ACLowSwitchOffEdit")
            return off(lo) + raw(lo)
        case "ACHighSwitchOnEdit":
            let hi = idx("ACHighSwitchOffEdit")
            return -off(hi) - raw(hi)
        default:
            return off(i)
        }
    }

    // MARK: Raw

    /// The control's own raw value: the setting, the flag bit (0/1), or the peer field.
    func raw(_ c: DeviceConfiguration) -> Int? {
        switch binding {
        case .setting(let i): return Int(c.raw(i))
        case .flag(let n): return c.flag(n) ? 1 : 0
        case .peer(let spec, let handler):
            let w = spec.peers.map { p in p.variable?.index.map { Int(c.raw($0)) } ?? 0 }
            let p0 = spec.peers[0]
            func field(_ word: Int) -> Int {
                var r = (word & p0.mask) >> p0.shift
                if let sb = spec.codec.signBit, sb > 0, r >> sb & 1 == 1 { r -= 1 << (sb + 1) }
                return r
            }
            switch handler {
            case .plain, .readOnlyPlain: return field(w[0])
            case .unreadable, .vdeCosPhi: return w[0]
            case .twoWords32: return w.count > 1 ? w[0] + w[1] * 65536 : nil
            case .newMovingAverage:
                guard w.count > 1 else { return nil }
                let r = ((w[1] & 0xF000) >> 8) + ((w[0] & 0xF000) >> 12)
                return r > 127 ? r - 256 : r
            case .euFLowStage1: return w.count > 1 ? ((w[0] & 0xF000) >> 4) + (w[1] & 0xFF) : nil
            case .euFHighStage1: return w.count > 1 ? ((w[0] & 0xF000) >> 4) + ((w[1] & 0xFF00) >> 8) : nil
            case .euWaitingTime: return (w[0] & 0xFFF) - 4096
            case .polandFStart: return (w[0] >> 8) & 0xFF
            case .minCosPhi:
                if w[0] & 0x8000 != 0 { return 0 }
                return Int((cos(atan(Double(w[0]) / 256)) * 100).rounded())
            case .torD4Delay: return w[0] == 3 ? 0 : field(w[0])
            case .lom:
                let g = w[0]
                if lomBit4Supported(c) {
                    var r = g & 0x03
                    if g & 0x10 == 0 { r |= 0x04 }
                    return r & 7
                }
                return g & 0x03
            }
        }
    }

    private func lomBit4Supported(_ c: DeviceConfiguration) -> Bool {
        guard case .peer(let spec, _) = binding, let i = spec.peers.first?.variable?.index, let info = c.info.info(i) else { return false }
        return info.maxRaw & 0x10 != 0
    }

    /// Writes a new raw value; returns false when the device range or the handler rejects it.
    @discardableResult
    func setRaw(_ value: Int, in c: inout DeviceConfiguration) -> Bool {
        switch binding {
        case .setting(let i):
            guard let info = c.info.info(i) else { return false }
            let clamped = min(max(value, Int(info.minRaw)), Int(info.maxRaw))
            c.setRaw(i, UInt16(clamping: clamped))
            return clamped == value
        case .flag(let n):
            c.setFlag(n, value != 0)
            return true
        case .peer(let spec, let handler):
            guard isEditable else { return false }
            let ids = spec.peers.compactMap { $0.variable?.index }
            guard !ids.isEmpty else { return false }
            var w = ids.map { Int(c.raw($0)) }
            let p0 = spec.peers[0]
            func insert(_ word: Int, _ r: Int) -> Int {
                let width = p0.width
                let masked = width >= 32 ? r : r & ((1 << width) - 1)
                return (word & ~p0.mask) | ((masked << p0.shift) & p0.mask)
            }
            switch handler {
            case .plain, .torD4Delay: w[0] = insert(w[0], value)
            case .twoWords32:
                guard w.count > 1 else { return false }
                w[0] = value & 0xFFFF; w[1] = (value >> 16) & 0xFFFF
            case .newMovingAverage:
                guard w.count > 1 else { return false }
                w[0] = (w[0] & 0x0FFF) | ((value & 0xF) << 12)
                w[1] = (w[1] & 0x0FFF) | ((value & 0xF0) << 8)
            case .euFLowStage1:
                guard w.count > 1 else { return false }
                w[0] = (w[0] & 0x0FFF) | ((value & 0xF00) << 4); w[1] = (w[1] & 0xFF00) | (value & 0xFF)
            case .euFHighStage1:
                guard w.count > 1 else { return false }
                w[0] = (w[0] & 0x0FFF) | ((value & 0xF00) << 4); w[1] = (w[1] & 0x00FF) | ((value & 0xFF) << 8)
            case .euWaitingTime: w[0] = (w[0] & 0xF000) | (value & 0xFFF)
            case .polandFStart: w[0] = (value & 0xFF) * 0x101
            case .minCosPhi:
                w[0] = value == 0 ? 0xFFFF : Int((tan(acos(Double(value) / 100)) * 256).rounded(.toNearestOrEven))
            case .lom:
                var g = (w[0] & ~0x03) | (value & 0x03)
                if lomBit4Supported(c) { g = value & 0x04 != 0 ? g & ~0x10 : g | 0x10 }
                w[0] = g
            case .vdeCosPhi: w[0] = value
            case .readOnlyPlain, .unreadable: return false
            }
            for (k, id) in ids.enumerated() { c.setRaw(id, UInt16(clamping: max(0, min(0xFFFF, w[k])))) }
            return true
        }
    }

    // MARK: Display

    func display(_ c: DeviceConfiguration) -> Double? {
        guard let r = raw(c) else { return nil }
        return display(raw: r, c)
    }

    func display(raw r: Int, _ c: DeviceConfiguration) -> Double? {
        switch binding {
        case .setting: return scale(c) * (Double(r) + offset(c))
        case .flag: return Double(r)
        case .peer(let spec, let handler):
            let k = spec.codec
            switch handler {
            case .unreadable: return nil
            case .vdeCosPhi:
                let f = Double(r) / 32768
                return f >= 1 ? 2 - f : -f
            default:
                if k.reciprocal == true {
                    let d = k.scale * (Double(r) + (k.offsetBeforeInvert == false ? 0 : k.offset))
                    return d == 0 ? nil : 1 / d
                }
                return k.scale * (Double(r) + k.offset)
            }
        }
    }

    /// Nearest raw for a physical value; Delphi `Round` is round-half-even.
    func rawValue(forDisplay v: Double, _ c: DeviceConfiguration) -> Int? {
        switch binding {
        case .setting:
            let s = scale(c)
            guard s != 0 else { return nil }
            return Int((v / s - offset(c)).rounded(.toNearestOrEven))
        case .flag: return v != 0 ? 1 : 0
        case .peer(let spec, let handler):
            let k = spec.codec
            if handler == .vdeCosPhi {
                let f = v <= 0 ? -v : 2 - v
                return Int((f * 32768).rounded(.toNearestOrEven))
            }
            var x = v
            if k.reciprocal == true {
                guard x != 0 else { return nil }
                x = 1 / x
            }
            if !(k.reciprocal == true && k.offsetBeforeInvert == false) { x -= k.scale * k.offset }
            guard k.scale != 0 else { return nil }
            return Int((x / k.scale).rounded(.toNearestOrEven))
        }
    }

    /// Writes a physical value. Returns false if out of range (and nothing is written).
    @discardableResult
    func setDisplay(_ v: Double, in c: inout DeviceConfiguration) -> Bool {
        if let r = range(c), v < r.min - r.step / 2 || v > r.max + r.step / 2 { return false }
        guard let raw = rawValue(forDisplay: v, c) else { return false }
        return setRaw(raw, in: &c)
    }

    struct Range { var min: Double; var max: Double; var defaultValue: Double?; var step: Double }

    func range(_ c: DeviceConfiguration) -> Range? {
        switch binding {
        case .setting(let i):
            guard let info = c.info.info(i), info.isSupported else { return nil }
            let a = display(raw: Int(info.minRaw), c) ?? 0, b = display(raw: Int(info.maxRaw), c) ?? 0
            return Range(min: Swift.min(a, b), max: Swift.max(a, b), defaultValue: display(raw: Int(info.defaultRaw), c),
                         step: abs(scale(c)))
        case .flag: return nil
        case .peer(let spec, _):
            let k = spec.codec
            let step = k.reciprocal == true ? 0 : abs(k.scale)
            var lo = k.min ?? 0, hi = k.max ?? 0
            if lo == 0 && hi == 0 {
                // No VariableInfo bounds: the field width bounds the raw value.
                let p = spec.peers[0]
                let maxRaw = (1 << p.width) - 1
                let signed = k.signBit != nil
                let a = display(raw: signed ? -(maxRaw + 1) / 2 : 0, c) ?? 0
                let b = display(raw: signed ? maxRaw / 2 : maxRaw, c) ?? 0
                lo = Swift.min(a, b); hi = Swift.max(a, b)
            }
            return Range(min: lo, max: hi, defaultValue: k.default, step: step)
        }
    }

    /// Decimals: catalog precision, else the smallest n with scale·10ⁿ integral (FUN_004a079c).
    func precision(_ c: DeviceConfiguration) -> Int {
        if case .peer(let spec, _) = binding, let p = spec.codec.precision { return p }
        if let p = control.semantics?.precision { return p }
        let s = abs(scale(c))
        for n in 0...4 {
            let x = s * pow(10, Double(n))
            if abs(x - x.rounded()) < 1e-6 { return n }
        }
        return 3
    }

    func format(_ v: Double, _ c: DeviceConfiguration) -> String {
        v.formatted(.number.precision(.fractionLength(precision(c))).grouping(.never))
    }

    /// Value as shown in the change list (with unit, or item text for choices).
    func formatted(_ c: DeviceConfiguration, context: RuleContext? = nil) -> String {
        guard let r = raw(c) else { return "—" }
        if let items = control.items, let item = items.first(where: { $0.matches(r) }) {
            let t = item.displayText(context: context)
            return control.name == "GridCodeComboBox" ? GridCodes.clean(t) : t
        }
        if case .flag = binding { return (r != 0) != control.isInverted ? "On" : "Off" }
        if control.kind == .toggle { return (r != 0) != control.isInverted ? "On" : "Off" }
        guard let v = display(raw: r, c) else { return "\(r)" }
        return format(v, c) + (control.unit.map { " " + $0 } ?? "")
    }
}

// MARK: - Controls without a device variable

/// VE Configure's local checkboxes and combos that encode their state in a setting.
enum LocalControls {
    static func setting(_ control: String) -> Int? { Catalog.shared.controls[control]?.variable?.index }

    static func isChecked(_ name: String, _ c: DeviceConfiguration) -> Bool? {
        switch name {
        case "EnableBatteryMonitorCheckBox": return setting("BatteryCapacityEdit").map { c.raw($0) != 0 }
        case "EnableLowSOCShutDownCheckBox": return setting("LOWSOCStartSettingEdit").map { c.raw($0) != 0 }
        case "StopChargeDueToTempCheckBox": return setting("StopChargeBelowTBatSettingEdit").map { c.raw($0) != 0 }
        case "PolandEnableLFSMOCheckbox":
            guard let ctl = Catalog.shared.controls["PolandFStartSettingEdit"] ?? Catalog.shared.controls.values.first(where: {
                $0.handler("OnPeerDataSet") == "PolandFStartPeerDataSet" }), let codec = ValueCodec(control: ctl) else { return nil }
            return codec.raw(c).map { $0 != 255 }
        default: return nil
        }
    }

    /// User click on a local checkbox (EnableBatteryMonitorCheckBoxClick, EnableLowSOCShutDownCheckBoxClick, …).
    static func setChecked(_ name: String, _ on: Bool, in c: inout DeviceConfiguration) {
        switch name {
        case "EnableBatteryMonitorCheckBox":
            guard let id = setting("BatteryCapacityEdit"), let info = c.info.info(id) else { return }
            // VE Configure opens the capacity dialog; the field becomes editable at its default (or 200 Ah).
            let fallback = ValueCodec(setting: id)?.rawValue(forDisplay: 200, c) ?? Int(info.maxRaw)
            c.setRaw(id, on ? (info.defaultRaw != 0 ? info.defaultRaw : UInt16(clamping: fallback)) : 0)
        case "EnableLowSOCShutDownCheckBox":
            guard let stop = setting("LOWSOCStopSettingEdit"), let start = setting("LOWSOCStartSettingEdit") else { return }
            if on {
                ValueCodec(setting: stop)?.setDisplay(10, in: &c)
                ValueCodec(setting: start)?.setDisplay(20, in: &c)
            } else {
                c.setRaw(stop, 0); c.setRaw(start, 0)
            }
        case "StopChargeDueToTempCheckBox":
            guard let id = setting("StopChargeBelowTBatSettingEdit"), let info = c.info.info(id) else { return }
            if on {
                if info.defaultRaw != 0 { c.setRaw(id, info.defaultRaw) } else { ValueCodec(setting: id)?.setDisplay(5, in: &c) }
            } else {
                c.setRaw(id, 0)
            }
        case "PolandEnableLFSMOCheckbox":
            guard let ctl = Catalog.shared.controls.values.first(where: { $0.handler("OnPeerDataSet") == "PolandFStartPeerDataSet" }),
                  let codec = ValueCodec(control: ctl) else { return }
            if on, let d = ctl.peer?.codec.default { codec.setDisplay(d, in: &c) } else { codec.setRaw(255, in: &c) }
        default: break
        }
    }

    /// Vs2UBatOffActionComboBox: index 0 "bulk finished", 1 "absorption finished", 2 "Udc higher than" (raw ≥ 0x100).
    static func vs2OffAction(_ c: DeviceConfiguration) -> Int {
        guard let id = setting("vs2UBatOffEdit") else { return 2 }
        let r = c.raw(id)
        return r < 0x100 ? Int(min(r, 1)) : 2
    }

    static func setVs2OffAction(_ index: Int, in c: inout DeviceConfiguration) {
        guard let id = setting("vs2UBatOffEdit"), let info = c.info.info(id) else { return }
        c.setRaw(id, index < 2 ? UInt16(index) : max(info.defaultRaw, 0x100))
    }
}
