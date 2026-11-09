// Page structure and row state: which sections and rows a page shows and how each row looks.
import type { DeviceConfiguration } from '../engine/deviceConfiguration'
import {
  catalog, cleanCaption, cleanDescription, cleanGridCode, displayUnit, fallbackText, itemDisplayText, itemMatches,
  nodeFrame, reflow, settingTargets, type CatalogControl, type CatalogGroup, type CatalogNode, type CatalogPage, type CatalogText,
} from './catalog'
import { Access, gridTable, type RuleContext } from './context'
import { parseExpr, numberOf } from './expr'
import { GridPages, Lighting, Visibility, type DiagramPart } from './editingRules'
import { L, catalogText, catalogTextOpt, stripMarkup } from './l10n'
import { ValueCodec } from './valueCodec'

const chars = (s: string) => [...s]
const trimWS = (s: string) => s.replace(/^[ \t ]+|[ \t ]+$/g, '')

// MARK: - Sections (sidebar)

/** The seven VE Configure tabs, in VE Configure's order. */
export const sections = ['general', 'grid', 'inverter', 'charger', 'virtualSwitch', 'assistants', 'advanced'] as const
export type Section = (typeof sections)[number]

export function sectionTitle(s: Section): string {
  switch (s) {
    case 'general': return L('General')
    case 'grid': return L('Grid')
    case 'inverter': return L('Inverter')
    case 'charger': return L('Charger')
    case 'virtualSwitch': return L('Virtual Switch')
    case 'assistants': return L('Assistants')
    case 'advanced': return L('Advanced')
  }
}

/** What each tab governs in the installation; the diagram lights these parts. */
export const sectionLit: Record<Section, DiagramPart[]> = {
  general: ['acIn', 'acIn2', 'transferSwitch', 'battery'],
  grid: ['acIn', 'feedIn', 'transferSwitch'],
  inverter: ['inverter', 'dcBus', 'acOut'],
  charger: ['charger', 'battery'],
  virtualSwitch: ['relay'],
  assistants: ['acIn', 'feedIn', 'battery', 'relay'],
  advanced: ['charger', 'acIn'],
}

// MARK: - Text helpers

/** A runtime caption as displayed, in the interface language. */
export function resolveText(t: CatalogText | undefined, ctx: RuleContext): string | undefined {
  return catalogTextOpt(resolveRawText(t, ctx))
}

/** Resolves a runtime caption (English): the first variant whose `when` holds, else the literal. */
export function resolveRawText(t: CatalogText | undefined, ctx: RuleContext): string | undefined {
  if (!t) return undefined
  if (t.variants && t.variants.length) {
    for (const v of t.variants) {
      if (v.when === undefined) continue
      if (v.when === 'otherwise' || v.when === 'always') continue
      if (ctx.evaluate(v.when) === true && v.text !== undefined) return cleanCaption(v.text)
    }
    const other = t.variants.find((v) => v.when === 'otherwise' || v.when === 'always')?.text
    if (other !== undefined) return cleanCaption(other)
  }
  const s = cleanCaption(fallbackText(t))
  return s === '' ? undefined : s
}

/** Victron writes some labels in lower case ("waiting time"); keep the wording, capitalise the first letter. */
export function capitalizedFirst(s: string): string {
  const c = chars(s)
  const f = c[0]
  if (f === undefined || !/^\p{Ll}$/u.test(f)) return s
  return f.toUpperCase() + c.slice(1).join('')
}

export { stripMarkup }

// MARK: - Page structure

/** A form section built from the catalog: a captioned group box, or a run of loose controls. */
export interface LayoutSection { id: string; title?: CatalogText; rows: LayoutRow[] }
export interface LayoutRow {
  control: CatalogControl
  /** Containers between the page and the control; their visibility and enable rules apply to it. */
  ancestors: CatalogGroup[]
}

/** grid.vde.reactiveType: the reactive-power type picker shows one sheet and in it one panel. */
export const ReactivePanels = {
  typeExpr: 'raw(ctl.ReactivePowerTypeSettingComboBox)',
  types: {
    VDECosPhiCurveTabSheet: [0, 1], VDEQCurveTabSheet: [2, 3],
    VDECosPhiFixedSettings: [0], VDECosPhiCurveSettings: [1], VDEQFixedSettings: [2], VDEQCurveSettings: [3],
  } as Record<string, number[]>,

  /** undefined when the group is not one of the reactive-power panels; false when the type is unknown. */
  isVisible(name: string, ctx: RuleContext): boolean | undefined {
    const set = ReactivePanels.types[name]
    if (!set) return undefined
    const e = parseExpr(ReactivePanels.typeExpr)
    const t = e ? numberOf(ctx.eval(e)) : undefined
    if (t === undefined) return false
    return set.includes(Math.trunc(t))
  },

  /** Section title: the picker's item text for the panel shown. */
  title(sheet: string): CatalogText | undefined {
    const set = ReactivePanels.types[sheet]
    const items = catalog().controls.get('ReactivePowerTypeSettingComboBox')?.items
    if (!set || !items) return undefined
    const variants = [...set].sort((a, b) => a - b).flatMap((v) => {
      const it = items.find((i) => i.value === v)
      return it ? [{ when: `${ReactivePanels.typeExpr} == ${v}`, text: fallbackText(it.text) }] : []
    })
    return { text: '', variants }
  },
}

/** Pages whose two Delphi columns read better column by column. */
const columnPages = new Set(['InverterSheet'])

function sortedTopLevel(nodes: CatalogNode[]): CatalogNode[] {
  const lefts = nodes.map((n) => nodeFrame(n)?.[0]).filter((x): x is number => x !== undefined)
  if (!lefts.some((x) => x < 150) || !lefts.some((x) => x >= 196)) return nodes
  return nodes.map((n, offset) => ({ n, offset })).sort((a, b) => {
    const ca = (nodeFrame(a.n)?.[0] ?? 0) >= 196 ? 1 : 0, cb = (nodeFrame(b.n)?.[0] ?? 0) >= 196 ? 1 : 0
    if (ca !== cb) return ca - cb
    const ta = nodeFrame(a.n)?.[1] ?? 0, tb = nodeFrame(b.n)?.[1] ?? 0
    return ta !== tb ? ta - tb : a.offset - b.offset
  }).map((x) => x.n)
}

export function isRow(c: CatalogControl): boolean {
  switch (c.kind) {
    case 'number': case 'toggle': case 'choice': case 'localToggle': case 'localChoice': return true
    case 'button': return ['BatteryTypeButton', 'HideInverterWarningButton'].includes(c.name)
    case 'canvas': return c.name === 'ChargeCurvePaintBox'
    case 'text': {
      const skip = ['LocationFor', 'Dummy', 'Helper', 'SizeLabel', 'BoxWidth', 'StaticText', 'HintLabel']
      if (skip.some((s) => c.name.includes(s)) || c.name === 'Label3') return false
      if (c.class === 'TMemo') return chars(c.text ?? '').length > 20
      if ((c.visibleWhen ?? []).length > 0 || c.name.toLowerCase().includes('warning')) return true
      const t = (c.label ? fallbackText(c.label) : undefined) ?? (c.caption ? fallbackText(c.caption) : undefined) ?? ''
      return chars(t).length > 60 && c.class !== 'TRelatedLabel'
    }
    default: return false
  }
}

const captionOf = (g: CatalogGroup) => (g.caption ? trimWS(fallbackText(g.caption)) : '')

class Builder {
  sections: LayoutSection[] = []
  current: LayoutSection = { id: 'loose-0', rows: [] }
  counter = 0

  flush(): void {
    if (this.current.rows.length) this.sections.push(this.current)
    this.counter++
    this.current = { id: `loose-${this.counter}`, rows: [] }
  }

  process(nodes: CatalogNode[], ancestors: CatalogGroup[]): void {
    // A checkbox drawn on an uncaptioned group box's border is that group's header (PowerAssist, AES…).
    const headers = new Map<string, CatalogControl>()
    const consumed = new Set<string>()
    for (const g of nodes) {
      if (g.type !== 'group' || g.kind !== 'groupBox') continue
      const gf = g.frame
      if (captionOf(g) !== '' || g.caption?.variants !== undefined || !gf || gf.length !== 4) continue
      for (const c of nodes) {
        if (c.type !== 'control' || !(c.kind === 'toggle' || c.kind === 'localToggle') || consumed.has(c.name)) continue
        const f = c.frame
        if (f && f.length === 4 && Math.abs(f[1]! - gf[1]!) <= 8 && f[0]! >= gf[0]! - 4 && f[0]! <= gf[0]! + gf[2]!) {
          headers.set(g.name, c)
          consumed.add(c.name)
          break
        }
      }
    }
    for (const node of nodes) {
      if (consumed.has(node.name)) continue
      switch (node.type) {
        case 'control':
          if (isRow(node)) this.current.rows.push({ control: node, ancestors })
          break
        case 'group': {
          const titled = node.kind === 'groupBox' && (captionOf(node) !== '' || node.caption?.variants !== undefined)
          const header = headers.get(node.name)
          if (titled || header) {
            this.flush()
            this.current = { id: node.name, title: titled ? node.caption : undefined, rows: [] }
            if (header) this.current.rows.push({ control: header, ancestors })
            this.process(node.children, [...ancestors, node])
            this.flush()
          } else {
            this.process(node.children, [...ancestors, node])
          }
          break
        }
        case 'pageControl':
          // A tab control inside a page (VDE reactive power): each sheet is a section, its visibility carried by an
          // ancestor named after the sheet (see ReactivePanels).
          for (const sheet of node.pages) {
            this.flush()
            this.current = { id: sheet.name, title: ReactivePanels.title(sheet.name), rows: [] }
            const anchor: CatalogGroup = { type: 'group', kind: 'panel', name: sheet.name, children: [] }
            this.process(sheet.children, [...ancestors, anchor])
            this.flush()
          }
          break
        default:
          break
      }
    }
  }
}

const layoutCache = new WeakMap<CatalogPage, LayoutSection[]>()

export const PageLayout = {
  sections(page: CatalogPage): LayoutSection[] {
    const hit = layoutCache.get(page)
    if (hit) return hit
    const b = new Builder()
    b.process(columnPages.has(page.name) ? sortedTopLevel(page.children) : page.children, [])
    b.flush()
    const result = b.sections.filter((s) => s.rows.length > 0)
    layoutCache.set(page, result)
    return result
  },
  isRow,
}

// MARK: - Sub-pages of a section

export interface PageEntry { id: string; title: string; page: CatalogPage }

export const SectionPages = {
  sheet: {
    general: 'GeneralSheet', grid: 'GridSheet', inverter: 'InverterSheet', charger: 'ChargerSheet',
    virtualSwitch: 'VirtualSwitchsheet', assistants: 'DDCSheet', advanced: 'AdvancedSheet',
  } as Record<Section, string>,

  entries(section: Section, ctx: RuleContext): PageEntry[] {
    const cat = catalog()
    const page = cat.pages.get(SectionPages.sheet[section])
    if (!page) return []
    if (section === 'grid') {
      const out: PageEntry[] = []
      const sel = cat.pages.get(GridPages.selectionPage)
      if (sel) out.push({ id: sel.name, title: L('Grid Code'), page: sel })
      const n = GridPages.page(ctx.config)
      const p = n !== undefined ? cat.pages.get(n) : undefined
      if (n !== undefined && p) out.push({ id: n, title: GridPages.title(n, ctx.config, resolveRawText(p.caption, ctx) ?? n), page: p })
      const mg = cat.pages.get('MicroGridPage')
      if (GridPages.showsMicrogrid(ctx.config) && mg) out.push({ id: mg.name, title: L('Microgrid'), page: mg })
      return out
    }
    if (section === 'virtualSwitch') {
      let pages: CatalogPage[] = []
      for (const c of page.children) if (c.type === 'pageControl') pages = c.pages
      const short: Record<string, string> = {
        VirtualSwitchUsageSheet: L('Usage'), VirtualSwitchOnSheet: L('A: Set VS On'),
        VirtualSwitchOffSheet: L('B: Set VS Off'), VirtualSwitchOptionsSheet: L('Options'),
      }
      return pages.filter((p) => Visibility.isPageVisible(p.name, ctx) && SectionPages.hasVisibleRows(p, ctx))
        .map((p) => ({ id: p.name, title: short[p.name] ?? resolveText(p.caption, ctx) ?? p.name, page: p }))
    }
    return [{ id: page.name, title: sectionTitle(section), page }]
  },

  hasVisibleRows(page: CatalogPage, ctx: RuleContext): boolean {
    return PageLayout.sections(page).some((s) => s.rows.some((r) => SectionPages.isVisible(r, ctx) && r.control.kind !== 'text'))
  },

  isVisible(row: LayoutRow, ctx: RuleContext): boolean {
    return row.ancestors.every((g) => Visibility.isGroupVisible(g, ctx)) && Visibility.isVisible(row.control, ctx)
  },

  /** Enable rules that cannot be evaluated offline disable the control (fail closed). */
  isEnabled(row: LayoutRow, page: string, ctx: RuleContext): boolean {
    return row.ancestors.every((g) => ctx.all(g.enabledWhen, false)) && ctx.all(row.control.enabledWhen, false)
      && Visibility.extraEnabled(row.control, catalog().pageOfControl.get(row.control.name) === 'ChargerSheet' ? 'ChargerSheet' : page, ctx)
  },
}

export interface VisibleSection { section: LayoutSection; rows: LayoutRow[]; lit: Set<DiagramPart> }

/** The sections shown on a page for this context. */
export function visibleSections(page: CatalogPage, ctx: RuleContext): VisibleSection[] {
  const out: VisibleSection[] = []
  for (const s of PageLayout.sections(page)) {
    const rows = s.rows.filter((r) => SectionPages.isVisible(r, ctx))
    // A section of notes only (all its settings hidden) is dropped, like VE Configure's empty group boxes.
    if (!(rows.some((r) => r.control.kind !== 'text') || rows.some((r) => (r.control.visibleWhen ?? []).length > 0))) continue
    out.push({ section: s, rows, lit: Lighting.parts(rows.map((r) => r.control), page.name, ctx.config) })
  }
  return out
}

// MARK: - Row state

/** Everything a row needs to decide how it looks right now. */
export class RowState {
  /** False on pages that already carry the password banner. */
  showsLock = true
  /** False when the whole section requires a reset (said once in the section footer instead). */
  showsResetMark = true

  constructor(readonly control: CatalogControl, readonly ctx: RuleContext, readonly enabled: boolean, readonly page: string | undefined) {}

  get codec(): ValueCodec | undefined { return ValueCodec.forControl(this.control) }
  get config(): DeviceConfiguration { return this.ctx.config }
  get label(): string { return capitalizedFirst(this.rawLabel) }

  private get rawLabel(): string {
    const c = this.control
    if (c.name === 'StopChargeBelowTBatSettingEdit') return L('Battery temperature limit')
    const l = resolveRawText(c.label ?? c.caption, this.ctx)
    if (l !== undefined && chars(l).length > 3 && l !== 'for') return catalogText(l)
    if (l === 'for') { const d = cleanDescription(c); return d !== undefined ? L('Delay — %@', d) : L('Delay') }
    return cleanDescription(c) ?? catalogTextOpt(c.help?.title) ?? (l !== undefined ? catalogText(l) : undefined) ?? c.name
  }

  get locked(): boolean { return Access.isLocked(this.control, this.ctx) }
  get resetRequired(): boolean { return Access.requiresReset(this.control, this.config) }

  get changed(): boolean {
    const v = this.control.variable
    if (v?.kind === 'flag' && v.index !== undefined) return this.config.flag(v.index) !== this.ctx.baseline.flag(v.index)
    return settingTargets(this.control).some((id) => this.config.raw(id) !== this.ctx.baseline.raw(id))
  }

  get unit(): string | undefined { return displayUnit(this.control.unit) }

  /** Range, default and step line for the tooltip and the info popover. */
  get rangeDetail(): string | undefined {
    const k = this.codec
    const r = k && this.control.kind === 'number' ? k.range(this.config) : undefined
    if (!k || !r) return undefined
    const u = this.unit !== undefined ? ' ' + this.unit : ''
    const parts = [L('Range %@ – %@', k.format(r.min, this.config), k.format(r.max, this.config) + u)]
    if (r.defaultValue !== undefined) parts.push(L('default %@', k.format(r.defaultValue, this.config) + u))
    if (r.step > 0) parts.push(L('step %@', k.format(r.step, this.config)))
    return parts.join(', ')
  }

  get helpText(): string | undefined {
    const t = this.control.help?.text
    return t !== undefined ? catalogText(reflow(t)) : undefined
  }

  get tooltip(): string {
    const parts: string[] = []
    const d = cleanDescription(this.control)
    if (d !== undefined && d !== this.label) parts.push(d)
    const r = this.rangeDetail
    if (r !== undefined) parts.push(r)
    const h = this.helpText
    if (h !== undefined) {
      const c = chars(h)
      parts.push(c.slice(0, 400).join('') + (c.length > 400 ? '…' : ''))
    }
    return parts.join('\n\n')
  }

  /** Editable right now: enabled, not locked, and the codec can write. */
  get editable(): boolean { return this.enabled && !this.locked && this.codec?.isEditable !== false }
}

export function rowStates(page: CatalogPage, section: Section, ctx: RuleContext): { section: VisibleSection; rows: RowState[]; resetCount: number; allReset: boolean }[] {
  return visibleSections(page, ctx).map((v) => {
    const settings = v.rows.filter((r) => r.control.kind !== 'text' && r.control.kind !== 'button')
    const resetCount = settings.filter((r) => Access.requiresReset(r.control, ctx.config)).length
    const allReset = resetCount > 0 && resetCount === settings.length
    const rows = v.rows.map((r) => {
      const s = new RowState(r.control, ctx, SectionPages.isEnabled(r, page.name, ctx), page.name)
      s.showsLock = section !== 'grid'
      s.showsResetMark = !allReset
      return s
    })
    return { section: v, rows, resetCount, allReset }
  })
}

// MARK: - Choice options

export interface ChoiceOption { value: number; title: string; enabled: boolean }

/** The items the picker offers for this row. */
export function choiceOptions(row: RowState): ChoiceOption[] {
  const c = row.config
  const current = row.codec?.raw(c)
  const lith = catalog().variables.get('EBIT_LithiumBattery')
  const lithium = lith ? c.flag(lith.index) : false
  const out: ChoiceOption[] = []
  for (const item of row.control.items ?? []) {
    const value = item.value
    if (value === undefined) continue
    const selected = current !== undefined ? itemMatches(item, current) : false
    if (!selected) {
      if (item.hidden === true || item.plusMarked === true) continue
      if (row.control.name === 'ChargeCharacteristicComboBox' && lithium && value === 3) continue
    }
    let title = itemDisplayText(item, row.ctx)
    let enabled = true
    if (row.control.name === 'GridCodeComboBox') {
      title = cleanGridCode(title)
      enabled = gridTable(c)?.entries.get(value) !== undefined
    }
    if (row.control.name === 'VirtualSwitchActionSelectRadioGroup') {
      const u = catalog().vsUsage.get(value)
      if (u) {
        const ref = catalog().variables.get('EBIT_vsInvert')
        const inverted = ref ? c.flag(ref.index) : false
        title = (inverted ? u.labelInverted : undefined) ?? u.label
      }
    }
    out.push({ value, title: catalogText(cleanCaption(title)), enabled })
  }
  return out
}

/** The item value the picker shows as selected. */
export function choiceSelection(row: RowState): number {
  const raw = row.codec?.raw(row.config) ?? -1
  return (row.control.items ?? []).find((i) => itemMatches(i, raw))?.value ?? raw
}

/** Note text for a text row. */
export function noteText(row: RowState): string {
  return stripMarkup(resolveRawText(row.control.label ?? row.control.caption, row.ctx) ?? row.control.text ?? '')
}
