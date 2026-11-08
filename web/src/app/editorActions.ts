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

/** Saves a new file (download) or explains why it can't be saved yet. Returns the saved name. */
export function save(): string | undefined {
  const doc = editor.doc
  if (!doc) return undefined
  const reason = doc.saveBlockReason
  if (reason !== undefined) {
    editor.push({ k: 'saveBlocked', reason })
    return undefined
  }
  const name = suggestedName(doc.fileName)
  try {
    const bytes = doc.save()
    download(bytes, name, 'application/octet-stream')
    editor.toast(appText(editor.language, 'downloaded', { name }))
    return name
  } catch (e) {
    editor.push({ k: 'saveBlocked', reason: e instanceof SaveError ? e.reason : e instanceof Error ? e.message : String(e) })
    return undefined
  }
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
