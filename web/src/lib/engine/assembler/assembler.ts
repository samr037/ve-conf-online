// The VLL macro assembler (port of Sources/VEKit/Assembler/Assembler.swift, docs/re/03-assembler.md §1, §5–§10).
// The CPU instruction set is not here: it is defined as macros in asfStart.vll that emit bytes through DATA.
//
// Everything that can reach a wizard step (`.AUE` in AssistantAssembler) is a generator: the Swift version pauses
// the assembly thread at a step, here the generator yields the step and resumes with the decision.
import { latin1Decode, latin1Encode, type Bytes } from '../binary'
import { Calculator, Label, evaluationOk, type CalculatorHost, type ReadBackResult } from './calculator'
import { LineList, SourceLine } from './sourceLine'
import type { AssemblerMessage, AssemblyGen, MessageKind } from './types'
import { asText, optionalValueEquals, sameClass, vInt, vString, type Value } from './value'

export type LabelTable = Map<string, Label>

export interface MacroParam { name: string; isString: boolean }

export interface Macro {
  name: string
  minParams: number
  params: MacroParam[]
  body: SourceLine[]
}

function macroEquals(a: Macro, b: Macro): boolean {
  return a.name === b.name && a.minParams === b.minParams && a.body.length === b.body.length
    && a.body.every((l, i) => l.equals(b.body[i]!))
    && a.params.length === b.params.length
    && a.params.every((p, i) => p.name === b.params[i]!.name && p.isString === b.params[i]!.isString)
}

interface WhileEntry { line: number; k: number; list: LineList }

/** One executing line list: a `.SOURCE` file, a macro body or the root. */
export class Frame {
  index = 0
  conditions: string[] = []
  /** Active `.WHILE`s: line and iteration, and the list holding the `.WHILE`. */
  whiles: WhileEntry[] = []
  pendingWhile = new Map<number, number>()

  constructor(readonly list: LineList, readonly path: string) {}

  /** Unique, deterministic id of the line being executed (call-site path; includes `.WHILE` iterations). */
  get site(): string {
    return this.path + '|' + String(this.index) + this.whiles.map((w) => `w${w.line}.${w.k}`).join('')
  }
}

export class Scope {
  macros = new Map<string, Macro>()
  pub = new Set<string>()
  ext = new Set<string>()
  constructor(readonly path: string, readonly labels: LabelTable) {}
}

/**
 * `$CODE`: a growable buffer behind a string value. Emitting writes in place; reading returns an immutable copy,
 * cached until the next write (Swift gets the same effect from copy-on-write arrays).
 */
class CodeLabel extends Label {
  private buf = new Uint8Array(256)
  private len = 0
  private cached: Value | undefined
  private nil = false

  constructor() {
    super(undefined, 2)
    this.cached = vString(new Uint8Array())
  }

  override get value(): Value | undefined {
    if (this.nil) return undefined
    if (!this.cached) this.cached = vString(this.buf.slice(0, this.len))
    return this.cached
  }

  override set value(v: Value | undefined) {
    if (v === undefined) { this.nil = true; this.cached = undefined; return }
    this.nil = false
    if (v.t === 'string') {
      this.buf = new Uint8Array(Math.max(256, v.v.length))
      this.buf.set(v.v)
      this.len = v.v.length
      this.cached = v
    } else {
      // A system label keeps its class (store() checks it); keep any other value verbatim.
      this.cached = v
      this.len = 0
    }
  }

  get isString(): boolean { return !this.nil && (!this.cached || this.cached.t === 'string') }

  /** In-place write at `at`, padding with 0xFF; false when `$CODE` is not a string. */
  write(at: number, byte: number): boolean {
    if (this.nil || (this.cached && this.cached.t !== 'string')) return false
    if (at >= 0) {
      if (at >= this.buf.length) {
        const nb = new Uint8Array(Math.max(at + 1, this.buf.length * 2))
        nb.set(this.buf.subarray(0, this.len))
        this.buf = nb
      }
      if (this.len <= at) { this.buf.fill(0xff, this.len, at + 1); this.len = at + 1 }
      this.buf[at] = byte
      this.cached = undefined
    }
    return true
  }

  bytes(): Bytes {
    const v = this.value
    return v?.t === 'string' ? v.v : new Uint8Array()
  }
}

export type Handler = (line: SourceLine, frame: Frame) => AssemblyGen | void

const isLetter = (c: number) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c === 0x5f
const isDigitCode = (c: number) => c >= 0x30 && c <= 0x39

const ifOps = new Set(['.IF', '.IFDEF', '.IFNDEF', '.IFNOT'])

type Assignment = { k: 'value'; v: Value } | { k: 'unset' }

export class Assembler implements CalculatorHost {
  // Label lists (§5.2).
  global: LabelTable = new Map()
  publics: LabelTable = new Map()
  scopeRegistry = new Map<string, LabelTable>()
  localRegistry = new Map<string, LabelTable>()
  scope: Scope
  /** F: macro parameters */
  frameLabels: LabelTable | undefined
  /** K: .LOCAL space of the current expansion */
  macroLocals: LabelTable | undefined
  /** .LOCAL list */
  localNames = new Set<string>()
  globalDepth = 0
  globalMacros = new Map<string, Macro>()
  macroDepth = 0
  /** Active `.SOURCE` / `.INSERT` / `.ASSEMBLE` nesting. */
  includeDepth = 0
  /** Lines processed in this assembly (all passes), against `lineBudget`. */
  linesProcessed = 0
  lineBudget = 4_000_000 // Assembler.maxLines

  // Limits that VE Configure does not have; they turn hostile sources into errors instead of crashes or hangs.
  static readonly maxIncludeDepth = 255
  /** Highest `$` a DATA may write to. The device holds 4 KB; this only bounds memory. */
  static readonly maxCodeSize = 1 << 20
  /** Lines processed per assembly. The largest library assistant processes about 110 000 lines. */
  static readonly maxLines = 4_000_000

  pass = 0
  stopped = false
  success = true
  messages: AssemblerMessage[] = []
  currentFrame: Frame | undefined

  readonly calculator: Calculator

  /** Supplies the text of a `.SOURCE` / `.INSERT` file. */
  sourceProvider: (name: string) => Bytes | undefined = () => undefined

  constructor() {
    this.scope = new Scope('root', new Map())
    this.calculator = new Calculator(this)
  }

  // MARK: Driver (§10.1)

  /** Two passes over the root list, answering any step with the values shown. */
  assemble(root: LineList, passes = 2): boolean {
    const g = this.assembleSteps(root, passes)
    let r = g.next()
    while (!r.done) r = g.next({ k: 'next', values: r.value.values })
    return r.value
  }

  *assembleSteps(root: LineList, passes = 2): AssemblyGen<boolean> {
    this.linesProcessed = 0
    for (let p = 1; p <= passes; p++) {
      this.reset(p === 1)
      this.pass = p
      this.willStartPass(p)
      yield* this.run(root, 'root', true)
      if (this.stopped) break
    }
    return this.success && !this.stopped
  }

  willStartPass(_pass: number): void {}

  reset(firstPass: boolean): void {
    if (firstPass) {
      this.global = new Map()
      this.publics = new Map()
      this.scopeRegistry = new Map()
      this.localRegistry = new Map()
      this.stopped = false
    }
    this.global.set('$', new Label(vInt(0), 2))
    this.global.set('$CODE', new CodeLabel())
    this.global.set('$LISTING', new Label(vString(new Uint8Array()), 2))
    this.globalDepth = 0
    this.globalMacros = new Map()
    this.macroDepth = 0
    this.includeDepth = 0
    this.frameLabels = undefined
    this.macroLocals = undefined
    this.localNames = new Set()
    if (!this.stopped) { this.messages = []; this.success = true }
  }

  get code(): Bytes {
    const l = this.global.get('$CODE')
    if (l instanceof CodeLabel) return l.bytes().slice()
    const v = l?.value
    return v?.t === 'string' ? v.v.slice() : new Uint8Array()
  }

  // MARK: Executing line lists

  *run(list: LineList, path: string, newScope: boolean): AssemblyGen {
    const frame = new Frame(list, path)
    const savedScope = this.scope
    if (newScope) {
      const labels = this.scopeRegistry.get(path) ?? new Map()
      this.scopeRegistry.set(path, labels)
      this.scope = new Scope(path, labels)
    }
    const savedFrame = this.currentFrame
    this.currentFrame = frame
    while (!this.stopped) {
      frame.index++
      if (!(frame.index < list.count)) break
      yield* this.process(list.line(frame.index), frame)
    }
    if (!this.stopped) {
      if (frame.conditions.includes('w')) this.report('expected .ENDW')
      else if (frame.conditions.length > 0) this.report('expected .ENDIF')
    }
    this.currentFrame = savedFrame
    if (newScope) this.scope = savedScope
  }

  *process(line: SourceLine, frame: Frame): AssemblyGen {
    this.linesProcessed++
    if (this.linesProcessed > this.lineBudget) {
      this.report(`Assembly stopped: more than ${this.lineBudget} lines processed (runaway .WHILE loops?)`, 'error', true)
      return
    }
    if (line.error !== undefined) { this.report(line.error); return }
    const op = line.opcode.toLowerCase()
    const handler = this.directive(op)
    if (handler) {
      const g = handler(line, frame)
      if (g) yield* g
      return
    }
    if (line.label.length > 0) {
      if (!line.label.endsWith(':')) { this.report('expected ":" after label name'); return }
      const name = line.label.slice(0, -1)
      if (name.length === 0) { this.report('no labelname specified'); return }
      this.define(name, vInt(this.location), false, 1)
    }
    if (line.opcode.length === 0) return
    const m = this.scope.macros.get(op) ?? this.globalMacros.get(op)
    if (m) yield* this.expand(m, line, frame)
    else this.report('cannot interpret opcode field')
  }

  // MARK: Errors (§10.3)

  report(text: string, kind: MessageKind = 'error', fatal = false): void {
    if (this.stopped) return
    if (this.pass === 1 && !fatal) return
    if (fatal) this.stopped = true
    if (kind === 'error' || kind === 'fatal' || fatal) this.success = false
    const f = this.currentFrame
    this.messages.push({ kind: fatal ? 'fatal' : kind, text, position: f ? `${f.list.header}:${f.index}` : '' })
  }

  /** Evaluates a parameter; failures are reported as *calculation error* (pass 2) unless `shouldReport` is false. */
  evaluate(text: Bytes | string, shouldReport = true): Value | undefined {
    const e = this.calculator.evaluate(typeof text === 'string' ? latin1Encode(text) : text)
    if (shouldReport) for (const w of e.warnings) this.report(w, 'warning')
    if (!evaluationOk(e)) {
      if (shouldReport) this.report(`calculation error: ${e.error ?? ''}`)
      return undefined
    }
    return e.value
  }

  // MARK: Labels (§5.3, §5.4)

  lookup(name: string): Label | undefined {
    if (this.localNames.has(name)) return this.macroLocals?.get(name)
    const f = this.frameLabels?.get(name)
    if (f) return f
    if (this.scope.pub.has(name) || this.scope.ext.has(name)) return this.publics.get(name)
    return this.scope.labels.get(name) ?? this.global.get(name)
  }

  static isLegalName(name: string): boolean {
    if (name.length === 0) return false
    const lower = name.toLowerCase()
    if (lower === 'true' || lower === 'false') return false
    if (!isLetter(name.charCodeAt(0))) return false
    for (let i = 1; i < name.length; i++) {
      const c = name.charCodeAt(i)
      if (!(isLetter(c) || isDigitCode(c) || c === 0x23)) return false
    }
    return true
  }

  define(rawName: string, value: Value | undefined, force: boolean, flags: number): void {
    if (value === undefined) return // e.g. ".SET <unknown>" keeps the old value
    this.store(rawName, { k: 'value', v: value }, force, flags)
  }

  /** §5.4 (`FUN_004fa434`): `unset` is the UNSET marker of `.UNSET`, which goes through the same target selection. */
  private store(rawName: string, assignment: Assignment, force: boolean, flags: number): void {
    const sys = this.global.get(rawName)
    if (sys && sys.isSystem) {
      if (assignment.k !== 'value') { this.report('Cannot remove a system label'); return }
      const cur = sys.value
      if (!(cur ? sameClass(cur, assignment.v) : true)) { this.report('Expression returns wrong type'); return }
      sys.value = assignment.v
      return
    }
    // User function definition: Name(p1,p2,…) with a string body.
    let name = rawName
    let params: string[] | undefined
    const open = rawName.indexOf('(')
    if (open >= 0) {
      const bad = 'Not a legal function defintion (parameter list not correct or expression is not a string)'
      if (!rawName.endsWith(')')) { this.report(bad); return }
      const base = rawName.slice(0, open)
      const ps = rawName.slice(open + 1, rawName.length - 1).split(',')
      if (!Assembler.isLegalName(base) || ps.length === 0 || !ps.every(Assembler.isLegalName)) { this.report(bad); return }
      if (assignment.k !== 'value' || assignment.v.t !== 'string') { this.report('string expression expected'); return }
      name = base + '('
      params = ps
    } else if (!Assembler.isLegalName(rawName)) {
      this.report('illegal label name'); return
    }

    let target: LabelTable
    const g = this.global.get(name)
    if (this.globalDepth > 0) {
      target = this.global
    } else if ((flags & 1) === 0 && g && !g.isFixed) {
      target = this.global
    } else {
      if (this.frameLabels?.has(name)) { this.report('Cannot redefine a macro parameter'); return }
      if (this.localNames.has(name)) {
        if (!this.macroLocals) this.macroLocals = new Map()
        target = this.macroLocals
      } else if (this.scope.pub.has(name) || this.scope.ext.has(name)) {
        target = this.publics
      } else {
        target = this.scope.labels
      }
    }
    const old = target.get(name)
    if (!old) {
      if (assignment.k !== 'value') return
      if (this.scope.ext.has(name)) {
        this.report((flags & 1) === 0 ? 'trying to re-define a non-defined external' : 'It is not allowed to define the value of an external')
        return
      }
      target.set(name, new Label(assignment.v, flags, params))
      return
    }
    if (force) return
    if ((flags === 0 && old.isFixed) || (flags !== 0 && flags !== old.flags)) {
      this.report('Labeltype (fixed/variable) different from previous pass'); return
    }
    if (assignment.k !== 'value') {
      // Only variables get here (UNSET has flags 0, so a fixed label failed the type check above).
      if (target === this.publics) this.report('Cannot remove a public or external label')
      else target.delete(name)
      return
    }
    const value = assignment.v
    if (!old.isFixed) {
      old.value = value
      if (params) old.params = params
    } else if (!optionalValueEquals(old.value, value) || (params && !sameParams(old.params, params))) {
      this.report('label value different from first assignment. Cannot re-define the value for this type of label')
    }
  }

  // MARK: Code generation (§9)

  get location(): number {
    const v = this.global.get('$')?.value
    return v?.t === 'int' ? v.v : 0
  }

  emit(byte: number): void {
    const codeLabel = this.global.get('$CODE'), locLabel = this.global.get('$')
    const loc = locLabel?.value
    if (!codeLabel || !locLabel || loc?.t !== 'int') return
    if (codeLabel instanceof CodeLabel ? !codeLabel.isString : codeLabel.value?.t !== 'string') return
    const at = loc.v
    if (at >= Assembler.maxCodeSize) {
      this.report(`location counter $ beyond the ${Assembler.maxCodeSize / 1024} KB code limit`, 'error', true)
      return
    }
    if (codeLabel instanceof CodeLabel) {
      codeLabel.write(at, byte & 0xff)
    } else if (at >= 0) {
      const code = (codeLabel.value as { v: Bytes }).v
      const out = new Uint8Array(Math.max(code.length, at + 1)).fill(0xff)
      out.set(code)
      out[at] = byte & 0xff
      codeLabel.value = vString(out)
    }
    locLabel.value = vInt(loc.v + 1)
  }

  // MARK: Directives (§6)

  directive(op: string): Handler | undefined {
    switch (op) {
      case '.equ': return (l) => this.equ(l)
      case '.set': return (l) => this.set(l)
      case '.unset': return (l) => this.unset(l)
      case '.macro': return (l, f) => this.macroDefinition(l, f)
      case '.endm': return () => this.report('unexpected .ENDM')
      case '.if': case '.ifnot': case '.ifdef': case '.ifndef': return (l, f) => this.conditional(l, f)
      case '.else': return (l, f) => this.elseDirective(l, f)
      case '.endif': return (_l, f) => this.endif(f)
      case '.while': return (l, f) => this.whileDirective(l, f)
      case '.endw': return (_l, f) => this.endw(f)
      case '.local': return (l) => this.local(l)
      case '.nop': case '.list': case '.nolist': case '.defer': case '.nodefer': return () => {}
      case 'data': return (l) => this.data(l)
      case '.renmacro': return (l) => this.renameMacro(l)
      case '.ext': return (l) => { for (const p of l.params) this.scope.ext.add(latin1Decode(p)) }
      case '.pub': return (l) => { for (const p of l.params) this.scope.pub.add(latin1Decode(p)) }
      case '.messg': return (l) => this.message(l, 'message', false)
      case '.error': return (l) => this.message(l, 'error', false)
      case '.ferror': return (l) => this.message(l, 'fatal', true)
      case '.assemble': return (l, f) => this.assembleDirective(l, f)
      case '.source': return (l, f) => this.include(l, f, true)
      case '.insert': return (l, f) => this.include(l, f, false)
      case '.global': return (l) => this.globalDirective(l)
      default: return undefined
    }
  }

  codeLabel(line: SourceLine): void {
    if (line.label.length === 0) return
    if (!line.label.endsWith(':')) { this.report('expected ":" after label name'); return }
    this.define(line.label.slice(0, -1), vInt(this.location), false, 1)
  }

  needsLabel(line: SourceLine): boolean {
    if (line.label.length === 0) { this.report('label expected'); return false }
    return true
  }

  params(line: SourceLine, min: number, max: number): boolean {
    if (line.params.length > max) { this.report('too many parameters'); return false }
    if (line.params.length < min) { this.report('too few parameters'); return false }
    return true
  }

  private equ(line: SourceLine): void {
    if (!this.needsLabel(line) || !this.params(line, 1, 1)) return
    this.define(line.label, this.evaluate(line.params[0]!), false, 1)
  }

  private set(line: SourceLine): void {
    if (!this.needsLabel(line) || !this.params(line, 1, 3)) return
    let flags = 0
    let force = false
    const n = line.params.length
    if (n >= 2) {
      const v = this.evaluate(line.params[1]!)
      if (v === undefined) return
      if (v.t === 'int') flags = v.v
      else if (v.t === 'bool' && n === 2) force = v.v
      else { this.report(n === 3 ? 'result of expression must be integer' : 'result of expression must be boolean or integer'); return }
    }
    if (n === 3) {
      const b = this.evaluate(line.params[2]!)
      if (b?.t !== 'bool') { this.report('result of expression must be boolean'); return }
      force = b.v
    }
    this.define(line.label, this.evaluate(line.params[0]!), force, flags)
  }

  /** `.UNSET` defines the UNSET marker (§5.4). */
  private unset(line: SourceLine): void {
    if (!this.needsLabel(line) || !this.params(line, 0, 0)) return
    this.store(line.label, { k: 'unset' }, false, 0)
  }

  private local(line: SourceLine): void {
    if (!(this.macroDepth > 0)) { this.report('only allowed inside a MACRO'); return }
    for (const p of line.params) {
      const name = latin1Decode(p)
      if (name.endsWith('(')) { this.localNames.add(name.slice(0, -1) + '('); continue }
      if (!Assembler.isLegalName(name)) { this.report('illegal label name'); continue }
      this.localNames.add(name)
    }
    if (!this.macroLocals) this.macroLocals = new Map()
  }

  private data(line: SourceLine): void {
    this.codeLabel(line)
    if (!this.params(line, 1, 1)) return
    const v = this.evaluate(line.params[0]!, this.pass > 1)
    if (v?.t === 'int') this.emit(v.v & 0xff)
    else if (v) { this.report('result of expression must be integer'); this.emit(0) }
    else {
      if (this.pass > 1) this.report('result of expression still undefined in last pass')
      this.emit(0)
    }
  }

  private message(line: SourceLine, kind: MessageKind, fatal: boolean): void {
    const p = line.params[0]
    if (!p) return
    const v = this.evaluate(p)
    const text = v ? latin1Decode(asText(v)) : latin1Decode(p)
    this.report(text, kind, fatal)
  }

  private globalDirective(line: SourceLine): void {
    if (!this.params(line, 1, 1)) return
    const v = this.evaluate(line.params[0]!)
    if (v?.t !== 'bool') return
    if (v.v) this.globalDepth++
    else if (this.globalDepth > 0) this.globalDepth--
    else this.report('.GLOBAL not properly nested')
  }

  private *assembleDirective(line: SourceLine, frame: Frame): AssemblyGen {
    this.codeLabel(line)
    if (!this.params(line, 1, 1)) return
    const v = this.evaluate(line.params[0]!)
    if (v?.t !== 'string') { this.report('string expression expected'); return }
    if (!this.enterInclude()) return
    try {
      yield* this.process(SourceLine.parse(v.v), frame)
    } finally {
      this.includeDepth--
    }
  }

  *include(line: SourceLine, frame: Frame, newScope: boolean): AssemblyGen {
    this.codeLabel(line)
    if (!this.params(line, 1, 1)) return
    const v = this.evaluate(line.params[0]!)
    if (v?.t !== 'string') return
    const name = latin1Decode(v.v)
    const text = this.sourceProvider(name)
    if (!text) { this.report('Cannot open file'); return }
    if (!this.enterInclude()) return
    try {
      const list = LineList.fromText(name, text)
      if (newScope) {
        const saved = [this.frameLabels, this.macroLocals, this.localNames, this.scope] as const
        this.frameLabels = undefined; this.macroLocals = undefined; this.localNames = new Set()
        this.willEnterSource(name)
        yield* this.run(list, frame.site + '#' + name, true)
        this.didLeaveSource(name)
        ;[this.frameLabels, this.macroLocals, this.localNames, this.scope] = saved
      } else {
        // .INSERT shares the current scope and its conditional stack (§6).
        const inserted = new Frame(list, frame.site + '+' + name)
        inserted.conditions = frame.conditions
        inserted.whiles = frame.whiles
        const saved = this.currentFrame
        this.currentFrame = inserted
        while (!this.stopped) {
          inserted.index++
          if (!(inserted.index < list.count)) break
          yield* this.process(list.line(inserted.index), inserted)
        }
        this.currentFrame = saved
        frame.conditions = inserted.conditions
        frame.whiles = inserted.whiles
      }
    } finally {
      this.includeDepth--
    }
  }

  /** Counts one more `.SOURCE` / `.INSERT` / `.ASSEMBLE` level; false (after a fatal error) past the limit. */
  private enterInclude(): boolean {
    if (!(this.includeDepth < Assembler.maxIncludeDepth)) {
      this.report(`nesting too deep (.SOURCE / .INSERT / .ASSEMBLE more than ${Assembler.maxIncludeDepth} levels)`, 'error', true)
      return false
    }
    this.includeDepth++
    return true
  }

  willEnterSource(_name: string): void {}
  didLeaveSource(_name: string): void {}

  // MARK: Conditionals and loops (§8)

  /** Skip mode: find the matching .ELSE/.ENDIF (for an .IF) or .ENDW (for a .WHILE). Opcode compares are exact. */
  skip(frame: Frame, forWhile: boolean, acceptElse: boolean): ['else' | 'endif' | 'endw', number] | undefined {
    const nested: string[] = []
    for (let j = frame.index + 1; j < frame.list.count; j++) {
      const op = frame.list.line(j).opcode
      if (ifOps.has(op)) nested.push('i')
      else if (op === '.WHILE') nested.push('w')
      else if (op === '.ENDIF') {
        if (nested.length === 0) { if (!forWhile) return ['endif', j] } else nested.pop()
      } else if (op === '.ENDW') {
        if (nested.length === 0) { if (forWhile) return ['endw', j] } else nested.pop()
      } else if (op === '.ELSE' && nested.length === 0 && !forWhile && acceptElse) {
        return ['else', j]
      }
    }
    this.report(forWhile ? 'expected .ENDW' : 'expected .ENDIF')
    return undefined
  }

  private conditional(line: SourceLine, frame: Frame): void {
    if (!this.params(line, 1, 1)) return
    const op = line.opcode.toLowerCase()
    let truth: boolean
    if (op === '.ifdef' || op === '.ifndef') {
      const ok = evaluationOk(this.calculator.evaluate(line.params[0]!))
      truth = op === '.ifdef' ? ok : !ok
    } else {
      const v = this.evaluate(line.params[0]!)
      if (v?.t === 'bool') truth = op === '.if' ? v.v : !v.v
      else {
        if (v) this.report('result of expression must be boolean')
        truth = false
      }
    }
    if (truth) {
      frame.conditions.push('i')
    } else {
      const s = this.skip(frame, false, true)
      if (s) {
        if (s[0] === 'else') frame.conditions.push('e')
        frame.index = s[1]
      } else frame.index = frame.list.count
    }
  }

  private elseDirective(_line: SourceLine, frame: Frame): void {
    if (frame.conditions[frame.conditions.length - 1] !== 'i') { this.report('unexpected .ELSE'); return }
    frame.conditions.pop()
    const s = this.skip(frame, false, false)
    frame.index = s ? s[1] : frame.list.count
  }

  private endif(frame: Frame): void {
    const top = frame.conditions[frame.conditions.length - 1]
    if (!(top === 'i' || top === 'e')) { this.report('unexpected .ENDIF'); return }
    frame.conditions.pop()
  }

  private whileDirective(line: SourceLine, frame: Frame): void {
    if (!this.params(line, 1, 1)) return
    const k = frame.pendingWhile.get(frame.index) ?? 1
    frame.pendingWhile.delete(frame.index)
    let truth = false
    const v = this.evaluate(line.params[0]!)
    if (v?.t === 'bool') truth = v.v
    else if (v) this.report('result of expression must be boolean')
    if (truth) {
      frame.conditions.push('w')
      frame.whiles.push({ line: frame.index, k, list: frame.list })
    } else {
      const s = this.skip(frame, true, false)
      frame.index = s ? s[1] : frame.list.count
    }
  }

  private endw(frame: Frame): void {
    if (frame.conditions[frame.conditions.length - 1] !== 'w' || frame.whiles.length === 0) { this.report('unexpected .ENDW'); return }
    const w = frame.whiles.pop()!
    frame.conditions.pop()
    if (w.list !== frame.list) { this.report('internal error with while construction'); return }
    if (w.k <= 1024) {
      frame.pendingWhile.set(w.line, w.k + 1)
      frame.index = w.line - 1
    } else {
      this.report('while loop must stop within 1024 iterations')
    }
  }

  // MARK: Macros (§7)

  static isLegalMacroName(name: string): boolean {
    if (name.length === 0 || !isLetter(name.charCodeAt(0))) return false
    for (let i = 1; i < name.length; i++) {
      const c = name.charCodeAt(i)
      if (!(isLetter(c) || isDigitCode(c) || c === 0x23 || c === 0x2b || c === 0x2d || c === 0x40 || c === 0x5b || c === 0x5d)) return false
    }
    return true
  }

  private macroDefinition(line: SourceLine, frame: Frame): void {
    // Record the body first so the stream always moves past .ENDM.
    const body: SourceLine[] = []
    let j = frame.index + 1
    let closed = false
    while (j < frame.list.count) {
      const l = frame.list.line(j)
      if (l.opcode === '.ENDM') { closed = true; break }
      body.push(l)
      j++
    }
    frame.index = j
    if (!closed) { this.report('expected .ENDM'); return }
    if (!this.needsLabel(line)) return
    const name = line.label
    if (this.directive(name.toLowerCase()) !== undefined || !Assembler.isLegalMacroName(name)) { this.report('illegal macro name'); return }
    const ps = line.params.map(latin1Decode)
    let minimum: number | undefined
    const first = ps[0]
    if (first !== undefined && first.length > 0 && isDigitCode(first.charCodeAt(0))) {
      const v = this.evaluate(line.params[0]!)
      if (v?.t !== 'int') { this.report('illegal label name'); return }
      minimum = v.v
      ps.shift()
    }
    const params: MacroParam[] = []
    for (const p of ps) {
      const isString = p.startsWith('s:')
      const n = isString ? p.slice(2) : p
      if (!Assembler.isLegalName(n)) { this.report('illegal label name'); return }
      if (n === 'Params' || params.some((q) => q.name === n)) {
        this.report("A parameter name is used twice (mind the implicit 'Params' parameter"); return
      }
      params.push({ name: n, isString })
    }
    if (minimum !== undefined && minimum > params.length) {
      this.report('Specified a minimum nr of parameters higher than the nr of parameters in the list'); return
    }
    const macro: Macro = { name, minParams: minimum ?? params.length, params, body }
    const key = name.toLowerCase()
    const table = this.globalDepth > 0 ? this.globalMacros : this.scope.macros
    const old = table.get(key)
    if (old && !macroEquals(old, macro)) { this.report('MACRO exists already and defintion differs from previous!'); return }
    table.set(key, macro)
  }

  private renameMacro(line: SourceLine): void {
    if (!this.params(line, 2, 2)) return
    const old = latin1Decode(line.params[0]!).toLowerCase()
    const nw = latin1Decode(line.params[1]!)
    const table = this.globalDepth > 0 ? this.globalMacros : this.scope.macros
    const m = table.get(old)
    if (!m) { this.report('cannot rename a non-existing macro'); return }
    table.delete(old)
    if (nw.toLowerCase() !== old) table.set(nw.toLowerCase(), { ...m, name: nw })
  }

  *expand(macro: Macro, line: SourceLine, frame: Frame): AssemblyGen {
    if (!(this.macroDepth < 255)) { this.report('Macro nesting not allowed deeper than 255'); return }
    const actual = line.params.length
    if (!(actual >= macro.minParams && actual <= macro.params.length)) {
      this.report('nr of parameters in macro call less than required minimum or more than specifed during macro defintion')
      return
    }
    let newFrame: LabelTable | undefined
    if (actual > 0 || macro.params.length > 0) {
      const f: LabelTable = new Map()
      f.set('Params', new Label(vInt(actual), 0))
      macro.params.forEach((p, i) => {
        if (i < actual) {
          const raw = line.params[i]!
          f.set(p.name, new Label(p.isString ? vString(raw) : this.evaluate(raw), 0))
        } else {
          f.set(p.name, new Label(undefined, 0))
        }
      })
      const joined: number[] = []
      line.params.forEach((p, i) => { if (i > 0) joined.push(0x2c); for (const b of p) joined.push(b) })
      f.set('$ParamString', new Label(vString(joined), 0))
      newFrame = f
    }
    const site = frame.site + '@' + macro.name
    const saved = [this.frameLabels, this.macroLocals, this.localNames] as const
    this.frameLabels = newFrame
    this.macroLocals = this.localRegistry.get(site)
    this.localNames = new Set()
    this.macroDepth++
    const body = LineList.fromLines(macro.name, macro.body)
    const inner = new Frame(body, site)
    const savedFrame = this.currentFrame
    this.currentFrame = inner
    while (!this.stopped) {
      inner.index++
      if (!(inner.index < body.count)) break
      yield* this.process(body.line(inner.index), inner)
    }
    if (!this.stopped && inner.conditions.length > 0) {
      this.report(inner.conditions.includes('w') ? 'expected .ENDW' : 'expected .ENDIF')
    }
    this.currentFrame = savedFrame
    this.macroDepth--
    if (this.macroLocals) this.localRegistry.set(site, this.macroLocals)
    ;[this.frameLabels, this.macroLocals, this.localNames] = saved
  }

  // MARK: CalculatorHost

  readBack(_bytes: number, _address: number): ReadBackResult { return { ok: true, value: -1 } }
  assistantText(_key: Value): Bytes | undefined { return undefined }
  assistantLabelValue(_name: string): number | undefined { return undefined }
  noteReadBackUsed(): void {}
}

function sameParams(a: string[] | undefined, b: string[]): boolean {
  return !!a && a.length === b.length && a.every((x, i) => x === b[i])
}
