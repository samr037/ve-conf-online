// Rule context, device facts, the firmware grid-code table and access bytes.
import type { Bytes } from '../engine/binary'
import type { DeviceConfiguration } from '../engine/deviceConfiguration'
import { GridPassword } from '../engine/gridPassword'
import * as names from '../engine/settingNames'
import { catalog, type CatalogControl, type VariableRef } from './catalog'
import { boolValue, num, numberOf, parseExpr, truthy, valueEquals, type EValue, type Expr } from './expr'
import { GridPages, Visibility } from './editingRules'
import { L } from './l10n'
import { LocalControls, ValueCodec } from './valueCodec'

// MARK: - Session

/** Per-document state that is not stored in the file (VE Configure keeps it in its window state). */
export class SessionState {
  private authorization: GridPassword | undefined
  /** "Unhide charge parameters" was pressed on an inverter-only device. */
  chargerUnhidden = false
  /** A configuration read from a device: every control is locked and the grid password cannot be entered. */
  readOnly = false

  get gridAuthorization(): GridPassword | undefined { return this.authorization }
  get gridPasswordEntered(): boolean { return this.authorization !== undefined }

  unlockGrid(password: string): boolean {
    if (this.readOnly) return false
    const a = GridPassword.verify(password)
    if (!a) return false
    this.authorization = a
    return true
  }

  clone(): SessionState {
    const s = new SessionState()
    s.authorization = this.authorization
    s.chargerUnhidden = this.chargerUnhidden
    s.readOnly = this.readOnly
    return s
  }
}

// MARK: - Device facts

export function supports(c: DeviceConfiguration, ref: VariableRef): boolean {
  switch (ref.kind) {
    case 'setting': return c.info.info(ref.index)?.isSupported === true
    case 'flag': return ref.index < 80 ? c.supportsFlag(ref.index) : false
    default: return false
  }
}

const defaultDisplay = (c: DeviceConfiguration, id: number) => {
  const i = c.info.info(id)
  return i ? i.display(i.defaultRaw) : undefined
}

/** 12, 24 or 48 V, from the default of the DC low shut-down, as VE Configure derives it. */
export function dcVoltageClass(c: DeviceConfiguration): number {
  let v = defaultDisplay(c, 11) ?? 0
  if (v <= 0) v = defaultDisplay(c, 3) ?? 0
  if (v <= 0) v = 12
  return v > 24 ? 48 : v > 12 ? 24 : 12
}

/** Battery cells (6 per 12 V). */
export const cells = (c: DeviceConfiguration) => Math.trunc(dcVoltageClass(c) / 2)

/** 120, 230 or 277 V, nearest to the default inverter output voltage. */
export function acVoltageClass(c: DeviceConfiguration): number {
  const v = defaultDisplay(c, 5) ?? 230
  let best = 120
  for (const x of [230, 277]) if (Math.abs(x - v) < Math.abs(best - v)) best = x
  return best
}

/** A pure inverter: no AC-input current limit (as VE Configure decides it; product type 14 excluded). */
export const isInverterOnly = (c: DeviceConfiguration) => c.firmware.type !== 14 && c.info.info(6)?.isSupported !== true

export const hasSecondACInput = (c: DeviceConfiguration) => c.info.info(49)?.isSupported === true

// MARK: - Grid table

export interface GridTableEntry {
  variant: number
  word: number
  editable: Bytes
  present: Bytes
  /** Default value per setting index (129…190) for the bits set in `present`. */
  defaults: Map<number, number>
}

export const isPresent = (e: GridTableEntry, id: number) => {
  const bit = id - 128
  return bit >= 0 && Math.floor(bit / 8) < e.present.length && ((e.present[Math.floor(bit / 8)]! >> (bit % 8)) & 1) === 1
}

/** Firmware grid-code table (the BareSettingInfo v≥3 trailer). */
export class GridTable {
  entries = new Map<number, GridTableEntry>()

  constructor(b: Bytes) {
    const u16 = (p: number) => (p + 1 < b.length ? b[p]! | (b[p + 1]! << 8) : undefined)
    const version = b[2]!, n = b[3]!, k = b[4]!
    for (let g = 0; g < n; g++) {
      let p = u16(5 + 2 * g)
      if (p === undefined || p >= b.length) continue
      const variant = b[p]!
      p += 1
      let word = 0
      if (version > 2) { word = u16(p) ?? 0; p += 2 }
      if (p + 2 * k > b.length) continue
      const editable = b.slice(p, p + k), present = b.slice(p + k, p + 2 * k)
      const defaults = new Map<number, number>()
      if (present[0] !== 0) {
        p += 2 * k
        const bits: number[] = []
        for (let bit = 0; bit < 8 * k; bit++) if ((present[Math.floor(bit / 8)]! & (1 << (bit % 8))) !== 0) bits.push(bit)
        const count = bits.length - 2
        bits.slice(1, 1 + Math.max(0, count)).forEach((bit, i) => {
          const v = u16(p! + 2 * i)
          if (v !== undefined) defaults.set(128 + bit, v)
        })
      }
      this.entries.set(g, { variant, word, editable, present, defaults })
    }
  }
}

const tableCache = new WeakMap<Bytes, GridTable>()

export function gridTable(c: DeviceConfiguration): GridTable | undefined {
  const b = c.info.gridTable
  if (!b || b.length <= 5) return undefined
  let t = tableCache.get(b)
  if (!t) { t = new GridTable(b); tableCache.set(b, t) }
  return t
}

// MARK: - Assistant directory

/** Assistant IDs stored at the top of the 4096-byte program image, read downward. */
export function assistantDirectory(c: DeviceConfiguration): number[] {
  const mem = c.data.assistantMemory
  if (mem.length < 8 || mem.every((b) => b === 0xff)) return []
  const ids: number[] = []
  for (let p = mem.length - 6; p >= 0; p -= 2) {
    const id = mem[p]! | (mem[p + 1]! << 8)
    if (id === 0xffff || id === 0) break
    ids.push(id)
  }
  return ids
}

// MARK: - Context

/** Everything an expression may look at: the live configuration, the loaded one, and session state. */
export class RuleContext {
  constructor(readonly config: DeviceConfiguration, readonly baseline: DeviceConfiguration, readonly session: SessionState) {}

  /** undefined = cannot be decided offline. */
  evaluate(source: string): boolean | undefined {
    const e = parseExpr(source)
    if (!e) return undefined
    const v = this.eval(e)
    return v === undefined ? undefined : truthy(v)
  }

  /** All expressions true; unknown counts as `unknownIs`. */
  all(exprs: string[] | undefined, unknownIs = true): boolean {
    return (exprs ?? []).every((e) => this.evaluate(e) ?? unknownIs)
  }

  eval(e: Expr): EValue | undefined {
    switch (e.t) {
      case 'number': return num(e.v)
      case 'string': return { t: 'string', v: e.v }
      case 'list': {
        const v = e.items.map((x) => this.eval(x))
        return v.every((x) => x !== undefined) ? { t: 'list', v: v as EValue[] } : undefined
      }
      case 'ident': return this.resolve(e.name)
      case 'call': return this.call(e.name, e.args)
      case 'not': { const x = this.eval(e.x); return x === undefined ? undefined : boolValue(!truthy(x)) }
      case 'negate': { const x = numberOf(this.eval(e.x)); return x === undefined ? undefined : num(-x) }
      case 'binary': {
        if (e.op === '&&') {
          const l = this.eval(e.a)
          if (l !== undefined && !truthy(l)) return boolValue(false)
          const r = this.eval(e.b)
          if (r !== undefined && !truthy(r)) return boolValue(false)
          if (l === undefined || r === undefined) return undefined
          return boolValue(true)
        }
        if (e.op === '||') {
          const l = this.eval(e.a)
          if (l !== undefined && truthy(l)) return boolValue(true)
          const r = this.eval(e.b)
          if (r !== undefined && truthy(r)) return boolValue(true)
          if (l === undefined || r === undefined) return undefined
          return boolValue(false)
        }
        const l = this.eval(e.a), r = this.eval(e.b)
        if (l === undefined || r === undefined) return undefined
        switch (e.op) {
          case '==': return boolValue(equal(l, r))
          case '!=': return boolValue(!equal(l, r))
          case 'in': return r.t === 'list' ? boolValue(r.v.some((x) => equal(l, x))) : undefined
        }
        const x = numberOf(l), y = numberOf(r)
        if (x === undefined || y === undefined) return undefined
        switch (e.op) {
          case '<': return boolValue(x < y)
          case '<=': return boolValue(x <= y)
          case '>': return boolValue(x > y)
          case '>=': return boolValue(x >= y)
          case '+': return num(x + y)
          case '-': return num(x - y)
          case '*': return num(x * y)
          case '/': return y === 0 ? undefined : num(x / y)
          case '&': return num(Number(BigInt(Math.trunc(x)) & BigInt(Math.trunc(y))))
          default: return undefined
        }
      }
    }
  }

  // MARK: Identifiers

  private resolve(name: string): EValue | undefined {
    if (name.startsWith('original.')) return this.variableValue(name.slice(9), this.baseline)
    const v = this.variableValue(name, this.config)
    if (v) return v
    if (name.startsWith('ctl.')) return this.controlValue(name.slice(4))
    if (name.startsWith('device.')) return this.deviceFact(name.slice(7))
    if (name.startsWith('app.')) {
      switch (name.slice(4)) {
        case 'gridPasswordEntered': return boolValue(this.session.gridPasswordEntered)
        case 'assistantFilesOk': case 'assistantsUnlocked': case 'remoteFile': return boolValue(true)
        case 'assistantCount': return num(assistantDirectory(this.config).length)
        default: return undefined
      }
    }
    if (name === 'session.gridSelectionWasFree') return boolValue(!Access.gridCodeNeedsPassword(this))
    return undefined
  }

  variableValue(name: string, c: DeviceConfiguration): EValue | undefined {
    const ref = catalog().variables.get(name)
    if (!ref) return undefined
    switch (ref.kind) {
      case 'flag': return boolValue(c.flag(ref.index))
      case 'setting': {
        const control = catalog().settingControls.get(ref.index)
        if (control) {
          const v = ValueCodec.forControl(control)?.display(c)
          if (v !== undefined) return num(v)
        }
        const d = c.value(ref.index)
        return num(d ?? c.raw(ref.index))
      }
      default: return undefined
    }
  }

  private controlValue(path: string): EValue | undefined {
    const parts = path.split('.').filter((p) => p !== '')
    const name = parts.shift()!
    const prop = parts[0]
    const config = this.config
    if (name === 'gridParamsValid') return boolValue(GridPages.paramsValid(config))
    if (name === 'InverterWarningPanel' && prop === 'visible') return boolValue(isInverterOnly(config) && !this.session.chargerUnhidden)
    if (name === 'EnableBatteryMonitorCheckBox' && prop === 'checked') return boolValue(config.raw(64) !== 0)
    if (name === 'EnableBatteryMonitorCheckBox' && prop === 'visible')
      return boolValue(config.info.info(64)?.isSupported === true && config.info.info(64)?.minRaw === 0)
    if (name === 'VirtualSwitchPageControl' && prop === 'visible') return boolValue(config.info.info(15)?.isSupported === true)
    if (name === 'ManualChargeCharacteristicComboBox')
      return { t: 'string', v: config.raw(10) === 1 ? 'Fixed' : config.raw(10) === 2 ? 'Adaptive' : 'Adaptive + BatterySafe' }
    const control = catalog().controls.get(name)
    if (!control) return undefined
    if (prop === 'visible') return boolValue(Visibility.isVisible(control, this))
    if (control.kind === 'localToggle') {
      const v = LocalControls.isChecked(control.name, config)
      return v === undefined ? undefined : boolValue(v)
    }
    const codec = ValueCodec.forControl(control)
    if (!codec) return undefined
    if (prop === 'raw' || control.kind !== 'number') {
      const r = codec.raw(config)
      return r === undefined ? undefined : num(r)
    }
    const d = codec.display(config)
    return d === undefined ? undefined : num(d)
  }

  private deviceFact(name: string): EValue | undefined {
    const c = this.config
    switch (name) {
      case 'firmwareVersion': return num(c.firmware.version)
      case 'firmwareType': case 'productType': return num(c.firmware.type)
      case 'firmwareNumber': return num(c.firmware.number)
      case 'dcVoltageClass': return num(dcVoltageClass(c))
      case 'acVoltageClass': return num(acVoltageClass(c))
      case 'hasCharger': return boolValue(!isInverterOnly(c))
      case 'acInputCount': return num(c.info.info(49)?.isSupported === true ? 2 : 1)
      case 'isInverterOnly': return boolValue(isInverterOnly(c))
      case 'configResponseChar': return num(c.info.configResponseChar)
      default: return undefined // isGen2, hasDipSwitches, hasInternalInterfaceProtection… need the device table
    }
  }

  private call(name: string, args: Expr[]): EValue | undefined {
    const c = this.config
    const varRef = (i: number) => {
      const a = args[i]
      return a?.t === 'ident' ? catalog().variables.get(a.name) : undefined
    }
    const number = (i: number) => {
      const a = args[i]
      if (!a) return undefined
      const v = numberOf(this.eval(a))
      return v === undefined ? undefined : Math.trunc(v)
    }
    switch (name) {
      case 'device.supports': {
        const r = varRef(0)
        return r ? boolValue(supports(c, r)) : undefined
      }
      case 'device.min': {
        const r = varRef(0)
        if (!r || r.kind !== 'setting') return undefined
        const i = c.info.info(r.index)
        return i ? num(i.minRaw) : undefined
      }
      case 'device.access': {
        const r = varRef(0)
        return r ? num(Access.attribute(r, c)) : undefined
      }
      case 'raw': {
        const a = args[0]
        if (a?.t === 'ident') {
          const r = catalog().variables.get(a.name)
          if (r) return r.kind === 'flag' ? boolValue(c.flag(r.index)) : num(c.raw(r.index))
          if (a.name.startsWith('ctl.')) {
            const ctl = catalog().controls.get(a.name.slice(4).split('.')[0]!)
            if (ctl) {
              const k = ValueCodec.forControl(ctl)
              if (!k) return undefined
              const raw = k.raw(c)
              return raw === undefined ? undefined : num(raw)
            }
          }
        }
        return undefined
      }
      case 'device.gridCodeSupported': {
        const n = number(0)
        if (n === undefined) return undefined
        return boolValue(gridTable(c)?.entries.get(n) !== undefined)
      }
      case 'device.gridVariant': {
        const n = number(0)
        if (n === undefined) return undefined
        const e = gridTable(c)?.entries.get(n)
        return e ? num(e.variant) : undefined
      }
      case 'device.gridTableWord': {
        const n = number(0)
        if (n === undefined) return undefined
        const e = gridTable(c)?.entries.get(n)
        return e ? num(e.word) : undefined
      }
      default: return undefined
    }
  }
}

function equal(a: EValue, b: EValue): boolean {
  if (a.t === 'number' && b.t === 'number') return Math.abs(a.v - b.v) < 1e-9
  return valueEquals(a, b)
}

// MARK: - Access bytes (reset / password)

export const Access = {
  /** Attribute byte of a setting or flag, with the corrections VE Configure applies for some firmware. */
  attribute(ref: VariableRef, c: DeviceConfiguration): number {
    let a: number
    if (ref.kind === 'setting') a = c.info.settingAttributes[ref.index] ?? 0
    else if (ref.kind === 'flag') a = c.info.flagAttributes[ref.index] ?? 0
    else return 0
    const fw = c.firmware.version
    const n = ref.name
    if (fw === 308 && ['EPROM_GridCode', 'EBIT_AllowEnableFeedIn'].includes(n)) a |= 0x80
    if (fw < 309 && ['EPROM_IInv2AES', 'EPROM_IInvAESHysterese', 'EPROM_BatteryCapacity'].includes(n)) a |= 0x80
    if (fw >= 300 && fw < 309 && ['EBIT_LithiumBattery', 'EPROM_UBatFloat', 'EPROM_UBat2Low'].includes(n)) a |= 0x80
    if (fw < 200 && n === 'EPROM_ChargePercentageResetValueForBatteryMonitor') a |= 0x80
    return a
  },

  attributeOfSetting(id: number, c: DeviceConfiguration): number {
    const vname = catalog().settingControls.get(id)?.variable?.name
    const ref = (vname !== undefined ? catalog().variables.get(vname) : undefined) ?? { kind: 'setting' as const, index: id, name: '' }
    return Access.attribute(ref, c)
  },

  /** Variables a control writes, as references. */
  refs(control: CatalogControl): VariableRef[] {
    const v = control.variable
    if (v && v.index !== undefined && v.name !== undefined) return [{ kind: v.kind, index: v.index, name: v.name }]
    if (control.kind === 'localToggle' || control.kind === 'localChoice') {
      return LocalControls.writtenControls(control.name).flatMap((x) => Access.refs(x))
    }
    const out: VariableRef[] = []
    for (const p of control.peer?.peers ?? []) {
      if (p.variable?.index !== undefined) out.push({ kind: p.variable.kind, index: p.variable.index, name: p.variable.name ?? '' })
    }
    return out
  },

  requiresReset(control: CatalogControl, c: DeviceConfiguration): boolean {
    return Access.refs(control).some((r) => (Access.attribute(r, c) & 0x80) !== 0)
  },

  /** Password areas (bits 0–6); bit 0 is the grid code ("GC"). */
  passwordAreas(control: CatalogControl, c: DeviceConfiguration): number {
    return Access.refs(control).reduce((a, r) => a | (Access.attribute(r, c) & 0x7f), 0)
  },

  /** Changing the grid code needs the GC password unless the loaded code was a "free" one. Unknown counts as "needs". */
  gridCodeNeedsPassword(ctx: RuleContext): boolean {
    const expr = catalog().rulesByID.get('grid.code.password')?.expr
    if (expr !== undefined) {
      const v = ctx.evaluate(expr)
      if (v !== undefined) return v
    }
    return true
  },

  /** The grid code, its parameter words and the checker words: protected whatever the attribute bytes say. */
  isGridFamily(id: number): boolean { return id === 81 || (id >= 128 && id <= 191) },

  isProtectedSetting(id: number, c: DeviceConfiguration): boolean {
    return Access.isGridFamily(id) || (Access.attributeOfSetting(id, c) & 1) !== 0
  },

  isProtectedFlag(n: number, c: DeviceConfiguration): boolean { return c.info.isProtectedFlag(n) },

  isProtected(ref: VariableRef, c: DeviceConfiguration): boolean {
    if (ref.kind === 'setting') return Access.isProtectedSetting(ref.index, c)
    if (ref.kind === 'flag') return Access.isProtectedFlag(ref.index, c)
    return false
  },

  /** Only the grid-code family may change without the password, and only when the loaded code was "free". */
  mayChangeWithoutPassword(ref: VariableRef, ctx: RuleContext): boolean {
    if (ref.kind !== 'setting' || !Access.isGridFamily(ref.index)) return false
    return !Access.gridCodeNeedsPassword(ctx)
  },

  /** Whether the control is locked behind the grid-code password right now. */
  isLocked(control: CatalogControl, ctx: RuleContext): boolean {
    if (ctx.session.readOnly) return true
    if (ctx.session.gridPasswordEntered) return false
    if (control.name === 'GridCodeComboBox') return Access.gridCodeNeedsPassword(ctx)
    return Access.refs(control).filter((r) => Access.isProtected(r, ctx.config)).some((r) => !Access.mayChangeWithoutPassword(r, ctx))
  },

  /** Protected values an edit (`old` → `new`) would change to something other than the loaded value without being allowed to. */
  forbiddenEdits(old: DeviceConfiguration, nw: DeviceConfiguration, ctx: RuleContext): VariableRef[] {
    if (ctx.session.gridPasswordEntered) return []
    const out: VariableRef[] = []
    for (let id = 0; id < nw.data.values.length; id++) {
      if (nw.raw(id) === old.raw(id) || nw.raw(id) === ctx.baseline.raw(id)) continue
      const ref: VariableRef = { kind: 'setting', index: id, name: names.settings[id] ?? '' }
      if (Access.isProtectedSetting(id, nw) && !Access.mayChangeWithoutPassword(ref, ctx)) out.push(ref)
    }
    for (let n = 0; n < names.flags.length; n++) {
      if (nw.flag(n) === old.flag(n) || nw.flag(n) === ctx.baseline.flag(n)) continue
      if (Access.isProtectedFlag(n, nw)) out.push({ kind: 'flag', index: n, name: names.flags[n]! })
    }
    return out
  },

  /** Protected values that differ from the loaded file without being allowed to (checked before saving). */
  forbiddenChanges(ctx: RuleContext): VariableRef[] {
    return Access.forbiddenEdits(ctx.baseline, ctx.config, ctx)
  },

  infoText(key: 'reset' | 'password'): string {
    return key === 'reset'
      ? L('Changing this setting requires a reset of the device after the file has been uploaded. The GX device does this for you.')
      : L('Enter the grid code password on the Grid page to edit this setting.')
  },
}
