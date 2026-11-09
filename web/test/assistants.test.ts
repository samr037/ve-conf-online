// Ported from Tests/VEKitTests/AssemblerTests.swift (end-to-end, wizard content, library-wide),
// AssistantImageTests.swift, AssistantWizardTests.swift and WizardHardeningTests.swift.
import { existsSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { AssistantLibrary } from '../src/lib/engine/assistantPackage'
import { DeviceConfiguration } from '../src/lib/engine/deviceConfiguration'
import { settingNamed } from '../src/lib/engine/settingNames'
import {
  AssistantComposer, MetaGenerator, WizardStepContent, WizardText, composerItem, fieldDisplay, fieldParse,
  vInt, vStr, type AssistantBuildResult, type AssistantStepDefinition, type AssistantWizard, type StepField,
} from '../src/lib/engine/assembler'
import { bytes, expected, hasExpected, hasLibrary, libraryPath, samplePath } from './fixtures'

const hasSamples = ['s1', 's2', 's5'].every((s) => existsSync(samplePath(s)))
const lib = hasLibrary ? AssistantLibrary.parse(bytes(libraryPath)) : undefined
const library = () => lib!
const sampleConfig = (name: string) => DeviceConfiguration.parse(bytes(samplePath(name)))
const batteryCapacityID = settingNamed('eestBatteryCapacity')!
const pkgNamed = (n: string) => library().latest.find((p) => p.baseName === n)!

/** A composer holding a configuration's assistants (reconstructed from its program). */
function reconstructedComposer(c: DeviceConfiguration): AssistantComposer {
  const composer = new AssistantComposer(library())
  composer.meta = MetaGenerator.metaSource(c)
  const r = composer.reconstruct(c.data.assistantMemory)
  expect(r.success, JSON.stringify(r.messages)).toBe(true)
  return composer
}

/** Walks a wizard answering Next with the shown values, or `answers[label]` where given. */
function walkWizard(w: AssistantWizard, answers: Record<string, number> = {}, limit = 300): [AssistantBuildResult | undefined, string[]] {
  const trail: string[] = []
  while (trail.length < limit) {
    const s = w.status
    if (s.k === 'step') {
      trail.push(s.step.step.id)
      const v = [...s.step.values]
      s.step.labels.forEach((l, i) => { if (answers[l] !== undefined) v[i] = answers[l]! })
      w.next(v)
    } else if (s.k === 'finished') return [s.result, trail]
    else return [undefined, trail]
  }
  return [undefined, trail]
}

const answerValues = (c: AssistantComposer, a: string) =>
  Object.fromEntries([...(c.answers.get(a)?.answers ?? new Map())].map(([k, v]) => [k, v.value]))

const memory = (c: DeviceConfiguration) => Array.from(c.data.assistantMemory)

describe.runIf(hasLibrary && hasSamples && hasExpected)('AssistantEndToEndTests', () => {
  for (const name of ['s2', 's5']) {
    it(`reconstruct and rebuild byte-identical (${name})`, () => {
      const config = sampleConfig(name)
      const composer = new AssistantComposer(library())
      composer.meta = MetaGenerator.metaSource(config)
      const r = composer.reconstruct(config.data.assistantMemory)
      expect(r.success).toBe(true)
      const e = expected(name)
      expect(composer.items.map((i) => i.package.id)).toEqual(e.assistants)
      expect(composer.answers.get('ESS')?.answers.get('alSystem')?.value).toBe(e.alSystem)
      const b = composer.build()
      expect(b.success).toBe(true)
      expect(Array.from(composer.image(b.code))).toEqual(memory(config))
    })
  }

  it('image checksum matches device', () => {
    for (const name of ['s1', 's2', 's4', 's5']) {
      if (!existsSync(samplePath(name))) continue
      const mem = sampleConfig(name).data.assistantMemory
      const stored = (mem[4092]! | (mem[4093]! << 8) | (mem[4094]! << 16) | (mem[4095]! << 24)) >>> 0
      expect(AssistantComposer.checksum(mem.subarray(0, 4092))).toBe(stored)
    }
  })
})

describe.runIf(hasLibrary)('WizardContentTests', () => {
  it('ESS steps', () => {
    const ess = library().latest.find((p) => p.baseName === 'ESS')!
    const text = new WizardText(ess.scripts.get('en')!.bytes)
    const radio: AssistantStepDefinition = {
      id: 'aidSystem', stepName: 'System', kind: 'R', inSummary: true, buttons: 6,
      fields: [{ precision: { k: 'decimals', d: 0 }, unitCode: 'N', min: 0, max: 5, defaultValue: 0 }],
    }
    const r = new WizardStepContent(radio, text, [])
    expect(r.title).toBe('Battery system')
    expect(r.options.length).toBe(6)
    expect(r.options[4]!.length).toBe(2) // option with a continuation line
    const entry: AssistantStepDefinition = {
      id: 'aidCap', stepName: 'Capacity', kind: 'E', inSummary: true, buttons: 0,
      fields: [{ precision: { k: 'decimals', d: 0 }, unitCode: 'N', min: 0, max: 60000, defaultValue: 200 }],
    }
    const e = new WizardStepContent(entry, text, [])
    expect(e.entry[0]).toContainEqual({ k: 'field', index: 0, items: undefined })
  })
})

describe('WizardContent format and fields', () => {
  it('format and codes', () => {
    const s = WizardStepContent.format('See the %0:sESS manual%1:s now', [vStr('\\IS\\'), vStr('\\IL:http://ve3.nl/ess\\')])
    const runs = WizardStepContent.runs(s)
    expect(runs.map((r) => r.text).join('')).toBe('See the ESS manual now')
    expect(runs.find((r) => r.text === 'ESS manual')?.link).toBe('http://ve3.nl/ess')
    expect(WizardStepContent.runs('\\FS:1\\Note:\\FS:0\\ text')[0]?.bold).toBe(true)
  })

  it('field display', () => {
    const f: StepField = { precision: { k: 'decimals', d: 2 }, unitCode: 'B', min: 0, max: 6000, defaultValue: 4600 }
    expect(fieldParse(f, '46,5')).toBe(4650)
    expect(fieldParse(f, '99')).toBe(6000)
    const t: StepField = { precision: { k: 'time' }, unitCode: 'N', min: 0, max: 1439, defaultValue: 60 }
    expect(fieldDisplay(t, 75)).toBe('01:15')
    expect(fieldParse(t, '02:30')).toBe(150)
  })
})

describe('WizardFormatTests', () => {
  const args = [vInt(255), vStr('ab'), vInt(-3)]
  const f = (s: string) => WizardStepContent.format(s, args)

  it('indexes and sequential arguments', () => {
    expect(f('%0:s %1:s')).toBe('255 ab')
    expect(f('%s|%s|%s|%s')).toBe('255|ab|-3|')
    expect(f('%1:s %s')).toBe('ab -3')
    expect(f('%2:d %s')).toBe('-3 ')
    expect(f('100% sure')).toBe('100% sure')
    expect(f('50%%')).toBe('50%')
  })

  it('width, precision and types', () => {
    expect(f('[%5d]')).toBe('[  255]')
    expect(f('[%-5s]')).toBe('[255  ]')
    expect(f('[%1:-4s]')).toBe('[ab  ]')
    expect(f('[%0:5s]')).toBe('[  255]')
    expect(f('%0:x')).toBe('FF')
    expect(f('%0:.4x')).toBe('00FF')
    expect(f('%2:.3d')).toBe('-003')
    expect(f('%2:u')).toBe('4294967293')
    expect(f('%1:.1s')).toBe('a')
    expect(f('[%*d]')).toBe('[' + ' '.repeat(253) + 'ab]')
    expect(WizardStepContent.format('%0:.2f', [vInt(3)]).startsWith('3')).toBe(true)
    expect(WizardStepContent.format('%0:.0n', [vInt(3)])).toBe('3')
    expect(f('%1:k')).toBe('ab')
  })

  it('hostile specifiers do not crash', () => {
    expect(WizardStepContent.format('%9223372036854775807:s', [vInt(1)])).toBe('%9223372036854775807:s')
    expect(WizardStepContent.format('%99999999999999999999999d', [vInt(1)]).startsWith('%')).toBe(true)
    expect(WizardStepContent.format('%2147483647:s', [vInt(1)])).toBe('')
    expect(WizardStepContent.format('%2147483647d', [vInt(1)]).length).toBe(4096)
    expect(WizardStepContent.format('%0:.2147483647d', [vInt(1)]).length).toBe(64)
    expect(f('%q %')).toBe('%q %')
  })

  it('generic inserts its text unformatted', () => {
    const step: AssistantStepDefinition = { id: 'x', stepName: 'Generic', kind: 'E', inSummary: false, fields: [], buttons: 0 }
    const c = new WizardStepContent(step, undefined, [vStr('%1:s'), vStr('LEAK'), vStr('Title %0:s')])
    expect(c.title).toBe('Title %1:s')
  })
})

describe('WizardFieldTests', () => {
  const dec: StepField = { precision: { k: 'decimals', d: 1 }, unitCode: 'N', min: 0, max: 100000, defaultValue: 0 }
  const time: StepField = { precision: { k: 'time' }, unitCode: 'N', min: -1439, max: 1439, defaultValue: 0 }

  it('non-finite and non-numbers are rejected', () => {
    const f: StepField = { precision: { k: 'decimals', d: 2 }, unitCode: 'N', min: 0, max: 100, defaultValue: 0 }
    for (const t of ['nan', 'NaN', 'inf', '-infinity', '0x10', '1e3', '', '-', '.', '1,2,3.4.5', '12abc']) {
      expect(fieldParse(f, t), t).toBeUndefined()
    }
    const l: StepField = { precision: { k: 'list' }, unitCode: 'N', min: 0, max: 5, defaultValue: 0 }
    expect(fieldParse(l, 'nan')).toBeUndefined()
    expect(fieldParse(l, '3')).toBe(3)
  })

  it('display has no grouping and reads back', () => {
    for (const locale of ['en-US', 'fr-FR', 'de-DE']) {
      const shown = fieldDisplay(dec, 12345, locale)
      expect(/^[0-9.,]+$/.test(shown), shown).toBe(true)
      expect(fieldParse(dec, shown)).toBe(12345)
    }
  })

  it('parse tolerates grouping and both decimal marks', () => {
    expect(fieldParse(dec, '1 234,5')).toBe(12345)
    expect(fieldParse(dec, '1\u00a0234,5')).toBe(12345)
    expect(fieldParse(dec, '1\u202f234.5')).toBe(12345)
    expect(fieldParse(dec, '1,234.5')).toBe(12345)
    expect(fieldParse(dec, '1.234,5')).toBe(12345)
    expect(fieldParse(dec, "1'234.5")).toBe(12345)
    expect(fieldParse(dec, ' 46,5 ')).toBe(465)
    expect(fieldParse(dec, '99999999999999999999')).toBe(100000)
  })

  it('times are signed and overflow safe', () => {
    expect(fieldDisplay(time, -1)).toBe('-00:01')
    expect(fieldDisplay(time, -90)).toBe('-01:30')
    expect(fieldDisplay(time, 75)).toBe('01:15')
    expect(fieldParse(time, '-1:30')).toBe(-90)
    expect(fieldParse(time, '-0:30')).toBe(-30)
    expect(fieldParse(time, '1:30')).toBe(90)
    expect(fieldParse(time, fieldDisplay(time, -1))).toBe(-1)
    expect(fieldParse(time, '300000000000000000:00')).toBe(1439)
    expect(fieldParse(time, '99999999999999999999999:00')).toBe(1439)
    expect(fieldParse(time, '1:-30')).toBeUndefined()
    expect(fieldParse(time, 'nan:00')).toBeUndefined()
    expect(fieldParse(time, '1:2:3')).toBeUndefined()
  })
})

describe.runIf(hasLibrary && hasSamples)('AssistantImageFixTests', () => {
  it('oversize image throws', () => {
    const c = new AssistantComposer(library())
    c.items = [composerItem(pkgNamed('ESS'))]
    const room = 4096 - 4 - 2 * 3
    expect(() => c.image(new Uint8Array(room + 1).fill(0x11))).toThrow()
    expect(() => c.image(new Uint8Array(5000).fill(0x11))).toThrow()
    expect(() => c.image(new Uint8Array([0x11]), 2048)).toThrow()
    const full = c.image(new Uint8Array(room).fill(0x11))
    expect(full.length).toBe(4096)
    const ids = [c.framework.stop.id, c.items[0]!.package.id, c.framework.start.id]
    expect(Array.from(full.subarray(room, room + 6))).toEqual(ids.flatMap((id) => [id & 0xff, id >> 8]))
    expect(AssistantComposer.installedIDs(full, library())).toEqual([...ids].reverse())
  })

  it('apply refuses a failed build and bad memory', () => {
    const s5 = sampleConfig('s5')
    const c = reconstructedComposer(s5)
    const b = { ...c.build(), success: false }
    expect(() => c.apply(b, s5)).toThrow()
    const small = s5.clone()
    small.data.assistantMemory = new Uint8Array(100).fill(0xff)
    expect(() => c.apply(c.build(), small)).toThrow()
  })

  for (const slack of [0, 4, 10, 15, 16, 20]) {
    it(`nearly full memory trims the directory (slack ${slack})`, () => {
      const c = new AssistantComposer(library())
      c.items = [composerItem(pkgNamed('ESS'))]
      const trailer = 4 + 2 * 3
      const code = new Uint8Array(4096 - trailer - slack).fill(0x11)
      const img = c.image(code)
      expect(Array.from(AssistantComposer.trimmed(img, code.length, trailer))).toEqual(Array.from(code))
      expect(Array.from(AssistantComposer.trimmed(code, code.length))).toEqual(Array.from(code))
    })
  }

  it('empty and stub memory reconstruct empty', () => {
    for (const mem of [new Uint8Array(4096).fill(0xff), AssistantComposer.emptyImage()]) {
      const c = new AssistantComposer(library())
      const r = c.reconstruct(mem)
      expect(r.success).toBe(true)
      expect(c.items).toEqual([])
      expect(r.code.length).toBe(0)
    }
    const s1 = sampleConfig('s1')
    const c = new AssistantComposer(library())
    c.meta = MetaGenerator.metaSource(s1)
    const r = c.reconstruct(s1.data.assistantMemory)
    expect(r.success).toBe(true)
    expect(c.items).toEqual([])
  })

  it.runIf(hasExpected)('ID list stops at the stop package', () => {
    expect(AssistantComposer.installedIDs(sampleConfig('s5').data.assistantMemory, library())).toEqual(expected('s5').installedIDs)
  })
})

describe.runIf(hasLibrary && hasSamples)('AssistantMetaFixTests', () => {
  it('battery type in META', () => {
    expect(MetaGenerator.metaLines(sampleConfig('s5'), true, 2)).toContain('BatteryType_VEC .SET 2,4,true')
  })

  it('META .EQU edit', () => {
    const meta = MetaGenerator.metaSource(sampleConfig('s5'))
    const info = MetaGenerator.equValue('cDeviceInfo', meta)!
    expect(info).toBeDefined()
    const edited = MetaGenerator.replacingEqu('cDeviceInfo', '99', meta)
    expect(MetaGenerator.equValue('cDeviceInfo', edited)).toBe('99')
    expect(Array.from(MetaGenerator.replacingEqu('cDeviceInfo', info, edited))).toEqual(Array.from(meta))
    expect(MetaGenerator.replacingEqu('NoSuchLabel', '1', meta)).toBe(meta)
  })

  it('battery preset hook runs before VEC changes', () => {
    const s5 = sampleConfig('s5')
    const c = reconstructedComposer(s5)
    const b = c.build()
    const order: string[] = []
    const { config: out, batteryType } = c.apply(b, s5, new Map([['BatteryType_VEC', vInt(1)], ['eestBatteryCapacity_VEC', vInt(321)]]), (preset, cfg) => {
      order.push(`preset ${preset}`)
      cfg.setRaw(batteryCapacityID, 5)
    })
    expect(order).toEqual(['preset 1'])
    expect(batteryType).toBe(1)
    expect(out.raw(batteryCapacityID)).toBe(321)
  })

  it('ESS managed settings', () => {
    expect(AssistantComposer.managedSettings(pkgNamed('ESS'))).toEqual(['eestBatteryCapacity_VEC', '_AssistEnabled_VEC',
      '_LithiumBattery_VEC', '_TakeGeneratorDelayIntoAccount_VEC', '_EnableReducedFloat_VEC'])
  })
})

describe.runIf(hasLibrary && hasSamples)('AssistantWizardFixTests', () => {
  it('ESS capacity reaches the configuration', () => {
    const s5 = sampleConfig('s5')
    const c = reconstructedComposer(s5)
    expect(c.answers.get('ESS')?.answers.get('alBatteryCapacity')?.value).not.toBe(200)
    const [r] = walkWizard(c.wizard('ESS'), { alBatteryCapacity: 200 })
    expect(r).toBeDefined()
    expect(c.answers.get('ESS')?.answers.get('alBatteryCapacity')?.value).toBe(200)
    expect(r!.vecChanges.get('eestBatteryCapacity_VEC')).toEqual(vInt(200))
    const b = c.build()
    expect(b.success).toBe(true)
    expect(c.apply(b, s5, r!.vecChanges).config.raw(batteryCapacityID)).toBe(200)
  })

  it('new ESS on s1 like s2', () => {
    const s1 = sampleConfig('s1'), s2 = sampleConfig('s2')
    const answers = answerValues(reconstructedComposer(s2), 'ESS')
    const c = new AssistantComposer(library())
    c.meta = MetaGenerator.metaSource(s1)
    c.items = [composerItem(pkgNamed('ESS'))]
    const [r] = walkWizard(c.wizard('ESS'), answers)
    expect(r).toBeDefined()
    expect(c.answers.get('ESS')?.answers.get('alBatteryCapacity')?.value).toBe(answers.alBatteryCapacity)
    const b = c.build()
    expect(b.success).toBe(true)
    const out = c.apply(b, s1, r!.vecChanges).config
    expect(out.raw(batteryCapacityID)).toBe(s2.raw(batteryCapacityID))
  })

  it('lead to lithium gets the lithium cut-off curve', () => {
    const s1 = sampleConfig('s1')
    const c = new AssistantComposer(library())
    c.meta = MetaGenerator.metaSource(s1)
    c.items = [composerItem(pkgNamed('ESS'))]
    const [first] = walkWizard(c.wizard('ESS'), { alSystem: 0 })
    expect(first).toBeDefined()
    const curve = () => ['alDC0', 'alDC1', 'alDC2', 'alDC3'].map((k) => c.answers.get('ESS')?.answers.get(k)?.value)
    expect(curve()).toEqual([4800, 4500, 4220, 4000])
    let shownCurve: number[] = []
    const w = c.wizard('ESS')
    for (let n = 0; n < 60 && w.status.k === 'step'; n++) {
      const p = w.status.step
      let v = p.values
      if (p.step.id === 'aidSystem') v = [4]
      if (p.labels.includes('alDC0')) shownCurve = p.values
      w.next(v)
    }
    expect(w.status.k).toBe('finished')
    expect(curve()).toEqual([5200, 5000, 4920, 4800])
    expect(shownCurve.length === 0 || shownCurve.join() === [5200, 5000, 4920, 4800].join()).toBe(true)
  })

  it('replay without changes is identical', () => {
    const s5 = sampleConfig('s5')
    const c = reconstructedComposer(s5)
    const before = answerValues(c, 'ESS')
    const [r, trail] = walkWizard(c.wizard('ESS'))
    expect(r).toBeDefined()
    expect(trail.length).toBeGreaterThan(3)
    expect(answerValues(c, 'ESS')).toEqual(before)
    expect(Array.from(c.image(c.build().code))).toEqual(memory(s5))
    expect(Array.from(c.image(r!.code))).toEqual(memory(s5))
  })

  it('previous then next completes', () => {
    const s5 = sampleConfig('s5')
    const c = reconstructedComposer(s5)
    const w = c.wizard('ESS')
    const seen: string[] = []
    let backs = 0
    while (seen.length < 100 && w.status.k === 'step') {
      const p = w.status.step
      seen.push(p.step.id)
      if (seen.length === 3 && backs === 0) {
        backs = 1
        w.previous()
        expect(w.status.k).toBe('step')
        if (w.status.k === 'step') expect(w.status.step.step.id).toBe(seen[1])
        continue
      }
      w.next(p.values)
    }
    expect(w.status.k).toBe('finished')
    if (w.status.k === 'finished') expect(Array.from(c.image(w.status.result.code))).toEqual(memory(s5))
  })

  it('cancelled wizard ignores next; answers untouched', () => {
    const s5 = sampleConfig('s5')
    const c = reconstructedComposer(s5)
    const before = JSON.stringify([...c.answers.get('ESS')!.answers])
    const w = c.wizard('ESS')
    let last: number[] = []
    for (let i = 0; i < 3; i++) if (w.status.k === 'step') { last = w.status.step.values; w.next(last) }
    w.cancel()
    expect(w.status.k).toBe('cancelled')
    w.next(last)
    w.previous()
    expect(w.status.k).toBe('cancelled')
    expect(JSON.stringify([...c.answers.get('ESS')!.answers])).toBe(before)
  })

  it('finished wizard ignores next', () => {
    const c = reconstructedComposer(sampleConfig('s5'))
    const w = c.wizard('ESS')
    walkWizard(w)
    expect(w.status.k).toBe('finished')
    w.next([1]); w.previous(); w.cancel()
    expect(w.status.k).toBe('finished')
  })

  it('abandoned wizard does not hang', () => {
    const c = reconstructedComposer(sampleConfig('s5'))
    for (let i = 0; i < 3; i++) {
      const w = c.wizard('ESS')
      if (w.status.k === 'step') w.next(w.status.step.values)
    }
    expect(walkWizard(c.wizard('ESS'))[0]).toBeDefined()
  })
})

describe.runIf(hasLibrary && hasSamples)('LibraryWideTests', () => {
  /** Every assistant assembles with its default answers on a sample device, and reads back to the same program. */
  it('every assistant assembles and reads back', () => {
    const config = sampleConfig('s5')
    const report: string[] = []
    for (const p of library().latest) {
      if (p.baseName === 'asfStart' || p.baseName === 'asfStop') continue
      const c = new AssistantComposer(library())
      c.meta = MetaGenerator.metaSource(config)
      c.items = [composerItem(p)]
      const b = c.build()
      if (p.baseName === 'Microgrid enabler' && b.messages.some((m) => m.text.includes('does not support Microgrid'))) continue
      if (!b.success) {
        report.push(`${p.baseName}: build — ${b.messages.find((m) => m.kind === 'fatal' || m.kind === 'error')?.text ?? '?'}`)
        continue
      }
      const back = new AssistantComposer(library())
      back.meta = c.meta
      const r = back.reconstruct(c.image(b.code))
      if (!r.success) report.push(`${p.baseName}: readback — ${r.messages.find((m) => m.kind !== 'message')?.text ?? '?'}`)
    }
    expect(report).toEqual([])
  })
})
