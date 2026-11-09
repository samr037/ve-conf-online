// Editing rules against the Swift app (web/fixtures/golden/rules, from Tests/VEConfigureTests/RulesGoldenExport.swift),
// plus a port of Tests/VEConfigureTests/GridUnlockTests.swift.
import { readFileSync } from 'node:fs'
import { beforeAll, describe, expect, it } from 'vitest'
import { DeviceConfiguration } from '../src/lib/engine/deviceConfiguration'
import { GridPassword } from '../src/lib/engine/gridPassword'
import * as names from '../src/lib/engine/settingNames'
import {
  Access, BatteryPresets, ConfigDocument, Confirmations, GridPages, LocalControls, PageLayout, RowState, SectionPages,
  SessionState, ValueCodec, assistantDirectory, buildCatalog, catalog, cells, changeListLabel, choiceOptions,
  cleanCaption, cleanDescription, cleanGridCode, configureL10n, dcVoltageClass, acVoltageClass, displayUnit, fallbackText,
  formatFlag, gridCodeName, gridTable, isInverterOnly, isInverted, isRow, Labels, labelInConfig, modelName, noteText,
  parseExpr, reflow, reportBlocks, reportText, resolveRawText, resolveText, sectionTitle, sections, settingTargets,
  staticLabel, stripMarkup, targetKey, useCatalog, visibleSections, type Change, type EValue, type GridChoice, type Section,
} from '../src/lib/rules'
import { existsSync } from 'node:fs'
import { bytes, catalogJSONPath, hasRulesGolden, hex, rulesGolden, samplePath, samples } from './fixtures'

// Victron's grid code password is never written in this repository: give it through the environment
// (VE_GRID_PASSWORD) to run the tests that need it. They skip without it.
const gridKey = process.env.VE_GRID_PASSWORD?.trim() ?? ''
const hasKey = gridKey.length === 12
const hasRulesRefs = hasRulesGolden && hasKey

/** JSON-comparable form: numbers to 12 significant digits, undefined → null, Sets sorted. */
function norm(x: unknown): unknown {
  if (x === undefined || x === null) return null
  if (typeof x === 'number') return Number.isFinite(x) ? Number(x.toPrecision(12)) : String(x)
  if (typeof x === 'bigint') return Number(x)
  if (Array.isArray(x)) return x.map(norm)
  if (typeof x === 'object') return Object.fromEntries(Object.entries(x as object).map(([k, v]) => [k, norm(v)]))
  return x
}
const same = (actual: unknown, expected: unknown, msg?: string) => expect(norm(actual), msg).toEqual(norm(expected))

beforeAll(() => {
  useCatalog(buildCatalog(JSON.parse(readFileSync(catalogJSONPath, 'utf8'))))
  if (hasRulesRefs) {
    const g = rulesGolden('catalog.json')
    configureL10n({ language: g.language, locale: g.locale })
  } else {
    configureL10n({ language: 'en', locale: 'en-US' })
  }
})

// MARK: - Mirrors of the Swift generator

function allExpressions(): string[] {
  const cat = catalog()
  const set = new Set<string>()
  for (const r of cat.rules) if (r.expr !== undefined) set.add(r.expr)
  for (const c of cat.controls.values()) {
    for (const e of [...(c.enabledWhen ?? []), ...(c.visibleWhen ?? [])]) set.add(e)
    for (const t of [c.caption, c.label, ...(c.labels ?? []).map((l) => l.text)]) for (const v of t?.variants ?? []) if (v.when !== undefined) set.add(v.when)
    for (const i of c.items ?? []) for (const v of i.runtimeText ?? []) if (v.when !== undefined) set.add(v.when)
  }
  for (const g of cat.groups.values()) for (const e of [...(g.enabledWhen ?? []), ...(g.visibleWhen ?? [])]) set.add(e)
  set.add('raw(ctl.ReactivePowerTypeSettingComboBox)')
  return [...set]
}

function value(v: EValue | undefined): unknown {
  if (!v) return null
  if (v.t === 'number') return { n: Number.isFinite(v.v) ? v.v : String(v.v).toLowerCase().replace('infinity', 'inf') }
  if (v.t === 'string') return { s: v.v }
  return { l: v.v.map(value) }
}

const fresh = (name: string, unlocked: boolean, env = {}) => {
  const d = ConfigDocument.open(bytes(samplePath(name)), `${name}.rvsc`, env)
  if (unlocked && !d.unlockGrid(gridKey)) throw new Error('VE_GRID_PASSWORD is missing or wrong')
  return d
}

function rowState(row: RowState): Record<string, unknown> {
  const c = row.config, ctl = row.control
  const d: Record<string, unknown> = {
    control: ctl.name, kind: ctl.kind, enabled: row.enabled, label: row.label, locked: row.locked, resetRequired: row.resetRequired,
    changed: row.changed, unit: row.unit, rangeDetail: row.rangeDetail, tooltip: row.tooltip, passwordAreas: Access.passwordAreas(ctl, c),
  }
  const k = row.codec
  if (k) {
    const r = k.range(c), disp = k.display(c)
    d.codec = {
      supported: k.isSupported(c), editable: k.isEditable, raw: k.raw(c), display: disp, formatted: k.formatted(c, row.ctx),
      precision: k.precision(c), scale: k.scale(c), offset: k.offset(c),
      range: r ? { min: r.min, max: r.max, default: r.defaultValue, step: r.step } : null,
      valueText: disp !== undefined ? k.format(disp, c) : '—',
    }
  }
  switch (ctl.kind) {
    case 'choice': d.options = choiceOptions(row); break
    case 'localToggle': d.checked = LocalControls.isChecked(ctl.name, c); break
    case 'localChoice': d.selection = LocalControls.vs2OffAction(c); break
    case 'button': if (ctl.name === 'BatteryTypeButton') { const p = BatteryPresets.matching(c); d.preset = p ? p.name : null } break
    case 'text': d.text = noteText(row); break
  }
  return d
}

function pages(document: ConfigDocument) {
  const ctx = document.ruleContext
  const c = ctx.config
  const out: unknown[] = []
  for (const section of sections) {
    if (section === 'assistants') continue
    for (const entry of SectionPages.entries(section, ctx)) {
      out.push({
        section, sectionTitle: sectionTitle(section), id: entry.id, title: entry.title, hasVisibleRows: SectionPages.hasVisibleRows(entry.page, ctx),
        sections: visibleSections(entry.page, ctx).map((v) => {
          const settings = v.rows.filter((r) => r.control.kind !== 'text' && r.control.kind !== 'button')
          const resetCount = settings.filter((r) => Access.requiresReset(r.control, c)).length
          const allReset = resetCount > 0 && resetCount === settings.length
          return {
            id: v.section.id, title: resolveText(v.section.title, ctx), lit: [...v.lit].sort(), resetCount,
            rows: v.rows.map((r) => {
              const row = new RowState(r.control, ctx, SectionPages.isEnabled(r, entry.page.name, ctx), entry.page.name)
              row.showsLock = section !== 'grid'
              row.showsResetMark = !allReset
              return rowState(row)
            }),
          }
        }),
      })
    }
  }
  return out
}

const changesOf = (d: ConfigDocument) => d.changes.map((ch) => [targetKey(ch.target), ch.label, ch.before, ch.after])

function record(document: ConfigDocument, extra: Record<string, unknown> = {}): Record<string, unknown> {
  const c = document.config, b = document.baseline
  const d: Record<string, unknown> = { ...extra }
  d.notices = document.notices.map((n) => [n.title, n.message, n.actionTitle ?? null])
  d.changes = changesOf(document)
  const diff = (x: DeviceConfiguration) => x.data.values.map((v, id) => [id, v]).filter(([id, v]) => v !== b.raw(id!))
  d.values = diff(c)
  d.saveBlockReason = document.saveBlockReason
  let reverted = 0
  for (;;) {
    const ch: Change | undefined = document.changes.find((x) => x.target.t !== 'assistants')
    if (!ch || reverted >= 40) break
    document.notices = []
    document.revert(ch)
    reverted++
    const first = document.changes[0]
    if (first && targetKey(first.target) === targetKey(ch.target) && first.after === ch.after) break
  }
  d.afterRevert = {
    changes: changesOf(document),
    values: c.data.values.map((_, id) => [id, document.config.raw(id)]).filter(([id, v]) => v !== b.raw(id!)),
    notices: document.notices.map((n) => [n.title, n.message]),
  }
  return d
}

function describeChoice(c: GridChoice): Record<string, unknown> {
  switch (c.t) {
    case 'accept': return { accept: c.code }
    case 'reject': return { reject: c.message }
    case 'propose': return { propose: c.message, alternative: c.alternative, button: c.button, keep: c.keep ?? null }
    case 'confirm': return { confirm: c.message, button: c.button, then: describeChoice(c.then) }
  }
}

function autoResolve(c: GridChoice): number | undefined {
  switch (c.t) {
    case 'accept': return c.code
    case 'reject': return undefined
    case 'propose': return c.alternative
    case 'confirm': return autoResolve(c.then)
  }
}

function editsFor(row: RowState, name: string, unlocked: boolean): Record<string, unknown>[] {
  const ctl = row.control
  const out: Record<string, unknown>[] = []
  const run = (op: Record<string, unknown>, body: (d: ConfigDocument) => Record<string, unknown>) => {
    const d = fresh(name, unlocked)
    const e = { control: ctl.name, unlocked, ...op, ...body(d) }
    out.push(record(d, e))
  }
  switch (ctl.kind) {
    case 'number': {
      const k = row.codec
      const r = k?.range(row.config)
      if (!k || !r) return []
      const step = Math.max(r.step, 1)
      for (const v of [r.min, r.max, (r.min + r.max) / 2, r.max + 10 * step, r.min - 10 * step, r.min + r.step / 3]) {
        run({ op: 'setDisplay', value: v }, (d) => {
          let ok = true
          d.edit('Change', ctl.name, (c) => { ok = k.setDisplay(v, c) })
          return { ok }
        })
      }
      break
    }
    case 'toggle': {
      const k = row.codec
      if (!k) return []
      const on = (k.raw(row.config) ?? 0) !== 0
      const nw = !(on !== isInverted(ctl))
      run({ op: 'toggle', value: nw, confirm: ctl.name === 'MicroGridModeCheckBox' && nw }, (d) => {
        d.edit('Change', ctl.name, (c) => { k.setRaw(nw !== isInverted(ctl) ? 1 : 0, c) })
        return {}
      })
      break
    }
    case 'localToggle': {
      const nw = !(LocalControls.isChecked(ctl.name, row.config) ?? false)
      run({ op: 'localToggle', value: nw, confirm: ctl.name === 'StopChargeDueToTempCheckBox' && nw }, (d) => {
        d.edit('Change', ctl.name, (c) => LocalControls.setChecked(ctl.name, nw, c))
        return {}
      })
      break
    }
    case 'localChoice':
      (ctl.items ?? []).forEach((_, i) => run({ op: 'localChoice', value: i }, (d) => {
        d.edit('Change', ctl.name, (c) => LocalControls.setVs2OffAction(i, c))
        return {}
      }))
      break
    case 'choice': {
      const k = row.codec
      if (!k) return []
      for (const o of choiceOptions(row)) {
        run({ op: 'choose', value: o.value }, (d) => {
          const e: Record<string, unknown> = { lom: Confirmations.needsLOM(ctl.name, o.value, d.config) }
          if (ctl.name === 'GridCodeComboBox') {
            if (o.value === d.config.raw(81) || Access.isLocked(ctl, d.ruleContext)) { e.skipped = true; return e }
            const choice = GridPages.choose(o.value, d.ruleContext)
            e.choice = describeChoice(choice)
            const n = autoResolve(choice)
            if (n !== undefined) d.edit('Change Grid Code', ctl.name, (c) => GridPages.apply(n, c))
            return e
          }
          if (ctl.name === 'VirtualSwitchActionSelectRadioGroup') e.vsConfirm = o.value !== 0 && (k.raw(d.config) ?? 0) === 0
          d.edit('Change', ctl.name, (c) => { k.setRaw(o.value, c) })
          return e
        })
      }
      break
    }
  }
  return out
}

function edits(name: string): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = []
  for (const unlocked of [false, true]) {
    const probe = fresh(name, unlocked)
    const ctx = probe.ruleContext
    const seen = new Set<string>()
    for (const section of sections) {
      if (section === 'assistants') continue
      for (const entry of SectionPages.entries(section as Section, ctx)) {
        for (const v of visibleSections(entry.page, ctx)) {
          for (const r of v.rows) {
            if (seen.has(r.control.name)) continue
            seen.add(r.control.name)
            const row = new RowState(r.control, ctx, SectionPages.isEnabled(r, entry.page.name, ctx), entry.page.name)
            if (!unlocked && !row.locked) continue
            out.push(...editsFor(row, name, unlocked))
          }
        }
      }
    }
  }
  return out
}

// MARK: - Catalog-wide

describe.runIf(hasRulesRefs)('catalog matches Swift', () => {
  it('text helpers', () => {
    const g = rulesGolden('catalog.json')
    for (const [i, o] of g.cleanCaption) expect(cleanCaption(i)).toBe(o)
    for (const [i, o] of g.gridClean) expect(cleanGridCode(i)).toBe(o)
    expect(Array.from({ length: 40 }, (_, i) => gridCodeName(i))).toEqual(g.gridCodeNames)
    for (const [i, o] of g.parseNumber) expect(ValueCodec.parseNumber(i) ?? null, i).toBe(o)
    for (const [i, o] of g.units) expect(displayUnit(i) ?? null, i).toBe(o)
    for (const [i, o] of g.reflow) expect(reflow(i)).toBe(o)
    for (const [i, o] of g.stripMarkup) expect(stripMarkup(i)).toBe(o)
  })

  it('controls, variables and indexes', () => {
    const g = rulesGolden('catalog.json')
    const cat = catalog()
    expect([...cat.controls.keys()].sort()).toEqual(g.controls.map((c: any) => c.name).sort())
    for (const e of g.controls) {
      const c = cat.controls.get(e.name)!
      same({
        name: c.name, page: cat.pageOfControl.get(c.name), staticLabel: staticLabel(c), cleanDescription: cleanDescription(c),
        changeListLabel: changeListLabel(c), settingTargets: settingTargets(c), isRow: isRow(c), hasCodec: ValueCodec.forControl(c) !== undefined,
      }, e, e.name)
    }
    same([...cat.variables.keys()].sort().map((k) => [k, cat.variables.get(k)!.kind, cat.variables.get(k)!.index]), g.variables)
    same([...cat.settingControls.keys()].sort((a, b) => a - b).map((k) => [k, cat.settingControls.get(k)!.name]), g.settingControls)
    same([...cat.flagControls.keys()].sort((a, b) => a - b).map((k) => [k, cat.flagControls.get(k)!.name]), g.flagControls)
    same([...cat.peerControlsBySetting.keys()].sort((a, b) => a - b).map((k) => [k, cat.peerControlsBySetting.get(k)!.map((c) => c.name)]), g.peerControlsBySetting)
    same([...cat.gridCodePages.keys()].sort((a, b) => a - b).map((k) => [k, [0, 1, 2, 3].map((v) => cat.gridCodePages.get(k)!.page(v))]), g.gridPageChoice)
  })

  it('page layouts', () => {
    const g = rulesGolden('catalog.json')
    for (const e of g.layouts) {
      const p = catalog().pages.get(e.page)!
      same(PageLayout.sections(p).map((s) => ({
        id: s.id, title: s.title ? fallbackText(s.title) : null,
        rows: s.rows.map((r) => ({ control: r.control.name, ancestors: r.ancestors.map((a) => a.name) })),
      })), e.sections, e.page)
    }
  })

  it('expressions parse the same', () => {
    const g = rulesGolden('catalog.json')
    expect(new Set(allExpressions())).toEqual(new Set(g.expressions.map((x: any) => x[0])))
    for (const [e, ok] of g.expressions) expect(parseExpr(e) !== undefined, e).toBe(ok)
  })
})

// MARK: - Per sample

for (const name of samples) {
  describe.runIf(hasRulesRefs)(`rules on ${name} match Swift`, () => {
    let g: any
    const env = () => ({ ratings: () => ({ dc: g.facts.ratings[0], ac: g.facts.ratings[1], power: g.facts.ratings[2] }) })
    beforeAll(() => { g = rulesGolden(`${name}.json`) })

    it('device facts and grid table', () => {
      const d = fresh(name, false, env())
      const c = d.config
      const p = BatteryPresets.matching(c)
      same({
        dcVoltageClass: dcVoltageClass(c), acVoltageClass: acVoltageClass(c), isInverterOnly: isInverterOnly(c), cells: cells(c),
        modelName: modelName(c, d.env.ratings), ratings: g.facts.ratings, assistantIDs: assistantDirectory(c), batteryPreset: p?.id,
        gridPage: GridPages.page(c), showsMicrogrid: GridPages.showsMicrogrid(c), paramsValid: GridPages.paramsValid(c),
        gridCodeNeedsPassword: Access.gridCodeNeedsPassword(d.ruleContext),
      }, g.facts)
      const t = gridTable(c)
      same(t ? [...t.entries.keys()].sort((a, b) => a - b).map((k) => {
        const e = t.entries.get(k)!
        return { code: k, variant: e.variant, word: e.word, editable: hex(e.editable), present: hex(e.present),
          defaults: [...e.defaults.keys()].sort((a, b) => a - b).map((x) => [x, e.defaults.get(x)]) }
      }) : null, g.gridTable)
    })

    it('expressions, values and variables', () => {
      const ctx = fresh(name, false).ruleContext
      for (const [e, v] of g.expressions) expect(ctx.evaluate(e) ?? null, e).toBe(v)
      for (const [e, v] of g.values) same(value(ctx.eval(parseExpr(e)!)), v, e)
      for (const [n, v] of g.variables) same(value(ctx.variableValue(n, ctx.config)), v, n)
    })

    it('labels and access', () => {
      const c = fresh(name, false).config
      g.labels.forEach((exp: unknown[], id: number) => {
        same([Labels.settingIn(id, c), Labels.format(c, id), catalog().label(id), catalog().unit(id)], exp, `setting ${id}`)
      })
      g.flagLabels.forEach((exp: unknown[], n: number) => same([Labels.flag(n), formatFlag(n, false), formatFlag(n, true)], exp, `flag ${n}`))
      g.access.forEach((exp: unknown[], id: number) => same([Access.attributeOfSetting(id, c), Access.isProtectedSetting(id, c)], exp, `access ${id}`))
    })

    it('pages and rows', () => {
      same(pages(fresh(name, false)), g.pages)
      same(pages(fresh(name, true)), g.pagesUnlocked)
      if (g.pagesChargerUnhidden) {
        const d = fresh(name, false)
        d.unhideCharger()
        same(pages(d), g.pagesChargerUnhidden)
      }
    })

    it('every edit', () => {
      const mine = edits(name)
      expect(mine.length).toBe(g.edits.length)
      mine.forEach((e, i) => same(e, g.edits[i], `${g.edits[i].control} ${g.edits[i].op} ${g.edits[i].value} unlocked=${g.edits[i].unlocked}`))
    })

    it('grid code choices', () => {
      const out: unknown[] = []
      for (const unlocked of [false, true]) {
        for (let n = 0; n < 34; n++) {
          const d = fresh(name, unlocked)
          const e: Record<string, unknown> = { code: n, unlocked, choice: describeChoice(GridPages.choose(n, d.ruleContext)) }
          d.edit('Change Grid Code', 'GridCodeComboBox', (c) => GridPages.apply(n, c))
          e.paramsValid = GridPages.paramsValid(d.config)
          e.page = GridPages.page(d.config)
          out.push(record(d, e))
        }
      }
      same(out, g.gridChoices)
    })

    it('battery presets', () => {
      const out = catalog().batteryPresets.map((p) => {
        const d = fresh(name, false)
        const values = BatteryPresets.order.map((n) => [n, BatteryPresets.value(p, n, d.config)])
        d.applyBatteryPreset(p)
        return record(d, { preset: p.id, presetValues: values, matchingAfter: BatteryPresets.matching(d.config)?.id })
      })
      same(out, g.presets)
    })

    it('edit script', () => {
      const d = fresh(name, false)
      const steps: unknown[] = []
      for (const n of ['AbsorptionVoltageEdit', 'FloatVoltageEdit', 'ChargeCurrentEdit', 'DCLowShutDownEdit', 'DCLowRestartEdit',
        'InverterOutputVoltageEdit', 'ACInputCurrentLimitEdit', 'LithiumCheckBox', 'EnableBatteryMonitorCheckBox']) {
        const ctl = catalog().controls.get(n)
        const k = ctl && ValueCodec.forControl(ctl)
        if (!ctl || !k || !k.isSupported(d.config)) continue
        d.notices = []
        const r = k.range(d.config)
        if (ctl.kind === 'number' && r) {
          const v = r.min + (r.max - r.min) * 0.37
          d.edit('Change', n, (c) => { k.setDisplay(v, c) })
          steps.push({ control: n, value: v, notices: d.notices.map((x) => [x.title, x.message]), changes: changesOf(d) })
        } else if (ctl.kind === 'toggle') {
          d.edit('Change', n, (c) => { k.setRaw((k.raw(c) ?? 0) === 0 ? 1 : 0, c) })
          steps.push({ control: n, notices: d.notices.map((x) => [x.title, x.message]), changes: changesOf(d) })
        }
      }
      same(steps, g.script)
    })

    it('settings report', () => {
      const d = fresh(name, false, env())
      const opts = { assistants: g.report.assistantBlocks, now: new Date(g.report.exportedAt * 1000) }
      const { header, blocks } = reportBlocks(d, opts)
      same(header, g.report.header)
      same(blocks, g.report.blocks)
      expect(reportText(d, opts)).toBe(g.report.plainText)
    })

    it('save with grid authorization', () => {
      const d = fresh(name, true)
      const before = d.config.raw(142)
      d.setRaw(142, before ^ 1, 'Test')
      if (g.save.error) {
        expect(() => d.save(BigInt(g.save.now))).toThrow()
        return
      }
      expect(hex(d.save(BigInt(g.save.tokenTime)))).toBe(g.save.bytes)
      expect(d.changes.length).toBe(g.save.changesAfter)
    })
  })
}

// MARK: - GridUnlockTests.swift

describe('grid unlock', () => {
  const hasS5 = (() => { try { bytes(samplePath('s5')); return true } catch { return false } })() && hasKey
  // The token VE Configure wrote into s2 after the password was entered: the one a save must write again.
  const referenceToken = hasS5 && existsSync(samplePath('s2')) ? [...DeviceConfiguration.parse(bytes(samplePath('s2'))).data.tokens[0]!] : []

  it.runIf(hasKey)('correct password unlocks only its session', () => {
    const session = new SessionState()
    const other = new SessionState()
    expect(session.unlockGrid(`  ${gridKey.toLowerCase()}  `)).toBe(true)
    expect(session.gridPasswordEntered).toBe(true)
    expect(other.gridPasswordEntered).toBe(false)
  })

  it('bad passwords do not unlock', () => {
    for (const input of ['', 'x', '23456789ABCD', '23456789ABC', 'A'.repeat(1000)]) {
      const session = new SessionState()
      expect(session.unlockGrid(input)).toBe(false)
      expect(session.gridPasswordEntered).toBe(false)
    }
  })

  it.runIf(hasS5)('document isolation and file round trip', () => {
    const first = fresh('s5', false), second = fresh('s5', false)
    expect(first.session.gridPasswordEntered).toBe(false)
    expect(first.unlockGrid('wrong')).toBe(false)
    const before = first.config.raw(142)
    first.setRaw(142, before ^ 1, 'Test')
    expect(first.config.raw(142)).toBe(before)
    expect(first.unlockGrid(gridKey)).toBe(true)
    expect(second.session.gridPasswordEntered).toBe(false)
    const control = catalog().controls.get('GridCodeComboBox')!
    expect(Access.isLocked(control, first.ruleContext)).toBe(false)
    expect(Access.isLocked(control, second.ruleContext)).toBe(true)
    first.setRaw(142, before ^ 1, 'Test')
    expect(first.config.raw(142)).toBe(before ^ 1)
    first.undo()
    expect(first.config.raw(142)).toBe(before)
    first.setRaw(142, before ^ 1, 'Test')
    expect(Access.forbiddenChanges(first.ruleContext)).toEqual([])
    const now = BigInt(Math.floor(Date.now() / 1000))
    const out = first.save(now)
    const reopened = ConfigDocument.open(out, 'out.rvsc')
    expect(reopened.session.gridPasswordEntered).toBe(false)
    expect(reopened.config.raw(142)).toBe(before ^ 1)
    expect(reopened.config.data.tokens.map((t) => [...t])).toEqual([referenceToken])
    expect(reopened.config.data.tokenTime).toBe(now)
    expect(Access.isLocked(control, reopened.ruleContext)).toBe(true)
    expect(first.session.gridPasswordEntered).toBe(true) // save does not end session
  })

  it.runIf(hasS5)('grid selection keeps consistency checks', () => {
    const doc = fresh('s5', false)
    expect(doc.unlockGrid(gridKey)).toBe(true)
    const keys = [...gridTable(doc.config)!.entries.keys()].sort((a, b) => a - b)
    const code = keys.find((k) => k > 1 && k !== 21 && k !== doc.config.raw(81))!
    doc.edit('Change Grid Code', 'GridCodeComboBox', (c) => GridPages.apply(code, c))
    expect(doc.config.raw(81)).toBe(code)
    expect(GridPages.paramsValid(doc.config)).toBe(true)
    doc.setRaw(128, 65535, 'Invalid checker')
    expect(doc.integrityProblem).toBeDefined()
    expect(doc.canSave).toBe(false)
  })

  it.runIf(hasS5)('verified authorization does not renew other tokens', () => {
    const c = DeviceConfiguration.parse(bytes(samplePath('s5')))
    const auth = GridPassword.verify(gridKey)!
    c.data.tokens.push(new Uint8Array([1, 2, 3]))
    auth.authorizeSave(c, 123n)
    expect(c.data.tokens.map((t) => [...t])).toEqual([referenceToken])
    expect(c.data.tokenTime).toBe(123n)
  })

  it('names table sanity', () => {
    expect(names.settings[81]).toBe('eecvGridCode')
    expect(labelInConfig).toBeTypeOf('function')
    if (existsSync(samplePath('s1'))) expect(resolveRawText(undefined, fresh('s1', false).ruleContext)).toBeUndefined()
  })
})
