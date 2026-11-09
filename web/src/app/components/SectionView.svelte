<!-- One sidebar tab rendered from the catalog: sub-page picker, then its group boxes as form sections. -->
<script lang="ts">
  import {
    Access, GridPages, L, SectionPages, capitalizedFirst, resolveText, rowStates, sectionTitle, type Section,
  } from '../../lib/rules'
  import { editor } from '../store.svelte'
  import AssistantsPage from './AssistantsPage.svelte'
  import SettingRow from './SettingRow.svelte'

  let { section }: { section: Section } = $props()

  const ctx = $derived((editor.rev, editor.doc!.ruleContext))
  const entries = $derived(SectionPages.entries(section, ctx))
  const selected = $derived(entries.find((e) => e.id === editor.subpage[section]) ?? entries[0])
  const groups = $derived(selected ? rowStates(selected.page, section, ctx) : [])
  const showsBanner = $derived(section === 'grid' && !ctx.session.readOnly && !!selected
    && (selected.page.name === GridPages.selectionPage || groups.some((g) => g.rows.some((r) => Access.isLocked(r.control, ctx)))))
  const paramsInvalid = $derived(section === 'grid' && !ctx.session.readOnly && selected?.page.name === GridPages.selectionPage && !GridPages.paramsValid(ctx.config))

  $effect(() => {
    const lit = new Set<string>()
    for (const g of groups) for (const p of g.section.lit) lit.add(p)
    editor.pageLit = lit
  })
</script>

<div class="page">
  <header class="page-head">
    <h1>{sectionTitle(section)}</h1>
    {#if entries.length > 1}
      <div class="segmented" role="group" aria-label={L('Page')}>
        {#each entries as e (e.id)}
          <button type="button" aria-pressed={e.id === selected?.id} onclick={() => (editor.subpage = { ...editor.subpage, [section]: e.id })}>{e.title}</button>
        {/each}
      </div>
    {/if}
  </header>

  {#if section === 'assistants'}
    <AssistantsPage />
  {:else if selected}
    {#if showsBanner}
      <div class="banner" class:open={ctx.session.gridPasswordEntered}>
        <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
          <rect x="3.5" y="8" width="11" height="8" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.5" />
          <path d={ctx.session.gridPasswordEntered ? 'M6 8V5.5a3 3 0 0 1 5.8-1' : 'M6 8V5.5a3 3 0 0 1 6 0V8'} fill="none" stroke="currentColor" stroke-width="1.5" />
        </svg>
        <div class="banner-text">
          {#if ctx.session.gridPasswordEntered}
            <p>{L('Grid settings are unlocked until you close this document.')}</p>
          {:else if Access.gridCodeNeedsPassword(ctx)}
            <p>{L('Enter the grid code password to edit these settings.')}</p>
          {:else if selected.page.name === GridPages.selectionPage}
            <p>{L('No grid code is set in this file, so the first selection needs no password. Choose the correct country or standard. Once it is on the device, changing or disabling it needs the password.')}</p>
          {/if}
          {#if !ctx.session.gridPasswordEntered && ctx.config.data.version < 2}
            <p class="muted">{L('This file format cannot store grid authorization. Open a newer RVSC file.')}</p>
          {/if}
        </div>
        {#if !ctx.session.gridPasswordEntered}
          <button type="button" class="btn" disabled={ctx.config.data.version < 2} onclick={() => editor.push({ k: 'gridPassword' })}>{L('Unlock grid settings…')}</button>
        {/if}
      </div>
    {/if}
    {#if paramsInvalid}
      <div class="banner warn" role="alert">
        <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true"><path d="M9 2.5 16.2 15H1.8L9 2.5Z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" /><path d="M9 7.4v3.4M9 12.8v.1" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" /></svg>
        <p>{L('The grid code parameters do not match the selected grid code or belong to another firmware version. Select the grid code again to load its defaults (password required).')}</p>
      </div>
    {/if}

    {#each groups as g (g.section.section.id)}
      {@const title = resolveText(g.section.section.title, ctx)}
      <section
        class="group"
        aria-label={title ? capitalizedFirst(title) : undefined}
        onpointerenter={() => (editor.hovered = g.section.lit)}
        onpointerleave={() => { if (editor.hovered === g.section.lit) editor.hovered = undefined }}
      >
        {#if title}<h2>{capitalizedFirst(title)}</h2>{/if}
        <div class="card">
          {#each g.rows as row (row.control.name)}
            <SettingRow {row} />
          {/each}
        </div>
        {#if g.resetCount > 0}
          <p class="footnote">
            <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true"><path d="M9.6 6A3.6 3.6 0 1 1 8.5 3.4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" /><path d="M9.6 1.6v2.6H7" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" /></svg>
            {g.allReset ? L('Changing these settings requires a device reset after upload. The GX does it.') : L('Settings marked with the arrow require a device reset after upload. The GX does it.')}
          </p>
        {/if}
      </section>
    {/each}
    {#if groups.length === 0}
      <div class="empty">
        <p class="strong">{L('No settings on this page')}</p>
        <p>{L('The firmware in this device does not support any of the settings on this page.')}</p>
      </div>
    {/if}
  {:else}
    <div class="empty">
      <p class="strong">{L('No settings on this page')}</p>
      <p>{L('The firmware in this device does not support any of the settings on this page.')}</p>
    </div>
  {/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 22px; max-width: 820px; }
  .page-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px 20px; }
  h1 { margin: 0; font-size: 26px; font-weight: 600; letter-spacing: -0.015em; line-height: 1.15; }
  .group { display: flex; flex-direction: column; gap: 8px; }
  h2 {
    margin: 0; padding-left: 2px;
    font-size: 11.5px; font-weight: 700; letter-spacing: 0.07em; text-transform: uppercase; color: var(--muted);
  }
  .card { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-panel); }
  .footnote { display: flex; align-items: center; gap: 6px; margin: 0; padding-left: 2px; font-size: 12px; color: var(--muted); }
  .banner {
    display: flex; flex-wrap: wrap; align-items: center; gap: 12px 14px;
    padding: 14px 16px; border-radius: var(--radius-panel);
    background: var(--accent-soft); color: var(--accent); border: 1px solid color-mix(in srgb, var(--accent) 25%, transparent);
  }
  .banner.open { background: var(--surface); color: var(--muted); border-color: var(--line); }
  .banner.warn { background: color-mix(in srgb, var(--changed) 9%, var(--surface)); color: var(--changed); border-color: color-mix(in srgb, var(--changed) 35%, transparent); }
  .banner svg { flex: none; }
  .banner-text { flex: 1 1 280px; min-width: 0; }
  .banner p { margin: 0; font-size: 13.5px; line-height: 1.5; color: var(--ink); }
  .banner p + p { margin-top: 4px; }
  .banner .muted { color: var(--muted); }
  .empty { padding: 48px 0; text-align: center; color: var(--muted); }
  .empty p { margin: 4px 0; font-size: 13px; }
  .empty .strong { font-size: 14px; font-weight: 500; color: var(--ink); }
</style>
