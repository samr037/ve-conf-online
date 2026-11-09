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
  import MoreMenu from './MoreMenu.svelte'
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
    if (abs && fl) out.battery = { text: L('Absorption %@ · Float %@', abs, fl), short: `${abs} · ${fl}`, changed: c.raw(2) !== b.raw(2) || c.raw(3) !== b.raw(3) }
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
    if (k === 's') { e.preventDefault(); if (!doc.readOnly) save() }
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

  const device = $derived(editor.device)
  const readAt = $derived(device ? new Intl.DateTimeFormat(currentLocale(), { dateStyle: 'medium', timeStyle: 'short' }).format(device.readAt) : '')
  const undoName = $derived((editor.rev, doc.undoActionName))
  const redoName = $derived((editor.rev, doc.redoActionName))
  const changeCount = $derived((editor.rev, doc.changes.length))

  // Narrow windows: the sections become a horizontal tab strip under the header.
  let headerHeight = $state(55)
  let tabs = $state<HTMLUListElement>()
  let moreLeft = $state(false)
  let moreRight = $state(false)
  const reducedMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches
  const isStrip = () => !!tabs && getComputedStyle(tabs).flexDirection === 'row'

  function edges() {
    if (!tabs) return
    moreLeft = tabs.scrollLeft > 2
    moreRight = tabs.scrollLeft + tabs.clientWidth < tabs.scrollWidth - 2
  }

  /** Brings the current tab into the strip, centred when it can be. */
  function revealTab(smooth: boolean) {
    if (!tabs || !isStrip()) return
    const b = tabs.querySelector<HTMLElement>('[aria-current="page"]')
    if (!b) return
    const li = b.parentElement as HTMLElement
    const left = li.offsetLeft - (tabs.clientWidth - li.offsetWidth) / 2
    tabs.scrollTo({ left: Math.max(0, left), behavior: smooth && !reducedMotion() ? 'smooth' : 'auto' })
  }

  function choose(s: Section) {
    const changed = editor.section !== s
    editor.section = s
    editor.hovered = undefined
    if (!changed || !isStrip()) return
    // The tab strip sticks at the top: a new page starts at its title, not halfway down.
    requestAnimationFrame(() => {
      const page = document.querySelector<HTMLElement>('.page-col')
      const strip = tabs?.closest('nav')
      if (!page || !strip) return
      const stuck = strip.getBoundingClientRect().bottom
      const top = page.getBoundingClientRect().top
      if (top < stuck) window.scrollTo({ top: window.scrollY + top - stuck - 12, behavior: 'auto' })
    })
  }

  $effect(() => {
    void editor.section
    requestAnimationFrame(() => { revealTab(true); edges() })
  })
  $effect(() => {
    if (!tabs) return
    const ro = new ResizeObserver(() => { edges(); revealTab(false) })
    ro.observe(tabs)
    return () => ro.disconnect()
  })

  // The save bar (narrow windows) steps aside while the change list, with its own Save button, is on screen.
  let changesCol = $state<HTMLElement>()
  let listInView = $state(false)
  $effect(() => {
    if (!changesCol) return
    const io = new IntersectionObserver(([e]) => (listInView = !!e?.isIntersecting), { rootMargin: '0px 0px -40px 0px' })
    io.observe(changesCol)
    return () => io.disconnect()
  })
  const barShown = $derived(changeCount > 0 && !doc.readOnly && !listInView)

  function reviewChanges() {
    const col = changesCol
    if (!col) return
    col.scrollIntoView({ behavior: reducedMotion() ? 'auto' : 'smooth', block: 'start' })
    requestAnimationFrame(() => col.querySelector<HTMLElement>('h2')?.focus({ preventScroll: true }))
  }

  const moreItems = $derived([
    { label: t('saveAs'), onclick: save, disabled: doc.readOnly, phoneOnly: true },
    { label: t('exportText'), onclick: exportText },
    { label: t('print'), onclick: print },
    { label: t('openAnother'), onclick: onopen },
  ])
</script>

<svelte:window onkeydown={onKey} onpagehide={persist} />
<svelte:document onvisibilitychange={() => { if (document.visibilityState === 'hidden') persist() }} />

<div class="editor" class:has-bar={changeCount > 0 && !doc.readOnly} style:--header-h="{headerHeight}px">
  <header class="top" bind:clientHeight={headerHeight}>
    <div class="brand">
      <span class="mark" aria-hidden="true"><svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M9 1 3 9h5l-1 6 6-8H8l1-6Z" /></svg></span>
      <span class="name">{productName}</span>
    </div>
    <div class="file">
      <span class="file-name" title={doc.fileName}>{device ? device.portLabel : (doc.fileName ?? L('Configuration'))}</span>
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
      <button type="button" class="btn quiet wide-only" onclick={exportText}>{t('exportText')}</button>
      <button type="button" class="btn quiet wide-only" onclick={print}>{t('print')}</button>
      <button type="button" class="btn quiet wide-only" onclick={onopen}>{t('openAnother')}</button>
      <span class="sep wide-only" aria-hidden="true"></span>
      <span class="header-tools"><Toolbar /></span>
      <span class="narrow-only">
        <MoreMenu label={t('moreActions')} items={moreItems}>
          {#snippet extra()}<Toolbar />{/snippet}
        </MoreMenu>
      </span>
      <button type="button" class="btn primary header-save" disabled={doc.readOnly} onclick={save}>{t('saveAs')}</button>
    </div>
  </header>

  <div class="body">
    <nav class="sidebar" class:more-left={moreLeft} class:more-right={moreRight} aria-label={t('sections')}>
      <div class="identity">
        <span class="model">{model}</span>
        <dl>
          <dt>{t('serialLabel')}</dt><dd>{c.serial ?? '—'}</dd>
          <dt>{t('firmwareLabel')}</dt><dd>{c.firmware.toString()}</dd>
          {#if c.readDate}<dt>{t('readLabel')}</dt><dd title={formatDateTime(c.readDate)}>{c.readDate.toLocaleDateString(currentLocale(), { dateStyle: 'medium' })}</dd>{/if}
        </dl>
      </div>
      <ul bind:this={tabs} onscroll={edges}>
        {#each sections as s (s)}
          <li>
            <button type="button" class="nav" aria-current={editor.section === s ? 'page' : undefined}
              onclick={() => choose(s)}>
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
      {#if device}
        <div class="device-banner" role="status">
          <svg width="18" height="18" viewBox="0 0 20 20" aria-hidden="true"><path d="M7 3v4M13 3v4M5 7h10v3a5 5 0 0 1-10 0V7zM10 15v3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
          <p>{t('deviceBanner', { model, port: device.portLabel, time: readAt })}</p>
        </div>
      {/if}
      <div class="content">
        <div class="page-col">
          {#key editor.section}
            <SectionView section={editor.section} />
          {/key}
        </div>
        {#if editor.showsChanges}
          <div class="changes-col" bind:this={changesCol}><ChangeList onsave={save} /></div>
        {/if}
      </div>
    </main>
  </div>

  {#if changeCount > 0 && !doc.readOnly}
    <div class="savebar" class:shown={barShown} role="region" aria-label={L('Changes')} inert={!barShown}>
      <button type="button" class="savebar-count" aria-label={t('reviewChanges')} onclick={reviewChanges}>
        <span>{L('Changes')}</span>
        <span class="savebar-n">{changeCount}</span>
        <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true"><path d="M3 4.5 6 7.5l3-3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
      </button>
      <button type="button" class="btn primary" onclick={save}>{t('saveAs')}</button>
    </div>
  {/if}
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
    position: sticky; top: var(--header-h); align-self: flex-start; height: calc(100vh - var(--header-h)); overflow: auto;
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
  @media (hover: hover) { .nav:hover { background: var(--line-faint); } }
  .nav[aria-current='page'] { background: var(--accent-soft); color: var(--accent); font-weight: 600; }
  .nav[aria-current='page'] svg { color: var(--accent); }
  .nav-title { flex: 1; }
  .badge { font: 500 12px var(--font-mono); color: var(--changed); }

  .main { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .strip { border-bottom: 1px solid var(--line); }
  .device-banner {
    display: flex; align-items: center; gap: 10px; margin: 20px 28px 0; padding: 11px 14px;
    border: 1px solid color-mix(in srgb, var(--accent) 35%, var(--line)); border-radius: var(--radius-panel);
    background: var(--accent-soft); color: var(--ink);
  }
  .device-banner svg { flex: none; color: var(--accent); }
  .device-banner p { margin: 0; font-size: 13.5px; }
  .content { flex: 1; display: flex; flex-wrap: wrap; align-items: flex-start; gap: 24px; padding: 28px; }
  .page-col { flex: 999 1 520px; min-width: 0; }
  .changes-col { flex: 1 1 280px; max-width: 340px; position: sticky; top: calc(var(--header-h) + 28px); height: calc(100vh - var(--header-h) - 56px); min-height: 320px; }

  .print-report { display: none; }

  .narrow-only { display: none; }
  .header-tools { display: contents; }
  .savebar { display: none; }

  @media (max-width: 1100px) {
    .changes-col { max-width: none; position: static; height: auto; flex-basis: 100%; scroll-margin-top: calc(var(--header-h) + 64px); }

    /* The change list is now at the very end of the page: Save rides along at the bottom of the screen. */
    .savebar {
      position: fixed; z-index: 20; left: 0; right: 0; bottom: 0;
      display: flex; align-items: center; justify-content: space-between; gap: 12px;
      padding: 10px max(16px, env(safe-area-inset-right)) calc(10px + env(safe-area-inset-bottom)) max(16px, env(safe-area-inset-left));
      background: color-mix(in srgb, var(--surface) 94%, transparent);
      -webkit-backdrop-filter: blur(10px); backdrop-filter: blur(10px);
      border-top: 1px solid var(--line);
      box-shadow: 0 -8px 24px -18px rgba(20, 24, 29, 0.35);
      transform: translateY(110%); transition: transform 200ms cubic-bezier(0.2, 0.8, 0.2, 1);
    }
    .savebar.shown { transform: none; }
    .savebar-count {
      display: inline-flex; align-items: center; gap: 8px; min-height: 44px; padding: 0 10px 0 6px; margin-left: -6px;
      border: 0; border-radius: var(--radius-block); background: none; color: var(--ink); font: 500 14px var(--font-sans); cursor: pointer;
    }
    .savebar-count:hover { background: var(--line-faint); }
    .savebar-count svg { color: var(--muted); }
    .savebar-n {
      min-width: 22px; height: 22px; padding: 0 6px; border-radius: 11px; display: inline-flex; align-items: center; justify-content: center;
      background: color-mix(in srgb, var(--changed) 14%, var(--surface)); color: var(--changed); font: 600 12.5px var(--font-mono); font-variant-numeric: tabular-nums;
    }
    .savebar .btn { min-height: 44px; padding: 0 20px; font-size: 14px; }
    .has-bar .content { padding-bottom: calc(28px + 64px + env(safe-area-inset-bottom)); }
  }

  @media (max-width: 860px) {
    .body { flex-direction: column; background: none; }
    .wide-only { display: none; }
    .narrow-only { display: inline-flex; }
    .file { flex: 1 1 0; min-width: 72px; }
    .file-meta { display: none; }

    /* Sections: a strip of tabs that scrolls on its own and sticks under the header. */
    .sidebar {
      position: sticky; top: var(--header-h); z-index: 9; align-self: stretch; min-width: 0;
      height: auto; flex: none; padding: 0; overflow: visible;
      border-right: 0; border-bottom: 1px solid var(--line); background: var(--surface-sunken);
    }
    .sidebar::before, .sidebar::after {
      content: ''; position: absolute; top: 0; bottom: 0; width: 36px; pointer-events: none;
      opacity: 0; transition: opacity 160ms;
    }
    .sidebar::before { left: 0; background: linear-gradient(to right, var(--surface-sunken) 20%, transparent); }
    .sidebar::after { right: 0; background: linear-gradient(to left, var(--surface-sunken) 20%, transparent); }
    .sidebar.more-left::before, .sidebar.more-right::after { opacity: 1; }
    .identity { display: none; }
    ul {
      flex-direction: row; gap: 2px; overflow-x: auto; overscroll-behavior-x: contain;
      padding: 6px max(10px, env(safe-area-inset-right)) 6px max(10px, env(safe-area-inset-left));
      scroll-snap-type: x proximity; scroll-padding-inline: 10px; scrollbar-width: none;
    }
    ul::-webkit-scrollbar { display: none; }
    li { flex: none; scroll-snap-align: start; }
    .nav { width: auto; white-space: nowrap; padding: 8px 12px; }
    .content { padding: 18px 14px; }
  }

  @media (max-width: 600px) {
    .top { position: static; flex-wrap: nowrap; gap: 8px; padding: 6px 6px 6px 12px; }
    .name, .sep, .header-tools, .header-save { display: none; }
    .actions { flex-wrap: nowrap; gap: 0; }
    .sidebar { top: 0; }
    .device-banner { margin: 14px 14px 0; }
  }
  /* Phones on their side: no room for two sticky bars. */
  @media (max-width: 860px) and (max-height: 500px) {
    .top { position: static; }
    .sidebar { top: 0; }
  }
  @media (pointer: coarse) {
    .nav { min-height: 44px; }
  }

  @media print {
    .editor { display: none; }
    .print-report { display: block; margin: 0; font: 10pt/1.45 var(--font-mono); white-space: pre-wrap; color: #000; }
  }
</style>
