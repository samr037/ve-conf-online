// Generates the META source (composer item 0) describing the target device, exactly as VE Configure 3 does
// (port of Sources/VEKit/Assembler/MetaGenerator.swift; see docs/re/05-meta.md for every derivation).
import { ByteWriter, latin1Decode, latin1Encode, type Bytes } from '../binary'
import { roundHalfEven, type DeviceConfiguration, type SettingInfo } from '../deviceConfiguration'
import * as SettingNames from '../settingNames'

export const veConfigVersion = 9_004_248
export const packageVersion = 112
const gridCodesRequiringENS = [3, 4]
const pTable = [430, 700, 1025, 1290, 1625, 2500, 4150, 4500, 6250, 6519, 8300, 12000]
const ratedTable = [500, 800, 1200, 1600, 2000, 3000, 4500, 5000, 6500, 8000, 10000, 15000]
export const batteryPresets = ['cbtLiIon', 'cbtLiIonVEBusBMS', 'cbtMKBattery', 'cbtExideA400', 'cbtGelAGM',
  'cbtFloadedDeepDischarge', 'cbtAGMDeepDischarge', 'cbtFloodedTubularPlate', 'cbtRedflowZCell']
/** Variable ordinals of every TSetting* control on the main form, in DFM order (the `_VEC` list order). */
const vecOrdinals = [
  67, 69, 54, 125, 168, 77, 41, 132, 133, 40, 39, 184, 183, 191, 208, 200, 76, 42, 66, 46, 163, 164, 166, 165, 124,
  169, 170, 70, 47, 182, 131, 130, 167, 192, 44, 52, 103, 202, 203, 50, 68, 45, 129, 43, 53, 121, 122, 123, 126, 127,
  128, 75, 206, 205, 78, 79, 134, 65, 55, 135, 137, 136, 142, 141, 140, 139, 143, 144, 145, 146, 56, 57, 58, 59, 64,
  138, 147, 149, 148, 153, 154, 151, 152, 150, 155, 158, 159, 160, 161, 60, 61, 62, 63, 156, 157, 185, 186, 187, 188,
  74, 73, 181, 162, 173, 174, 177, 178, 189, 171, 172, 175, 176, 71, 72, 190, 207, 80, 247, 248, 249, 250, 251, 254,
  255, 252, 253, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275,
  276, 277, 310, 307, 305, 298, 299, 300, 301, 302, 303, 304, 306, 309, 278, 279, 280, 281, 282, 283, 284, 285, 286,
  287, 288, 289, 290, 291, 292, 293, 294, 295, 296, 297, 308,
]

/** Ordinal → name: 0 NoVariableID, 1…38 RAM, 39…118 flags, 119…310 settings. */
const names: readonly string[] = ['NoVariableID', ...SettingNames.ram, ...SettingNames.flags, ...SettingNames.settings]

export function metaSource(c: DeviceConfiguration, assistantsInfo = true, batteryType = 0): Bytes {
  return latin1Encode(metaLines(c, assistantsInfo, batteryType).map((l) => l + '\r\n').join(''))
}

export function metaLines(c: DeviceConfiguration, assistantsInfo = true, batteryType = 0): string[] {
  const m = new MetaList()
  const k = constants(c)
  for (const [name, value] of k.ordered) m.put(name, value)
  if (k.vll !== 0) m.put('ConnectionBoardWithPIC', String(k.pic))
  for (const [name, value] of bsi(c)) m.put(name, value)
  for (const [name, value] of infoLines(c)) m.put(name, value)
  for (const [name, value] of vecPairs(c, assistantsInfo, batteryType)) m.put(name, value, true)
  return [' .NOLIST', ' .GLOBAL True', ...m.lines, ' .GLOBAL False', ' .LIST']
}

/** Bytes split on LF without empty pieces (Swift `split(separator:)`), CRs removed, decoded as Latin-1. */
function metaTextLines(meta: Bytes): string[] {
  const out: string[] = []
  let start = 0
  for (let i = 0; i <= meta.length; i++) {
    if (i === meta.length || meta[i] === 0x0a) {
      if (i > start) out.push(latin1Decode(meta.subarray(start, i).filter((b) => b !== 0x0d)))
      start = i + 1
    }
  }
  return out
}

/** Value text of a ` .EQU` line in a META source (FUN_0050eb9c reads it the same way). */
export function equValue(name: string, meta: Bytes): string | undefined {
  const prefix = name + ' .EQU '
  for (const line of metaTextLines(meta)) if (line.startsWith(prefix)) return line.slice(prefix.length)
  return undefined
}

/** The META source with the ` .EQU` value of `name` replaced (FUN_0050eb9c); unchanged when absent. */
export function replacingEqu(name: string, value: string, meta: Bytes): Bytes {
  const prefix = name + ' .EQU '
  const lines = latin1Decode(meta).split('\r\n')
  const i = lines.findIndex((l) => l.startsWith(prefix))
  if (i < 0) return meta
  lines[i] = prefix + value
  return latin1Encode(lines.join('\r\n'))
}

export { metaTextLines }

/** `_VEC` label → (setting id | flag bit) for reading assistant changes back (docs/re/05-meta.md §write-back). */
export type VecTarget = { k: 'setting'; id: number } | { k: 'flag'; n: number }

export function vecTargets(c: DeviceConfiguration): Map<string, VecTarget> {
  const out = new Map<string, VecTarget>()
  for (const o of vecOrdinals) {
    if (names[o]!.includes('@')) continue
    if (o >= 39 && o <= 118) {
      if (c.supportsFlag(o - 39)) out.set(names[o] + '_VEC', { k: 'flag', n: o - 39 })
    } else if (o >= 119 && c.info.info(o - 119)?.isSupported === true) {
      out.set(names[o] + '_VEC', { k: 'setting', id: o - 119 })
    }
  }
  return out
}

/** Swift `Int(String)`: optional sign and decimal digits only. */
export function swiftInt(s: string): number | undefined {
  return /^[+-]?[0-9]+$/.test(s) ? Number(s) : undefined
}

/** Nominal DC voltage, AC voltage and rated power (VA) derived like VE Configure's META constants. */
export function ratings(c: DeviceConfiguration): { dc: number; ac: number; power: number } {
  const k = constants(c).ordered
  const v = (n: string) => swiftInt(k.find((e) => e[0] === n)?.[1] ?? '') ?? 0
  return { dc: v('hwDC'), ac: v('hwAC'), power: v('cRatedPower') }
}

// MARK: Pieces

class MetaList {
  lines = ['\t.NOLIST']
  put(name: string, value: string, set = false): void {
    const line = set ? `${name} .SET ${value},4,true` : `${name} .EQU ${value}`
    let i = -1
    for (let k = this.lines.length - 1; k >= 0; k--) if (this.lines[k]!.startsWith(name + ' ')) { i = k; break }
    if (i >= 0) {
      if (value.length === 0) this.lines.splice(i, 1)
      else this.lines[i] = line
      return
    }
    if (value.length > 0) this.lines.push(line)
  }
}

const list = (bytes: ArrayLike<number>) => '[]' + Array.from(bytes, (b) => `+${b}`).join('')

/** Swift `.rounded()` (to nearest, ties away from zero). */
const roundAway = (x: number) => (x < 0 ? -Math.round(-x) : Math.round(x))

function disp(c: DeviceConfiguration, id: number, raw: (i: SettingInfo) => number): number | undefined {
  const i = c.info.info(id)
  if (!i || !i.isSupported) return undefined
  return roundAway(i.display(raw(i)) * 1e6) / 1e6
}

function isCompactModel(t: number): boolean {
  return [0x76f, 0x818, 0xa2b, 0xa94, 0xa9e, 0x7d8, 0x7e2, 0x80e].includes(t) || (t >= 0x772 && t <= 0x774)
    || t === 0x772 + 7 || (t >= 0x77c && t <= 0x77e) || (t >= 0xa2e && t <= 0xa30) || t === 0xa2e + 7
    || (t >= 0xa38 && t <= 0xa3a)
}

/** First element minimising `key` (Swift `min(by:)` keeps the first of equals). */
function argmin<T>(xs: T[], key: (x: T) => number): T {
  let best = xs[0] as T, bk = key(best)
  for (const x of xs.slice(1)) { const k = key(x); if (k < bk) { best = x; bk = k } }
  return best
}

export interface MetaConstants { ordered: [string, string][]; vll: number; pic: number }

export function constants(c: DeviceConfiguration): MetaConstants {
  const fw = c.data.firmware & 0xffffff
  const ex = Array.from(c.data.firmwareExtra)
  const family = Math.floor(fw / 100_000), model = Math.floor(fw / 1000)
  const vll = ex.length === 0 ? 0 : ex[0]! + (ex.length > 2 ? ex[2]! << 8 : 0)
  let info = 0, pic = 0
  if (ex.length >= 2) {
    const b1 = ex[1]!
    pic = b1 & 1
    info |= ((b1 >> 1) & 1) << 1
    info |= ((b1 >> 2) & 1) << 4
    info |= ((b1 >> 3) & 1) << 5
    info |= ((b1 >> 4) & 1) << 6
    info |= ([2205, 2208].includes(model) ? 1 : 0) << 7
  }
  const sub = ex.length >= 4 ? ex[3]! : (fw % 1000 === 308 && [26, 27].includes(family)) ? 1 : 0
  let ubat = -1
  const u11 = disp(c, 11, (i) => i.defaultRaw)
  if (u11 !== undefined) ubat = u11
  if (ubat < 0) { const u3 = disp(c, 3, (i) => i.defaultRaw); if (u3 !== undefined) ubat = u3 }
  if (ubat < 0) ubat = 12
  const [lo, hi] = [14, 30].includes(family) ? [20, 40] : [12, 24]
  let half = 6
  if (ubat > lo) half = 12
  if (ubat > hi) half = 24
  const uinv = disp(c, 5, (i) => i.defaultRaw) ?? 0
  let hwAC = argmin([120, 230, 277], (x) => Math.abs(x - uinv))
  if ([14, 30].includes(family)) hwAC = 230
  let p = 0
  const v16 = disp(c, 16, (i) => i.defaultRaw)
  if (v16 !== undefined) {
    p = v16 * uinv
    if (p > 50) p -= 50
  }
  if (p === 0) { const v64 = disp(c, 64, (i) => i.maxRaw); if (v64 !== undefined) p = (Math.trunc(v64) & 0xff) * 100 }
  const pnom = roundHalfEven(roundHalfEven(p / 10) * 10)
  let iid: Bytes | undefined
  const r85 = c.info.info(85)
  if (r85 && r85.isSupported) {
    const w = new ByteWriter()
    w.u16(r85.scaleRaw & 0xffff); w.u16(r85.offset & 0xffff)
    w.u16(r85.defaultRaw); w.u16(r85.minRaw); w.u16(r85.maxRaw)
    iid = w.data
  }
  const winmon = iid ? (iid[3] !== 0xff ? iid[3]! : 0) : 0
  let iinv = 0, rated = 0
  if (pnom !== 0 && ![14, 30].includes(family)) {
    iinv = Math.trunc(((pnom + 50) * 100) / hwAC)
    const w = iid ? iid[4]! | (iid[5]! << 8) : 0xffff
    if (w !== 0xffff) {
      rated = w
    } else {
      const i = argmin([...Array(12).keys()], (k) => Math.abs(pnom / pTable[k]! - 1))
      rated = ratedTable[i]!
    }
    const secMax = disp(c, 49, (i) => i.maxRaw) ?? 0
    const ac1Max = disp(c, 6, (i) => i.maxRaw) ?? 0
    if (secMax === 0) {
      if ((info & 2) === 0 && isCompactModel(model)) info |= 2
      info = (info & ~1) | ((info & 2) !== 0 ? 0 : 1)
      if (ac1Max === 0) info |= 8
    } else {
      info |= 4
    }
  }
  const ordered: [string, string][] = [
    ['hwDC', String(2 * half)], ['hwAC', String(hwAC)], ['cDeviceInfo', String(info)],
    ['cPNominal', String(pnom)], ['cRatedPower', String(rated)], ['cIInvNominal', String(iinv)],
    ['cVEConfigVersion', String(veConfigVersion)], ['cMultiVersion', String(fw)],
    ['cMultiSubVersion', String(sub)], ['cMultiVersionFrameRemainder', list(c.data.firmwareExtra)],
    ['cVLLVersion', String(vll & 0xfff)], ['cVLLSystem', String(vll & 0xf000)],
    ['cWinmonIDOffset', String(winmon)], ['GridCodesRequiringENS', list(gridCodesRequiringENS)],
  ]
  return { ordered, vll, pic }
}

export function bsi(c: DeviceConfiguration): [string, string][] {
  if (c.data.deviceID === 0 || c.data.deviceRecord.length < 9) return []
  const r = Array.from(c.data.deviceRecord)
  const b0c = r[0]!, b0d = r[1]!
  const n10 = (r[2]! | (r[3]! << 8) | (r[4]! << 16) | (r[5]! << 24)) >>> 0
  const b08 = r[6]!, b09 = r[7]!, b14 = r[8]!
  const bit = (b: number, n: number) => (((b >> n) & 1) === 1 ? 'true' : 'false')
  const bool = (v: boolean) => (v ? 'true' : 'false')
  const phase = b09 & 3, acin = (b08 >> 4) & 3
  const fw = c.data.firmware & 0xffffff
  const out: [string, string][] = [['bsiStandAlone', bool(n10 === 1)]]
  out.push(['bsiPossibleChargeMaster', fw % 1000 >= 300 ? bool(b14 === 0) : bool(phase === 0 && b0d <= 0x20)])
  out.push(['bsiNrOfPhases', String(((b09 >> 2) & 3) + 1)], ['bsiPhase', String(phase)],
    ['bsiPossiblePhaseMaster', bool(!(b0d > 0x20 && b0c > 0x20))], ['bsiACInput', String(acin)],
    ['bsiLOLState', bit(b09, 7)], ['bsiLOLStateAC1', bit(b09, 5)], ['bsiLOLOutput', bit(b09, 6)],
    ['bsiFloating', bit(b08, 7)], ['bsiFloatReturn', bit(b08, 6)], ['bsiPhaseShift', String((b08 & 0xf) * 30)],
    ['bsiInvertRedundancy', String(b0c)], ['bsiChargeRedundancy', String(b0d)], ['bsiShortID', String(b14)])
  const tiles: number[][] = Array.from({ length: 12 }, () => [])
  tiles[4 * phase + acin] = [b14]
  let s = '[]'
  for (let g = 0; g < 3; g++) {
    s += '+([]'
    for (const t of tiles.slice(4 * g, 4 * g + 4)) s += '+' + (t.length === 0 ? "''" : t.map((x) => `#${x}`).join(''))
    s += ')'
  }
  const cnt = tiles.map((t) => t.length)
  const sum = (a: number[]) => a.reduce((x, y) => x + y, 0)
  out.push(['bsiTileIDs', s])
  for (let p = 0; p < 3; p++) out.push([`bsiNrOfDevicesInL${p + 1}`, String(sum(cnt.slice(4 * p, 4 * p + 4)))])
  for (let a = 0; a < 4; a++) out.push([`bsiNrOfDevicesACInput${a}`, String(cnt[a]! + cnt[4 + a]! + cnt[8 + a]!)])
  out.push(['bsiNrOfDevices', String(sum(cnt))])
  out.push(['bsiNrOfDevicesWithMyPhase', `bsiNrOfDevicesInL${phase + 1}`])
  out.push(['bsiNrOfDevicesWithMyACInput', `bsiNrOfDevicesACInput${acin}`])
  return out
}

export function infoLines(c: DeviceConfiguration): [string, string][] {
  const out: [string, string][] = []
  for (let o = 0; o < 311; o++) {
    const name = names[o]!
    if (name.includes('@')) continue
    if (o >= 39 && o <= 118) {
      const n = o - 39
      const r = c.info.info(SettingNames.flagWords[Math.floor(n / 16)]!)
      if (c.supportsFlag(n) && r) out.push([`ee${name}_default`, String((r.defaultRaw >> (n % 16)) & 1)])
    } else if (o >= 119) {
      const k = o - 119
      if (o >= 247 && o <= 310 && o !== 0xf8) continue
      const r = c.info.info(k)
      if (!r || !r.isSupported) continue
      out.push([`${name}_scale`, String(r.scaleRaw)], [`${name}_offset`, String(r.offset)],
        [`${name}_default`, String(r.defaultRaw)], [`${name}_minimum`, String(r.minRaw)],
        [`${name}_maximum`, String(r.maxRaw)])
    }
  }
  return out
}

export function vecPairs(c: DeviceConfiguration, assistantsInfo: boolean, batteryType: number): [string, string][] {
  const pairs: [string, string][] = []
  if (assistantsInfo) pairs.push(['packageversion', String(packageVersion)], ['DownloadedBy', String(veConfigVersion)])
  for (const o of vecOrdinals) {
    if (names[o]!.includes('@')) continue
    if (o >= 39 && o <= 118) {
      if (c.supportsFlag(o - 39)) pairs.push([names[o] + '_VEC', c.flag(o - 39) ? '1' : '0'])
    } else if (o >= 119 && c.info.info(o - 119)?.isSupported === true) {
      pairs.push([names[o] + '_VEC', String(c.raw(o - 119))])
    }
  }
  pairs.push(['BatteryType_VEC', String(batteryType)])
  batteryPresets.forEach((p, i) => pairs.push([p, String(i + 1)]))
  const versions = gridCodeVersions(c)
  SettingNames.gridCodes.forEach((name, code) => {
    pairs.push(['cgcVersion' + name, String(code < versions.length ? versions[code]! : -1)])
  })
  return pairs
}

/** First byte of each grid-table entry (BareSettingInfo grid table, docs/re/02-settings.md §2.3). */
export function gridCodeVersions(c: DeviceConfiguration): number[] {
  const g = c.info.gridTable
  if (!g || g.length < 5) return []
  const n = g[3]!
  const out: number[] = []
  for (let i = 0; i < n; i++) {
    const p = 5 + 2 * i
    if (!(p + 1 < g.length)) break
    const off = g[p]! | (g[p + 1]! << 8)
    out.push(off < g.length ? g[off]! : -1)
  }
  return out
}
