// Assistant extension of the assembler (port of Sources/VEKit/Assembler/AssistantAssembler.swift): wizard steps (.AID), answers (.AUE/.ALS), readback-defined labels (.ALD),
// messages and stepback.
import { latin1Decode, type Bytes } from '../binary'
import { Assembler, type Frame, type Handler } from './assembler'
import { Label, evaluationOk, type ReadBackResult } from './calculator'
import type { SourceLine } from './sourceLine'
import {
  AssemblerState, keepsAnswers, newAnswer, newAnswerTable,
  type AnswerTable, type AssemblyGen, type AssistantAnswer, type AssistantDecision, type AssistantStepDefinition,
  type AssistantStepPresentation, type Pending, type StepButtons, type StepField,
} from './types'
import { asText, optionalValueEquals, valueEquals, vBool, vInt, vList, vStr, vString, type Value } from './value'
import { WizardText, trimWhitespace } from './wizardText'

const INT32_MAX = 2147483647

/** Swift `Int64(_:radix:)`: one optional sign, then at least one digit; undefined outside Int64. */
function swiftInt64(s: string, radix: 10 | 16): bigint | undefined {
  const m = radix === 16 ? /^([+-]?)([0-9a-fA-F]+)$/.exec(s) : /^([+-]?)([0-9]+)$/.exec(s)
  if (!m) return undefined
  let v = BigInt((radix === 16 ? '0x' : '') + m[2])
  if (m[1] === '-') v = -v
  if (v > 0x7fffffffffffffffn || v < -0x8000000000000000n) return undefined
  return v
}

/** `Character.wholeNumberValue` for the Latin-1 range: ASCII digits and ¹²³. */
function wholeNumberValue(c: string): number | undefined {
  if (c >= '0' && c <= '9') return c.charCodeAt(0) - 0x30
  if (c === '¹') return 1
  if (c === '²') return 2
  if (c === '³') return 3
  return undefined
}

export interface WizardTexts { localized: WizardText | undefined; english: WizardText | undefined }

export class AssistantAssembler extends Assembler {
  /** Per-assistant answers, keyed by assistant name; kept between builds. */
  tables = new Map<string, AnswerTable>()
  states = new Map<string, AssemblerState>()
  texts = new Map<string, WizardTexts>()
  /** Reference binary for RBn (reconstruction or pass-3 verification). */
  referenceBinary: Bytes | undefined
  /** Steps are yielded to the caller when set; otherwise they are answered with the values shown. */
  interactive = false

  currentAssistant: string | undefined
  /** Every step bound in pass 1 (in order), with its final values: the source of the assistant summary. */
  stepLog: AssistantStepPresentation[] = []
  private readBackUsed = false
  private usedBeforeDefinition = new Set<string>()

  get state(): AssemblerState {
    return (this.currentAssistant !== undefined ? this.states.get(this.currentAssistant) : undefined) ?? AssemblerState.build
  }

  // MARK: Passes

  /** Wizard driver state; survives restarts (stepback) and is mirrored into the `$Assistant…` labels. */
  displayStep = 0
  backStepList: Value[] = []
  cancelled = false

  override reset(firstPass: boolean): void {
    // Read back what the sources may have changed (AUEStepBack, RemoveFromStepBack) before clearing.
    const d = this.global.get('$AssistantDisplayStep')?.value
    if (d?.t === 'int') this.displayStep = d.v
    const l = this.global.get('$AssistantBackStepList')?.value
    if (l?.t === 'list') this.backStepList = [...l.v]
    const c = this.global.get('$AssistantCancelled')?.value
    if (c?.t === 'bool') this.cancelled = c.v
    const keep = firstPass ? undefined : this.snapshotAssistantLabels()
    super.reset(firstPass)
    if (firstPass) {
      this.global.set('$AssistantStep', new Label(vInt(0), 2))
      this.global.set('$AutoNext', new Label(vBool(false), 2))
      this.global.set('$ForceDefaultOnAutoNext', new Label(vBool(false), 2))
      for (const name of [...this.tables.keys()]) {
        const s = this.states.get(name)
        if (!(s === undefined ? true : keepsAnswers(s))) this.tables.set(name, newAnswerTable())
      }
      for (const t of this.tables.values()) { t.steps = new Map(); t.order = [] }
    } else if (keep) {
      for (const [k, v] of keep) this.global.set(k, v)
    }
    this.global.set('$AssistantCancelled', new Label(vBool(this.cancelled), 1))
    this.global.set('$AssistantDisplayStep', new Label(vInt(this.displayStep), 6))
    this.global.set('$AssistantBackStepList', new Label(vList(this.backStepList), 6))
    this.global.set('$AUEHandled', new Label(vBool(false), 1))
    this.global.set('$HandledAUEStep', new Label(vString(new Uint8Array()), 1))
    this.global.set('$AssemblerState', new Label(vInt(0), 1))
    this.global.set('$AssemblerPass', new Label(vInt(0), 1))
  }

  /** Syncs the driver state from the labels after an assembly run. */
  captureDriverState(): void {
    const d = this.global.get('$AssistantDisplayStep')?.value
    if (d?.t === 'int') this.displayStep = d.v
    const l = this.global.get('$AssistantBackStepList')?.value
    if (l?.t === 'list') this.backStepList = [...l.v]
    const c = this.global.get('$AssistantCancelled')?.value
    if (c?.t === 'bool') this.cancelled = c.v
  }

  private snapshotAssistantLabels(): Map<string, Label> {
    const out = new Map<string, Label>()
    for (const k of ['$AssistantStep', '$AutoNext', '$ForceDefaultOnAutoNext']) {
      const l = this.global.get(k)
      if (l) out.set(k, l)
    }
    return out
  }

  override willStartPass(pass: number): void {
    const p = this.global.get('$AssemblerPass')
    if (p) p.value = vInt(pass)
    if (pass === 1) {
      const s = this.global.get('$AssistantStep')
      if (s) s.value = vInt(0)
      this.stepLog = []
    }
  }

  override willEnterSource(name: string): void {
    this.currentAssistant = name
    this.usedBeforeDefinition = new Set()
    if (!this.tables.has(name)) this.tables.set(name, newAnswerTable())
    const s = this.global.get('$AssemblerState')
    if (s) s.value = vInt(this.state)
  }

  override didLeaveSource(_name: string): void {
    this.currentAssistant = undefined
    const s = this.global.get('$AssemblerState')
    if (s) s.value = vInt(0)
  }

  // MARK: Calculator host

  override lookup(name: string): Label | undefined {
    const l = super.lookup(name)
    if (!l && !this.frameLabels?.has(name)) this.usedBeforeDefinition.add(name)
    return l
  }

  override readBack(bytes: number, address: number): ReadBackResult {
    const ref = this.referenceBinary
    if (!ref) return { ok: true, value: -1 }
    const a = address
    if (!(a >= 0 && a + bytes <= ref.length)) return { ok: false, error: 'Readback index out of bounds' }
    let v = 0
    for (let k = 0; k < bytes; k++) v = (v | (ref[a + k]! << (8 * k))) >>> 0
    return { ok: true, value: v | 0 }
  }

  override noteReadBackUsed(): void { this.readBackUsed = true }

  override assistantText(key: Value): Bytes | undefined {
    const a = this.currentAssistant
    const t = a !== undefined ? this.texts.get(a) : undefined
    if (!t) return undefined
    const raw = t.localized?.assistantText(key) ?? t.english?.assistantText(key)
    return raw === undefined ? undefined : WizardText.unescape(raw)
  }

  override assistantLabelValue(name: string): number | undefined {
    const a = this.currentAssistant
    if (a === undefined) return undefined
    return this.tables.get(a)?.answers.get(name)?.value
  }

  // MARK: Directives

  override directive(op: string): Handler | undefined {
    switch (op) {
      case '.aid': return (l) => this.aid(l)
      case '.aue': return (l) => this.aue(l, 'normal')
      case '.aer': return (l) => this.aue(l, this.state === AssemblerState.translatorBuild ? 'nextOnly' : 'cancelOnly')
      case '.aip': return (l) => this.aue(l, this.state === AssemblerState.translatorBuild ? 'nextOnly' : 'previousOnly')
      case '.ain': return (l) => this.aue(l, 'nextOnly')
      case '.ald': return (l) => this.ald(l)
      case '.als': return (l) => this.als(l)
      case '.amessg': return (l) => {
        const p = l.params[0]
        if (!p) return
        const v = this.evaluate(p)
        this.report(v ? latin1Decode(asText(v)) : '', 'message')
      }
      case '.aerror': return (l) => {
        const p = l.params[0]
        if (!p) return
        const v = this.evaluate(p, false)
        const text = v ? latin1Decode(asText(v)) : latin1Decode(p)
        this.report(`Assistant: ${this.currentAssistant ?? ''} generated the following error: ${text}`, 'fatal', true)
      }
      case '.restart': return () => this.report(AssistantAssembler.restartMessage, 'fatal', true)
      default: return super.directive(op)
    }
  }

  private intLabel(name: string): number {
    const v = this.global.get(name)?.value
    return v?.t === 'int' ? v.v : 0
  }

  private setGlobal(name: string, v: Value): void {
    const l = this.global.get(name)
    if (l) l.value = v
  }

  static readonly restartMessage = 'Assembly must be restarted for stepback'

  /** Errors of assistant pseudo-ops are fatal. */
  private fatal(text: string): void { this.report(text, 'fatal', true) }

  private get table(): AnswerTable { return this.tables.get(this.currentAssistant ?? '') ?? newAnswerTable() }
  private set table(t: AnswerTable) { this.tables.set(this.currentAssistant ?? '', t) }

  /** Delphi `Val`: decimal, `$hex`, `0x` hex, optional sign. */
  static delphiVal(s: string): number | undefined {
    let t = trimWhitespace(s)
    let neg = false
    if (t.startsWith('-')) { neg = true; t = t.slice(1) } else if (t.startsWith('+')) t = t.slice(1)
    let v: bigint | undefined
    if (t.startsWith('$')) v = swiftInt64(t.slice(1), 16)
    else if (t.toLowerCase().startsWith('0x')) v = swiftInt64(t.slice(2), 16)
    else v = swiftInt64(t, 10)
    if (v === undefined) return undefined
    return Number(BigInt.asIntN(32, neg ? -v : v))
  }

  private aid(line: SourceLine): void {
    if (this.pass !== 1) return
    if (line.label.length === 0 || !AssistantAssembler.isLegalName(line.label)) { this.fatal('illegal label name'); return }
    if (line.params.length < 2) { this.fatal('too few parameters'); return }
    const id = line.label
    if (this.table.steps.has(id)) { this.fatal('This assistant ID is already in use!'); return }
    const stepName = latin1Decode(line.params[0]!)
    const typeValue = this.evaluate(line.params[1]!, false) ?? vStr(latin1Decode(line.params[1]!))
    const typeBytes = typeValue.t === 'string' ? typeValue.v : undefined
    const kindChar = typeBytes && typeBytes.length > 0 ? String.fromCharCode(typeBytes[0]!).toUpperCase() : ''
    if (!typeBytes || !(kindChar === 'E' || kindChar === 'R' || kindChar === 'C')
      || !(typeBytes.length <= 2) || !(typeBytes.length === 1 || (typeBytes[1]! | 0x20) === 0x6c)) {
      this.fatal('Type must be {E|R|C}[L]'); return
    }
    const kind = kindChar as 'E' | 'R' | 'C'
    const inSummary = typeBytes.length === 2
    const values: Value[] = []
    for (const p of line.params.slice(2)) {
      const v = this.evaluate(p, false)
      if (!v) { this.fatal('The value of assistant entry info must be calculatable the 1st pass!'); return }
      values.push(v)
    }
    let fields: StepField[] = []
    let buttons = 0
    if (kind === 'E') {
      for (const v of values) {
        if (v.t !== 'string') { this.fatal('Error in parameter'); return }
        if (v.v.length === 0) { this.fatal('The parameter is an empty string'); return }
        const s = latin1Decode(v.v)
        const parts = s.split(' ').filter((x) => x.length > 0)
        const mn = parts.length === 4 ? AssistantAssembler.delphiVal(parts[1]!) : undefined
        const mx = parts.length === 4 ? AssistantAssembler.delphiVal(parts[2]!) : undefined
        const df = parts.length === 4 ? AssistantAssembler.delphiVal(parts[3]!) : undefined
        if (parts.length !== 4 || parts[0]!.length !== 2 || mn === undefined || mx === undefined || df === undefined) {
          this.fatal(`Error in: ${s}`); return
        }
        const p = parts[0]![0]!, k = parts[0]![1]!
        let precision: StepField['precision']
        if (p === 'L' || p === 'l') precision = { k: 'list' }
        else if (p === 'T' || p === 't') precision = { k: 'time' }
        else {
          const d = wholeNumberValue(p)
          if (d === undefined) { this.fatal(`Error in: ${s}`); return }
          precision = { k: 'decimals', d }
        }
        if (!(mn <= df && df <= mx)) { this.fatal(`Error in: ${s} default value not within limits.`); return }
        fields.push({ precision, unitCode: k, min: mn, max: mx, defaultValue: df })
      }
    } else {
      const n0 = values[0], d0 = values[1]
      if (n0?.t !== 'int') { this.fatal('Nr of buttons missing!'); return }
      if (d0?.t !== 'int') { this.fatal('Default value missing!'); return }
      const n = n0.v, d = d0.v
      if (kind === 'C' && n > 32) { this.fatal('Number of CheckBox buttons greater than 32.'); return }
      const max = kind === 'R' ? (n - 1) | 0 : n >= 32 ? INT32_MAX : n >= 0 ? 2 ** n - 1 : -1
      if (!(d >= 0 && d <= max)) { this.fatal('illegal default value'); return }
      buttons = n
      fields = [{ precision: { k: 'decimals', d: 0 }, unitCode: 'N', min: 0, max, defaultValue: d }]
    }
    const t = this.table
    t.steps.set(id, { id, stepName, kind, inSummary, fields, buttons })
    t.order.push(id)
    this.table = t
  }

  private *aue(line: SourceLine, buttons: StepButtons): AssemblyGen {
    if (this.pass !== 1) return
    this.setGlobal('$AUEHandled', vBool(false))
    this.setGlobal('$HandledAUEStep', vString(new Uint8Array()))
    const idBytes = line.params[0]
    if (!idBytes) { this.fatal('too few parameters'); return }
    const id = latin1Decode(idBytes)
    const step = this.table.steps.get(id)
    if (!step) { this.fatal('Unknown assistant ID'); return }
    const n = step.fields.length
    if (!(line.params.length === n + 1 || line.params.length === n + 2)) {
      this.fatal('The nr of labels does not match with the defintion in the assistant ID'); return
    }
    let format: Value[] = []
    if (line.params.length === n + 2) {
      const v = this.evaluate(line.params[n + 1]!, false)
      if (!v) { this.fatal('The value of assistant entry info must be calculatable the 1st pass!'); return }
      if (v.t !== 'list' || !v.v.every((e) => e.t === 'int' || e.t === 'string')) {
        this.fatal('Assistant entry info must be a List containing format parameters'); return
      }
      format = [...v.v]
    }
    const t = this.table
    const labels: string[] = []
    const prevs: number[] = [], before: number[] = []
    const isTrue = (name: string) => optionalValueEquals(this.global.get(name)?.value, vBool(true))
    const autoNext = isTrue('$AutoNext')
    const forceDefault = isTrue('$ForceDefaultOnAutoNext')
    for (let k = 0; k < step.fields.length; k++) {
      const field = step.fields[k]!
      const name = latin1Decode(line.params[k + 1]!)
      if (!AssistantAssembler.isLegalName(name)) { this.fatal('illegal label name'); return }
      labels.push(name)
      let rec: AssistantAnswer
      const existing = t.answers.get(name)
      if (existing) {
        if (!keepsAnswers(this.state) && existing.pending === undefined && existing.hasALD) {
          this.fatal('This assistant label is already used at another .AUE defintion.'); return
        }
        const pending = existing.pending
        if (pending === undefined) {
          if (this.state === AssemblerState.userEntry && autoNext && forceDefault) existing.value = field.defaultValue
        } else {
          switch (pending.k) {
            case 'defaultValue': existing.value = field.defaultValue; break
            case 'minimum': existing.value = field.min; break
            case 'maximum': existing.value = field.max; break
            case 'previous': existing.value = existing.previous; break
            case 'literal': existing.value = pending.v; break
          }
        }
        if (existing.pendingAlsoPrevious) existing.previous = existing.value
        existing.pending = undefined
        existing.pendingAlsoPrevious = false
        if (existing.previous === INT32_MAX) existing.previous = field.defaultValue
        rec = existing
      } else {
        rec = newAnswer(field.defaultValue, field.defaultValue)
      }
      rec.value = Math.min(Math.max(rec.value, field.min), field.max)
      rec.previous = Math.min(Math.max(rec.previous, field.min), field.max)
      t.answers.set(name, rec)
      prevs.push(rec.previous)
      before.push(rec.value)
    }
    this.table = t

    let handled = false
    const st = this.state
    if (st === AssemblerState.userEntry || st === AssemblerState.summary || st === AssemblerState.translatorBuild) {
      const stepNo = this.intLabel('$AssistantStep')
      this.setGlobal('$AssistantStep', vInt(stepNo + 1))
      const display = this.intLabel('$AssistantDisplayStep')
      if (stepNo + 1 === display) {
        handled = true
        let decision: AssistantDecision
        if (autoNext && (buttons === 'cancelOnly' || buttons === 'previousOnly')) this.setGlobal('$AutoNext', vBool(false))
        if (isTrue('$AutoNext')) {
          decision = { k: 'next', values: before }
        } else {
          const back = this.global.get('$AssistantBackStepList')?.value
          if (back?.t === 'list') this.setGlobal('$AssistantBackStepList', vList([...back.v, vInt(display)]))
          const presentation: AssistantStepPresentation = {
            assistant: this.currentAssistant ?? '', step, labels, values: [...before], format, buttons, isFirst: display === 1,
          }
          decision = this.interactive ? yield presentation : { k: 'next', values: before }
        }
        switch (decision.k) {
          case 'next': {
            const t2 = this.table
            labels.forEach((name, k) => {
              if (k >= decision.values.length) return
              const f = step.fields[k]!
              const a = t2.answers.get(name)
              if (a) a.value = Math.min(Math.max(decision.values[k]! | 0, f.min), f.max)
            })
            this.table = t2
            this.setGlobal('$AssistantDisplayStep', vInt(display + 1))
            break
          }
          case 'previous': {
            const backV = this.global.get('$AssistantBackStepList')?.value
            if (backV?.t === 'list') {
              const back = [...backV.v]
              if (back.length > 0) back.pop()
              const target = back.pop() ?? vInt(1)
              this.setGlobal('$AssistantBackStepList', vList(back))
              this.setGlobal('$AssistantDisplayStep', target)
            }
            this.report(AssistantAssembler.restartMessage, 'fatal', true)
            return
          }
          case 'cancel':
            this.setGlobal('$AssistantCancelled', vBool(true))
            this.report('Assembly cancelled by user', 'fatal', true)
            return
        }
      }
    }
    const after: number[] = []
    for (const l of labels) { const a = this.table.answers.get(l); if (a) after.push(a.value) }
    this.stepLog.push({ assistant: this.currentAssistant ?? '', step, labels, values: after, format, buttons, isFirst: false })
    const result = vList([vList(prevs.map(vInt)), vList(before.map(vInt)), vList(after.map(vInt))])
    const existingLabel = this.scope.labels.get(id)
    if (existingLabel) existingLabel.value = result
    else this.scope.labels.set(id, new Label(result, 0))
    if (handled) {
      this.setGlobal('$AUEHandled', vBool(true))
      this.setGlobal('$HandledAUEStep', vStr(id))
    }
  }

  private ald(line: SourceLine): void {
    const name = line.label
    if (name.length === 0) { this.fatal('label expected'); return }
    if (line.params.length !== 1) { this.fatal(line.params.length === 0 ? 'too few parameters' : 'too many parameters'); return }
    if (this.pass === 3) {
      const l = this.lookup(name)
      if (!l) { this.fatal('Cannot find label during 2nd pass readback check'); return }
      this.readBackUsed = false
      const v = this.evaluate(line.params[0]!, false)
      if (v?.t !== 'int') { this.fatal('Unexpected result of expression during 2nd pass readback check'); return }
      if (!optionalValueEquals(l.value, vInt(v.v))) this.fatal('readback after assembly returns a different value!')
      return
    }
    if (this.pass !== 1) return
    const rec = this.table.answers.get(name)
    if (!rec) { this.fatal('No corresponding .AUE found before this defintion'); return }
    if (this.localNames.has(name) || this.globalDepth !== 0 || this.scope.ext.has(name) || this.scope.pub.has(name)) {
      this.fatal('An assistant label must be a local label and cannot be an "external", global or macro local'); return
    }
    if (this.scope.labels.has(name)) { this.fatal('This label is already defined!'); return }
    if (this.usedBeforeDefinition.has(name)) { this.fatal('This label is already used! (An assistant label must be defined before use!)'); return }
    this.readBackUsed = false
    const e = this.calculator.evaluate(line.params[0]!)
    if (!this.readBackUsed) { this.fatal('The expression in the .ALD must make use of a readback function!'); return }
    if (!evaluationOk(e) || !e.value) { this.fatal('The value of an assistant label must be calculatable the 1st pass! (and all other passes)'); return }
    if (e.value.t !== 'int') { this.fatal('Assistant label expression must be an integer!'); return }
    const x = e.value.v
    // Swift copies the record; only the stored copy changes (same object here, written back below).
    const updated: AssistantAnswer = { ...rec, hasALD: true }
    if (this.state === AssemblerState.backReadBuild) {
      updated.value = x
      updated.previous = x
      updated.confirmed = true
    }
    const t = this.table
    t.answers.set(name, updated)
    this.table = t
    this.scope.labels.set(name, new Label(vInt(updated.value), 1))
  }

  private als(line: SourceLine): void {
    if (this.pass !== 1) return
    const name = line.label
    if (name.length === 0 || !AssistantAssembler.isLegalName(name)) { this.fatal('illegal label name'); return }
    if (!(line.params.length >= 1 && line.params.length <= 2)) { this.fatal('too many parameters'); return }
    if (this.scope.labels.has(name)) { this.fatal('This label is already defined!'); return }
    const v = this.evaluate(line.params[0]!, false)
    if (!v) { this.fatal('The value of assistant entry info must be calculatable the 1st pass!'); return }
    let pending: Pending
    const one = v.t === 'string' && v.v.length === 1 ? v.v[0] : undefined
    if (v.t === 'int') pending = { k: 'literal', v: v.v }
    else if (one === 0x44 || one === 0x64) pending = { k: 'defaultValue' }
    else if (one === 0x4e || one === 0x6e) pending = { k: 'minimum' }
    else if (one === 0x58 || one === 0x78) pending = { k: 'maximum' }
    else if (one === 0x50 || one === 0x70) pending = { k: 'previous' }
    else { this.fatal("Assistant label value must be an integer or 'D','N','P','X'"); return }
    let alsoPrevious = false
    if (line.params.length === 2) {
      const b = this.evaluate(line.params[1]!, false)
      if (!b || !(valueEquals(b, vStr('B')) || valueEquals(b, vStr('b')))) {
        this.fatal("Assistant label value must be an integer or 'D','N','P','X'"); return
      }
      alsoPrevious = true
    }
    const t = this.table
    const rec = t.answers.get(name) ?? newAnswer(0, INT32_MAX)
    rec.pending = pending
    rec.pendingAlsoPrevious = alsoPrevious
    // As in VE Configure, an integer is stored as the value at once (kind 5 → +8).
    if (pending.k === 'literal') rec.value = pending.v
    t.answers.set(name, rec)
    this.table = t
  }
}

export type { AssistantStepDefinition }
