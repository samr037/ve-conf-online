// How a catalog control reads and writes the device configuration (port of Sources/VEConfigure/ValueCodec.swift):
// a direct setting (with VE Configure's scale/offset hooks), a flag bit, or a peer view of grid words.
import { roundHalfEven, type DeviceConfiguration } from '../engine/deviceConfiguration'
import {
  catalog, cleanCaption, cleanGridCode, displayUnit, handler, isInverted, itemDisplayText, itemMatches,
  type CatalogControl, type PeerSpec,
} from './catalog'
import type { RuleContext } from './context'
import { L, catalogText, formatFixed } from './l10n'

export type PeerHandler =
  | 'plain' | 'readOnlyPlain' | 'unreadable'
  | 'twoWords32' | 'newMovingAverage' | 'euFLowStage1' | 'euFHighStage1' | 'euWaitingTime'
  | 'polandFStart' | 'minCosPhi' | 'torD4Delay' | 'lom' | 'vdeCosPhi'

const plainHandlers = new Set([
  'GenericSequenceNoEqualsTest', 'GenericSequenceWithEqualsTest', 'MicroGridModeCheckBoxPeerDataSet',
  'ReactivePowerTypeSettingComboBoxPeerDataSet', 'EnableLockInOnUSettingCheckBoxPeerDataSet',
  'EU_PFHighFStartStopSettingEditPeerDataSet', 'AS4777PowerRampPeeringEditPeerDataSet',
  'NRS097PowerRampPeeringEditPeerDataSet', 'CEI_PxMaxSettingEditPeerDataSet',
  'CEI_NSStartStopDelaySettingEditPeerDataSet', 'ChilePUVoltageSettingEditPeerDataSet', 'RomaniaPUVoltageEditPeerDataSet',
])
const readOnlyHandlers = new Set([
  'CEI_NSHFStartFreqSettingEditPeerDataSet', 'CEI_NSLFStartFreqSettingEditPeerDataSet',
  'CEI_NSLFStopFreqSettingEditPeerDataSet', 'CEI_NSHFStopFreqSettingEditPeerDataSet',
  'AS4777VoltageAPeeringEditPeerDataSet', 'AS4777VoltageBPeeringEditPeerDataSet',
  'AS4777VoltageCPeeringEditPeerDataSet', 'AS4777VoltageDPeeringEditPeerDataSet',
  'AS4777OffsetAPeeringEditPeerDataSet', 'AS4777OffsetBPeeringEditPeerDataSet',
  'AS4777OffsetCPeeringEditPeerDataSet', 'AS4777OffsetDPeeringEditPeerDataSet',
])
const namedHandlers: Record<string, PeerHandler> = {
  UMainsMovingAveragePeerDataSet: 'twoWords32',
  NewUMainsMovingAveragePeerDataSet: 'newMovingAverage',
  EU_FLowStage1DelaySettingEditPeerDataSet: 'euFLowStage1',
  EU_FHighStage1DelaySettingEditPeerDataSet: 'euFHighStage1',
  EU_WaitingTimeSettingEditPeerDataSet: 'euWaitingTime',
  PolandFStartPeerDataSet: 'polandFStart',
  MinCosPhiPeerDataSet: 'minCosPhi',
  TOR_D4_DisconnectDelayPeerDataSet: 'torD4Delay',
  LOMAC0SettingComboBoxPeerDataSet: 'lom',
  VDECosPhiValuePeerDataSet: 'vdeCosPhi',
}

export function peerHandler(name: string | undefined): PeerHandler {
  if (name === undefined) return 'plain'
  if (name in namedHandlers) return namedHandlers[name]!
  if (plainHandlers.has(name)) return 'plain'
  // Writing regenerates curve words (slopes, droop lines): not reproduced yet.
  if (readOnlyHandlers.has(name)) return 'readOnlyPlain'
  return 'unreadable' // CEI droop, AS4777 FStop, f/P and U/Q droop: derived values
}

export type Binding =
  | { t: 'setting'; id: number }
  | { t: 'flag'; n: number }
  | { t: 'peer'; spec: PeerSpec; handler: PeerHandler }

export interface Range { min: number; max: number; defaultValue: number | undefined; step: number }

/** Int from a rounded number, undefined for NaN, infinities and absurd magnitudes. */
function toInt(x: number): number | undefined {
  if (!Number.isFinite(x) || Math.abs(x) >= 1e12) return undefined
  return Math.trunc(x)
}

const clampU16 = (v: number) => Math.max(0, Math.min(0xffff, v))
const pow2 = (n: number) => 2 ** n

export class ValueCodec {
  private constructor(readonly control: CatalogControl, readonly binding: Binding) {}

  static forControl(control: CatalogControl): ValueCodec | undefined {
    if (control.peer && control.peer.peers.length > 0)
      return new ValueCodec(control, { t: 'peer', spec: control.peer, handler: peerHandler(handler(control, 'OnPeerDataSet')) })
    const v = control.variable
    if (v?.index !== undefined && v.kind === 'setting') return new ValueCodec(control, { t: 'setting', id: v.index })
    if (v?.index !== undefined && v.kind === 'flag') return new ValueCodec(control, { t: 'flag', n: v.index })
    return undefined
  }

  static forSetting(id: number): ValueCodec | undefined {
    const c = catalog().settingControls.get(id)
    return c ? ValueCodec.forControl(c) : undefined
  }

  // MARK: Support

  isSupported(c: DeviceConfiguration): boolean {
    const b = this.binding
    if (b.t === 'setting') return c.info.info(b.id)?.isSupported === true
    if (b.t === 'flag') return b.n < 80 && c.supportsFlag(b.n)
    return b.spec.peers.every((p) => (p.variable?.index !== undefined ? c.info.info(p.variable.index)?.isSupported === true : false))
  }

  get isEditable(): boolean {
    const b = this.binding
    if (b.t === 'peer') return b.handler !== 'readOnlyPlain' && b.handler !== 'unreadable'
    return true
  }

  // MARK: Scale and offset

  /** Effective display scale: device scale × OnScaleSet hooks (AdaptScaleTo…, InvertScale, power, mV). */
  scale(c: DeviceConfiguration): number {
    const b = this.binding
    if (b.t === 'flag') return 1
    if (b.t === 'peer') return b.spec.codec.scale
    let s = c.info.info(b.id)?.scale ?? 1
    switch (handler(this.control, 'OnScaleSet')) {
      case 'AdaptScaleToSeconds': s *= 60; break
      case 'AdaptScaleToHours': s /= 60; break
      case 'AdaptScaleToDays': s /= 1440; break
      case 'InvertScale': s = -s; break
      case 'TempCompensationSettingEditScaleSet': s *= -1000; break
      case 'ConvertIInvLimitToPowerLimit': {
        const inv = c.info.info(5)
        if (inv && inv.isSupported) s *= inv.display(inv.defaultRaw)
        break
      }
    }
    return s
  }

  /** Effective offset, including the coupled offsets VE Configure sets at runtime. */
  offset(c: DeviceConfiguration): number {
    const b = this.binding
    if (b.t === 'peer') return b.spec.codec.offset
    if (b.t === 'flag') return 0
    const idx = (name: string) => catalog().controls.get(name)?.variable?.index
    const off = (id: number | undefined) => (id !== undefined ? c.info.info(id)?.offset ?? 0 : 0)
    const raw = (id: number | undefined) => (id !== undefined ? c.raw(id) : 0)
    switch (this.control.name) {
      case 'DCLowRestartEdit': { const sd = idx('DCLowShutDownEdit'); return off(sd) + raw(sd) }
      case 'UBatPreAlarmOffsetEdit': {
        const sd = idx('DCLowShutDownEdit'), rs = idx('DCLowRestartEdit')
        return off(sd) + raw(sd) + raw(rs) - 32768
      }
      case 'ACLowSwitchOnEdit': { const lo = idx('ACLowSwitchOffEdit'); return off(lo) + raw(lo) }
      case 'ACHighSwitchOnEdit': { const hi = idx('ACHighSwitchOffEdit'); return -off(hi) - raw(hi) }
      default: return off(b.id)
    }
  }

  // MARK: Raw

  /** The control's own raw value: the setting, the flag bit (0/1), or the peer field. */
  raw(c: DeviceConfiguration): number | undefined {
    const b = this.binding
    if (b.t === 'setting') return c.raw(b.id)
    if (b.t === 'flag') return c.flag(b.n) ? 1 : 0
    const spec = b.spec
    const w = spec.peers.map((p) => (p.variable?.index !== undefined ? c.raw(p.variable.index) : 0))
    const p0 = spec.peers[0]!
    const field = (word: number) => {
      let r = Math.floor((word & p0.mask) / pow2(p0.shift))
      const sb = spec.codec.signBit
      if (sb !== undefined && sb > 0 && (Math.floor(r / pow2(sb)) & 1) === 1) r -= pow2(sb + 1)
      return r
    }
    const w0 = w[0]!, w1 = w[1]
    switch (b.handler) {
      case 'plain': case 'readOnlyPlain': return field(w0)
      case 'unreadable': case 'vdeCosPhi': return w0
      case 'twoWords32': return w1 !== undefined ? w0 + w1 * 65536 : undefined
      case 'newMovingAverage': {
        if (w1 === undefined) return undefined
        const r = ((w1 & 0xf000) >> 8) + ((w0 & 0xf000) >> 12)
        return r > 127 ? r - 256 : r
      }
      case 'euFLowStage1': return w1 !== undefined ? ((w0 & 0xf000) >> 4) + (w1 & 0xff) : undefined
      case 'euFHighStage1': return w1 !== undefined ? ((w0 & 0xf000) >> 4) + ((w1 & 0xff00) >> 8) : undefined
      case 'euWaitingTime': return (w0 & 0xfff) - 4096
      case 'polandFStart': return (w0 >> 8) & 0xff
      case 'minCosPhi':
        if ((w0 & 0x8000) !== 0) return 0
        return Math.round(Math.cos(Math.atan(w0 / 256)) * 100)
      case 'torD4Delay': return w0 === 3 ? 0 : field(w0)
      case 'lom': {
        if (this.lomBit4Supported(c)) {
          let r = w0 & 0x03
          if ((w0 & 0x10) === 0) r |= 0x04
          return r & 7
        }
        return w0 & 0x03
      }
    }
  }

  private lomBit4Supported(c: DeviceConfiguration): boolean {
    const b = this.binding
    if (b.t !== 'peer') return false
    const i = b.spec.peers[0]?.variable?.index
    const info = i !== undefined ? c.info.info(i) : undefined
    return !!info && (info.maxRaw & 0x10) !== 0
  }

  /** Writes a new raw value; false (and nothing written) when the range, field width or handler rejects it. Never clamps. */
  setRaw(value: number, c: DeviceConfiguration): boolean {
    const b = this.binding
    if (b.t === 'setting') {
      const info = c.info.info(b.id)
      if (!info || value < info.minRaw || value > info.maxRaw) return false
      c.setRaw(b.id, value)
      return true
    }
    return this.write(value, c, true)
  }

  /** Writes a raw value without range checks: used to restore a value read from the loaded file. */
  restoreRaw(value: number, c: DeviceConfiguration): boolean {
    const b = this.binding
    if (b.t === 'setting') {
      c.setRaw(b.id, clampU16(value))
      return true
    }
    return this.write(value, c, false)
  }

  private write(value: number, c: DeviceConfiguration, checked: boolean): boolean {
    const b = this.binding
    if (b.t === 'setting') return false
    if (b.t === 'flag') {
      c.setFlag(b.n, value !== 0)
      return true
    }
    const spec = b.spec, h = b.handler
    if (!(this.isEditable || !checked)) return false
    const ids = spec.peers.map((p) => p.variable?.index).filter((i): i is number => i !== undefined)
    if (ids.length === 0) return false
    const w = ids.map((id) => c.raw(id))
    const p0 = spec.peers[0]!
    if (checked && (h === 'plain' || h === 'torD4Delay') && p0.width < 32) {
      const sb = spec.codec.signBit
      const [lo, hi] = sb !== undefined && sb > 0 ? [-pow2(sb), pow2(sb) - 1] : [0, pow2(p0.width) - 1]
      if (value < lo || value > hi) return false
    }
    const insert = (word: number, r: number) => {
      const masked = p0.width >= 32 ? r : r & (pow2(p0.width) - 1)
      return (word & ~p0.mask) | ((masked << p0.shift) & p0.mask)
    }
    switch (h) {
      case 'plain': case 'torD4Delay': w[0] = insert(w[0]!, value); break
      case 'twoWords32':
        if (w.length <= 1) return false
        w[0] = value & 0xffff
        w[1] = Math.floor(value / 65536) & 0xffff
        break
      case 'newMovingAverage':
        if (w.length <= 1) return false
        w[0] = (w[0]! & 0x0fff) | ((value & 0xf) << 12)
        w[1] = (w[1]! & 0x0fff) | ((value & 0xf0) << 8)
        break
      case 'euFLowStage1':
        if (w.length <= 1 || (checked && !(value >= 0 && value <= 0xfff))) return false
        w[0] = (w[0]! & 0x0fff) | ((value & 0xf00) << 4)
        w[1] = (w[1]! & 0xff00) | (value & 0xff)
        break
      case 'euFHighStage1':
        if (w.length <= 1 || (checked && !(value >= 0 && value <= 0xfff))) return false
        w[0] = (w[0]! & 0x0fff) | ((value & 0xf00) << 4)
        w[1] = (w[1]! & 0x00ff) | ((value & 0xff) << 8)
        break
      case 'euWaitingTime': w[0] = (w[0]! & 0xf000) | (value & 0xfff); break
      case 'polandFStart':
        if (checked && !(value >= 0 && value <= 0xff)) return false
        w[0] = (value & 0xff) * 0x101
        break
      case 'minCosPhi': {
        if (!(value >= 0 && value <= 100)) return false
        if (value === 0) { w[0] = 0xffff; break }
        const word = toInt(roundHalfEven(Math.tan(Math.acos(value / 100)) * 256))
        if (word === undefined) return false
        w[0] = word
        break
      }
      case 'lom': {
        let g = (w[0]! & ~0x03) | (value & 0x03)
        if (this.lomBit4Supported(c)) g = (value & 0x04) !== 0 ? g & ~0x10 : g | 0x10
        w[0] = g
        break
      }
      case 'vdeCosPhi': w[0] = value; break
      case 'readOnlyPlain':
        if (checked) return false
        w[0] = insert(w[0]!, value)
        break
      case 'unreadable':
        if (checked) return false
        w[0] = value
        break
    }
    if (checked && !w.every((x) => x >= 0 && x <= 0xffff)) return false
    ids.forEach((id, k) => c.setRaw(id, clampU16(w[k]!)))
    return true
  }

  /** A typed number: finite decimal only ("12", "-0.5", "48,2" with a decimal comma). No hex, exponent, nan or inf. */
  static parseNumber(text: string): number | undefined {
    const t = text.trim().replaceAll(',', '.')
    if (!/^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$/.test(t)) return undefined
    const v = Number(t)
    return Number.isFinite(v) ? v : undefined
  }

  // MARK: Display

  display(c: DeviceConfiguration): number | undefined {
    const r = this.raw(c)
    return r === undefined ? undefined : this.displayRaw(r, c)
  }

  displayRaw(r: number, c: DeviceConfiguration): number | undefined {
    const b = this.binding
    if (b.t === 'setting') return this.scale(c) * (r + this.offset(c))
    if (b.t === 'flag') return r
    const k = b.spec.codec
    if (b.handler === 'unreadable') return undefined
    if (b.handler === 'vdeCosPhi') {
      const f = r / 32768
      return f >= 1 ? 2 - f : -f
    }
    if (k.reciprocal === true) {
      const d = k.scale * (r + (k.offsetBeforeInvert === false ? 0 : k.offset))
      return d === 0 ? undefined : 1 / d
    }
    return k.scale * (r + k.offset)
  }

  /** Nearest raw for a physical value; Delphi `Round` is round-half-even. */
  rawValue(v: number, c: DeviceConfiguration): number | undefined {
    const b = this.binding
    if (b.t === 'setting') {
      const s = this.scale(c)
      if (s === 0) return undefined
      return toInt(roundHalfEven(v / s - this.offset(c)))
    }
    if (b.t === 'flag') return v !== 0 ? 1 : 0
    const k = b.spec.codec
    if (b.handler === 'vdeCosPhi') {
      const f = v <= 0 ? -v : 2 - v
      return toInt(roundHalfEven(f * 32768))
    }
    let x = v
    if (k.reciprocal === true) {
      if (x === 0) return undefined
      x = 1 / x
    }
    if (!(k.reciprocal === true && k.offsetBeforeInvert === false)) x -= k.scale * k.offset
    if (k.scale === 0) return undefined
    return toInt(roundHalfEven(x / k.scale))
  }

  /** Writes a physical value; false (and nothing written) when the value, or the value rounded to the step, is out of range. */
  setDisplay(v: number, c: DeviceConfiguration): boolean {
    if (!Number.isFinite(v)) return false
    const r = this.range(c)
    if (r) {
      const typed = 0.5 * 10 ** -this.precision(c) + 1e-9 * Math.max(1, Math.abs(v))
      if (v < r.min - typed || v > r.max + typed) return false
    }
    const raw = this.rawValue(v, c)
    if (raw === undefined) return false
    if (r) {
      const d = this.displayRaw(raw, c)
      if (d !== undefined) {
        const eps = Math.max(r.step * 1e-3, 1e-9 * Math.max(1, Math.abs(d)))
        if (d < r.min - eps || d > r.max + eps) return false
      }
    }
    return this.setRaw(raw, c)
  }

  range(c: DeviceConfiguration): Range | undefined {
    const b = this.binding
    if (b.t === 'setting') {
      const info = c.info.info(b.id)
      if (!info || !info.isSupported) return undefined
      const a = this.displayRaw(info.minRaw, c) ?? 0, z = this.displayRaw(info.maxRaw, c) ?? 0
      return { min: Math.min(a, z), max: Math.max(a, z), defaultValue: this.displayRaw(info.defaultRaw, c), step: Math.abs(this.scale(c)) }
    }
    if (b.t === 'flag') return undefined
    const k = b.spec.codec
    const step = k.reciprocal === true ? 0 : Math.abs(k.scale)
    let lo = k.min ?? 0, hi = k.max ?? 0
    if (lo === 0 && hi === 0) {
      // No VariableInfo bounds: the field width bounds the raw value.
      const p = b.spec.peers[0]!
      const maxRaw = pow2(p.width) - 1
      const signed = k.signBit !== undefined
      const a = this.displayRaw(signed ? Math.trunc(-(maxRaw + 1) / 2) : 0, c) ?? 0
      const z = this.displayRaw(signed ? Math.trunc(maxRaw / 2) : maxRaw, c) ?? 0
      lo = Math.min(a, z)
      hi = Math.max(a, z)
    }
    return { min: lo, max: hi, defaultValue: k.default, step }
  }

  /** Decimals: catalog precision, else the smallest n with scale·10ⁿ integral (FUN_004a079c). */
  precision(c: DeviceConfiguration): number {
    const b = this.binding
    if (b.t === 'peer' && b.spec.codec.precision !== undefined) return b.spec.codec.precision
    if (this.control.semantics?.precision !== undefined) return this.control.semantics.precision
    const s = Math.abs(this.scale(c))
    for (let n = 0; n <= 4; n++) {
      const x = s * 10 ** n
      if (Math.abs(x - Math.round(x)) < 1e-6) return n
    }
    return 3
  }

  format(v: number, c: DeviceConfiguration, extraDecimals = 0): string {
    return formatFixed(v, this.precision(c) + extraDecimals, false)
  }

  /** " V", " s"… as displayed (empty when the control has no unit). */
  get unitSuffix(): string {
    const u = displayUnit(this.control.unit)
    return u !== undefined ? ' ' + u : ''
  }

  /** Value as shown in the change list (with unit, or item text for choices). */
  formatted(c: DeviceConfiguration, context?: RuleContext): string {
    const r = this.raw(c)
    if (r === undefined) return '—'
    const item = this.control.items?.find((i) => itemMatches(i, r))
    if (item) {
      const t = itemDisplayText(item, context)
      return catalogText(this.control.name === 'GridCodeComboBox' ? cleanGridCode(t) : cleanCaption(t))
    }
    if (this.binding.t === 'flag' || this.control.kind === 'toggle') return (r !== 0) !== isInverted(this.control) ? L('On') : L('Off')
    const v = this.displayRaw(r, c)
    if (v === undefined) return `${r}`
    return this.format(v, c) + this.unitSuffix
  }
}

// MARK: - Controls without a device variable

/** The controls whose settings a local control writes when clicked (it inherits their protection and reset mark). */
export function writtenControls(name: string): CatalogControl[] {
  const cat = catalog()
  let list: string[]
  switch (name) {
    case 'EnableBatteryMonitorCheckBox': list = ['BatteryCapacityEdit']; break
    case 'EnableLowSOCShutDownCheckBox': list = ['LOWSOCStopSettingEdit', 'LOWSOCStartSettingEdit']; break
    case 'StopChargeDueToTempCheckBox': list = ['StopChargeBelowTBatSettingEdit']; break
    case 'PolandEnableLFSMOCheckbox':
      return [polandFStart(), cat.controls.get('PolandDroopSettingEdit')].filter((x): x is CatalogControl => x !== undefined)
    case 'Vs2UBatOffActionComboBox': list = ['vs2UBatOffEdit']; break
    default: return []
  }
  return list.map((n) => cat.controls.get(n)).filter((x): x is CatalogControl => x !== undefined)
}

function polandFStart(): CatalogControl | undefined {
  const cat = catalog()
  return cat.controls.get('PolandFStart') ?? [...cat.controls.values()].find((c) => handler(c, 'OnPeerDataSet') === 'PolandFStartPeerDataSet')
}

/** VE Configure's local checkboxes and combos that encode their state in a setting. */
export const LocalControls = {
  setting(control: string): number | undefined { return catalog().controls.get(control)?.variable?.index },

  writtenControls,

  isChecked(name: string, c: DeviceConfiguration): boolean | undefined {
    const s = LocalControls.setting
    switch (name) {
      case 'EnableBatteryMonitorCheckBox': { const id = s('BatteryCapacityEdit'); return id === undefined ? undefined : c.raw(id) !== 0 }
      case 'EnableLowSOCShutDownCheckBox': { const id = s('LOWSOCStartSettingEdit'); return id === undefined ? undefined : c.raw(id) !== 0 }
      case 'StopChargeDueToTempCheckBox': { const id = s('StopChargeBelowTBatSettingEdit'); return id === undefined ? undefined : c.raw(id) !== 0 }
      case 'PolandEnableLFSMOCheckbox': {
        const ctl = polandFStart()
        const codec = ctl && ValueCodec.forControl(ctl)
        if (!codec) return undefined
        const r = codec.raw(c)
        return r === undefined ? undefined : r !== 255
      }
      default: return undefined
    }
  },

  /** User click on a local checkbox (EnableBatteryMonitorCheckBoxClick, EnableLowSOCShutDownCheckBoxClick, …). */
  setChecked(name: string, on: boolean, c: DeviceConfiguration): void {
    const s = LocalControls.setting
    switch (name) {
      case 'EnableBatteryMonitorCheckBox': {
        const id = s('BatteryCapacityEdit')
        const info = id !== undefined ? c.info.info(id) : undefined
        if (id === undefined || !info) return
        // VE Configure opens the capacity dialog; the field becomes editable at its default (or 200 Ah).
        const fallback = ValueCodec.forSetting(id)?.rawValue(200, c) ?? info.maxRaw
        c.setRaw(id, on ? (info.defaultRaw !== 0 ? info.defaultRaw : clampU16(fallback)) : 0)
        break
      }
      case 'EnableLowSOCShutDownCheckBox': {
        const stop = s('LOWSOCStopSettingEdit'), start = s('LOWSOCStartSettingEdit')
        if (stop === undefined || start === undefined) return
        if (on) {
          ValueCodec.forSetting(stop)?.setDisplay(10, c)
          ValueCodec.forSetting(start)?.setDisplay(20, c)
        } else {
          c.setRaw(stop, 0)
          c.setRaw(start, 0)
        }
        break
      }
      case 'StopChargeDueToTempCheckBox': {
        const id = s('StopChargeBelowTBatSettingEdit')
        const info = id !== undefined ? c.info.info(id) : undefined
        if (id === undefined || !info) return
        if (on) {
          if (info.defaultRaw !== 0) c.setRaw(id, info.defaultRaw)
          else ValueCodec.forSetting(id)?.setDisplay(5, c)
        } else {
          c.setRaw(id, 0)
        }
        break
      }
      case 'PolandEnableLFSMOCheckbox': {
        // PolandEnableLFSMOCheckboxClick @00551da0: checked → PolandFStart and PolandDroop := their defaults;
        // unchecked → PolandFStart raw := 0xFF (LFSM-O off).
        const ctl = polandFStart()
        const codec = ctl && ValueCodec.forControl(ctl)
        if (!codec) return
        if (on) {
          for (const target of writtenControls(name)) {
            const k = ValueCodec.forControl(target)
            const d = target.peer?.codec.default
            if (k && d !== undefined) k.setDisplay(d, c)
          }
        } else {
          codec.setRaw(255, c)
        }
        break
      }
    }
  },

  /** Vs2UBatOffActionComboBox: 0 "bulk finished", 1 "absorption finished", 2 "Udc higher than" (raw ≥ 0x100). */
  vs2OffAction(c: DeviceConfiguration): number {
    const id = LocalControls.setting('vs2UBatOffEdit')
    if (id === undefined) return 2
    const r = c.raw(id)
    return r < 0x100 ? Math.min(r, 1) : 2
  },

  setVs2OffAction(index: number, c: DeviceConfiguration): void {
    const id = LocalControls.setting('vs2UBatOffEdit')
    const info = id !== undefined ? c.info.info(id) : undefined
    if (id === undefined || !info) return
    c.setRaw(id, index < 2 ? index : Math.max(info.defaultRaw, 0x100))
  },
}
