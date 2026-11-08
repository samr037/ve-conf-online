// One open configuration file: edits, undo, the change list, grid unlock and saving
// (port of Sources/VEConfigure/ConfigDocument.swift plus the edit paths of SettingRows.swift and Confirmations.swift).
import { equalBytes, type Bytes } from '../engine/binary'
import { DeviceConfiguration } from '../engine/deviceConfiguration'
import * as names from '../engine/settingNames'
import {
  catalog, changeListLabel as changeListLabelOf, displayUnit, formatFlag, isInverted, settingTargets,
  type BatteryPreset, type CatalogControl, type VariableRef,
} from './catalog'
import { Access, RuleContext, SessionState } from './context'
import { BatteryPresets, Consequences, GridPages, Validation, gridCodeName, type GridChoice, type Notice } from './editingRules'
import { L, formatFixed } from './l10n'
import { ValueCodec, LocalControls } from './valueCodec'

/** Value equality of two configurations (Swift `DeviceConfiguration ==`), via their encoding. */
export function sameConfig(a: DeviceConfiguration, b: DeviceConfiguration): boolean {
  return a === b || (a.formatVersion === b.formatVersion && equalBytes(a.encoded(), b.encoded()))
}

export type ChangeTarget =
  | { t: 'setting'; id: number }
  | { t: 'flag'; n: number }
  | { t: 'assistants' }
  | { t: 'control'; name: string }
  | { t: 'gridCode' }

export const targetKey = (t: ChangeTarget): string =>
  t.t === 'setting' ? `setting:${t.id}` : t.t === 'flag' ? `flag:${t.n}` : t.t === 'control' ? `control:${t.name}` : t.t

export interface Change { target: ChangeTarget; label: string; before: string; after: string }

/** Optional providers for what lives in the assembler (being ported separately). */
export interface DocumentEnvironment {
  /** `MetaGenerator.ratings`: DC voltage, AC voltage and rated power of the device. */
  ratings?: (c: DeviceConfiguration) => { dc: number; ac: number; power: number }
}

interface UndoEntry { name: string; config: DeviceConfiguration }

/** Everything needed to bring a document back after a page reload. The grid password is never kept. */
export interface DocumentSnapshot {
  fileName?: string
  baseline: Bytes
  config: Bytes
  undo: { name: string; config: Bytes }[]
  redo: { name: string; config: Bytes }[]
  chargerUnhidden: boolean
}

export class ConfigDocument {
  config: DeviceConfiguration
  /** The configuration as loaded (or as last saved): the reference for the change list. */
  baseline: DeviceConfiguration
  fileName: string | undefined
  /** Session-only state (grid password entered, charger parameters unhidden…). */
  session = new SessionState()
  /** Messages from the last edit (VE Configure's info boxes), shown by the page. */
  notices: Notice[] = []
  env: DocumentEnvironment
  private undoStack: UndoEntry[] = []
  private redoStack: UndoEntry[] = []
  /** Called after every change of config, baseline, session or notices. */
  onChange: (() => void) | undefined

  constructor(config: DeviceConfiguration, fileName?: string, env: DocumentEnvironment = {}) {
    this.config = config
    this.baseline = config
    this.fileName = fileName
    this.env = env
  }

  static open(bytes: Bytes, fileName?: string, env?: DocumentEnvironment): ConfigDocument {
    return new ConfigDocument(DeviceConfiguration.parse(bytes), fileName, env)
  }

  snapshot(): DocumentSnapshot {
    const entry = (e: UndoEntry) => ({ name: e.name, config: e.config.encoded() })
    return {
      fileName: this.fileName,
      baseline: this.baseline.encoded(),
      config: this.config.encoded(),
      undo: this.undoStack.map(entry),
      redo: this.redoStack.map(entry),
      chargerUnhidden: this.session.chargerUnhidden,
    }
  }

  /** Rebuilds a document from `snapshot()`. Throws if any of its configurations no longer parses. */
  static restore(s: DocumentSnapshot, env?: DocumentEnvironment): ConfigDocument {
    const doc = new ConfigDocument(DeviceConfiguration.parse(s.baseline), s.fileName, env)
    doc.config = DeviceConfiguration.parse(s.config)
    const entry = (e: { name: string; config: Bytes }): UndoEntry => ({ name: e.name, config: DeviceConfiguration.parse(e.config) })
    doc.undoStack = s.undo.map(entry)
    doc.redoStack = s.redo.map(entry)
    doc.session.chargerUnhidden = s.chargerUnhidden
    return doc
  }

  get ruleContext(): RuleContext { return new RuleContext(this.config, this.baseline, this.session) }
  get title(): string { return this.fileName ?? L('Configuration') }
  get isEdited(): boolean { return !sameConfig(this.config, this.baseline) }

  private notify(): void { this.onChange?.() }

  /** A successful check applies only to this document, until it closes. */
  unlockGrid(password: string): boolean {
    if (this.config.data.version < 2) return false
    const ok = this.session.unlockGrid(password)
    this.notify()
    return ok
  }

  unhideCharger(): void {
    this.session.chargerUnhidden = true
    this.notify()
  }

  dismissNotice(): Notice | undefined {
    const n = this.notices.shift()
    this.notify()
    return n
  }

  // MARK: Editing

  setRaw(id: number, value: number, actionName: string): void {
    if (this.config.raw(id) === value) return
    this.applyRaw(actionName, (c) => c.setRaw(id, value))
  }

  setValue(id: number, value: number, actionName: string): void {
    const raw = this.config.info.info(id)?.rawValue(value)
    if (raw === undefined) return
    this.setRaw(id, raw, actionName)
  }

  setFlag(n: number, on: boolean, actionName: string): void {
    if (this.config.flag(n) === on) return
    this.applyRaw(actionName, (c) => c.setFlag(n, on))
  }

  /**
   * One user edit: the change itself plus VE Configure's consequences, undone as a single step.
   * An edit that would change a grid-code protected value (other than back to its loaded value) is refused as a
   * whole unless the user has verified the grid-code password for this document.
   */
  edit(actionName: string, control: string | undefined, change: (c: DeviceConfiguration) => void): void {
    const old = this.config
    const c = old.clone()
    change(c)
    if (sameConfig(c, old)) return
    const refused = Validation.rejection(old, c, control, this.ruleContext)
    if (refused) {
      this.notices.push(refused)
      this.notify()
      return
    }
    const found = Consequences.apply(old, c, control)
    const forbidden = Access.forbiddenEdits(old, c, this.ruleContext)
    if (forbidden.length) {
      this.notices.push({ title: L('Protected by the grid code password'), message: protectedMessage(forbidden, c) })
      this.notify()
      return
    }
    this.replace(c, actionName)
    if (found.length) this.notices.push(...found)
    this.notify()
  }

  /** Replaces the whole configuration (used by `edit`, presets and grid-code changes) with undo. */
  replace(nw: DeviceConfiguration, actionName: string): void {
    if (sameConfig(this.config, nw)) return
    this.undoStack.push({ name: actionName, config: this.config })
    this.redoStack = []
    this.config = nw
    this.notify()
  }

  /** Applies a raw change unless it touches a protected value. */
  private applyRaw(actionName: string, edit: (c: DeviceConfiguration) => void): boolean {
    const c = this.config.clone()
    edit(c)
    const forbidden = Access.forbiddenEdits(this.config, c, this.ruleContext)
    if (forbidden.length) {
      this.notices.push({ title: L('Protected by the grid code password'), message: protectedMessage(forbidden, c) })
      this.notify()
      return false
    }
    this.replace(c, actionName)
    return true
  }

  get canUndo(): boolean { return this.undoStack.length > 0 }
  get canRedo(): boolean { return this.redoStack.length > 0 }
  get undoActionName(): string | undefined { return this.undoStack.at(-1)?.name }
  get redoActionName(): string | undefined { return this.redoStack.at(-1)?.name }

  undo(): void {
    const e = this.undoStack.pop()
    if (!e) return
    this.redoStack.push({ name: e.name, config: this.config })
    this.config = e.config
    this.notify()
  }

  redo(): void {
    const e = this.redoStack.pop()
    if (!e) return
    this.undoStack.push({ name: e.name, config: this.config })
    this.config = e.config
    this.notify()
  }

  /**
   * "Restore unmodified value": puts a change back to its loaded value through `edit`, so the follow-up corrections run.
   * A control spanning several words is restored as a whole; a grid-code change with its parameter and checker words.
   */
  revert(change: Change): void {
    const base = this.baseline
    const action = L('Restore %@', change.label)
    const t = change.target
    switch (t.t) {
      case 'setting':
        this.edit(action, catalog().settingControls.get(t.id)?.name, (c) => c.setRaw(t.id, base.raw(t.id)))
        break
      case 'flag':
        this.edit(action, catalog().flagControls.get(t.n)?.name, (c) => c.setFlag(t.n, base.flag(t.n)))
        break
      case 'control': {
        const ctl = catalog().controls.get(t.name)
        if (ctl) this.restore(ctl, action)
        break
      }
      case 'gridCode':
        this.edit(action, 'GridCodeComboBox', (c) => { for (const id of [81, ...range(128, 192)]) c.setRaw(id, base.raw(id)) })
        break
      case 'assistants':
        break
    }
  }

  /** Restores everything one control writes to the loaded values. */
  restore(ctl: CatalogControl, actionName: string): void {
    const base = this.baseline
    this.edit(actionName, ctl.name, (c) => {
      const v = ctl.variable
      if (v?.kind === 'flag' && v.index !== undefined) { c.setFlag(v.index, base.flag(v.index)); return }
      if (ctl.peer) {
        const k = ValueCodec.forControl(ctl)
        const r = k?.raw(base)
        if (k && r !== undefined) { k.restoreRaw(r, c); return }
      }
      for (const id of settingTargets(ctl)) c.setRaw(id, base.raw(id))
    })
  }

  // MARK: Row actions (the edit paths of the Mac rows)

  /** Typed number committed in a numeric field. Returns false when refused (the Mac app beeps). */
  commitNumber(ctl: CatalogControl, text: string, label: string): boolean {
    const codec = ValueCodec.forControl(ctl)
    if (!codec) return false
    const v = ValueCodec.parseNumber(text)
    if (v === undefined) return false
    let ok = true
    this.edit(L('Change %@', label), ctl.name, (c) => { ok = codec.setDisplay(v, c) })
    return ok
  }

  /** Stepper: one raw step in whichever direction raises (or lowers) the displayed value. */
  step(ctl: CatalogControl, direction: 1 | -1, label: string): boolean {
    const codec = ValueCodec.forControl(ctl)
    const raw = codec?.raw(this.config)
    const now = codec?.display(this.config)
    if (!codec || raw === undefined || now === undefined) return false
    const up = (codec.displayRaw(raw + 1, this.config) ?? now) > now
    const next = raw + (up === direction > 0 ? 1 : -1)
    const v = codec.displayRaw(next, this.config)
    if (v === undefined) return false
    const r = codec.range(this.config)
    if (r && (v < r.min - 1e-9 || v > r.max + 1e-9)) return false
    this.edit(L('Change %@', label), ctl.name, (c) => { codec.setRaw(next, c) })
    return true
  }

  /** Toggle switched to `on` (as displayed). */
  toggle(ctl: CatalogControl, on: boolean, label: string): void {
    const codec = ValueCodec.forControl(ctl)
    this.edit(L('Change %@', label), ctl.name, (c) => { codec?.setRaw(on !== isInverted(ctl) ? 1 : 0, c) })
  }

  setLocalToggle(ctl: CatalogControl, on: boolean, label: string): void {
    this.edit(L('Change %@', label), ctl.name, (c) => LocalControls.setChecked(ctl.name, on, c))
  }

  setLocalChoice(ctl: CatalogControl, index: number): void {
    this.edit(L('Change stop condition'), ctl.name, (c) => LocalControls.setVs2OffAction(index, c))
  }

  /** Plain choice (not the grid code): writes the item value. */
  choose(ctl: CatalogControl, value: number, label: string): void {
    const codec = ValueCodec.forControl(ctl)
    if (!codec) return
    this.edit(L('Change %@', label), ctl.name, (c) => { codec.setRaw(value, c) })
  }

  /** Grid code picked: the dialogs to run (`undefined` when nothing happens). */
  planGridCode(value: number): GridChoice | undefined {
    const ctl = catalog().controls.get('GridCodeComboBox')
    if (!ctl || value === this.config.raw(81) || Access.isLocked(ctl, this.ruleContext)) return undefined
    return GridPages.choose(value, this.ruleContext)
  }

  applyGridCode(n: number): void {
    this.edit(L('Change Grid Code'), 'GridCodeComboBox', (c) => GridPages.apply(n, c))
  }

  applyBatteryPreset(p: BatteryPreset): void {
    let note: Notice | undefined
    this.edit(L('Apply Battery Preset'), undefined, (c) => { note = BatteryPresets.apply(p, c) })
    if (note) this.notices.push(note)
    this.notify()
  }

  // MARK: Saving

  /** Whether saving is possible: something changed, the grid parameters are consistent, protected changes authorized. */
  get canSave(): boolean { return this.saveBlockReason === undefined }

  /** Why saving is not possible right now (undefined when it is). */
  get saveBlockReason(): string | undefined {
    if (this.changes.length === 0) return L('There are no changes to save.')
    return this.integrityProblem
  }

  /** Problems that make the current configuration unfit to be uploaded to an inverter. */
  get integrityProblem(): string | undefined {
    if (!GridPages.paramsValid(this.config))
      return L('The grid code parameters do not match the selected grid code or belong to another firmware version. Select the grid code again to load its defaults before saving.')
    const forbidden = Access.forbiddenChanges(this.ruleContext)
    if (forbidden.length)
      return L('Settings protected by the grid code password were changed: %@. Restore them before saving.',
        forbidden.slice(0, 4).map((r) => (r.kind === 'flag' ? Labels.flag(r.index) : Labels.settingIn(r.index, this.config))).join(', ') + (forbidden.length > 4 ? '…' : ''))
    return undefined
  }

  /** VE Configure drops the unlock tokens of a file once they are more than 7200 s old. */
  static readonly tokenLifetime = 7200n

  static dropStaleTokens(c: DeviceConfiguration, now: bigint): void {
    if (c.data.tokens.length === 0) return
    const age = now - c.data.tokenTime
    if (age < 0n || age > ConfigDocument.tokenLifetime) c.data.tokens = []
  }

  /** The bytes of the file to upload; the document then treats them as loaded. Throws with the reason when refused. */
  save(now: bigint = BigInt(Math.floor(Date.now() / 1000)), fileName?: string): Bytes {
    const problem = this.integrityProblem
    if (problem !== undefined) throw new SaveError(problem)
    const out = this.config.clone()
    ConfigDocument.dropStaleTokens(out, now)
    const auth = this.session.gridAuthorization
    if (auth) {
      if (out.data.version < 2) throw new SaveError(L('This file format cannot store grid authorization. Open a newer RVSC file.'))
      auth.authorizeSave(out, now)
    }
    const bytes = out.encoded()
    if (fileName !== undefined) this.fileName = fileName
    this.config = out
    this.baseline = out
    this.notify()
    return bytes
  }

  // MARK: Change list

  get changes(): Change[] {
    const out: Change[] = []
    const config = this.config, baseline = this.baseline
    const skip = new Set<number>([...names.flagWords, 81, ...range(128, 192)])
    for (let id = 0; id < config.data.values.length; id++) {
      if (config.raw(id) === baseline.raw(id) || skip.has(id)) continue
      const [b, a] = Labels.formatPair(baseline, config, id)
      out.push({ target: { t: 'setting', id }, label: Labels.settingIn(id, config), before: b, after: a })
    }
    out.push(...this.gridChanges)
    for (let n = 0; n < names.flags.length; n++) {
      if (config.flag(n) === baseline.flag(n)) continue
      out.push({ target: { t: 'flag', n }, label: Labels.flag(n), before: formatFlag(n, baseline.flag(n)), after: formatFlag(n, config.flag(n)) })
    }
    if (!equalBytes(config.data.assistantMemory, baseline.data.assistantMemory))
      out.push({ target: { t: 'assistants' }, label: L('Assistants'), before: '', after: L('Reprogrammed') })
    return out
  }

  /** Grid changes as the user made them: the grid code as one unit, else one entry per control, raw words for the rest. */
  private get gridChanges(): Change[] {
    const config = this.config, baseline = this.baseline
    if (config.raw(81) !== baseline.raw(81)) {
      const words = range(128, 192).filter((id) => config.raw(id) !== baseline.raw(id)).length
      return [{ target: { t: 'gridCode' }, label: Labels.settingIn(81, config), before: Labels.format(baseline, 81),
        after: Labels.format(config, 81) + (words > 0 ? ' ' + L('(with %d grid parameter words)', words) : '') }]
    }
    const changedIDs = range(128, 192).filter((id) => config.raw(id) !== baseline.raw(id))
    if (changedIDs.length === 0) return []
    const pages = new Set<string>([GridPages.selectionPage])
    const p = GridPages.page(config)
    if (p !== undefined) pages.add(p)
    if (GridPages.showsMicrogrid(config)) pages.add('MicroGridPage')
    const out: Change[] = []
    const rest = config.clone() // the controls listed put back: what still differs is explained by no control
    const seen = new Set<string>()
    for (const id of changedIDs) {
      for (const ctl of catalog().peerControlsBySetting.get(id) ?? []) {
        if (seen.has(ctl.name)) continue
        const page = catalog().pageOfControl.get(ctl.name)
        if (page === undefined || !(pages.has(page) || (page.startsWith('VDE') && pages.has('VDEGridCodePage')))) continue
        seen.add(ctl.name)
        const k = ValueCodec.forControl(ctl)
        if (!k || !k.isSupported(config)) continue
        const rb = k.raw(baseline), ra = k.raw(config)
        if (rb === undefined || ra === undefined || rb === ra || k.display(config) === undefined || k.display(baseline) === undefined) continue
        const [b, a] = Labels.formatPairCodec(k, baseline, config)
        out.push({ target: { t: 'control', name: ctl.name }, label: Validation.label(ctl), before: b, after: a })
        k.restoreRaw(rb, rest)
      }
    }
    for (const id of changedIDs) {
      if (rest.raw(id) === baseline.raw(id)) continue
      out.push({ target: { t: 'setting', id }, label: Labels.setting(id), before: Labels.format(baseline, id), after: Labels.format(config, id) })
    }
    return out
  }
}

export class SaveError extends Error {
  constructor(readonly reason: string) {
    super(reason)
    this.name = 'SaveError'
  }
}

const range = (a: number, b: number) => Array.from({ length: b - a }, (_, i) => a + i)

export function protectedMessage(refs: VariableRef[], c: DeviceConfiguration): string {
  const list = refs.slice(0, 4).map((r) => (r.kind === 'flag' ? Labels.flag(r.index) : Labels.settingIn(r.index, c))).join(', ') + (refs.length > 4 ? '…' : '')
  return L('Enter the grid code password before changing these settings: %@.', list)
}

/** Human names and value formatting, used wherever the catalog has no richer label. */
export const Labels = {
  setting(id: number): string {
    return catalog().label(id) ?? Labels.fallback(names.settings[id] ?? '')
  },

  /** Change-list label for a grid word, naming the controls that view it on the page in use. */
  settingIn(id: number, config: DeviceConfiguration): string {
    return labelInConfig(id, config) ?? Labels.setting(id)
  },

  flag(n: number): string {
    return catalog().labelFlag(n) ?? Labels.fallback(names.flags[n] ?? '')
  },

  fallback(name: string): string {
    let n = name
    if (n.startsWith('@')) n = n.slice(1)
    for (const p of ['eest', 'eecv', 'eevs', 'eefs', '_']) if (n.startsWith(p)) n = n.slice(p.length)
    return n
  },

  format(c: DeviceConfiguration, id: number): string {
    if (id === 81) {
      const g = c.raw(id)
      return g >= 0 && g < names.gridCodes.length ? gridCodeName(g) : `${g}`
    }
    if (id >= 128 && id <= 191) return '0x' + c.raw(id).toString(16).toUpperCase().padStart(4, '0')
    const codec = ValueCodec.forSetting(id)
    if (codec && codec.isSupported(c)) return codec.formatted(c)
    const info = c.info.info(id)
    if (!info || !info.isSupported) return `${c.raw(id)}`
    return Labels.number(info.display(c.raw(id)), info.step) + unitSuffix(id)
  },

  number(v: number, step: number, extraDecimals = 0): string {
    const decimals = (step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : 3) + extraDecimals
    return formatFixed(v, decimals, true)
  },

  /** Before/after texts for the change list, with as many extra decimals as it takes to tell them apart. */
  formatPair(b: DeviceConfiguration, c: DeviceConfiguration, id: number): [string, string] {
    const k = ValueCodec.forSetting(id)
    if (k && k.isSupported(c)) return Labels.formatPairCodec(k, b, c)
    const x = Labels.format(b, id), y = Labels.format(c, id)
    const info = c.info.info(id)
    if (x !== y || !info || !info.isSupported) return [x, y]
    for (let extra = 1; extra <= 6; extra++) {
      const p = Labels.number(info.display(b.raw(id)), info.step, extra) + unitSuffix(id)
      const q = Labels.number(info.display(c.raw(id)), info.step, extra) + unitSuffix(id)
      if (p !== q) return [p, q]
    }
    return [x, y]
  },

  formatPairCodec(k: ValueCodec, b: DeviceConfiguration, c: DeviceConfiguration): [string, string] {
    const x = k.formatted(b), y = k.formatted(c)
    const vb = k.display(b), vc = k.display(c)
    if (x !== y || vb === undefined || vc === undefined) return [x, y]
    for (let extra = 1; extra <= 6; extra++) {
      const p = k.format(vb, b, extra) + k.unitSuffix, q = k.format(vc, c, extra) + k.unitSuffix
      if (p !== q) return [p, q]
    }
    return [x, y]
  },
}

function unitSuffix(id: number): string {
  const u = displayUnit(catalog().unit(id))
  return u !== undefined ? ' ' + u : ''
}

/** Catalog.label(forSetting:in:): a grid word named after the controls that view it on the page in use. */
export function labelInConfig(id: number, config: DeviceConfiguration): string | undefined {
  const page = id >= 129 && id <= 190 ? GridPages.page(config) : undefined
  if (page === undefined) return catalog().label(id)
  const ns = (catalog().peerControlsBySetting.get(id) ?? []).filter((c) => catalog().pageOfControl.get(c.name) === page)
    .map((c) => changeListLabelOf(c)).filter((x): x is string => x !== undefined)
  if (ns.length === 0) return catalog().label(id)
  const list = ns.slice(0, 3).join(', ') + (ns.length > 3 ? '…' : '')
  return L('%@ (grid word %@)', list, id === 190 ? 'G' : `${id - 129}`)
}


// MARK: - Confirmations (VE Configure's safety dialogs, as data for the UI)

export interface Confirmation { title: string; message: string; continueTitle: string }

export const Confirmations = {
  /** LOM type set to "disabled" (raw & 3 == 2) outside Denmark (18/19, where it is required). */
  needsLOM(control: string, newRaw: number, config: DeviceConfiguration): boolean {
    if (!(control === 'LOMAC0SettingComboBox' || control === 'LOMAC1SettingComboBox') || (newRaw & 3) !== 2) return false
    const code = config.raw(81)
    return code !== 18 && code !== 19
  },

  lom(): Confirmation {
    return {
      title: L('Safety warning!'),
      message: L("Disabling the LOM detection mechanism can result in dangerous AC voltages to be present on the AC input terminals of the Multi for an extended period of time when the AC input is 'unplugged'. It might be advisable to install anti-islanding protection equipment in the AC input line of the Multi/Quattro system to make sure that the system is disconnected from the grid in case of a mains failure! Disabling the LOM detection can be useful in installations where a generator (or other weak AC source) is connected to the AC input, because some generators become unstable when LOM detection is enabled. Disabling the LOM detection for an AC input will cause the device not to be compliant to the selected grid code on that AC input!")
        + '\n\n' + L('Do you want to continue and disable the LOM detection?'),
      continueTitle: L('Disable LOM Detection'),
    }
  },

  microgrid(): Confirmation {
    return {
      title: L('Safety warning!'),
      message: L('Enabling microgrid operation will result in dangerous AC voltages to be present on the AC input terminals of the Multi! Use this option with care!'),
      continueTitle: L('Enable Microgrid'),
    }
  },

  /** charger.tbatStopToggle: checking "stop charging on battery temperature" asks first. */
  tbatStop(): Confirmation {
    return {
      title: L('Battery temperature'),
      message: L('This feature is intended to be used with lithium battery systems which do NOT feature an internal temperature disconnect.\n\nThis option uses the temperature as measured by the temperature sensor wired directly to the inverter/charger.\n\nVictron Lithium Smart batteries: no need to use this feature\nVictron SuperPack batteries, HQ2040 and later: no need to use this feature\nAny other lithium battery, Victron or non-Victron: check the documentation'),
      continueTitle: L('Enable'),
    }
  },

  /** Enabling the virtual switch removes every assistant (VE Configure 0x55da34). */
  virtualSwitch(assistantCount: number): Confirmation | undefined {
    if (assistantCount <= 0) return undefined
    return {
      title: L('Warning'),
      message: L('Enabling the virtual switch will disable the assistant functionality. All configured assistants will be removed! Continue?'),
      continueTitle: L('Remove Assistants'),
    }
  },

  /** Button titles of a grid-code choice dialog, in order (the first applies the proposal). */
  gridButtons(choice: GridChoice): string[] {
    switch (choice.t) {
      case 'accept': return []
      case 'reject': return [L('OK')]
      case 'propose': return [choice.button, ...(choice.keep !== undefined ? [L('Keep Option %d', choice.keep)] : []), L('Cancel')]
      case 'confirm': return [choice.button, L('Cancel')]
    }
  },
}
