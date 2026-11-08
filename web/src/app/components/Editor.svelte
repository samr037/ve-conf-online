<!-- The editor window: header, section sidebar, diagram strip, the page, and the change list. -->
<script lang="ts">
  import { productName } from '../../lib/brand'
  import { MetaGenerator } from '../../lib/engine/assembler'
  import { appText } from '../../lib/i18n/app'
  import {
    L, currentLocale, formatDateTime, hasSecondACInput, modelName, sectionLit, sectionTitle, sections, Labels, type Section,
  } from '../../lib/rules'
  import { changeCounts, exportText, reportOf, save } from '../editorActions'
  import { editor } from '../store.svelte'
  import ChangeList from './ChangeList.svelte'
  import Diagram, { type Annotation } from './Diagram.svelte'
  import SectionView from './SectionView.svelte'
  import Toolbar from './Toolbar.svelte'

  let { onopen }: { onopen: () => void } = $props()

  const doc = $derived(editor.doc!)
  const ctx = $derived((editor.rev, doc.ruleContext))
  const c = $derived(ctx.config)
  const model = $derived(modelName(c, MetaGenerator.ratings))
  const counts = $derived(changeCounts(ctx, (editor.rev, doc.changes.some((x) => x.target.t === 'assistants'))))
  const lit = $derived(editor.hovered ?? (editor.pageLit.size ? editor.pageLit : new Set(sectionLit[editor.section])))
  const t = (k: Parameters<typeof appText>[1], v?: Record<string, string | number>) => appText(editor.language, k, v)
  let printText = $state('')

  const annotations = $derived.by(() => {
    const b = ctx.baseline
    const text = (id: number, unit: string) => {
      const info = c.info.info(id)
      return info && info.isSupported ? Labels.number(info.display(c.raw(id)), info.step) + ' ' + unit : undefined
    }
    const out: Record<string, Annotation> = {}
    const a = text(6, 'A'), o = text(5, 'V'), abs = text(2, 'V'), fl = text(3, 'V')
    if (a) out.acIn = { text: a, changed: c.raw(6) !== b.raw(6) }
    if (o) out.acOut = { text: o, changed: c.raw(5) !== b.raw(5) }
    if (abs && fl) out.battery = { text: L('Absorption %@ · Float %@', abs, fl), changed: c.raw(2) !== b.raw(2) || c.raw(3) !== b.raw(3) }
    return out
  })

  const icons: Record<Section, string> = {
    general: 'M3 5h10M3 11h10M6 3v4M10 9v4',
    grid: 'M8 2 4.5 14M8 2l3.5 12M5.2 10.5h5.6M6.4 6h3.2',
    inverter: 'M2 8c1.4-3.6 2.8-3.6 4 0s2.6 3.6 4 0 2.6-3.6 4-1',
    charger: 'M2.5 5.5h9.5v6H2.5zM12 7.5h1.5v2H12M7.8 6.5l-1.4 2h2.2l-1.4 2',
    virtualSwitch: 'M2 8h3l5-3.5M10 8h4M8 10.5v2',
    assistants: 'M3 3h10v7H7l-3 3V3z',
    advanced: 'M3 4h10M3 8h10M3 12h10M6 2.5v3M10 6.5v3M7 10.5v3',
  }

  function print() {
    printText = reportOf()
    requestAnimationFrame(() => window.print())
  }

  function onKey(e: KeyboardEvent) {
    const mod = e.metaKey || e.ctrlKey
    if (!mod) return
    const target = e.target as HTMLElement
    const inField = target.closest('input, select, textarea') !== null
    const k = e.key.toLowerCase()
    if (k === 's') { e.preventDefault(); save() }
    else if (k === 'o') { e.preventDefault(); onopen() }
    else if (k === 'e' && e.shiftKey) { e.preventDefault(); exportText() }
    else if (k === 'p') { e.preventDefault(); print() }
    else if (k === 'z' && !inField && editor.dialogs.length === 0) {
      e.preventDefault()
      if (e.shiftKey) doc.redo(); else doc.undo()
    } else if (k === 'y' && !inField && editor.dialogs.length === 0) { e.preventDefault(); doc.redo() }
  }

  /** Edits survive a reload: write them now instead of asking. */
  function persist() { editor.persistNow() }

  const undoName = $derived((editor.rev, doc.undoActionName))
  const redoName = $derived((editor.rev, doc.redoActionName))
</script>

<svelte:window onkeydown={onKey} onpagehide={persist} />
<svelte:document onvisibilitychange={() => { if (document.visibilityState === 'hidden') persist() }} />

<div class="editor">
  <header class="top">
    <div class="brand">
      <span class="mark" aria-hidden="true"><svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M9 1 3 9h5l-1 6 6-8H8l1-6Z" /></svg></span>
      <span class="name">{productName}</span>
    </div>
    <div class="file">
      <span class="file-name" title={doc.fileName}>{doc.fileName ?? L('Configuration')}</span>
      <span class="file-meta">{model}</span>
    </div>
    <div class="actions">
      <button type="button" class="icon-btn" disabled={!undoName} aria-label={undoName ? t('undoAction', { action: undoName }) : L('Undo')} title={undoName ? t('undoAction', { action: undoName }) : L('Undo')} onclick={() => doc.undo()}>
        <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><path d="M5 3 2 6l3 3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /><path d="M2.5 6H10a3.5 3.5 0 0 1 0 7H7" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
      </button>
      <button type="button" class="icon-btn" disabled={!redoName} aria-label={redoName ? t('redoAction', { action: redoName }) : L('Redo')} title={redoName ? t('redoAction', { action: redoName }) : L('Redo')} onclick={() => doc.redo()}>
        <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><path d="m11 3 3 3-3 3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /><path d="M13.5 6H6a3.5 3.5 0 0 0 0 7h3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
      </button>
      <span class="sep" aria-hidden="true"></span>
      <button type="button" class="btn quiet" onclick={exportText}>{t('exportText')}</button>
      <button type="button" class="btn quiet" onclick={print}>{t('print')}</button>
      <button type="button" class="btn quiet" onclick={onopen}>{t('openAnother')}</button>
      <span class="sep" aria-hidden="true"></span>
      <Toolbar />
      <button type="button" class="btn primary" onclick={save}>{t('saveAs')}</button>
    </div>
  </header>

  <div class="body">
    <nav class="sidebar" aria-label={t('sections')}>
      <div class="identity">
        <span class="model">{model}</span>
        <dl>
          <dt>{t('serialLabel')}</dt><dd>{c.serial ?? '—'}</dd>
          <dt>{t('firmwareLabel')}</dt><dd>{c.firmware.toString()}</dd>
          {#if c.readDate}<dt>{t('readLabel')}</dt><dd title={formatDateTime(c.readDate)}>{c.readDate.toLocaleDateString(currentLocale(), { dateStyle: 'medium' })}</dd>{/if}
        </dl>
      </div>
      <ul>
        {#each sections as s (s)}
          <li>
            <button type="button" class="nav" aria-current={editor.section === s ? 'page' : undefined}
              onclick={() => { editor.section = s; editor.hovered = undefined }}>
              <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><path d={icons[s]} fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" /></svg>
              <span class="nav-title">{sectionTitle(s)}</span>
              {#if counts[s] > 0}<span class="badge" aria-label={t('changesCount', { n: counts[s] })}>{s === 'assistants' ? '•' : counts[s]}</span>{/if}
            </button>
          </li>
        {/each}
      </ul>
    </nav>

    <main class="main">
      <div class="strip">
        <Diagram {lit} {model} hasSecondInput={hasSecondACInput(c)} {annotations} />
      </div>
      <div class="content">
        <div class="page-col">
          {#key editor.section}
            <SectionView section={editor.section} />
          {/key}
        </div>
        {#if editor.showsChanges}
          <div class="changes-col"><ChangeList onsave={save} /></div>
        {/if}
      </div>
    </main>
  </div>

</div>

<pre class="print-report" aria-hidden="true">{printText}</pre>

<style>
  .editor { min-height: 100vh; display: flex; flex-direction: column; }
  .top {
    position: sticky; top: 0; z-index: 10;
    display: flex; flex-wrap: wrap; align-items: center; gap: 10px 18px;
    padding: 10px 18px 10px 20px; background: var(--surface); border-bottom: 1px solid var(--line);
  }
  .brand { display: flex; align-items: center; gap: 10px; }
  .mark { width: 28px; height: 28px; border-radius: 6px; background: var(--accent); color: var(--on-accent); display: flex; align-items: center; justify-content: center; }
  .name { font-weight: 600; font-size: 15px; white-space: nowrap; }
  .file { flex: 1 1 260px; min-width: 0; display: flex; align-items: baseline; gap: 10px; }
  .file-name { font: 500 13px var(--font-mono); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .file-meta { font-size: 13px; color: var(--muted); white-space: nowrap; }
  .actions { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; }
  .sep { width: 1px; height: 20px; margin: 0 6px; background: var(--line); }

  .body { flex: 1; display: flex; min-height: 0; background: linear-gradient(to right, var(--surface-sunken) 232px, transparent 232px); }
  .sidebar {
    flex: 0 0 232px; padding: 18px 12px; border-right: 1px solid var(--line); background: var(--surface-sunken);
    position: sticky; top: 55px; align-self: flex-start; height: calc(100vh - 55px); overflow: auto;
  }
  .identity { padding: 4px 12px 16px; margin-bottom: 10px; border-bottom: 1px solid var(--line); }
  .model { display: block; font-size: 13px; font-weight: 600; margin-bottom: 6px; }
  .identity dl { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 2px 10px; margin: 0; font-size: 11.5px; }
  .identity dt { color: var(--muted); }
  .identity dd { margin: 0; font-family: var(--font-mono); color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-variant-numeric: tabular-nums; }
  ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
  .nav {
    width: 100%; display: flex; align-items: center; gap: 10px; padding: 8px 12px;
    border: 0; border-radius: var(--radius-block); background: transparent;
    font: 400 14px var(--font-sans); color: var(--ink); text-align: left; cursor: pointer;
  }
  .nav svg { color: var(--muted); flex: none; }
  .nav:hover { background: var(--line-faint); }
  .nav[aria-current='page'] { background: var(--accent-soft); color: var(--accent); font-weight: 600; }
  .nav[aria-current='page'] svg { color: var(--accent); }
  .nav-title { flex: 1; }
  .badge { font: 500 12px var(--font-mono); color: var(--changed); }

  .main { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .strip { border-bottom: 1px solid var(--line); }
  .content { flex: 1; display: flex; flex-wrap: wrap; align-items: flex-start; gap: 24px; padding: 28px; }
  .page-col { flex: 999 1 520px; min-width: 0; }
  .changes-col { flex: 1 1 280px; max-width: 340px; position: sticky; top: 83px; height: calc(100vh - 111px); min-height: 320px; }

  .print-report { display: none; }

  @media (max-width: 1100px) {
    .changes-col { max-width: none; position: static; height: auto; flex-basis: 100%; }
  }
  @media (max-width: 860px) {
    .body { flex-direction: column; }
    .body { background: none; }
    .sidebar { position: static; height: auto; flex: none; padding: 8px 12px; border-right: 0; border-bottom: 1px solid var(--line); }
    .identity { display: none; }
    ul { flex-direction: row; overflow-x: auto; }
    .nav { white-space: nowrap; }
    .content { padding: 18px 14px; }
    .file-meta { display: none; }
  }
  @media (max-width: 600px) {
    .actions .btn.quiet { display: none; }
  }

  @media print {
    .editor { display: none; }
    .print-report { display: block; margin: 0; font: 10pt/1.45 var(--font-mono); white-space: pre-wrap; color: #000; }
  }
</style>
