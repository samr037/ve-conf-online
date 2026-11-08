// The assistants programmed in one configuration: reconstruction, editing and re-programming
// (port of Sources/VEConfigure/AssistantsModel.swift and the WizardModel of WizardView.swift).
import type { AssistantLibrary, AssistantPackage } from '../lib/engine/assistantPackage'
import { equalBytes, type Bytes } from '../lib/engine/binary'
import type { DeviceConfiguration } from '../lib/engine/deviceConfiguration'
import {
  AssistantComposer, AssistantError, MetaGenerator, WizardStepContent, WizardText, cloneTables, composerItem, fieldDisplay, fieldParse,
  type AnswerTable, type AssemblerMessage, type AssistantBuildResult, type AssistantStepPresentation, type AssistantWizard,
  type ComposerItem, type Value, type WizardLine,
} from '../lib/engine/assembler'
import { BatteryPresets, L, catalog, currentLocale, type ConfigDocument, type Notice } from '../lib/rules'

export interface Installed {
  /** Position in the composer. */
  id: number
  package: AssistantPackage
  title: string
  summary: { label: string; value: string }[]
}

export type AssistantsStatus = { k: 'noLibrary' } | { k: 'ready' } | { k: 'failed'; why: string }

const clean = (m: AssemblerMessage): string => {
  let t = m.text
  if (t.startsWith("'") && t.endsWith("'") && t.length >= 2) t = t.slice(1, -1).replaceAll("''", "'")
  return t
}
const firstError = (ms: AssemblerMessage[]) => ms.find((m) => m.kind === 'error' || m.kind === 'fatal')

/** Battery preset index (`BatteryType_VEC`: 1-based in MetaGenerator.batteryPresets, 0 = none) the settings match. */
export function batteryType(c: DeviceConfiguration): number {
  const p = BatteryPresets.matching(c)
  const i = p ? MetaGenerator.batteryPresets.indexOf(p.id) : -1
  return i >= 0 ? i + 1 : 0
}

/** META for the configuration as it is now. */
export const metaFor = (c: DeviceConfiguration): Bytes => MetaGenerator.metaSource(c, true, batteryType(c))

function menuInfo(p: AssistantPackage, languages: string[]): string[] {
  const script = p.script(languages)
  return script ? new WizardText(script.bytes).lines('MenuInfo') ?? [] : []
}

export const hasMenuInfo = (p: AssistantPackage) => [...p.scripts.values()].some((s) => (new WizardText(s.bytes).lines('MenuInfo') ?? []).length > 0)

export function assistantTitle(p: AssistantPackage, languages: string[]): string {
  const menu = menuInfo(p, languages)
  if (menu.length >= 2) return WizardStepContent.plain(menu[1]!)
  if (menu[0] !== undefined) return WizardStepContent.plain(menu[0].split('->').at(-1) ?? menu[0])
  return p.baseName
}

export function assistantBlurb(p: AssistantPackage, languages: string[]): string {
  return menuInfo(p, languages).slice(2).map((l) => WizardStepContent.plain(l)).join(' ')
}

/** Victron lays summaries out with tabs: one cell per line, "-" cells become bullets. */
export function tidy(s: string): string {
  const cells: string[] = []
  for (const raw of s.split('\n')) for (const cell of raw.split('\t')) {
    const c = cell.split(' ').filter((x) => x.length > 0).join(' ')
    if (c.length) cells.push(c)
  }
  const out: string[] = []
  let bulletNext = false
  for (let c of cells) {
    if (c === '-' || c === '•') { bulletNext = true; continue }
    const parts = c.split(' - ')
    if (parts.length > 1) {
      const head = parts[0]!
      if (head.length) out.push(head.startsWith('- ') ? '• ' + head.slice(2) : head)
      out.push(...parts.slice(1).map((x) => '• ' + x))
      bulletNext = false
      continue
    }
    if (c.startsWith('- ')) c = '• ' + c.slice(2)
    if (bulletNext) { c = '• ' + c; bulletNext = false }
    const last = out.at(-1)
    if (last !== undefined && (c.startsWith('=') || last.endsWith('='))) out[out.length - 1] = last + ' ' + c
    else out.push(c)
  }
  return out.join('\n')
}

const lineText = (l: WizardLine[]) => l[0]?.runs.map((r) => r.text).join('') ?? ''

export function answerText(p: AssistantStepPresentation, content: WizardStepContent): string {
  switch (p.step.kind) {
    case 'R': {
      const v = p.values[0] ?? 0
      const o = content.options[v]
      return o ? lineText(o) : String(v)
    }
    case 'C': {
      const mask = BigInt(p.values[0] ?? 0)
      const on = content.options.filter((_, i) => i < 63 && ((mask >> BigInt(i)) & 1n) === 1n).map(lineText)
      return on.length === 0 ? L('None') : on.join(', ')
    }
    case 'E':
      return content.entry.map((pieces) => pieces.map((piece) => {
        if (piece.k === 'text') return piece.runs.map((r) => r.text).join('')
        const i = piece.index
        const f = p.step.fields[i]
        const v = p.values[i]
        if (f === undefined || v === undefined) return '?'
        if (piece.items) return piece.items[v - f.min] ?? String(v)
        return fieldDisplay(f, v, currentLocale())
      }).join('')).join('\n').trim()
  }
}

type Snapshot = [ComposerItem[], Map<string, AnswerTable>]

export class AssistantsModel {
  status: AssistantsStatus = { k: 'noLibrary' }
  installed: Installed[] = []
  codeSize = 0
  /** Message to show once (assembler messages, removal notes, failures). */
  message: string | undefined
  /** Called after every change of the fields above. */
  onChange: (() => void) | undefined

  private composer: AssistantComposer | undefined
  private lastImage: Bytes = new Uint8Array()
  private stepCounts = new Map<string, number>()
  private wizardOpen = false
  private reloadDeferred = false

  constructor(private readonly document: ConfigDocument, private library: AssistantLibrary | undefined, public languages: string[]) {
    this.reload()
  }

  get memorySize(): number { return this.document.config.data.assistantMemory.length || AssistantComposer.memorySize }
  /** Bytes the code may use: the area minus the ID directory (framework + assistants) and the checksum. */
  get capacity(): number { return this.memorySize - 4 - 2 * (this.installed.length + 2) }
  get hasLibrary(): boolean { return this.library !== undefined }

  setLibrary(lib: AssistantLibrary | undefined): void {
    this.library = lib
    this.reload()
  }

  /** Call after the document changed: reloads when the program changed underneath (undo, redo, another file). */
  documentChanged(): void {
    if (!equalBytes(this.document.config.data.assistantMemory, this.lastImage)) this.reload()
  }

  private notify(): void { this.onChange?.() }

  reload(): void {
    if (this.wizardOpen) { this.reloadDeferred = true; return }
    const config = this.document.config
    this.lastImage = config.data.assistantMemory
    this.composer = undefined
    this.installed = []
    this.codeSize = 0
    const lib = this.library
    if (!lib) { this.status = { k: 'noLibrary' }; this.notify(); return }
    if (config.data.assistantMemory.length !== AssistantComposer.memorySize) {
      this.status = { k: 'failed', why: new AssistantError({ kind: 'badMemorySize', size: config.data.assistantMemory.length }).message }
      this.notify()
      return
    }
    try {
      const c = new AssistantComposer(lib)
      c.languages = this.languages
      c.meta = metaFor(config)
      const r = c.reconstruct(config.data.assistantMemory)
      if (!r.success) {
        this.status = { k: 'failed', why: firstError(r.messages)?.text ?? L('The assistant program could not be read back.') }
        this.notify()
        return
      }
      if (c.items.length) {
        const b = c.build()
        if (!b.success) {
          const e = firstError(b.messages)
          this.status = { k: 'failed', why: e ? clean(e) : L('The assistants could not be assembled.') }
          this.notify()
          return
        }
        this.codeSize = b.code.length
        this.installed = this.describe(c, b.steps)
      }
      this.composer = c
      this.status = { k: 'ready' }
    } catch (e) {
      this.status = { k: 'failed', why: e instanceof Error ? e.message : String(e) }
    }
    this.notify()
  }

  /** Assistants available to add (framework excluded), with their menu titles. */
  get available(): { package: AssistantPackage; title: string; blurb: string }[] {
    const lib = this.library
    if (!lib) return []
    return lib.latest.filter((p) => !['asfStart', 'asfStop'].includes(p.baseName) && hasMenuInfo(p))
      .map((p) => ({ package: p, title: assistantTitle(p, this.languages), blurb: assistantBlurb(p, this.languages) }))
      .sort((a, b) => a.title.localeCompare(b.title, undefined, { sensitivity: 'base' }))
  }

  private describe(c: AssistantComposer, steps: AssistantStepPresentation[]): Installed[] {
    this.stepCounts = new Map()
    for (const s of steps) this.stepCounts.set(s.assistant, (this.stepCounts.get(s.assistant) ?? 0) + 1)
    return c.items.map((item, i) => {
      const script = item.package.script(this.languages)
      const text = script ? new WizardText(script.bytes) : undefined
      const summary: Installed['summary'] = []
      for (const p of steps) {
        if (p.assistant !== item.name || !p.step.inSummary) continue
        const content = new WizardStepContent(p.step, text, p.format, currentLocale())
        summary.push({ label: content.title, value: tidy(answerText(p, content)) })
      }
      return { id: i, package: item.package, title: assistantTitle(item.package, this.languages), summary }
    })
  }

  /** Report blocks for the settings export. */
  reportBlocks(): { title: string; rows: [string, string][] }[] {
    return this.installed.map((a) => ({ title: `${L('Assistants')} › ${a.title}`, rows: a.summary.map((s) => [s.label, s.value] as [string, string]) }))
  }

  // MARK: Editing

  /**
   * Starts the wizard of an installed assistant, or of a new one appended to the list. Undefined when nothing to
   * show: nothing to configure, or the wizard already ended (its result is then applied).
   */
  wizard(index: number | undefined, adding?: AssistantPackage): WizardSession | undefined {
    const c = this.composer
    if (!c || this.wizardOpen) return undefined
    c.meta = metaFor(this.document.config)
    const snapshot: Snapshot = [[...c.items], cloneTables(c.answers)]
    const restore = () => { c.items = snapshot[0]; c.answers = snapshot[1] }
    if (adding) {
      if (c.items.some((i) => i.name === adding.baseName)) {
        this.message = L('%@ is already installed. Use Configure to change it.', assistantTitle(adding, this.languages))
        this.notify()
        return undefined
      }
      c.items.push(composerItem(adding))
    }
    let name: string
    if (adding) name = adding.baseName
    else if (index !== undefined && c.items[index]) name = c.items[index]!.name
    else return undefined
    const title = adding ? assistantTitle(adding, this.languages) : this.installed.find((x) => x.id === index)?.title ?? name
    this.wizardOpen = true
    const session = new WizardSession(c, name, title, this.languages, adding ? undefined : this.stepCounts.get(name), (result) => {
      this.wizardOpen = false
      const deferred = this.reloadDeferred
      this.reloadDeferred = false
      if (!result) { restore(); if (deferred) this.reload(); this.notify(); return }
      if (deferred || this.composer !== c) {
        restore()
        this.message = L('The configuration changed while the assistant was open. Its answers were not applied.')
        this.reload()
        return
      }
      this.program(c, adding ? L('Add %@', title) : L('Configure %@', title), result.vecChanges, restore)
    })
    return session.finished ? undefined : session
  }

  remove(index: number): void {
    const c = this.composer
    if (!c || this.wizardOpen || !c.items[index]) return
    const snapshot: Snapshot = [[...c.items], cloneTables(c.answers)]
    const name = this.installed.find((x) => x.id === index)?.title ?? c.items[index]!.name
    const [item] = c.items.splice(index, 1)
    c.answers.delete(item!.name)
    const left = this.managedSettingLabels(item!.package)
    if (!this.program(c, L('Remove %@', name), new Map(), () => { c.items = snapshot[0]; c.answers = snapshot[1] })) return
    if (left.length) {
      const before = this.message
      this.message = L('%@ was removed. The settings it managed keep the values it gave them: %@. Check them on their pages.', name, left.join(', '))
        + (before ? '\n\n' + before : '')
      this.notify()
    }
  }

  /** Removes every assistant (enabling the virtual switch requires it). */
  removeAll(): void {
    const c = this.composer
    if (!c || this.wizardOpen || c.items.length === 0) return
    const snapshot: Snapshot = [[...c.items], cloneTables(c.answers)]
    const left = [...new Set(c.items.flatMap((i) => this.managedSettingLabels(i.package)))]
    c.items = []
    c.answers = new Map()
    if (!this.program(c, L('Remove All Assistants'), new Map(), () => { c.items = snapshot[0]; c.answers = snapshot[1] })) return
    if (left.length) {
      this.message = L('The assistants were removed. The settings they managed keep the values they gave them: %@. Check them on their pages.', left.join(', '))
      this.notify()
    }
  }

  move(index: number, delta: number): void {
    const c = this.composer
    if (!c || this.wizardOpen || !c.items[index] || !c.items[index + delta]) return
    const snapshot: Snapshot = [[...c.items], cloneTables(c.answers)]
    const a = c.items[index]!
    c.items[index] = c.items[index + delta]!
    c.items[index + delta] = a
    this.program(c, L('Reorder Assistants'), new Map(), () => { c.items = snapshot[0]; c.answers = snapshot[1] })
  }

  private managedSettingLabels(p: AssistantPackage): string[] {
    const targets = MetaGenerator.vecTargets(this.document.config)
    const out: string[] = []
    for (const name of AssistantComposer.managedSettings(p)) {
      const t = targets.get(name)
      if (!t) continue
      out.push((t.k === 'setting' ? catalog().label(t.id) : catalog().labelFlag(t.n)) ?? name.slice(0, -4))
    }
    return out
  }

  /** Re-assembles everything and writes the program (battery preset, settings, then the image) into the document. */
  private program(c: AssistantComposer, actionName: string, wizardChanges: Map<string, Value>, rollback: () => void): boolean {
    const doc = this.document
    c.meta = metaFor(doc.config)
    const r = c.build()
    if (!r.success) {
      rollback()
      const e = firstError(r.messages)
      this.message = e ? clean(e) : L('The assistants could not be assembled.')
      this.notify()
      return false
    }
    let preset: Notice | undefined
    let applied: { config: DeviceConfiguration; batteryType: number | undefined }
    try {
      applied = c.apply(r, doc.config, wizardChanges, (index, cfg) => {
        const id = MetaGenerator.batteryPresets[index - 1]
        const p = catalog().batteryPresets.find((x) => x.id === id)
        if (p) preset = BatteryPresets.apply(p, cfg)
      })
    } catch (e) {
      rollback()
      this.message = e instanceof AssistantError && e.detail.kind === 'imageTooLarge'
        ? L('Not enough assistant memory: %@ bytes needed, %@ available.', String(e.detail.needed), String(e.detail.size))
        : e instanceof Error ? e.message : String(e)
      this.notify()
      return false
    }
    this.lastImage = applied.config.data.assistantMemory
    this.codeSize = c.items.length ? r.code.length : 0
    this.installed = this.describe(c, r.steps)
    doc.replace(applied.config, actionName)
    const notes: string[] = []
    if (preset) notes.push(L('The assistant selected a battery type.') + ' ' + preset.title + '\n' + preset.message)
    else if (applied.batteryType !== undefined && applied.batteryType > 0)
      notes.push(L('The assistant selected battery preset %@. Check the Charger page.', String(applied.batteryType)))
    notes.push(...r.messages.filter((m) => m.kind === 'message').map(clean))
    if (notes.length && this.message === undefined) this.message = notes.join('\n\n')
    this.notify()
    return true
  }
}

/** Drives one assistant wizard: the assembly pauses at each step and resumes with the answer. */
export class WizardSession {
  readonly wizard: AssistantWizard
  step: AssistantStepPresentation | undefined
  content: WizardStepContent | undefined
  values: number[] = []
  texts: string[] = []
  error: string | undefined
  stepNumber = 0
  finished = false
  private done = false

  constructor(
    private readonly composer: AssistantComposer,
    assistant: string,
    readonly title: string,
    private readonly languages: string[],
    /** Steps seen in the last full build of this assistant (unknown for a new one). */
    readonly expectedSteps: number | undefined,
    private readonly completion: (r: AssistantBuildResult | undefined) => void,
  ) {
    this.wizard = composer.wizard(assistant)
    this.refresh(true)
  }

  get progress(): string {
    const n = Math.max(this.stepNumber, 1)
    if (this.expectedSteps !== undefined && n <= this.expectedSteps) return L('Step %@ of %@', String(n), String(this.expectedSteps))
    return L('Step %@', String(n))
  }

  private refresh(forward: boolean): void {
    const s = this.wizard.status
    switch (s.k) {
      case 'step': {
        const p = s.step
        this.step = p
        const pkg = this.composer.package(p.assistant)
        const script = pkg?.script(this.languages)
        this.content = new WizardStepContent(p.step, script ? new WizardText(script.bytes) : undefined, p.format, currentLocale())
        this.values = [...p.values]
        this.texts = p.step.fields.map((f, i) => fieldDisplay(f, p.values[i] ?? f.defaultValue, currentLocale()))
        this.stepNumber += forward ? 1 : -1
        this.error = undefined
        break
      }
      case 'finished': this.finish(s.result); break
      case 'failed': {
        const e = firstError(s.messages)
        this.error = e ? clean(e) : L('The assistant stopped with an error.')
        break
      }
      case 'cancelled': this.finish(undefined); break
    }
  }

  private finish(r: AssistantBuildResult | undefined): void {
    if (this.done) return
    this.done = true
    this.finished = true
    this.completion(r)
  }

  get canGoBack(): boolean {
    const s = this.step
    return !this.done && this.wizard.isWaiting && !!s && this.stepNumber > 1 && (s.buttons === 'normal' || s.buttons === 'previousOnly')
  }

  get canGoForward(): boolean {
    const s = this.step
    return !this.done && this.wizard.isWaiting && !!s && (s.buttons === 'normal' || s.buttons === 'nextOnly')
  }

  /** Returns false (with `error` set) when a typed value does not parse. */
  next(): boolean {
    const s = this.step
    if (this.done || !this.wizard.isWaiting || !s) return false
    const v = [...this.values]
    if (s.step.kind === 'E') {
      for (let i = 0; i < s.step.fields.length; i++) {
        const f = s.step.fields[i]!
        if (i >= this.texts.length || f.precision.k === 'list') continue
        const parsed = fieldParse(f, this.texts[i]!)
        if (parsed === undefined) { this.error = L('“%@” is not a valid value.', this.texts[i]!); return false }
        v[i] = parsed
      }
    }
    this.wizard.next(v)
    this.refresh(true)
    return true
  }

  previous(): void {
    if (!this.canGoBack) return
    this.wizard.previous()
    this.refresh(false)
  }

  cancel(): void {
    if (this.done) return
    this.wizard.cancel()
    this.finish(undefined)
  }
}
