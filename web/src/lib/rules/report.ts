// VE Configure's "Export settings" / "Print settings": every visible setting, page by page, plus the assistants
// (port of the text part of Sources/VEConfigure/SettingsReport.swift).
import type { DeviceConfiguration } from '../engine/deviceConfiguration'
import { changeListLabel } from './catalog'
import type { ConfigDocument } from './document'
import { L, formatDateTime } from './l10n'
import { PageLayout, SectionPages, resolveText, sectionTitle, sections } from './layout'
import { ValueCodec } from './valueCodec'

export interface ReportBlock { title: string; rows: [string, string][] }

export interface ReportOptions {
  /** Assistant summaries (title already prefixed "Assistants › …"), from the assistants model. */
  assistants?: ReportBlock[]
  now?: Date
}

/** Best-effort product name from the firmware type until the device table is decoded. */
export function modelName(c: DeviceConfiguration, ratings?: (c: DeviceConfiguration) => { dc: number; ac: number; power: number }): string {
  const r = ratings?.(c)
  if (!r || r.dc <= 0 || r.power <= 0) return L('VE.Bus inverter/charger')
  return `${r.dc} V · ${r.power} VA`
}

const reportKinds = new Set(['number', 'toggle', 'choice', 'localToggle', 'localChoice'])

export function reportBlocks(document: ConfigDocument, options: ReportOptions = {}): { header: [string, string][]; blocks: ReportBlock[] } {
  const c = document.config
  const ctx = document.ruleContext
  const header: [string, string][] = [
    [L('Device'), modelName(c, document.env.ratings)],
    [L('Serial'), c.serial ?? '—'],
    [L('Firmware'), c.firmware.toString()],
  ]
  const read = c.readDate
  if (read) header.push([L('Read'), formatDateTime(read)])
  if (document.fileName !== undefined) header.push([L('File'), document.fileName])
  header.push([L('Exported'), formatDateTime(options.now ?? new Date())])

  const blocks: ReportBlock[] = []
  for (const section of sections) {
    if (section === 'assistants') continue
    const st = sectionTitle(section)
    for (const entry of SectionPages.entries(section, ctx)) {
      for (const s of PageLayout.sections(entry.page)) {
        const rows: [string, string][] = []
        for (const row of s.rows) {
          if (!SectionPages.isVisible(row, ctx)) continue
          const control = row.control
          const codec = reportKinds.has(control.kind) ? ValueCodec.forControl(control) : undefined
          if (!codec) continue
          const label = resolveText(control.label, ctx) ?? resolveText(control.caption, ctx) ?? changeListLabel(control) ?? control.name
          rows.push([label, codec.formatted(c, ctx)])
        }
        if (rows.length === 0) continue
        const group = resolveText(s.title, ctx)
        const pageTitle = st === entry.title ? st : `${st} › ${entry.title}`
        blocks.push({ title: group !== undefined ? `${pageTitle} › ${group}` : pageTitle, rows })
      }
    }
  }
  blocks.push(...(options.assistants ?? []))
  return { header, blocks }
}

const len = (s: string) => [...s].length

export function reportText(document: ConfigDocument, options: ReportOptions = {}): string {
  const { header, blocks } = reportBlocks(document, options)
  let out = `VE Configure — ${L('VE.Bus configuration')}\n\n`
  for (const [k, v] of header) out += `${k}: ${v}\n`
  for (const b of blocks) {
    out += `\n${b.title}\n` + '-'.repeat(Math.min(len(b.title), 72)) + '\n'
    const width = Math.min(48, Math.max(0, ...b.rows.map(([k]) => len(k))))
    for (const [k, v] of b.rows) out += k + ' '.repeat(Math.max(width, len(k)) - len(k)) + '  ' + v + '\n'
  }
  return out
}
