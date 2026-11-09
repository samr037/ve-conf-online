import Foundation

/// Generates the META source (composer item 0) describing the target device, exactly as VE Configure 3
/// (v9004247) does. Port of tools/meta.py; see docs/re/05-meta.md for every derivation.
public enum MetaGenerator {
    public static let veConfigVersion = 9_004_248
    public static let packageVersion = 112
    static let gridCodesRequiringENS: [UInt8] = [3, 4]
    static let pTable: [Double] = [430, 700, 1025, 1290, 1625, 2500, 4150, 4500, 6250, 6519, 8300, 12000]
    static let ratedTable = [500, 800, 1200, 1600, 2000, 3000, 4500, 5000, 6500, 8000, 10000, 15000]
    public static let batteryPresets = ["cbtLiIon", "cbtLiIonVEBusBMS", "cbtMKBattery", "cbtExideA400", "cbtGelAGM",
                                        "cbtFloadedDeepDischarge", "cbtAGMDeepDischarge", "cbtFloodedTubularPlate",
                                        "cbtRedflowZCell"]
    /// Variable ordinals of every TSetting* control on the main form, in DFM order (the `_VEC` list order).
    static let vecOrdinals = [
        67, 69, 54, 125, 168, 77, 41, 132, 133, 40, 39, 184, 183, 191, 208, 200, 76, 42, 66, 46, 163, 164, 166, 165, 124,
        169, 170, 70, 47, 182, 131, 130, 167, 192, 44, 52, 103, 202, 203, 50, 68, 45, 129, 43, 53, 121, 122, 123, 126, 127,
        128, 75, 206, 205, 78, 79, 134, 65, 55, 135, 137, 136, 142, 141, 140, 139, 143, 144, 145, 146, 56, 57, 58, 59, 64,
        138, 147, 149, 148, 153, 154, 151, 152, 150, 155, 158, 159, 160, 161, 60, 61, 62, 63, 156, 157, 185, 186, 187, 188,
        74, 73, 181, 162, 173, 174, 177, 178, 189, 171, 172, 175, 176, 71, 72, 190, 207, 80, 247, 248, 249, 250, 251, 254,
        255, 252, 253, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275,
        276, 277, 310, 307, 305, 298, 299, 300, 301, 302, 303, 304, 306, 309, 278, 279, 280, 281, 282, 283, 284, 285, 286,
        287, 288, 289, 290, 291, 292, 293, 294, 295, 296, 297, 308,
    ]

    /// Ordinal → name: 0 NoVariableID, 1…38 RAM, 39…118 flags, 119…310 settings.
    static let names: [String] = ["NoVariableID"] + SettingNames.ram + SettingNames.flags + SettingNames.settings

    public static func source(for c: DeviceConfiguration, assistantsInfo: Bool = true, batteryType: Int = 0) -> [UInt8] {
        let lines = self.lines(for: c, assistantsInfo: assistantsInfo, batteryType: batteryType)
        return Latin1.encode(lines.map { $0 + "\r\n" }.joined())
    }

    public static func lines(for c: DeviceConfiguration, assistantsInfo: Bool = true, batteryType: Int = 0) -> [String] {
        var m = MetaList()
        let k = constants(c)
        for (name, value) in k.ordered { m.put(name, value) }
        if k.vll != 0 { m.put("ConnectionBoardWithPIC", String(k.pic)) }
        for (name, value) in bsi(c) { m.put(name, value) }
        for (name, value) in infoLines(c) { m.put(name, value) }
        for (name, value) in vecPairs(c, assistantsInfo: assistantsInfo, batteryType: batteryType) { m.put(name, value, set: true) }
        return [" .NOLIST", " .GLOBAL True"] + m.lines + [" .GLOBAL False", " .LIST"]
    }

    /// Value text of a ` .EQU` line in a META source (FUN_0050eb9c reads it the same way).
    public static func equValue(_ name: String, in meta: [UInt8]) -> String? {
        let prefix = name + " .EQU "
        for raw in meta.split(separator: 0x0A) {
            let line = String(decoding: raw.filter { $0 != 0x0D }, as: Latin1.self)
            if line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        }
        return nil
    }

    /// The META source with the ` .EQU` value of `name` replaced (FUN_0050eb9c); unchanged when absent.
    public static func replacingEqu(_ name: String, with value: String, in meta: [UInt8]) -> [UInt8] {
        let prefix = name + " .EQU "
        let text = String(decoding: meta, as: Latin1.self)
        var lines = text.components(separatedBy: "\r\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix(prefix) }) else { return meta }
        lines[i] = prefix + value
        return Latin1.encode(lines.joined(separator: "\r\n"))
    }

    /// `_VEC` label → (setting id | flag bit) for reading assistant changes back (docs/re/05-meta.md §write-back).
    public enum Target: Equatable, Sendable { case setting(Int), flag(Int) }
    public static func vecTargets(_ c: DeviceConfiguration) -> [String: Target] {
        var out: [String: Target] = [:]
        for o in vecOrdinals where !names[o].contains("@") {
            if (39...118).contains(o) {
                if c.supportsFlag(o - 39) { out[names[o] + "_VEC"] = .flag(o - 39) }
            } else if o >= 119, c.info.info(o - 119)?.isSupported == true {
                out[names[o] + "_VEC"] = .setting(o - 119)
            }
        }
        return out
    }

    /// Nominal DC voltage, AC voltage and rated power (VA) derived like VE Configure's META constants.
    public static func ratings(_ c: DeviceConfiguration) -> (dc: Int, ac: Int, power: Int) {
        let k = constants(c).ordered
        func v(_ n: String) -> Int { Int(k.first { $0.0 == n }?.1 ?? "") ?? 0 }
        return (v("hwDC"), v("hwAC"), v("cRatedPower"))
    }

    // MARK: Pieces

    private struct MetaList {
        var lines = ["\t.NOLIST"]
        mutating func put(_ name: String, _ value: String, set: Bool = false) {
            let line = set ? "\(name) .SET \(value),4,true" : "\(name) .EQU \(value)"
            if let i = lines.lastIndex(where: { $0.hasPrefix(name + " ") }) {
                if value.isEmpty { lines.remove(at: i) } else { lines[i] = line }
                return
            }
            if !value.isEmpty { lines.append(line) }
        }
    }

    private static func list(_ bytes: [UInt8]) -> String { "[]" + bytes.map { "+\($0)" }.joined() }

    private static func disp(_ c: DeviceConfiguration, _ id: Int, _ raw: (SettingInfo) -> UInt16) -> Double? {
        guard let i = c.info.info(id), i.isSupported else { return nil }
        return (i.display(raw(i)) * 1e6).rounded() / 1e6
    }

    private static func isCompactModel(_ t: Int) -> Bool {
        [0x76f, 0x818, 0xa2b, 0xa94, 0xa9e, 0x7d8, 0x7e2, 0x80e].contains(t) || (0x772...0x774).contains(t)
            || t == 0x772 + 7 || (0x77c...0x77e).contains(t) || (0xa2e...0xa30).contains(t) || t == 0xa2e + 7
            || (0xa38...0xa3a).contains(t)
    }

    struct Constants { var ordered: [(String, String)]; var vll: Int; var pic: Int }

    static func constants(_ c: DeviceConfiguration) -> Constants {
        let fw = Int(c.data.firmware & 0xFF_FFFF)
        let ex = c.data.firmwareExtra.map(Int.init)
        let family = fw / 100_000, model = fw / 1000
        let vll = ex.isEmpty ? 0 : ex[0] + (ex.count > 2 ? ex[2] << 8 : 0)
        var info = 0, pic = 0
        if ex.count >= 2 {
            let b1 = ex[1]
            pic = b1 & 1
            info |= (b1 >> 1 & 1) << 1
            info |= (b1 >> 2 & 1) << 4
            info |= (b1 >> 3 & 1) << 5
            info |= (b1 >> 4 & 1) << 6
            info |= ([2205, 2208].contains(model) ? 1 : 0) << 7
        }
        let sub = ex.count >= 4 ? ex[3] : ((fw % 1000 == 308 && [26, 27].contains(family)) ? 1 : 0)
        var ubat = -1.0
        if let v = disp(c, 11, { $0.defaultRaw }) { ubat = v }
        if ubat < 0, let v = disp(c, 3, { $0.defaultRaw }) { ubat = v }
        if ubat < 0 { ubat = 12 }
        let (lo, hi): (Double, Double) = [14, 30].contains(family) ? (20, 40) : (12, 24)
        var half = 6
        if ubat > lo { half = 12 }
        if ubat > hi { half = 24 }
        let uinv = disp(c, 5, { $0.defaultRaw }) ?? 0
        var hwAC = [120.0, 230, 277].min { abs($0 - uinv) < abs($1 - uinv) }!
        if [14, 30].contains(family) { hwAC = 230 }
        var p = 0.0
        if let v = disp(c, 16, { $0.defaultRaw }) {
            p = v * uinv
            if p > 50 { p -= 50 }
        }
        if p == 0, let v = disp(c, 64, { $0.maxRaw }) { p = Double(Int(v) & 0xff) * 100 }
        let pnom = Int(((p / 10).rounded(.toNearestOrEven) * 10).rounded(.toNearestOrEven))
        var iid: [UInt8]? = nil
        if let r = c.info.info(85), r.isSupported {
            var w = ByteWriter()
            w.u16(UInt16(bitPattern: r.scaleRaw)); w.u16(UInt16(bitPattern: r.offset))
            w.u16(r.defaultRaw); w.u16(r.minRaw); w.u16(r.maxRaw)
            iid = w.data
        }
        let winmon = iid.map { $0[3] != 0xff ? Int($0[3]) : 0 } ?? 0
        var iinv = 0, rated = 0
        if pnom != 0 && ![14, 30].contains(family) {
            iinv = (pnom + 50) * 100 / Int(hwAC)
            let w = iid.map { Int($0[4]) | Int($0[5]) << 8 } ?? 0xffff
            if w != 0xffff {
                rated = w
            } else {
                let i = (0..<12).min { abs(Double(pnom) / pTable[$0] - 1) < abs(Double(pnom) / pTable[$1] - 1) }!
                rated = ratedTable[i]
            }
            let secMax = disp(c, 49, { $0.maxRaw }) ?? 0
            let ac1Max = disp(c, 6, { $0.maxRaw }) ?? 0
            if secMax == 0 {
                if info & 2 == 0 && isCompactModel(model) { info |= 2 }
                info = (info & ~1) | (info & 2 != 0 ? 0 : 1)
                if ac1Max == 0 { info |= 8 }
            } else {
                info |= 4
            }
        }
        let ordered: [(String, String)] = [
            ("hwDC", String(2 * half)), ("hwAC", String(Int(hwAC))), ("cDeviceInfo", String(info)),
            ("cPNominal", String(pnom)), ("cRatedPower", String(rated)), ("cIInvNominal", String(iinv)),
            ("cVEConfigVersion", String(veConfigVersion)), ("cMultiVersion", String(fw)),
            ("cMultiSubVersion", String(sub)), ("cMultiVersionFrameRemainder", list(c.data.firmwareExtra)),
            ("cVLLVersion", String(vll & 0xfff)), ("cVLLSystem", String(vll & 0xf000)),
            ("cWinmonIDOffset", String(winmon)), ("GridCodesRequiringENS", list(gridCodesRequiringENS)),
        ]
        return Constants(ordered: ordered, vll: vll, pic: pic)
    }

    static func bsi(_ c: DeviceConfiguration) -> [(String, String)] {
        guard c.data.deviceID != 0, c.data.deviceRecord.count >= 9 else { return [] }
        let r = c.data.deviceRecord.map(Int.init)
        let b0c = r[0], b0d = r[1]
        let n10 = r[2] | r[3] << 8 | r[4] << 16 | r[5] << 24
        let b08 = r[6], b09 = r[7], b14 = r[8]
        func bit(_ b: Int, _ n: Int) -> String { (b >> n & 1) == 1 ? "true" : "false" }
        func bool(_ v: Bool) -> String { v ? "true" : "false" }
        let phase = b09 & 3, acin = b08 >> 4 & 3
        let fw = Int(c.data.firmware & 0xFF_FFFF)
        var out: [(String, String)] = [("bsiStandAlone", bool(n10 == 1))]
        out.append(("bsiPossibleChargeMaster", fw % 1000 >= 300 ? bool(b14 == 0) : bool(phase == 0 && b0d <= 0x20)))
        out += [("bsiNrOfPhases", String((b09 >> 2 & 3) + 1)), ("bsiPhase", String(phase)),
                ("bsiPossiblePhaseMaster", bool(!(b0d > 0x20 && b0c > 0x20))), ("bsiACInput", String(acin)),
                ("bsiLOLState", bit(b09, 7)), ("bsiLOLStateAC1", bit(b09, 5)), ("bsiLOLOutput", bit(b09, 6)),
                ("bsiFloating", bit(b08, 7)), ("bsiFloatReturn", bit(b08, 6)), ("bsiPhaseShift", String((b08 & 0xf) * 30)),
                ("bsiInvertRedundancy", String(b0c)), ("bsiChargeRedundancy", String(b0d)), ("bsiShortID", String(b14))]
        var tiles = [[Int]](repeating: [], count: 12)
        tiles[4 * phase + acin] = [b14]
        var s = "[]"
        for g in 0..<3 {
            s += "+([]"
            for t in tiles[4 * g..<4 * g + 4] { s += "+" + (t.isEmpty ? "''" : t.map { "#\($0)" }.joined()) }
            s += ")"
        }
        let cnt = tiles.map(\.count)
        out.append(("bsiTileIDs", s))
        for p in 0..<3 { out.append(("bsiNrOfDevicesInL\(p + 1)", String(cnt[4 * p..<4 * p + 4].reduce(0, +)))) }
        for a in 0..<4 { out.append(("bsiNrOfDevicesACInput\(a)", String(cnt[a] + cnt[4 + a] + cnt[8 + a]))) }
        out.append(("bsiNrOfDevices", String(cnt.reduce(0, +))))
        out.append(("bsiNrOfDevicesWithMyPhase", "bsiNrOfDevicesInL\(phase + 1)"))
        out.append(("bsiNrOfDevicesWithMyACInput", "bsiNrOfDevicesACInput\(acin)"))
        return out
    }

    static func infoLines(_ c: DeviceConfiguration) -> [(String, String)] {
        var out: [(String, String)] = []
        for o in 0..<311 {
            let name = names[o]
            if name.contains("@") { continue }
            if (39...118).contains(o) {
                let n = o - 39
                if c.supportsFlag(n), let r = c.info.info(SettingNames.flagWords[n / 16]) {
                    out.append(("ee\(name)_default", String(r.defaultRaw >> UInt16(n % 16) & 1)))
                }
            } else if o >= 119 {
                let k = o - 119
                if (247...310).contains(o) && o != 0xf8 { continue }
                guard let r = c.info.info(k), r.isSupported else { continue }
                out += [("\(name)_scale", String(r.scaleRaw)), ("\(name)_offset", String(r.offset)),
                        ("\(name)_default", String(r.defaultRaw)), ("\(name)_minimum", String(r.minRaw)),
                        ("\(name)_maximum", String(r.maxRaw))]
            }
        }
        return out
    }

    static func vecPairs(_ c: DeviceConfiguration, assistantsInfo: Bool, batteryType: Int) -> [(String, String)] {
        var pairs: [(String, String)] = []
        if assistantsInfo {
            pairs += [("packageversion", String(packageVersion)), ("DownloadedBy", String(veConfigVersion))]
        }
        for o in vecOrdinals where !names[o].contains("@") {
            if (39...118).contains(o) {
                if c.supportsFlag(o - 39) { pairs.append((names[o] + "_VEC", c.flag(o - 39) ? "1" : "0")) }
            } else if o >= 119, c.info.info(o - 119)?.isSupported == true {
                pairs.append((names[o] + "_VEC", String(c.raw(o - 119))))
            }
        }
        pairs.append(("BatteryType_VEC", String(batteryType)))
        pairs += batteryPresets.enumerated().map { ($1, String($0 + 1)) }
        let versions = gridCodeVersions(c)
        for (code, name) in SettingNames.gridCodes.enumerated() {
            pairs.append(("cgcVersion" + name, String(code < versions.count ? versions[code] : -1)))
        }
        return pairs
    }

    /// First byte of each grid-table entry (BareSettingInfo grid table, docs/re/02-settings.md §2.3).
    static func gridCodeVersions(_ c: DeviceConfiguration) -> [Int] {
        guard let g = c.info.gridTable, g.count >= 5 else { return [] }
        let n = Int(g[3])
        var out: [Int] = []
        for i in 0..<n {
            let p = 5 + 2 * i
            guard p + 1 < g.count else { break }
            let off = Int(g[p]) | Int(g[p + 1]) << 8
            out.append(off < g.count ? Int(g[off]) : -1)
        }
        return out
    }
}
