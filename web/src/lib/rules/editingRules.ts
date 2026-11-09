// Visibility, grid pages, validation, consequences of an edit, battery presets and diagram lighting.
import type { DeviceConfiguration } from '../engine/deviceConfiguration'
import * as names from '../engine/settingNames'
import {
  catalog, changeListLabel, handler, type BatteryPreset, type CatalogControl, type CatalogGroup, type VariableRef,
} from './catalog'
import { RuleContext, SessionState, assistantDirectory, cells, dcVoltageClass, gridTable, isInverterOnly, isPresent, supports } from './context'
import { parses } from './expr'
import { L, catalogText, formatDefault } from './l10n'
import { capitalizedFirst, ReactivePanels } from './layout'
import { LocalControls, ValueCodec } from './valueCodec'

const lower = (s: string) => s.toLowerCase()

export const conditions = (name: string, kind: string) => catalog().conditions(name, kind, parses)

// MARK: - Visibility and enablement

export const Visibility = {
  /** VE Configure's generic rules: unsupported ⇒ hidden; Tag bit 0 ⇒ hidden helper; then `visibleWhen`. */
  isVisible(c: CatalogControl, ctx: RuleContext): boolean {
    if (((c.tag ?? 0) & 1) !== 0) return false
    if (c.visibleAtDesign === false && (c.visibleWhen ?? []).length === 0) return false
    const codec = ValueCodec.forControl(c)
    if (codec && !codec.isSupported(ctx.config)) return false
    if (handler(c, 'OnScaleSet') === 'RenewableEnergyCheckBoxScaleSet') {
      const id = LocalControls.setting('UBatDontChargeSettingEdit')
      if (id !== undefined && ctx.config.info.info(id)?.isSupported !== true) return false
    }
    if (c.name === 'LOMAC1SettingComboBox' && ctx.config.info.info(49)?.isSupported !== true) return false
    if (c.kind === 'text') {
      // Warning labels are shown by their `warning` / `visibleWhen` rules only.
      for (const kind of ['visibleWhen', 'warning']) {
        const rules = conditions(c.name, kind)
        if (rules && !ctx.all(rules, false)) return false
      }
      if (lower(c.name).includes('warning') && (c.visibleWhen ?? []).length === 0 && conditions(c.name, 'warning') === undefined) return false
    }
    return ctx.all(c.visibleWhen)
  },

  isGroupVisible(g: CatalogGroup, ctx: RuleContext): boolean {
    if (((g.tag ?? 0) & 16) !== 0) return false
    const shown = ReactivePanels.isVisible(g.name, ctx)
    if (shown === false) return false
    if (g.visibleAtDesign === false && (g.visibleWhen ?? []).length === 0) return false
    const rules = conditions(g.name, 'visibleWhen')
    if (rules && !ctx.all(rules)) return false
    return ctx.all(g.visibleWhen)
  },

  isPageVisible(name: string, ctx: RuleContext): boolean {
    if (name === 'DDCSheetUnderDevelopment') return false
    const rules = conditions(name, 'visibleWhen')
    return rules ? ctx.all(rules) : true
  },

  /** Extra enable conditions VE Configure applies from event handlers rather than from copied rules. */
  extraEnabled(c: CatalogControl, page: string | undefined, ctx: RuleContext): boolean {
    const cfg = ctx.config
    switch (c.name) {
      case 'SoCWhenBulkFinishedEdit': case 'BatteryCapacityEdit': case 'ChargeEfficiencyEdit': {
        // Battery monitor off (capacity 0) greys the group; the checkbox stays live.
        const m = catalog().controls.get('EnableBatteryMonitorCheckBox')
        if (m && Visibility.isVisible(m, ctx) && LocalControls.isChecked('EnableBatteryMonitorCheckBox', cfg) === false) return false
        break
      }
      case 'LOWSOCStopSettingEdit': case 'LOWSOCStartSettingEdit':
        if (LocalControls.isChecked('EnableLowSOCShutDownCheckBox', cfg) === false) return false
        break
      case 'vs2UBatOffEdit':
        if (LocalControls.vs2OffAction(cfg) < 2) return false
        break
      case 'AllowRushCurrentCheckBox':
        return false // slaved to the UPS function
    }
    if (page === 'ChargerSheet') {
      const warning = isInverterOnly(cfg) && !ctx.session.chargerUnhidden
      switch (c.name) {
        case 'EnableChargerCheckBox': return !warning
        case 'Memo1': case 'HideInverterWarningButton': return true
        default: {
          const ref = catalog().variables.get('EBIT_DisableCharge')
          const disabled = ref ? cfg.flag(ref.index) : false
          if (disabled || warning) return false
        }
      }
    }
    return true
  },
}

// MARK: - Grid codes

/** Display names for the firmware grid-code enum (VE Configure's grid code combo box). */
export function gridCodeName(index: number): string {
  return catalog().gridCodeName(index) ?? names.gridCodes[index] ?? L('Grid code %d', index)
}

export type GridChoice =
  | { t: 'accept'; code: number }
  | { t: 'reject'; message: string }
  /** VE Configure proposes another code: the button applies `alternative`; with `keep`, declining applies `keep`. */
  | { t: 'propose'; message: string; alternative: number; button: string; keep: number | undefined }
  /** A rule depends on a device fact this app cannot read from the file: the user must confirm, then `then`. */
  | { t: 'confirm'; message: string; button: string; then: GridChoice }

const extendedVEBusMessage = () =>
  L("A MultiPlus-II/Multigrid does not allow a grid code to be selected when it is part of a VE.Bus system with extended features!!\n\nRemove the extended features with the aid of VE.Bus System Configurator:\n - Do not uncheck any 'Switch as Group' box.\n - Do not use more than 1 AC input in a system with Multi's or do not use more than 2 AC Inputs in a system with Quattro's.")

function gridRule(id: string, n: number, ctx: RuleContext): boolean | undefined {
  const expr = catalog().rulesByID.get(id)?.expr
  if (expr === undefined) return undefined
  return ctx.evaluate(expr.replaceAll('newValue', String(n)))
}

export const GridPages = {
  selectionPage: 'StandardTransferSwitchPage',

  /** Which grid-code page VE Configure shows (FUN_00545f4c + caller FUN_00547548). */
  page(c: DeviceConfiguration): string | undefined {
    const code = c.raw(81)
    if (code < 2 || code === 21) return undefined
    const entry = gridTable(c)?.entries.get(code)
    const choice = catalog().gridCodePages.get(code)
    if (!entry || !choice) return undefined
    return choice.page(entry.variant)
  },

  showsMicrogrid(c: DeviceConfiguration): boolean {
    return c.raw(81) === 0 && (gridTable(c)?.entries.get(0)?.variant ?? 0) !== 0
  },

  /** Runtime page titles (FUN_00545f4c). */
  title(page: string, c: DeviceConfiguration, fallback: string): string {
    const code = c.raw(81)
    const t = gridTable(c)
    const variant = t?.entries.get(code)?.variant ?? 0
    switch (code) {
      case 20: return L('Northern Ireland')
      case 31: return 'UK G98'
      case 2: return t?.entries.get(31) !== undefined ? 'UK G99' : 'UK'
      case 9: return variant > 1 ? 'VFR 2019' : 'UTE C15'
      case 17: return L('European')
      case 18: return L('DK1 (Western Denmark)')
      case 19: return L('DK2 (Eastern Denmark)')
      case 30: return 'Czech 2023'
    }
    if (code === 11 && variant !== 0) return 'C10/11'
    if (code === 12 && variant !== 0) return 'TOR Erzeuger Typ A'
    if (code >= 22 && code <= 29)
      return [L('Australia A'), L('Australia B'), L('Australia C'), L('New Zealand')][(code > 25 ? code - 4 : code) - 22]!
    return catalogText(fallback.replaceAll(' grid code settings', ''))
  },

  /** §3.4: checker words A/B consistent with the grid code and the firmware's parameter-set version. */
  paramsValid(c: DeviceConfiguration): boolean {
    const code = c.raw(81), a = c.raw(128), b = c.raw(191)
    const ok = (code === 0 && a === 0xffff) || (a >> 8 === b >> 8 && (a & 0xff) === code)
    if (!ok) return false
    if (!(code !== 0 || a !== 0xffff)) return true
    const ver = ((b & 0xff) - (a & 0xff)) & 0xff
    return ver === (gridTable(c)?.entries.get(code)?.variant ?? ver)
  },

  /** GridCodeComboBoxDataSet + AfterDataSet: the code, its default parameter words, and the checker words. */
  apply(n: number, c: DeviceConfiguration): void {
    const entry = gridTable(c)?.entries.get(n)
    if (!entry) return
    c.setRaw(81, n)
    for (let id = 129; id <= 190; id++) {
      if (c.info.info(id)?.isSupported !== true) continue
      c.setRaw(id, isPresent(entry, id) ? (entry.defaults.get(id) ?? 0xffff) : 0xffff)
    }
    c.setRaw(128, n)
    c.setRaw(191, (n + entry.variant) & 0xff)
  },

  /** What happens when the user picks grid code `n` (GridCodeComboBoxDataSet @00545140). */
  choose(n: number, ctx: RuleContext): GridChoice {
    const c = ctx.config
    if (gridTable(c)?.entries.get(n) === undefined)
      return { t: 'reject', message: L('Grid code “%@” is not supported by the firmware in this device.', gridCodeName(n)) }
    const codeRules = byCode(n, ctx)
    // grid.extendedVEBus.reject: a MultiPlus-II ('/') part of a VE.Bus system with extended features.
    const r = gridRule('grid.extendedVEBus.reject', n, ctx)
    if (r === false) return { t: 'reject', message: extendedVEBusMessage() }
    if (r === undefined)
      return {
        t: 'confirm',
        message: L('Shunt cannot tell from the file whether this device is part of a VE.Bus system with extended features. VE Configure refuses the selection in that case:') + '\n\n' + extendedVEBusMessage(),
        button: L('The System Has No Extended Features'),
        then: codeRules,
      }
    return codeRules
  },
}

/** The per-code checks. Device facts this app cannot read fail closed. */
function byCode(n: number, ctx: RuleContext): GridChoice {
  const name = gridCodeName
  if (n === 4) {
    // grid.vde.internalIP.4to5: only proposed when the device is known to have internal protection.
    if (gridRule('grid.vde.internalIP.4to5', n, ctx) === true)
      return {
        t: 'propose',
        message: L('This device is equipped with internal interface protection!\nYou selected option:\n\n   %@\n\nIs it OK to change to option:\n\n   %@\n\ninstead?', name(4), name(5)),
        alternative: 5, button: L('Use Option 5'), keep: 4,
      }
    return { t: 'accept', code: 4 }
  }
  if (n === 5) {
    const r = gridRule('grid.vde.noIP.5to4', n, ctx)
    if (r === false) return { t: 'accept', code: 5 }
    if (r === true)
      return {
        t: 'propose',
        message: L('This device is not equipped with internal interface protection!\nSo you cannot choose option:\n\n   %@\n\nIs it OK to use option:\n\n   %@\n\ninstead?', name(5), name(4)),
        alternative: 4, button: L('Use Option 4'), keep: undefined,
      }
    return {
      t: 'propose',
      message: L('Option:\n\n   %@\n\nis only allowed on a device equipped with internal interface protection. Shunt cannot tell from the file whether this device has it.\n\nIs it OK to use option:\n\n   %@\n\ninstead?', name(5), name(4)),
      alternative: 4, button: L('Use Option 4'), keep: undefined,
    }
  }
  if ((n >= 6 && n <= 19) || (n >= 22 && n <= 29)) {
    // grid.noIP.reject: firmware < 485 without internal interface protection (unknown = not equipped).
    if (gridRule('grid.noIP.reject', n, ctx) !== true)
      return { t: 'reject', message: L('This device is not equipped with internal interface protection!\nSo you cannot choose option:\n\n   %@', name(n)) }
    return { t: 'accept', code: n }
  }
  if ([0, 1, 2, 3, 20, 21, 30, 31, 32].includes(n)) return { t: 'accept', code: n }
  return { t: 'reject', message: L('Grid code “%@” is not supported by Shunt.', name(n)) }
}

// MARK: - Notices

/** A message VE Configure shows after a change (info, warning or a question with an action). */
export interface Notice {
  title: string
  message: string
  action?: 'openBatteryPresets'
  actionTitle?: string
}

// MARK: - Validation (values VE Configure refuses: the old value is kept and a message shown)

export const Validation = {
  /** The message VE Configure shows when it refuses the edit of `control` (`old` → `new`), or undefined if accepted. */
  rejection(old: DeviceConfiguration, c: DeviceConfiguration, control: string | undefined, ctx: RuleContext): Notice | undefined {
    if (control === undefined) return undefined
    const ctl = catalog().controls.get(control)
    if (!ctl) return undefined
    return orderRule(ctl, c, ctx) ?? sequence(ctl, old, c) ?? socNeedsMonitor(ctl, old, c, ctx)
  },

  label(ctl: CatalogControl): string { return capitalizedFirst(changeListLabel(ctl) ?? ctl.name) },
}

/** inverter.socEditNeedsMonitor: the SOC shut-down levels cannot be set while the battery monitor is disabled. */
function socNeedsMonitor(ctl: CatalogControl, old: DeviceConfiguration, c: DeviceConfiguration, ctx: RuleContext): Notice | undefined {
  const rule = catalog().rulesByID.get('inverter.socEditNeedsMonitor')
  if (!rule || rule.expr === undefined) return undefined
  const turningOn = ctl.name === 'EnableLowSOCShutDownCheckBox'
    && LocalControls.isChecked(ctl.name, old) === false && LocalControls.isChecked(ctl.name, c) === true
  if (!(rule.targets.includes(ctl.name) || turningOn)) return undefined
  const before = new RuleContext(old, ctx.baseline, ctx.session)
  // The monitor can only be off when its checkbox exists (BatteryCapacity minimum 0).
  const monitor = catalog().controls.get('EnableBatteryMonitorCheckBox')
  if (!monitor || !Visibility.isVisible(monitor, before) || before.evaluate(rule.expr) === true) return undefined
  return { title: L('Battery monitor disabled'), message: L('Please enable the battery monitor on the general page first!') }
}

/** grid.chile.order / grid.romania.order: U start < U stop. */
function orderRule(ctl: CatalogControl, c: DeviceConfiguration, ctx: RuleContext): Notice | undefined {
  for (const id of ['grid.chile.order', 'grid.romania.order']) {
    const rule = catalog().rulesByID.get(id)
    if (!rule || !rule.targets.includes(ctl.name) || rule.expr === undefined) continue
    const after = new RuleContext(c, ctx.baseline, ctx.session)
    if (after.evaluate(rule.expr) !== false) continue
    const ls = rule.targets.map((t) => catalog().controls.get(t)).filter((x): x is CatalogControl => !!x).map(Validation.label)
    if (ls.length !== 2) continue
    return { title: L('Illegal value!'), message: L('Illegal value!\n%@ should be lower than %@!', ls[0], ls[1]) }
  }
  return undefined
}

/** grid.sequence: the RelevantComponents values must rise strictly (NoEquals) or not fall (WithEquals). */
function sequence(ctl: CatalogControl, old: DeviceConfiguration, c: DeviceConfiguration): Notice | undefined {
  const h = handler(ctl, 'OnPeerDataSet')
  const list = ctl.semantics?.relevantComponents
  if (h === undefined || !h.startsWith('GenericSequence') || !list || list.length < 2) return undefined
  const equalsAllowed = h === 'GenericSequenceWithEqualsTest'
  const items = list.map((n) => catalog().controls.get(n)).filter((x): x is CatalogControl => !!x)
  if (items.length !== list.length) return undefined
  const codecs = items.map((i) => ValueCodec.forControl(i)).filter((x): x is ValueCodec => !!x)
  if (codecs.length !== items.length || !codecs.every((k) => k.isSupported(c))) return undefined
  const values = codecs.map((k) => k.display(c)).filter((x): x is number => x !== undefined)
  if (values.length !== codecs.length) return undefined
  // Only the edited control's change is judged (VE Configure checks on its OnPeerDataSet).
  const me = items.findIndex((i) => i.name === ctl.name)
  if (me < 0 || codecs[me]!.raw(old) === codecs[me]!.raw(c)) return undefined
  let ok = true
  for (let i = 0; i + 1 < values.length; i++) {
    const a = values[i]!, b = values[i + 1]!
    if (!(equalsAllowed ? a <= b + 1e-9 : a < b - 1e-9)) { ok = false; break }
  }
  if (ok) return undefined
  const title = L('The chosen value is not allowed!')
  if (items.length === 2) {
    const other = me === 0 ? 1 : 0
    const otherText = Validation.label(items[other]!) + ' (' + codecs[other]!.formatted(c) + ')'
    const l = Validation.label(ctl)
    const message = me === 0
      ? (equalsAllowed ? L('%@ must be lower than or equal to: %@', l, otherText) : L('%@ must be lower than: %@', l, otherText))
      : (equalsAllowed ? L('%@ must be higher than or equal to: %@', l, otherText) : L('%@ must be higher than: %@', l, otherText))
    return { title, message }
  }
  const rows = items.map((it, i) => '  ' + Validation.label(it) + ': ' + codecs[i]!.formatted(c)).join('\n')
  return {
    title,
    message: (equalsAllowed
      ? L('The following values must be in rising order (equal values are allowed):')
      : L('The following values must be in rising order (equal values are not allowed):')) + '\n' + rows,
  }
}

// MARK: - Consequences of an edit (SetCheckRules and the AfterDataSet handlers)

const v = (name: string) => catalog().variables.get(name)
function flagOf(name: string, c: DeviceConfiguration): boolean | undefined {
  const r = v(name)
  return r ? c.flag(r.index) : undefined
}
function setFlag(name: string, on: boolean, c: DeviceConfiguration): void {
  const r = v(name)
  if (r && c.supportsFlag(r.index)) c.setFlag(r.index, on)
}
function codecOf(name: string): ValueCodec | undefined {
  const r = v(name)
  return r ? ValueCodec.forSetting(r.index) : undefined
}
function displayOf(name: string, c: DeviceConfiguration): number | undefined {
  const k = codecOf(name)
  if (!k || !k.isSupported(c)) return undefined
  return k.display(c)
}
function rawOf(name: string, c: DeviceConfiguration): number | undefined {
  const r = v(name)
  return r ? c.raw(r.index) : undefined
}
function setRawOf(name: string, r: number, c: DeviceConfiguration): void {
  const ref = v(name)
  if (ref && c.info.info(ref.index)?.isSupported === true) c.setRaw(ref.index, Math.max(0, Math.min(0xffff, r)))
}
function changed(name: string, a: DeviceConfiguration, b: DeviceConfiguration): boolean {
  const r = v(name)
  if (!r) return false
  return r.kind === 'flag' ? a.flag(r.index) !== b.flag(r.index) : a.raw(r.index) !== b.raw(r.index)
}

export const Consequences = {
  /** Runs after every user edit; returns the messages to show. `old` is the configuration before the edit. */
  apply(old: DeviceConfiguration, c: DeviceConfiguration, control: string | undefined): Notice[] {
    const notices: Notice[] = []

    // Charge curve chosen by the user: VE Configure resets the repeated absorption defaults.
    if (control === 'ChargeCharacteristicComboBox' && changed('EPROM_ChargeCharacteristic', old, c)) {
      const fixed = rawOf('EPROM_ChargeCharacteristic', c) === 1
      codecOf('EPROM_EqualiseQuarters')?.setDisplay(fixed ? 0.5 : 1, c)
      codecOf('EPROM_FloatDays')?.setDisplay(fixed ? 1 : 7, c)
      setFlag('EBIT_EnableReducedFloat', fixed ? false : !(flagOf('EBIT_LithiumBattery', c) ?? false), c)
    }

    // 1. Float above absorption → float := absorption.
    {
      const abs = displayOf('EPROM_UBatAbs', c), fl = displayOf('EPROM_UBatFloat', c)
      const r = rawOf('EPROM_UBatAbs', c)
      if (abs !== undefined && fl !== undefined && abs < fl - 1e-9 && r !== undefined) {
        setRawOf('EPROM_UBatFloat', r, c)
        notices.push({ title: L('Float voltage adapted'), message: L('Absorption voltage must be higher than float voltage. The float voltage was set to the absorption voltage.') })
      }
    }
    // 3. SoC low restart below shut-down → shut-down := restart.
    {
      const start = rawOf('EPROM_SOCStartInvert', c), stop = rawOf('EPROM_SOCStopInvert', c)
      if (start !== undefined && stop !== undefined && start !== 0 && start < stop) {
        setRawOf('EPROM_SOCStopInvert', start, c)
        notices.push({ title: L('SOC low shut-down adapted'), message: L('“SOC low restart” must not be lower than “SOC low shut-down”. “SOC low shut-down” was adapted.') })
      }
    }
    // 4. VS2 load: "higher than" below "lower than" → lower := higher.
    {
      const hi = displayOf('EPROM_vs2onILoadHigh', c), lo = displayOf('EPROM_vs2offILoadLow', c)
      const r = rawOf('EPROM_vs2onILoadHigh', c)
      if (hi !== undefined && lo !== undefined && hi < lo && r !== undefined) {
        setRawOf('EPROM_vs2offILoadLow', r, c)
        notices.push({ title: L('Limit adapted'), message: L('Secondary virtual switch “Load higher than” limit must be higher than the “Load lower than” limit. “Load lower than” limit was adapted.') })
      }
    }
    // 5. VS2 battery: "Udc higher than" below "Udc lower than" → lower := higher.
    {
      const offRaw = rawOf('EPROM_vs2offUBat', c)
      if (offRaw !== undefined && offRaw > 0xff) {
        const off = displayOf('EPROM_vs2offUBat', c), low = displayOf('EPROM_vs2onUBatLow', c)
        if (off !== undefined && low !== undefined && off < low) {
          codecOf('EPROM_vs2onUBatLow')?.setDisplay(off, c)
          notices.push({ title: L('Limit adapted'), message: L('Secondary virtual switch “Udc lower than” limit must be lower than the “Udc higher than” limit. “Udc lower than” limit was adapted.') })
        }
      }
    }
    // 9. DC input low restart minimum 10.9 / 20.6 / 41.2 V.
    {
      const ctl = catalog().controls.get('DCLowRestartEdit')
      const k = ctl && ValueCodec.forControl(ctl)
      const restart = k && k.isSupported(c) ? k.display(c) : undefined
      if (k && restart !== undefined) {
        const minimum = ({ 12: 10.9, 24: 20.6, 48: 41.2 } as Record<number, number>)[dcVoltageClass(c)] ?? 10.9
        if (restart < minimum - 1e-6) {
          k.setDisplay(minimum, c)
          notices.push({ title: L('Restart voltage adapted'), message: L('DC input low restart voltage must be ≥ %@ V. The restart voltage acts as an offset on the DC input low shut-down, so this can happen even when its own minimum looks lower.', formatDefault(minimum)) })
        }
      }
    }
    // UPS function ⇒ "allow low voltage during in-rush" follows it (MakeConsitenWithWaveShapeCheck).
    {
      const wave = flagOf('EBIT_DisableMainsWaveCheck', c)
      if (wave !== undefined) setFlag('EBIT_DisableBFLockOnLargeCurrents', !wave, c)
    }
    // 14. Lithium on/off side effects.
    {
      const was = flagOf('EBIT_LithiumBattery', old), isNow = flagOf('EBIT_LithiumBattery', c)
      if (was !== undefined && isNow !== undefined && was !== isNow) {
        if (isNow) {
          setFlag('EBIT_EnableReducedFloat', false, c)
          setFlag('EBIT_TubularPlateTractionBatteryCurve', false, c)
          const curve = rawOf('EPROM_ChargeCharacteristic', c)
          if (curve !== undefined && curve > 2) setRawOf('EPROM_ChargeCharacteristic', 1, c)
          if (control === 'LithiumCheckBox') {
            notices.push({
              title: L('Lithium batteries'),
              message: L('This is not the only relevant setting for lithium batteries. Normally more settings need to be changed: use a battery preset to set them together.'),
              action: 'openBatteryPresets', actionTitle: L('Battery Presets…'),
            })
          }
        } else {
          setRawOf('EPROM_TBatStopCharge', 0, c)
          setFlag('EBIT_ConfiguredForVEBusBMS', false, c)
        }
      }
    }
    // 13. "Stop after excessive bulk" needs the battery monitor.
    {
      const cap = rawOf('EPROM_BatteryCapacity', c)
      const ref = v('EBIT_DoNotStopAfter10HrBulk')
      if (cap === 0 && ref && c.supportsFlag(ref.index) && !c.flag(ref.index)
        && (changed('EPROM_BatteryCapacity', old, c) || changed('EBIT_DoNotStopAfter10HrBulk', old, c))) {
        const m = catalog().controls.get('EnableBatteryMonitorCheckBox')
        if (m && Visibility.isVisible(m, new RuleContext(c, old, new SessionState()))) {
          c.setFlag(ref.index, true)
          notices.push({ title: L('“Stop after excessive bulk” disabled'), message: L('The battery monitor is disabled. The firmware requires the battery monitor for the bulk protection to work. To use “Stop after excessive bulk”, enable the battery monitor first.') })
        }
      }
    }
    // VS options: frequency shift on VS and on Udc are mutually exclusive.
    if (flagOf('EBIT_vsSetInverterPeriodTime', c) === true && flagOf('EBIT_vsSetInverterPeriodTime', old) === false) {
      setFlag('EBIT_vsInverterPeriodTimeOnUBat', false, c)
    } else if (flagOf('EBIT_vsInverterPeriodTimeOnUBat', c) === true && flagOf('EBIT_vsInverterPeriodTimeOnUBat', old) === false) {
      setFlag('EBIT_vsSetInverterPeriodTime', false, c)
    }
    // 12. Inverter period time follows the system frequency while the virtual switch is unused.
    if (changed('EBIT_60Hz', old, c) || changed('EPROM_vsUsage', old, c)) {
      const usage = rawOf('EPROM_vsUsage', c)
      if (usage !== undefined && (usage === 0 || c.info.info(v('EPROM_vsUsage')?.index ?? 15)?.isSupported !== true)) {
        const ctl = catalog().controls.get('PeriodToFrequencySettingEdit')
        const f = ctl && ValueCodec.forControl(ctl)
        if (f && f.isSupported(c)) f.setDisplay(flagOf('EBIT_60Hz', c) === true ? 60 : 50, c)
      }
    }
    // VS2 start/stop delay coupling (Checkvs2…FilterTime).
    if (changed('EPROM_vs2tonILoadHigh', old, c) && rawOf('EPROM_vs2tonILoadHigh', c) !== undefined) {
      const on = rawOf('EPROM_vs2tonILoadHigh', c)!
      if (on === 0) setRawOf('EPROM_vs2toffILoadLow', 0, c)
      else if (rawOf('EPROM_vs2toffILoadLow', c) === 0) setRawOf('EPROM_vs2toffILoadLow', 1, c)
    } else if (changed('EPROM_vs2toffILoadLow', old, c) && rawOf('EPROM_vs2toffILoadLow', c) === 0) {
      setRawOf('EPROM_vs2tonILoadHigh', 0, c)
    }
    if (changed('EPROM_vs2tonUBatLow', old, c) || changed('EPROM_vs2StartOnSOC', old, c)) {
      const soc = displayOf('EPROM_vs2StartOnSOC', c)
      const start = (rawOf('EPROM_vs2tonUBatLow', c) ?? 0) !== 0 || (soc !== undefined ? soc !== 0 : false)
      if (!start) setRawOf('EPROM_vs2toffUBat', 0, c)
      else if (rawOf('EPROM_vs2toffUBat', c) === 0) setRawOf('EPROM_vs2toffUBat', 1, c)
    } else if (changed('EPROM_vs2toffUBat', old, c) && rawOf('EPROM_vs2toffUBat', c) === 0) {
      setRawOf('EPROM_vs2tonUBatLow', 0, c)
      setRawOf('EPROM_vs2StartOnSOC', 0, c)
    }
    // Enabling the virtual switch disables assistants.
    if (changed('EPROM_vsUsage', old, c) && rawOf('EPROM_vsUsage', old) === 0 && (rawOf('EPROM_vsUsage', c) ?? 0) !== 0
      && assistantDirectory(c).length > 0) {
      notices.push({ title: L('Assistants will stop working'), message: L('Enabling the virtual switch disables the assistant functionality. VE Configure removes all configured assistants in this case; remove them on the Assistants tab, or set the virtual switch back to “Do not use VS”.') })
    }
    // Informative warnings.
    if (control?.startsWith('RepeatedAbsorption')) {
      const t = displayOf('EPROM_EqualiseQuarters', c), d = displayOf('EPROM_FloatDays', c)
      if (t !== undefined && d !== undefined && t >= d * 24)
        notices.push({ title: L('Continuous absorption'), message: L('Repeated absorption time ≥ repeated absorption interval time. This results in continuous absorption.') })
    }
    if (control === 'TPTBCheckBox' && flagOf('EBIT_TubularPlateTractionBatteryCurve', c) === true) {
      notices.push({ title: L('Tubular plate traction battery curve'), message: L('Note that the system DC voltage can get as high as %@ V.', `${Math.trunc(cells(c) / 6) * 17}`) })
    }
    if (control === 'ACLowSwitchOnEdit' || control === 'ACHighSwitchOnEdit') {
      const loC = catalog().controls.get('ACLowSwitchOnEdit'), hiC = catalog().controls.get('ACHighSwitchOnEdit')
      const lo = loC ? ValueCodec.forControl(loC)?.display(c) : undefined
      const hi = hiC ? ValueCodec.forControl(hiC)?.display(c) : undefined
      if (lo !== undefined && hi !== undefined && lo >= hi)
        notices.push({ title: L('AC connect levels'), message: L('AC low connect is set higher than or equal to AC high connect. The grid voltage would never be accepted.') })
    }
    if (control === 'GridCodeComboBox') {
      const code = rawOf('EPROM_GridCode', c)
      if (code === 1 || code === 21)
        notices.push({ title: L('Not compliant with any standard'), message: L('With grid code “%@” the Multi/Quattro does not comply with any standard. Installing external certified equipment might be mandatory.', gridCodeName(code)) })
    }
    return notices
  },
}

// MARK: - Battery presets

export const BatteryPresets = {
  /** Settings a preset may set, in VE Configure's order. */
  order: ['EPROM_UBatAbs', 'EPROM_UBatFloat', 'EPROM_AbsorptionHours', 'EPROM_EqualiseQuarters', 'EPROM_FloatDays',
    'EBIT_EnableReducedFloat', 'EBIT_LithiumBattery', 'EPROM_ChargeCharacteristic',
    'EPROM_ChargePercentageResetValueForBatteryMonitor', 'EPROM_ChargeEfficiency',
    'EPROM_TempCompensationSlope', 'EPROM_TBatStopCharge', 'EBIT_ConfiguredForVEBusBMS'],
  voltageScaled: new Set(['EPROM_UBatAbs', 'EPROM_UBatFloat', 'EPROM_TempCompensationSlope']),

  /** Value in this device's units (12 V preset values × cells/6). */
  value(p: BatteryPreset, name: string, c: DeviceConfiguration): number | undefined {
    const x = p.values[name]
    if (!x || (p.notSet ?? []).includes(name) || !(x.value < 1e40)) return undefined
    return BatteryPresets.voltageScaled.has(name) ? (x.value * cells(c)) / 6 : x.value
  },

  /** The preset whose every value matches within half a step (FUN_0051cb68); most compared values wins. */
  matching(c: DeviceConfiguration): BatteryPreset | undefined {
    let best: [BatteryPreset, number] | undefined
    for (const p of catalog().batteryPresets) {
      let compared = 0, ok = true
      for (const name of BatteryPresets.order) {
        const target = BatteryPresets.value(p, name, c)
        const ref = catalog().variables.get(name)
        if (target === undefined || !ref || !supports(c, ref)) continue
        compared++
        if (ref.kind === 'flag') {
          if (c.flag(ref.index) !== (target !== 0)) { ok = false; break }
        } else {
          const k = ValueCodec.forSetting(ref.index)
          const cur = k?.display(c)
          if (k && cur !== undefined && Math.abs(cur - target) > Math.abs(k.scale(c)) / 2 + 1e-9) { ok = false; break }
        }
      }
      if (ok && compared > 0 && compared > (best?.[1] ?? 0)) best = [p, compared]
    }
    return best?.[0]
  },

  /** Applies a preset (TBatteryDefaultForm OK → FUN_0051e574). Returns the summary message. */
  apply(preset: BatteryPreset, c: DeviceConfiguration): Notice {
    let p = preset
    let extra = ''
    const bms = catalog().variables.get('EBIT_ConfiguredForVEBusBMS')
    const liion = catalog().batteryPresets.find((x) => x.id === 'cbtLiIon')
    if (p.flags?.requiresVEBusBMSSupport === true && !(bms && supports(c, bms)) && liion) {
      p = liion
      extra = L('The firmware in the Multi/Quattro does not support a VE.Bus BMS directly. An assistant is required to handle the VE.Bus BMS. Battery type set to standard Li-Ion.') + '\n\n'
    }
    const changedNames: string[] = []
    const limited: string[] = []
    for (const name of BatteryPresets.order) {
      const target = BatteryPresets.value(p, name, c)
      const ref = catalog().variables.get(name)
      if (target === undefined || !ref || !supports(c, ref)) continue
      const label = (ref.kind === 'flag' ? catalog().labelFlag(ref.index) : catalog().label(ref.index)) ?? name
      if (ref.kind === 'flag') {
        if (c.flag(ref.index) !== (target !== 0)) { c.setFlag(ref.index, target !== 0); changedNames.push(label) }
      } else {
        const k = ValueCodec.forSetting(ref.index)
        if (!k) continue
        const before = c.raw(ref.index)
        if (!k.setDisplay(target, c)) {
          const r = k.range(c)
          if (r) {
            k.setDisplay(Math.min(Math.max(target, r.min), r.max), c)
            limited.push(label)
          }
        }
        if (c.raw(ref.index) !== before) changedNames.push(label)
      }
    }
    const tptb = catalog().variables.get('EBIT_TubularPlateTractionBatteryCurve')
    if (tptb && c.supportsFlag(tptb.index)) c.setFlag(tptb.index, false)
    let msg = extra + (changedNames.length === 0 ? L('No settings needed to change.') : L('Changed: %@.', changedNames.join(', ')))
    if (limited.length) msg += '\n\n' + L('Limited by the device range: %@.', limited.join(', '))
    return { title: L('Battery type set to %@', catalogText(p.name)), message: msg }
  },
}

// MARK: - Diagram lighting

export type DiagramPart =
  | 'acIn' | 'acIn2' | 'generator' | 'transferSwitch' | 'feedIn' | 'inverter' | 'charger' | 'battery' | 'dcBus' | 'acOut' | 'relay'

export const Lighting = {
  /** Parts of the installation a set of variables acts on (the diagram lights them for the group in focus). */
  parts(controls: CatalogControl[], page: string, c: DeviceConfiguration): Set<DiagramPart> {
    const lit = new Set<DiagramPart>()
    const add = (...p: DiagramPart[]) => p.forEach((x) => lit.add(x))
    const usage = c.raw(15)
    for (const ctl of controls) {
      const ns = [ctl.variable?.name, ...(ctl.peer?.peers.map((p) => p.variable?.name) ?? [])].filter((x): x is string => x !== undefined)
      for (const n of ns) {
        const ln = lower(n)
        const has = (...keys: string[]) => keys.some((k) => ln.includes(lower(k)))
        if (has('GridSettings', 'GridCode', 'FeedIn', 'GeneralGrid')) add('acIn', 'feedIn')
        else if (has('vs2')) { if (usage === 4 || usage === 6) add('generator', 'acIn2', 'relay'); else add('acIn', 'transferSwitch') }
        else if (has('EPROM_vs', 'EBIT_vs', 'fsUBat')) add('relay')
        else if (has('IMainsLimitAC1')) add('acIn2')
        else if (has('IMainsLimit', 'RemoteOverrules', 'CurrentSensor', 'AdjustMainsLimit', 'AllowIMainsHigher')) add('acIn')
        else if (has('UMains', 'WideInput', 'MainsWave', 'BFLock')) add('acIn', 'transferSwitch')
        else if (has('Assist')) add('acIn', 'inverter', 'acOut')
        else if (has('BatteryCapacity', 'ChargePercentage', 'ChargeEfficiency')) add('battery', 'dcBus')
        else if (has('SOC', 'UBat2Low', 'UBatLowMargin', 'UBatPreAlarm')) add('battery', 'inverter', 'dcBus')
        else if (has('60Hz', 'UInvSetpoint', 'RequestedInv', 'AES', 'GndRelay', 'ShortCircuit', 'IInv', 'MultiPhase', 'NrOfSlaves')) add('inverter', 'acOut')
        else if (has('UBatAbs', 'UBatFloat', 'IBatBulk', 'Charge', 'Absorption', 'Lithium', 'TempComp', 'TBat', 'ReducedFloat',
          'Tubular', 'FloatDays', 'EqualiseQuarters', 'VEBusBMS', 'WeakAC', 'Bulk', 'DontCharge', 'Renewable', 'VSense')) add('charger', 'battery')
      }
    }
    if (lit.size === 0) {
      if (page === 'ChargerSheet' || page === 'AdvancedSheet') add('charger', 'battery')
      else if (page === 'InverterSheet') add('inverter', 'acOut')
    }
    return lit
  },
}

export type { VariableRef }
