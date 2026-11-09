// File-level actions: open, save, export, print, per-section change counts.
import { appText } from '../lib/i18n/app'
import {
  L, PageLayout, SectionPages, SaveError, reportText, sections, settingTargets, type RuleContext, type Section,
} from '../lib/rules'
import { editor } from './store.svelte'

/** The name of the file to save: the original name plus "-edited", never the original itself. */
export function suggestedName(fileName: string | undefined): string {
  const name = fileName ?? 'configuration.rvsc'
  const dot = name.lastIndexOf('.')
  const base = dot > 0 ? name.slice(0, dot) : name
  const ext = dot > 0 ? name.slice(dot) : '.rvsc'
  return (base.endsWith('-edited') ? base : base + '-edited') + ext
}

export function download(bytes: Uint8Array | string, name: string, type: string): void {
  const blob = new Blob([bytes as BlobPart], { type })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = name
  document.body.append(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 2000)
}

/** `showSaveFilePicker` where the browser has it (Chromium): the user picks the folder and the name. */
interface SaveHandle { name: string; createWritable(): Promise<{ write(b: BlobPart): Promise<void>; close(): Promise<void> }> }
type SavePicker = (o: { suggestedName: string; types: { description: string; accept: Record<string, string[]> }[] }) => Promise<SaveHandle>

/** The name the user typed, with the original extension when they left it out. */
export function withExtension(name: string, original: string | undefined): string {
  const n = name.trim()
  if (/\.(rvsc|vsc)$/i.test(n)) return n
  const ext = original?.match(/\.(rvsc|vsc)$/i)?.[0] ?? '.rvsc'
  return n + ext
}

/**
 * Saves a new file: in a folder the user picks (Chromium), else as a download under the name typed in the Save
 * dialog. Explains why it can't be saved yet when blocked. Returns the saved name.
 */
export async function save(): Promise<string | undefined> {
  const doc = editor.doc
  if (!doc) return undefined
  const reason = doc.saveBlockReason
  if (reason !== undefined) {
    editor.push({ k: 'saveBlocked', reason })
    return undefined
  }
  const suggested = suggestedName(doc.fileName)
  const picker = (window as unknown as { showSaveFilePicker?: SavePicker }).showSaveFilePicker
  if (typeof picker === 'function') {
    let handle: SaveHandle
    try {
      handle = await picker({ suggestedName: suggested, types: [{ description: 'VE.Bus configuration', accept: { 'application/octet-stream': ['.rvsc', '.vsc'] } }] })
    } catch {
      return undefined // cancelled
    }
    return commit(handle.name, async (bytes) => {
      const w = await handle.createWritable()
      await w.write(bytes as BlobPart)
      await w.close()
    })
  }
  const typed = await editor.askSaveName(suggested)
  if (typed === undefined) return undefined
  const name = withExtension(typed, doc.fileName)
  if (doc.fileName && name.toLowerCase() === doc.fileName.toLowerCase()) {
    const ok = await editor.confirm({
      title: L('Replace the original download “%@”?', doc.fileName),
      message: L("This is the file you opened. Keep it as it is so you can go back to the inverter's current settings; save the edited configuration under a new name instead."),
      continueTitle: L('Replace Original'),
    })
    if (!ok) return undefined
  }
  return commit(name, async (bytes) => download(bytes, name, 'application/octet-stream'))
}

/** Saves the document, writes the bytes, and puts everything back if writing fails. */
async function commit(name: string, write: (bytes: Uint8Array) => Promise<void>): Promise<string | undefined> {
  const doc = editor.doc!
  const before = { config: doc.config, baseline: doc.baseline, fileName: doc.fileName }
  let bytes: Uint8Array
  try {
    bytes = doc.save(undefined, name)
  } catch (e) {
    editor.push({ k: 'saveBlocked', reason: e instanceof SaveError ? e.reason : e instanceof Error ? e.message : String(e) })
    return undefined
  }
  try {
    await write(bytes)
  } catch {
    doc.config = before.config
    doc.baseline = before.baseline
    doc.fileName = before.fileName
    editor.bump()
    editor.push({ k: 'message', title: appText(editor.language, 'saveTitle'), message: appText(editor.language, 'saveFailed') })
    return undefined
  }
  editor.toast(appText(editor.language, 'downloaded', { name }))
  void editor.rememberRecent(name, bytes)
  return name
}

/** "Restore all": every setting back to the loaded file, as one step that Undo takes back. */
export async function restoreAll(): Promise<void> {
  const doc = editor.doc
  if (!doc || doc.changes.length === 0) return
  const ok = await editor.confirm({
    title: appText(editor.language, 'restoreAllTitle', { n: doc.changes.length }),
    message: appText(editor.language, 'restoreAllMessage'),
    continueTitle: appText(editor.language, 'restoreAll'),
  })
  if (ok) doc.replace(doc.baseline.clone(), appText(editor.language, 'restoreAllAction'))
}

export function reportOf(): string {
  const doc = editor.doc!
  return reportText(doc, { assistants: editor.assistants?.reportBlocks() })
}

export function exportText(): void {
  const doc = editor.doc
  if (!doc) return
  const base = (doc.fileName ?? 'configuration').replace(/\.[^.]+$/, '')
  download(reportOf(), `${base}-settings.txt`, 'text/plain;charset=utf-8')
}

/** Rows changed per sidebar section (settings and flags written by the section's controls). */
export function changeCounts(ctx: RuleContext, assistantsChanged: boolean): Record<Section, number> {
  const out = {} as Record<Section, number>
  const c = ctx.config, b = ctx.baseline
  for (const s of sections) {
    if (s === 'assistants') { out[s] = assistantsChanged ? 1 : 0; continue }
    const seen = new Set<string>()
    let n = 0
    for (const e of SectionPages.entries(s, ctx)) {
      for (const sec of PageLayout.sections(e.page)) {
        for (const r of sec.rows) {
          const ctl = r.control
          if (seen.has(ctl.name)) continue
          seen.add(ctl.name)
          const v = ctl.variable
          const changed = v?.kind === 'flag' && v.index !== undefined
            ? c.flag(v.index) !== b.flag(v.index)
            : settingTargets(ctl).some((id) => c.raw(id) !== b.raw(id))
          if (changed) n++
        }
      }
    }
    out[s] = n
  }
  return out
}

export { L }
