// How VE Configure drives the assembler (port of Sources/VEKit/Assembler/Composer.swift, docs/re/03-assembler.md §13):
// META, asfStart, the assistants, asfStop, assembled as one root file; device image = code + 0xFF padding +
// assistant IDs in reverse order.
import { latin1Decode, latin1Encode, type Bytes } from '../binary'
import { FormatError } from '../binary'
import type { AssistantLibrary, AssistantPackage } from '../assistantPackage'
import type { DeviceConfiguration } from '../deviceConfiguration'
import { AssistantAssembler } from './assistantAssembler'
import { equValue, metaTextLines, replacingEqu, swiftInt, vecTargets } from './metaGenerator'
import { LineList, SourceLine } from './sourceLine'
import {
  AssemblerState, cloneTables,
  type AnswerTable, type AssemblerMessage, type AssistantDecision, type AssistantStepPresentation,
} from './types'
import { valueText, type Value } from './value'
import { WizardText, trimWhitespace } from './wizardText'

export interface AssistantBuildResult {
  success: boolean
  /** META `.SET` labels whose final value differs from META (`name` → new value), docs/re/05-meta.md §6. */
  vecChanges: Map<string, Value>
  code: Bytes
  messages: AssemblerMessage[]
  answers: Map<string, AnswerTable>
  cancelled: boolean
  /** Steps bound during the build, in order (for summaries). */
  steps: AssistantStepPresentation[]
}

export class AssistantError extends Error {
  constructor(readonly detail:
    | { kind: 'unknownAssistant'; id: number }
    | { kind: 'imageTooLarge'; needed: number; size: number }
    | { kind: 'badMemorySize'; size: number }
    | { kind: 'buildFailed'; message: string }) {
    super(AssistantError.describe(detail))
    this.name = 'AssistantError'
  }

  static describe(d: AssistantError['detail']): string {
    switch (d.kind) {
      case 'unknownAssistant':
        return `An Assistant, which is not on your system (ID 0x${d.id.toString(16).toUpperCase().padStart(4, '0')}), is installed in the device.`
      case 'imageTooLarge': return `Not enough assistant memory: ${d.needed} bytes needed, ${d.size} available.`
      case 'badMemorySize': return `The assistant memory of this configuration is ${d.size} bytes; 4096 expected.`
      case 'buildFailed': return d.message.length === 0 ? 'The assistants could not be assembled.' : d.message
    }
  }
}

export interface ComposerItem { package: AssistantPackage; readonly name: string }
export const composerItem = (p: AssistantPackage): ComposerItem => ({ package: p, get name() { return p.baseName } })

export class AssistantComposer {
  /** Assistants between asfStart and asfStop, in order. */
  items: ComposerItem[] = []
  /** Answers per assistant name (the user's choices), kept between builds. */
  answers = new Map<string, AnswerTable>()
  /** Text of the META environment item (target description), see docs/re/05-meta.md. */
  meta: Bytes = new Uint8Array()
  framework: { start: AssistantPackage; stop: AssistantPackage }
  languages: string[] = ['en']

  /** Size of the assistant program memory: VE Configure only ever handles 4096 bytes. */
  static readonly memorySize = 4096

  constructor(readonly library: AssistantLibrary, start?: AssistantPackage, stop?: AssistantPackage) {
    const latest = library.latest
    const s = start ?? latest.find((p) => p.baseName === 'asfStart')
    const e = stop ?? latest.find((p) => p.baseName === 'asfStop')
    if (!s || !e) throw new FormatError({ kind: 'badMagic', what: 'assistant library (asfStart/asfStop missing)' })
    this.framework = { start: s, stop: e }
  }

  get allPackages(): AssistantPackage[] { return [this.framework.start, ...this.items.map((i) => i.package), this.framework.stop] }

  package(named: string): AssistantPackage | undefined { return this.allPackages.find((p) => p.baseName === named) }

  root(): LineList {
    const lines = [SourceLine.parse(latin1Encode(" .SOURCE 'META'"))]
    for (const p of this.allPackages) lines.push(SourceLine.parse(latin1Encode(` .SOURCE '${p.baseName}'`)))
    return LineList.fromLines('Assistant Composer', lines)
  }

  assembler(state: (name: string) => AssemblerState): AssistantAssembler {
    const a = new AssistantAssembler()
    const packages = new Map<string, AssistantPackage>()
    for (const p of this.allPackages) if (!packages.has(p.baseName)) packages.set(p.baseName, p)
    const meta = this.meta
    a.sourceProvider = (name) => (name === 'META' ? meta : packages.get(name)?.source?.bytes)
    for (const [name, p] of packages) {
      a.states.set(name, state(name))
      const scripts = p.scripts
      const en = scripts.get('en')
      const english = en ? new WizardText(en.bytes) : undefined
      let localized: WizardText | undefined
      for (const lang of this.languages) { const s = scripts.get(lang); if (s) { localized = new WizardText(s.bytes); break } }
      a.texts.set(name, { localized, english })
    }
    a.states.set('META', AssemblerState.build)
    a.tables = cloneTables(this.answers)
    return a
  }

  /** Normal build of configured assistants (state 4), with the pass-3 readback verification. */
  build(): AssistantBuildResult {
    const a = this.assembler(() => AssemblerState.build)
    const ok = a.assemble(this.root(), 2)
    let verified = ok
    if (ok) {
      a.referenceBinary = a.code
      const code = a.code
      verified = a.assemble(this.root(), 3) && equalBytes(a.code, code)
    }
    this.answers = a.tables
    return {
      success: verified, code: a.code, messages: a.messages, answers: cloneTables(a.tables), cancelled: false,
      vecChanges: AssistantComposer.vecChanges(this.meta, a), steps: a.stepLog,
    }
  }

  /** FUN_0050EE78: every META ` .SET` label whose final value, as text, differs from the original. */
  static vecChanges(meta: Bytes, a: AssistantAssembler): Map<string, Value> {
    const out = new Map<string, Value>()
    for (const line of metaTextLines(meta)) {
      const set = line.indexOf(' .SET ')
      const tail = line.lastIndexOf(',4,true')
      if (set < 0 || tail < 0) continue
      const name = trimWhitespace(line.slice(0, set))
      if (tail < set + 6) continue // Swift would trap on the inverted range; no META line looks like this
      const original = line.slice(set + 6, tail)
      const v = a.global.get(name)?.value
      if (!v || valueText(v) === original) continue
      out.set(name, v)
    }
    return out
  }

  /** The "assistants removed" image: a 6-byte stub that keeps the checksum at the erased value. */
  static emptyImage(size = 4096): Bytes {
    const out = new Uint8Array(size).fill(0xff)
    out.set([0xa7, 0xfe, 0x00, 0x00, 0x57, 0x01])
    return out
  }

  static emptyImageChecked(size: number): Bytes {
    if (size !== AssistantComposer.memorySize) throw new AssistantError({ kind: 'badMemorySize', size })
    return AssistantComposer.emptyImage(size)
  }

  /** Bytes an image needs: code, the ID directory (framework + assistants) and the 4-byte checksum. */
  bytesNeeded(code: Bytes): number { return code.length + 2 * this.allPackages.length + 4 }

  /**
   * Applies a successful build to a configuration: the battery preset an assistant selected (`BatteryType_VEC`,
   * through `batteryPreset`), then the settings changed by the assistants (clamped to the device range), then the
   * new program image. Returns a new configuration; throws when the build failed or the program does not fit.
   */
  apply(
    result: AssistantBuildResult,
    config: DeviceConfiguration,
    extraChanges: Map<string, Value> = new Map(),
    batteryPreset?: (preset: number, config: DeviceConfiguration) => void,
  ): { config: DeviceConfiguration; batteryType: number | undefined } {
    if (!result.success) {
      const m = result.messages.find((x) => x.kind === 'fatal' || x.kind === 'error')
      throw new AssistantError({ kind: 'buildFailed', message: m?.text ?? '' })
    }
    const size = config.data.assistantMemory.length
    const memory = this.items.length === 0 ? AssistantComposer.emptyImageChecked(size) : this.image(result.code, size)
    const c = config.clone()
    const targets = vecTargets(config)
    const changes = new Map(extraChanges)
    for (const [k, v] of result.vecChanges) changes.set(k, v)
    let battery: number | undefined
    const b = changes.get('BatteryType_VEC')
    if (b?.t === 'int') {
      battery = b.v
      if (b.v > 0) batteryPreset?.(b.v, c)
    }
    for (const [name, value] of changes) {
      const target = targets.get(name)
      if (value.t !== 'int' || !target) continue
      if (target.k === 'setting') {
        const info = c.info.info(target.id)
        if (!info) continue
        c.setRaw(target.id, Math.min(Math.max(value.v, info.minRaw), info.maxRaw))
      } else {
        c.setFlag(target.n, value.v !== 0)
      }
    }
    c.data.assistantMemory = memory
    return { config: c, batteryType: battery }
  }

  /**
   * `_VEC` settings an assistant declares it changes (`AddVECSettingToChange` / `ChangeVECSetting` in its source),
   * in source order. Removing the assistant leaves them at the values it set.
   */
  static managedSettings(pkg: AssistantPackage): string[] {
    const source = pkg.source?.bytes
    if (!source) return []
    const out: string[] = []
    for (const raw of splitNonEmpty(source, 0x0a)) {
      const line = latin1Decode(raw).replace(/^[\s\u0085]+|[\s\u0085]+$/g, '')
      for (const macro of ['AddVECSettingToChange ', 'ChangeVECSetting ']) {
        if (line.slice(0, macro.length).toLowerCase() !== macro.toLowerCase()) continue
        const rest = line.slice(macro.length)
        const m = /^[^,\s\u0085]*/.exec(rest)!
        const name = m[0]
        if (name.endsWith('_VEC') && !out.includes(name)) out.push(name)
      }
    }
    return out
  }

  /** Starts the wizard of one assistant (state 5); the others replay their stored answers. */
  wizard(assistant: string): AssistantWizard { return new AssistantWizard(this, assistant) }

  // MARK: Device image

  /**
   * Assistant IDs stored at the top of an image, read downward until the asfStop package (by name when the library
   * knows the ID, else the historical 0x000E), an erased word, or 64 entries.
   */
  static installedIDs(image: Bytes, library?: AssistantLibrary, trailer = 4): number[] {
    const ids: number[] = []
    let p = image.length - trailer - 2
    while (p >= 0) {
      const id = image[p]! | (image[p + 1]! << 8)
      if (id === 0xffff) break
      ids.push(id)
      p -= 2
      const pkg = library?.package(id)
      const isStop = library ? (pkg ? pkg.baseName === 'asfStop' : id === 0x000e) : id === 0x000e
      if (isStop || ids.length > 64) break
    }
    return ids
  }

  /** Fills the composer from an image's ID directory (top-down: asfStart, assistants…, asfStop). */
  load(image: Bytes): void {
    const ids = AssistantComposer.installedIDs(image, this.library)
    if (ids.length < 2) { this.items = []; return }
    const s = this.library.package(ids[0]!), e = this.library.package(ids[ids.length - 1]!)
    if (!s || !e) throw new AssistantError({ kind: 'unknownAssistant', id: ids[0]! })
    this.framework = { start: s, stop: e }
    this.items = ids.slice(1, -1).map((id) => {
      const p = this.library.package(id)
      if (!p) throw new AssistantError({ kind: 'unknownAssistant', id })
      return composerItem(p)
    })
  }

  /**
   * Recovers the user's answers from a device image (state 2) and checks the code re-assembles identically.
   * Port of FUN_00515ccc: on a 2614 model (0xA36) that does not read back, try again with `cDeviceInfo xor 3`.
   */
  reconstruct(image: Bytes): AssistantBuildResult {
    this.load(image)
    if (AssistantComposer.installedIDs(image, this.library).length < 2) {
      this.answers = new Map()
      return { success: true, code: new Uint8Array(), messages: [], answers: new Map(), cancelled: false, vecChanges: new Map(), steps: [] }
    }
    const first = this.readBack(image)
    const mv = swiftInt(equValue('cMultiVersion', this.meta) ?? '')
    const infoText = equValue('cDeviceInfo', this.meta)
    const info = infoText !== undefined ? swiftInt(infoText) : undefined
    if (first.success || mv === undefined || Math.trunc(mv / 1000) !== 0xa36 || info === undefined || info > 2147483647 || info < -2147483648) return first
    const original = this.meta
    this.meta = replacingEqu('cDeviceInfo', String((info ^ 3) | 0), this.meta)
    const second = this.readBack(image)
    this.meta = original
    return second.success ? second : first
  }

  private readBack(image: Bytes): AssistantBuildResult {
    const a = this.assembler(() => AssemblerState.backReadBuild)
    a.states.set('META', AssemblerState.build)
    a.tables = new Map()
    a.referenceBinary = image
    const ok = a.assemble(this.root())
    const result: AssistantBuildResult = {
      success: ok, code: a.code, messages: [...a.messages], answers: cloneTables(a.tables), cancelled: false, vecChanges: new Map(), steps: [],
    }
    if (ok) {
      const code = a.code
      const device = AssistantComposer.trimmed(image, code.length, 4 + 2 * this.allPackages.length)
      if (!equalBytes(device, AssistantComposer.trimmed(code, code.length))) {
        let first = Math.min(device.length, code.length)
        for (let i = 0; i < Math.min(device.length, code.length); i++) if (device[i] !== code[i]) { first = i; break }
        result.success = false
        result.messages.push({ kind: 'error', text: `The reconstructed binary does not match! First difference is located at 0x${first.toString(16).toUpperCase()}`, position: '' })
      } else {
        this.answers = a.tables
      }
    }
    return result
  }

  /**
   * The code part of a program for comparison: the ID directory and checksum (`trailer` bytes) removed, at most
   * 16 bytes past the code, without the trailing erased (0xFF) bytes.
   */
  static trimmed(b: Bytes, codeLength: number, trailer = 0): Bytes {
    let x = b.subarray(0, Math.max(b.length - trailer, 0))
    x = x.subarray(0, Math.max(codeLength, 0) + 16)
    let n = x.length
    while (n > 0 && x[n - 1] === 0xff) n--
    return x.slice(0, n)
  }

  /** Image checksum (VEConfig FUN_00510494): Σ((bᵢ xor 0xFF) << 8·(i mod 4)) − 1 over all bytes but the last 4. */
  static checksum(bytes: Bytes): number {
    let sum = 0
    for (let i = 0; i < bytes.length; i++) sum = (sum + (((bytes[i]! ^ 0xff) << (8 * (i % 4))) >>> 0)) >>> 0
    return (sum - 1) >>> 0
  }

  /**
   * Complete device image: code, 0xFF padding, IDs (asfStop lowest … asfStart highest), 4-byte checksum.
   * Throws unless `size` is the 4096-byte assistant memory and everything fits in it.
   */
  image(code: Bytes, size = AssistantComposer.memorySize): Bytes {
    if (size !== AssistantComposer.memorySize) throw new AssistantError({ kind: 'badMemorySize', size })
    const needed = this.bytesNeeded(code)
    if (needed > size) throw new AssistantError({ kind: 'imageTooLarge', needed, size })
    const img = new Uint8Array(size).fill(0xff)
    img.set(code)
    let p = size - 4
    for (const pkg of this.allPackages) {
      p -= 2
      img[p] = pkg.id & 0xff
      img[p + 1] = (pkg.id >>> 8) & 0xff
    }
    const c = AssistantComposer.checksum(img.subarray(0, size - 4))
    for (let k = 0; k < 4; k++) img[size - 4 + k] = (c >>> (8 * k)) & 0xff
    return img
  }
}

function equalBytes(a: Bytes, b: Bytes): boolean {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

function splitNonEmpty(b: Bytes, sep: number): Bytes[] {
  const out: Bytes[] = []
  let start = 0
  for (let i = 0; i <= b.length; i++) {
    if (i === b.length || b[i] === sep) {
      if (i > start) out.push(b.subarray(start, i))
      start = i + 1
    }
  }
  return out
}

export type WizardStatus =
  | { k: 'step'; step: AssistantStepPresentation }
  | { k: 'finished'; result: AssistantBuildResult }
  | { k: 'failed'; messages: AssemblerMessage[] }
  | { k: 'cancelled' }

/**
 * One run of an assistant's wizard (driver FUN_00500bec, docs/re/03-assembler.md §11.7).
 *
 * Like VE Configure, the assembly is one continuous run that pauses at each step shown: whatever the sources do once
 * a step is handled (`$AUEHandled`, `.ALS`, `_VEC` settings) happens exactly once, with the user's answer. Only
 * Previous (and a source's `.RESTART`) restarts the assembly from scratch, replaying the earlier steps.
 *
 * The calls are synchronous: `next`/`previous` return once the following step is shown or the wizard has ended.
 * After a cancel, finish or failure the wizard ignores further calls.
 */
export class AssistantWizard {
  status: WizardStatus
  private readonly session: Generator<AssistantStepPresentation, WizardStatus, AssistantDecision>

  constructor(readonly composer: AssistantComposer, readonly assistant: string) {
    this.session = AssistantWizard.drive(composer, assistant)
    this.status = this.resume(undefined)
  }

  /** A step is shown and waits for an answer. */
  get isWaiting(): boolean { return this.status.k === 'step' }

  next(values: number[]): void { this.answer({ k: 'next', values }) }
  previous(): void { this.answer({ k: 'previous' }) }
  cancel(): void {
    if (!this.isWaiting) return
    this.resume({ k: 'cancel' })
    this.status = { k: 'cancelled' }
  }

  private answer(d: AssistantDecision): void {
    if (!this.isWaiting) return
    this.status = this.resume(d)
  }

  private resume(d: AssistantDecision | undefined): WizardStatus {
    const r = d === undefined ? this.session.next() : this.session.next(d)
    if (!r.done) return { k: 'step', step: r.value }
    if (r.value.k === 'finished') this.composer.answers = cloneTables(r.value.result.answers)
    return r.value
  }

  /** The assembly loop, restarted on stepback. */
  private static *drive(composer: AssistantComposer, assistant: string): Generator<AssistantStepPresentation, WizardStatus, AssistantDecision> {
    let displayStep = 1
    let backList: Value[] = []
    let tables = cloneTables(composer.answers)
    for (let i = 0; i < 1024; i++) {
      const a = composer.assembler((n) => (n === assistant ? AssemblerState.userEntry : AssemblerState.build))
      a.tables = tables
      a.displayStep = displayStep
      a.backStepList = backList
      a.interactive = true
      const ok = yield* a.assembleSteps(composer.root())
      a.captureDriverState()
      displayStep = a.displayStep
      backList = a.backStepList
      tables = a.tables
      if (ok) {
        return {
          k: 'finished',
          result: {
            success: true, code: a.code, messages: a.messages, answers: cloneTables(tables), cancelled: false,
            vecChanges: AssistantComposer.vecChanges(composer.meta, a), steps: a.stepLog,
          },
        }
      }
      if (a.cancelled) return { k: 'cancelled' }
      if (a.messages.find((m) => m.kind === 'fatal')?.text === AssistantAssembler.restartMessage) continue
      return { k: 'failed', messages: a.messages }
    }
    return { k: 'failed', messages: [{ kind: 'fatal', text: 'Wizard did not converge', position: '' }] }
  }
}
