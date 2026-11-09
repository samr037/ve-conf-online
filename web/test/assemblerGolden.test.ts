// The assembler, composer and wizard against the Swift reference (web/fixtures/golden, `swift run vegolden`).
import { describe, expect, it } from 'vitest'
import { AssistantLibrary } from '../src/lib/engine/assistantPackage'
import { DeviceConfiguration } from '../src/lib/engine/deviceConfiguration'
import {
  AssistantComposer, MetaGenerator,
  type AnswerTable, type AssemblerMessage, type AssistantBuildResult, type AssistantStepDefinition,
  type AssistantStepPresentation, type Value,
} from '../src/lib/engine/assembler'
import { bytes, golden, hasGolden, hasLibrary, hex, libraryPath, samplePath, samples } from './fixtures'
import { existsSync } from 'node:fs'
import { latin1Decode } from '../src/lib/engine/binary'

// MARK: encoding like Sources/vegolden/main.swift

export function jValue(v: Value): unknown {
  switch (v.t) {
    case 'int': return { int: v.v }
    case 'bool': return { bool: v.v }
    case 'string': return { string: hex(v.v) }
    case 'list': return { list: v.v.map(jValue) }
  }
}
const jMessage = (m: AssemblerMessage) => ({ kind: m.kind, text: m.text, position: m.position })
const jStep = (s: AssistantStepDefinition) => ({
  id: s.id, stepName: s.stepName, kind: s.kind, inSummary: s.inSummary, buttons: s.buttons,
  fields: s.fields.map((f) => ({
    precision: f.precision.k === 'decimals' ? { decimals: f.precision.d } : f.precision.k,
    unitCode: f.unitCode, min: f.min, max: f.max, default: f.defaultValue,
  })),
})
const mapObj = <V, R>(m: Map<string, V>, f: (v: V) => R) => Object.fromEntries([...m].map(([k, v]) => [k, f(v)]))
const jTable = (t: AnswerTable) => ({
  order: t.order,
  answers: mapObj(t.answers, (a) => ({ value: a.value, previous: a.previous, hasALD: a.hasALD, confirmed: a.confirmed })),
  steps: mapObj(t.steps, jStep),
})
export const jPresentation = (p: AssistantStepPresentation) => ({
  assistant: p.assistant, step: jStep(p.step), labels: p.labels, values: p.values,
  format: p.format.map(jValue), buttons: p.buttons, isFirst: p.isFirst,
})
export const jResult = (r: AssistantBuildResult) => ({
  success: r.success, cancelled: r.cancelled, code: hex(r.code), messages: r.messages.map(jMessage),
  answers: mapObj(r.answers, jTable), vecChanges: mapObj(r.vecChanges, jValue), steps: r.steps.map(jPresentation),
})

const library = hasLibrary ? AssistantLibrary.parse(bytes(libraryPath)) : undefined
const available = (n: string) => existsSync(samplePath(n))

describe.runIf(hasGolden && hasLibrary)('samples: META, reconstruction and rebuild match Swift', () => {
  for (const name of samples) {
    it.runIf(available(name))(name, () => {
      const g = golden(`samples/${name}.json`)
      const lib = library!
      const c = DeviceConfiguration.parse(bytes(samplePath(name)))
      const meta = MetaGenerator.metaSource(c)
      expect(latin1Decode(meta)).toBe(g.meta)
      expect(AssistantComposer.installedIDs(c.data.assistantMemory, lib)).toEqual(g.installedIDs)
      const composer = new AssistantComposer(lib)
      composer.meta = meta
      const r = composer.reconstruct(c.data.assistantMemory)
      expect(jResult(r)).toEqual(g.reconstruct)
      expect(composer.items.map((i) => i.name)).toEqual(g.reconstructItems)
      const b = composer.build()
      expect(jResult(b)).toEqual(g.rebuild)
      if (b.success) {
        const { config, batteryType } = composer.apply(b, c)
        const enc = config.encoded()
        expect(hex(enc)).toBe(g.rebuildApplied.encoded)
        expect(batteryType ?? null).toBe(g.rebuildApplied.batteryType)
        expect(hex(enc) === hex(bytes(samplePath(name)))).toBe(g.rebuildApplied.identical)
      } else {
        expect(g.rebuildApplied).toBeUndefined()
      }
    })
  }
})

interface WalkIndex { walks: { file: string; sample: string; assistant: string; outcome: string; steps: number }[] }
const walks: WalkIndex['walks'] = hasGolden && existsSync(`${import.meta.dirname}/../fixtures/golden/walks/index.json`)
  ? golden<WalkIndex>('walks/index.json').walks : []

describe.runIf(hasGolden && hasLibrary && walks.length > 0)('wizard walks match Swift', () => {
  const configs = new Map<string, DeviceConfiguration>()
  for (const w of walks) {
    it(`${w.sample} ${w.assistant}`, () => {
      const g = golden(w.file)
      const lib = library!
      let c = configs.get(w.sample)
      if (!c) { c = DeviceConfiguration.parse(bytes(samplePath(w.sample))); configs.set(w.sample, c) }
      const pkg = lib.latest.find((p) => p.baseName === w.assistant)!
      expect(pkg.id).toBe(g.id)
      const composer = new AssistantComposer(lib)
      composer.meta = MetaGenerator.metaSource(c)
      composer.items = [{ package: pkg, name: pkg.baseName }]
      const trail: unknown[] = []
      const wiz = composer.wizard(pkg.baseName)
      let outcome: string | undefined
      const doc: Record<string, unknown> = {}
      while (trail.length < 300) {
        const s = wiz.status
        if (s.k === 'step') {
          trail.push(jPresentation(s.step))
          wiz.next(s.step.values)
          continue
        }
        if (s.k === 'finished') {
          outcome = 'finished'
          doc.result = jResult(s.result)
          const b = composer.build()
          doc.build = jResult(b)
          if (b.success) {
            try {
              const { config, batteryType } = composer.apply(b, c, s.result.vecChanges)
              doc.applied = { encoded: hex(config.encoded()), batteryType: batteryType ?? null }
            } catch { /* like Swift's try? */ }
          }
        } else if (s.k === 'failed') {
          outcome = 'failed'
          doc.messages = s.messages.map(jMessage)
        } else outcome = 'cancelled'
        break
      }
      expect(trail).toEqual(g.steps)
      expect(outcome ?? 'limit').toBe(g.outcome)
      if (g.result) expect(doc.result).toEqual(g.result)
      if (g.build) expect(doc.build).toEqual(g.build)
      expect(doc.applied).toEqual(g.applied)
      expect(doc.messages).toEqual(g.messages)
    })
  }
})
