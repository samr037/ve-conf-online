// Row edits with VE Configure's safety confirmations.
import { Confirmations, L, ValueCodec, isInverted, type RowState } from '../lib/rules'
import { editor } from './store.svelte'

/** Typed number committed in a numeric field. False when refused. */
export function commitNumber(row: RowState, text: string): boolean {
  const doc = editor.doc
  return !!doc && doc.commitNumber(row.control, text, row.label)
}

export function step(row: RowState, direction: 1 | -1): boolean {
  const doc = editor.doc
  return !!doc && doc.step(row.control, direction, row.label)
}

export async function toggle(row: RowState, on: boolean): Promise<void> {
  const doc = editor.doc
  if (!doc) return
  if (row.control.name === 'MicroGridModeCheckBox' && on && !(await editor.confirm(Confirmations.microgrid()))) { editor.bump(); return }
  doc.toggle(row.control, on, row.label)
}

export async function localToggle(row: RowState, on: boolean): Promise<void> {
  const doc = editor.doc
  if (!doc) return
  if (row.control.name === 'StopChargeDueToTempCheckBox' && on && !(await editor.confirm(Confirmations.tbatStop()))) { editor.bump(); return }
  doc.setLocalToggle(row.control, on, row.label)
}

export function localChoice(row: RowState, index: number): void {
  editor.doc?.setLocalChoice(row.control, index)
}

export async function choose(row: RowState, value: number): Promise<void> {
  const doc = editor.doc
  const codec = row.codec
  if (!doc || !codec) return
  if (Confirmations.needsLOM(row.control.name, value, row.config) && !(await editor.confirm(Confirmations.lom()))) { editor.bump(); return }
  if (row.control.name === 'VirtualSwitchActionSelectRadioGroup' && value !== 0 && (codec.raw(row.config) ?? 0) === 0) {
    const count = editor.assistants?.installed.length ?? 0
    const c = Confirmations.virtualSwitch(count)
    if (c && !(await editor.confirm(c))) { editor.bump(); return }
    doc.choose(row.control, value, row.label)
    if (count > 0) editor.assistants?.removeAll()
    return
  }
  if (row.control.name === 'GridCodeComboBox') {
    const plan = doc.planGridCode(value)
    if (!plan) { editor.bump(); return }
    const n = await editor.gridChoice(plan)
    if (n === undefined) { editor.bump(); return }
    doc.applyGridCode(n)
    return
  }
  doc.choose(row.control, value, row.label)
}

export function restore(row: RowState): void {
  editor.doc?.restore(row.control, L('Restore %@', row.label))
}

/** Whether a toggle row is on as displayed. */
export function toggleIsOn(row: RowState): boolean {
  const raw = row.codec?.raw(row.config) ?? 0
  return (raw !== 0) !== isInverted(row.control)
}

export { ValueCodec }
