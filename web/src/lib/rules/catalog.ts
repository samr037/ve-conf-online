// Data-driven description of VE Configure's UI (tabs → pages → groups → controls), from catalog.json
// `buildCatalog(json)` is pure; `useCatalog()` makes it current.
import * as names from '../engine/settingNames'
import { L, catalogText, catalogTextOpt, setCleanCaption } from './l10n'
import type { RuleContext } from './context'
import { writtenControls } from './valueCodec'

export type VariableKind = 'setting' | 'flag' | 'ram' | 'peer'

export interface VariableRef { kind: VariableKind; index: number; name: string }

export interface TextVariant { when?: string; text?: string }

/** A caption that is either a literal or set at runtime (`variants` chosen by a `when` expression). */
export interface CatalogText { text?: string; variants?: TextVariant[]; dfmText?: string }

/** Text without evaluating variants: the literal, else the first non-empty variant. */
export function fallbackText(t: CatalogText): string {
  if (t.text) return t.text
  return t.variants?.find((v) => (v.text ?? '') !== '')?.text ?? ''
}

export interface HelpTopic { id?: number; title?: string; text?: string }

export type ControlKind =
  | 'number' | 'toggle' | 'choice' | 'readout' | 'button' | 'text' | 'localToggle' | 'localChoice' | 'localText'
  | 'canvas' | 'list' | 'progress' | 'link' | 'unknown'

export interface Variable { kind: VariableKind; index?: number; name?: string }
export interface Peer { control: string; mask: number; shift: number; width: number; variable?: Variable }
export interface Codec {
  scale: number; offset: number; signBit?: number; reciprocal?: boolean; offsetBeforeInvert?: boolean
  min?: number; max?: number; default?: number; precision?: number
}
export interface PeerSpec { peers: Peer[]; codec: Codec; custom?: boolean }
export interface Item {
  text: CatalogText; value?: number; values?: number[]; hidden?: boolean; plusMarked?: boolean; runtimeText?: TextVariant[]
}
export interface Semantics { precision?: number; inverted?: boolean; linkedControl?: string; relevantComponents?: string[] }
export interface Label { text?: CatalogText; position?: string }

export interface CatalogControl {
  type: 'control'
  kind: ControlKind
  name: string
  class?: string
  tag?: number
  frame?: number[]
  caption?: CatalogText
  label?: CatalogText
  labels?: Label[]
  description?: string
  unit?: string
  help?: HelpTopic
  text?: string
  variable?: Variable
  peer?: PeerSpec
  items?: Item[]
  semantics?: Semantics
  events?: Record<string, { handler: string }>
  enabledWhen?: string[]
  visibleWhen?: string[]
  rules?: string[]
  visibleAtDesign?: boolean
}

export type GroupKind = 'groupBox' | 'panel' | 'scroll' | 'frame'
export interface CatalogGroup {
  type: 'group'
  kind: GroupKind
  name: string
  caption?: CatalogText
  tag?: number
  frame?: number[]
  visibleAtDesign?: boolean
  enabledWhen?: string[]
  visibleWhen?: string[]
  children: CatalogNode[]
}
export interface CatalogPage { type: 'page'; name: string; caption?: CatalogText; help?: HelpTopic; children: CatalogNode[] }
export interface CatalogPageControl { type: 'pageControl'; name: string; pages: CatalogPage[] }
export type CatalogNode = CatalogPage | CatalogPageControl | CatalogGroup | CatalogControl

export const nodeFrame = (n: CatalogNode): number[] | undefined => (n.type === 'group' || n.type === 'control' ? n.frame : undefined)

export interface CatalogRule { id: string; kind: string; targets: string[]; expr?: string; message?: string; notes?: string }
export interface PeerHandlerInfo { read?: string; write?: string; uncertain?: boolean }
export interface VSUsage { label: string; labelInverted?: string }
export interface BatteryPresetValue { value: number; unit?: string; normalisedTo12V?: boolean }
export interface BatteryPreset {
  id: string
  name: string
  values: Record<string, BatteryPresetValue>
  notSet?: string[]
  flags?: { clearsTubularPlate?: boolean; requiresVEBusBMSSupport?: boolean }
}

// MARK: - Decoding (mirrors the Swift Decodable rules: optional fields of the wrong type are dropped)

type J = any

const str = (v: J): string | undefined => (typeof v === 'string' ? v : undefined)
const int = (v: J): number | undefined => (typeof v === 'number' && Number.isInteger(v) ? v : undefined)
const num = (v: J): number | undefined => (typeof v === 'number' ? v : undefined)
const bool = (v: J): boolean | undefined => (typeof v === 'boolean' ? v : undefined)
const strArr = (v: J): string[] | undefined => (Array.isArray(v) && v.every((x) => typeof x === 'string') ? v : undefined)
const intArr = (v: J): number[] | undefined => (Array.isArray(v) && v.every((x) => Number.isInteger(x)) ? v : undefined)
const numArr = (v: J): number[] | undefined => (Array.isArray(v) && v.every((x) => typeof x === 'number') ? v : undefined)

function variant(v: J): TextVariant | undefined {
  if (!v || typeof v !== 'object') return undefined
  return { when: str(v.when), text: str(v.text) }
}

function text(v: J): CatalogText | undefined {
  if (typeof v === 'string') return { text: v }
  if (!v || typeof v !== 'object') return undefined
  const t: CatalogText = { text: str(v.text), dfmText: str(v.dfmText) }
  if (Array.isArray(v.variants)) {
    const vs = v.variants.map(variant)
    if (vs.every((x: TextVariant | undefined) => x)) t.variants = vs
  }
  return t
}

function help(v: J): HelpTopic | undefined {
  if (!v || typeof v !== 'object') return undefined
  return { id: int(v.id), title: str(v.title), text: str(v.text) }
}

const variableKinds = new Set(['setting', 'flag', 'ram', 'peer'])
function variable(v: J): Variable | undefined {
  if (!v || typeof v !== 'object' || !variableKinds.has(v.kind)) return undefined
  return { kind: v.kind, index: int(v.index), name: str(v.name) }
}

function peerSpec(v: J): PeerSpec | undefined {
  if (!v || typeof v !== 'object' || !Array.isArray(v.peers) || !v.codec || typeof v.codec !== 'object') return undefined
  const peers: Peer[] = []
  for (const p of v.peers) {
    if (typeof p?.control !== 'string' || int(p.mask) === undefined || int(p.shift) === undefined || int(p.width) === undefined) return undefined
    const pv = p.variable == null ? undefined : variable(p.variable)
    if (p.variable != null && !pv) return undefined
    peers.push({ control: p.control, mask: p.mask, shift: p.shift, width: p.width, variable: pv })
  }
  const k = v.codec
  if (num(k.scale) === undefined || num(k.offset) === undefined) return undefined
  return {
    peers,
    codec: {
      scale: k.scale, offset: k.offset, signBit: int(k.signBit), reciprocal: bool(k.reciprocal), offsetBeforeInvert: bool(k.offsetBeforeInvert),
      min: num(k.min), max: num(k.max), default: num(k.default), precision: int(k.precision),
    },
    custom: bool(v.custom),
  }
}

function items(v: J): Item[] | undefined {
  if (!Array.isArray(v)) return undefined
  const out: Item[] = []
  for (const it of v) {
    const t = text(it?.text)
    if (!t) return undefined
    let rt: TextVariant[] | undefined
    if (it.runtimeText != null) {
      if (!Array.isArray(it.runtimeText)) return undefined
      rt = it.runtimeText.map(variant)
    }
    out.push({ text: t, value: int(it.value), values: intArr(it.values), hidden: bool(it.hidden), plusMarked: bool(it.plusMarked), runtimeText: rt })
  }
  return out
}

const controlKinds = new Set<ControlKind>([
  'number', 'toggle', 'choice', 'readout', 'button', 'text', 'localToggle', 'localChoice', 'localText', 'canvas', 'list', 'progress', 'link',
])

function control(v: J): CatalogControl {
  const sem = v.semantics && typeof v.semantics === 'object'
    ? { precision: int(v.semantics.precision), inverted: bool(v.semantics.inverted), linkedControl: str(v.semantics.linkedControl),
        relevantComponents: strArr(v.semantics.relevantComponents) }
    : undefined
  let events: Record<string, { handler: string }> | undefined
  if (v.events && typeof v.events === 'object') {
    events = {}
    for (const [k, e] of Object.entries<J>(v.events)) {
      if (typeof e?.handler !== 'string') { events = undefined; break }
      events[k] = { handler: e.handler }
    }
  }
  let labels: Label[] | undefined
  if (Array.isArray(v.labels)) labels = v.labels.map((l: J) => ({ text: text(l?.text), position: str(l?.position) }))
  return {
    type: 'control',
    kind: controlKinds.has(v.kind) ? v.kind : 'unknown',
    name: v.name,
    class: str(v.class),
    tag: int(v.tag),
    frame: numArr(v.frame),
    caption: text(v.caption),
    label: text(v.label),
    labels,
    description: str(v.description),
    unit: str(v.unit),
    help: help(v.help),
    text: str(v.text),
    variable: variable(v.variable),
    peer: peerSpec(v.peer),
    items: items(v.items),
    semantics: sem,
    events,
    enabledWhen: strArr(v.enabledWhen),
    visibleWhen: strArr(v.visibleWhen),
    rules: strArr(v.rules),
    visibleAtDesign: bool(v.visibleAtDesign),
  }
}

function page(v: J): CatalogPage {
  return { type: 'page', name: v.name, caption: v.caption == null ? undefined : text(v.caption), help: v.help == null ? undefined : help(v.help),
    children: (v.children as J[]).map(node) }
}

function node(v: J): CatalogNode {
  switch (v.type) {
    case 'page': return page(v)
    case 'pageControl': return { type: 'pageControl', name: v.name, pages: (v.pages as J[]).map(page) }
    case 'group':
      return {
        type: 'group', kind: v.kind, name: v.name, caption: v.caption == null ? undefined : text(v.caption), tag: int(v.tag),
        frame: numArr(v.frame), visibleAtDesign: bool(v.visibleAtDesign), enabledWhen: strArr(v.enabledWhen), visibleWhen: strArr(v.visibleWhen),
        children: (v.children as J[]).map(node),
      }
    default: return control(v)
  }
}

// MARK: - Grid page choice

/** `gridCodePages` entry: "AS4777GridCodePage|variant!=0:NewAS4777GridCodePage". */
export class GridPageChoice {
  base: string
  alternatives: { op: string; value: number; page: string }[] = []

  constructor(spec: string) {
    const parts = spec.split('|').filter((p) => p !== '')
    this.base = parts[0] ?? spec
    for (const alt of parts.slice(1)) {
      const colon = alt.indexOf(':')
      if (colon < 0) continue
      const cond = alt.slice(0, colon).replaceAll('variant', '')
      const pg = alt.slice(colon + 1)
      for (const op of ['>=', '<=', '!=', '==', '>', '<']) {
        if (!cond.startsWith(op)) continue
        const rest = cond.slice(op.length)
        if (/^[+-]?\d+$/.test(rest)) { this.alternatives.push({ op, value: Number(rest), page: pg }); break }
      }
    }
  }

  page(variant: number): string {
    for (const a of this.alternatives) {
      const hit = a.op === '>=' ? variant >= a.value : a.op === '<=' ? variant <= a.value : a.op === '!=' ? variant !== a.value
        : a.op === '==' ? variant === a.value : a.op === '>' ? variant > a.value : variant < a.value
      if (hit) return a.page
    }
    return this.base
  }
}

// MARK: - Catalog

export class Catalog {
  tabs: CatalogNode[]
  gridCodePages = new Map<number, GridPageChoice>()
  vsUsage = new Map<number, VSUsage>()
  batteryPresets: BatteryPreset[]
  rules: CatalogRule[]
  peerHandlers: Record<string, PeerHandlerInfo>
  rulesByID = new Map<string, CatalogRule>()

  controls = new Map<string, CatalogControl>()
  groups = new Map<string, CatalogGroup>()
  variables = new Map<string, VariableRef>()
  settingControls = new Map<number, CatalogControl>()
  flagControls = new Map<number, CatalogControl>()
  peerControlsBySetting = new Map<number, CatalogControl[]>()
  pageOfControl = new Map<string, string>()
  pages = new Map<string, CatalogPage>()

  constructor(json: J) {
    this.tabs = (json.tabs as J[]).map(node)
    for (const [k, v] of Object.entries<J>(json.gridCodePages ?? {})) {
      if (/^[+-]?\d+$/.test(k) && typeof v === 'string') this.gridCodePages.set(Number(k), new GridPageChoice(v))
    }
    for (const [k, v] of Object.entries<J>(json.vsUsage ?? {})) {
      if (/^[+-]?\d+$/.test(k)) this.vsUsage.set(Number(k), { label: v.label, labelInverted: str(v.labelInverted) })
    }
    this.batteryPresets = (json.batteryPresets as J[]).map((p) => ({
      id: p.id, name: p.name,
      values: Object.fromEntries(Object.entries<J>(p.values).map(([k, x]) => [k, { value: x.value, unit: str(x.unit), normalisedTo12V: bool(x.normalisedTo12V) }])),
      notSet: strArr(p.notSet),
      flags: p.flags ? { clearsTubularPlate: bool(p.flags.clearsTubularPlate), requiresVEBusBMSSupport: bool(p.flags.requiresVEBusBMSSupport) } : undefined,
    }))
    this.rules = (json.rules as J[]).map((r) => ({ id: r.id, kind: r.kind, targets: r.targets, expr: str(r.expr), message: str(r.message), notes: str(r.notes) }))
    for (const r of this.rules) if (!this.rulesByID.has(r.id)) this.rulesByID.set(r.id, r)
    this.peerHandlers = json.peerHandlers ?? {}
    for (const t of this.tabs) this.index(t, undefined)
  }

  private index(n: CatalogNode, pageName: string | undefined): void {
    switch (n.type) {
      case 'page':
        this.pages.set(n.name, n)
        for (const c of n.children) this.index(c, n.name)
        break
      case 'pageControl':
        for (const p of n.pages) this.index(p, p.name)
        break
      case 'group':
        this.groups.set(n.name, n)
        for (const c of n.children) this.index(c, pageName)
        break
      case 'control': {
        this.controls.set(n.name, n)
        if (pageName !== undefined) this.pageOfControl.set(n.name, pageName)
        const v = n.variable
        if (v?.name !== undefined && v.index !== undefined) this.variables.set(v.name, { kind: v.kind, index: v.index, name: v.name })
        if (v?.index !== undefined) {
          if (v.kind === 'setting' && !this.settingControls.has(v.index)) this.settingControls.set(v.index, n)
          if (v.kind === 'flag' && !this.flagControls.has(v.index)) this.flagControls.set(v.index, n)
        }
        for (const p of n.peer?.peers ?? []) {
          const pv = p.variable
          if (pv?.name !== undefined && pv.index !== undefined) this.variables.set(pv.name, { kind: pv.kind, index: pv.index, name: pv.name })
          if (pv?.index !== undefined) {
            const list = this.peerControlsBySetting.get(pv.index) ?? []
            list.push(n)
            this.peerControlsBySetting.set(pv.index, list)
          }
        }
      }
    }
  }

  label(forSetting: number): string | undefined {
    const c = this.settingControls.get(forSetting)
    if (c) return changeListLabel(c)
    const id = forSetting
    if (id >= 129 && id <= 190) return L('Grid code parameter word %@', id === 190 ? L('general') : `${id - 129}`)
    if (id === 128 || id === 191) return L('Grid parameter checker %@', id === 128 ? 'A' : 'B')
    return undefined
  }

  labelFlag(n: number): string | undefined {
    const c = this.flagControls.get(n)
    return c ? changeListLabel(c) : undefined
  }

  unit(forSetting: number): string | undefined { return this.settingControls.get(forSetting)?.unit }

  gridCodeName(index: number): string | undefined {
    const item = this.controls.get('GridCodeComboBox')?.items?.find((i) => i.value === index)
    return item ? catalogText(cleanGridCode(fallbackText(item.text))) : undefined
  }

  /** Rule expressions of one kind whose target list names this node exactly. */
  conditions(name: string, kind: string, parses: (e: string) => boolean): string[] | undefined {
    const exprs = this.rules.filter((r) => r.kind === kind && r.targets.includes(name)).map((r) => r.expr).filter((e): e is string => e !== undefined && parses(e))
    return exprs.length ? exprs : undefined
  }
}

let current: Catalog | undefined

export function useCatalog(c: Catalog): void { current = c }
export function catalog(): Catalog {
  if (!current) throw new Error('No catalog loaded: call useCatalog(buildCatalog(json)) first')
  return current
}
export const buildCatalog = (json: J) => new Catalog(json)

/** Fetches and installs the catalog (browser). */
export async function loadCatalog(url: string): Promise<Catalog> {
  const res = await fetch(url)
  const c = buildCatalog(await res.json())
  useCatalog(c)
  return c
}

// MARK: - Control helpers

export const handler = (c: CatalogControl, event: string) => c.events?.[event]?.handler
export const isInverted = (c: CatalogControl) => c.semantics?.inverted === true

const chars = (s: string) => [...s]
const trimWS = (s: string) => s.replace(/^[\s ]+|[\s ]+$/g, '')

/** Removes Delphi accelerators and caption padding. */
export function cleanCaption(s: string): string {
  let t = s.replaceAll('&&', '\u0001').replaceAll('&', '').replaceAll('\u0001', '&')
  t = t.replaceAll('\r', ' ').replaceAll('\n', ' ')
  while (t.includes('  ')) t = t.replaceAll('  ', ' ')
  t = trimWS(t)
  if (t.endsWith(':')) t = t.slice(0, -1)
  return trimWS(t)
}
setCleanCaption(cleanCaption)

/** CHM help text reflowed: hard wraps joined, short lines (lists, headings) kept. */
export function reflow(s: string): string {
  const lines = s.replaceAll('\r', '').split('\n')
  let out = ''
  lines.forEach((line, i) => {
    const l = trimWS(line)
    if (i === 0) { out = l; return }
    const prev = trimWS(lines[i - 1]!)
    if (l === '') { out += '\n\n'; return }
    const last = prev.slice(-1)
    const breakLine = prev === '' || (chars(prev).length < 28 && ((last !== '' && '.:!?'.includes(last)) || /^\p{Lu}/u.test(l)))
    out += breakLine ? '\n' + l : ' ' + l
  })
  while (out.includes('\n\n\n')) out = out.replaceAll('\n\n\n', '\n\n')
  return out
}

/** "09_France:                UTE C15-712-1:2013-07" → "France — UTE C15-712-1:2013-07". */
export function cleanGridCode(s: string): string {
  let t = s
  const c = chars(t)
  if (c.length > 3 && c[2] === '_' && /^[+-]?\d+$/.test(c.slice(0, 2).join(''))) t = c.slice(3).join('')
  t = cleanCaption(t)
  const i = t.indexOf(':')
  if (i < 0) return t
  const name = trimWS(t.slice(0, i))
  const rest = trimWS(t.slice(i + 1))
  return rest === '' ? name : `${name} — ${rest}`
}

/** Units as shown next to values: "Hr", "seconds" and "deg C" in their short forms, translated. */
export function displayUnit(unit: string | undefined): string | undefined {
  if (unit === undefined) return undefined
  let u = trimWS(unit)
  if (u === '') return undefined
  if (u === 'Hr') u = 'h'
  else if (u === 'seconds' || u === 'sec' || u === 'Seconds') u = 's'
  else if (u === 'deg C' || u === 'degC') u = '°C'
  return catalogText(u)
}

/** Label text without runtime context. */
export function staticLabel(c: CatalogControl): string | undefined {
  const t = c.label ?? c.caption
  if (!t) return undefined
  const s = cleanCaption(fallbackText(t))
  return s === '' ? undefined : s
}

/** LongSettingDescription, without Delphi format placeholders, in the interface language. */
export function cleanDescription(c: CatalogControl): string | undefined {
  let d = c.description
  if (d === undefined || d === '') return undefined
  if (d.startsWith('|')) return undefined
  const bar = d.indexOf('|')
  if (bar >= 0) d = d.slice(0, bar)
  d = d.replaceAll('%s', '').replaceAll('%0:s', '').replaceAll('%1:s', '')
  d = d.replace(/^[ \t]+|[ \t]+$/g, '')
  if (d === '') return undefined
  const cs = chars(d)
  return catalogText(cleanCaption(cs[0]!.toUpperCase() + cs.slice(1).join('')))
}

/** Label used in the change list: the visible label unless it is only a fragment ("for"). */
export function changeListLabel(c: CatalogControl): string | undefined {
  const l = staticLabel(c)
  if (l !== undefined && chars(l).length > 4 && !l.endsWith(' for')) return catalogText(l)
  return cleanDescription(c) ?? catalogTextOpt(l ?? c.help?.title)
}

/** Settings this control writes (direct variable, grid words, or for a local control the settings it sets). */
export function settingTargets(c: CatalogControl): number[] {
  if (c.variable?.kind === 'setting' && c.variable.index !== undefined) return [c.variable.index]
  if (c.kind === 'localToggle' || c.kind === 'localChoice') return writtenControls(c.name).flatMap(settingTargets)
  return (c.peer?.peers ?? []).map((p) => p.variable?.index).filter((i): i is number => i !== undefined)
}

export function itemMatches(item: Item, raw: number): boolean {
  return (item.values ?? [item.value ?? -1]).includes(raw)
}

export function itemDisplayText(item: Item, context: RuleContext | undefined): string {
  const rt = item.runtimeText
  if (rt && rt.length) {
    if (context) {
      const v = rt.find((x) => (x.when !== undefined ? context.evaluate(x.when) === true : false))
      if (v && v.text !== undefined) return v.text
    }
    if (rt[0]!.text !== undefined) return rt[0]!.text
  }
  return fallbackText(item.text)
}

/** The value of a flag as the user reads it on the control (inverted checkboxes, 50/60 Hz radios…). */
export function formatFlag(n: number, on: boolean): string {
  const c = catalog().flagControls.get(n)
  if (!c) return on ? L('On') : L('Off')
  if (c.kind === 'choice' && c.items) {
    const item = c.items.find((i) => itemMatches(i, on ? 1 : 0))
    if (item) return catalogText(cleanCaption(itemDisplayText(item, undefined)))
  }
  const checked = isInverted(c) ? !on : on
  return checked ? L('On') : L('Off')
}

export const settingNames = names
