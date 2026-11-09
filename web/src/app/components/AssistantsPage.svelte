<!-- The Assistants tab: what is programmed in the inverter, its answers, and the wizard to change them. -->
<script lang="ts">
  import { appText } from '../../lib/i18n/app'
  import { L, formatFixed } from '../../lib/rules'
  import { importLibrary } from '../library'
  import { editor } from '../store.svelte'

  const model = $derived((editor.rev, editor.assistants!))
  const status = $derived((editor.rev, model.status))
  const installed = $derived((editor.rev, model.installed))
  const available = $derived((editor.rev, status.k === 'ready' ? model.available : []))
  const used = $derived((editor.rev, model.codeSize))
  const capacity = $derived((editor.rev, Math.max(model.capacity, 1)))
  const fraction = $derived(Math.min(1, used / capacity))
  const t = (k: Parameters<typeof appText>[1], v?: Record<string, string | number>) => appText(editor.language, k, v)

  let picker: HTMLInputElement
  let libraryError = $state<string | undefined>(undefined)
  let addOpen = $state(false)
  let menuFor = $state<number | undefined>(undefined)

  async function onLibrary(e: Event) {
    const input = e.currentTarget as HTMLInputElement
    const f = input.files?.[0]
    input.value = ''
    if (!f) return
    try {
      libraryError = undefined
      editor.setLibrary(await importLibrary(f.name, new Uint8Array(await f.arrayBuffer())))
    } catch {
      libraryError = t('libraryInvalid')
    }
  }

  function configure(index: number | undefined, adding?: Parameters<typeof model.wizard>[1]) {
    addOpen = false
    const s = model.wizard(index, adding)
    if (s) editor.push({ k: 'wizard', session: s })
    editor.bump()
  }

  const n = (x: number) => formatFixed(x, 0, true)
</script>

<svelte:window onpointerdown={(e) => { if (!(e.target as HTMLElement).closest?.('[data-menu]')) { addOpen = false; menuFor = undefined } }} />

<input type="file" class="visually-hidden" bind:this={picker} onchange={onLibrary} tabindex="-1" aria-hidden="true" />

{#if editor.device}
  <div class="card intro device-note">
    <svg width="24" height="24" viewBox="0 0 20 20" aria-hidden="true"><path d="M7 3v4M13 3v4M5 7h10v3a5 5 0 0 1-10 0V7zM10 15v3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
    <div><p>{t('deviceAssistants')}</p></div>
  </div>
{:else if status.k === 'noLibrary' && editor.libraryLoading}
  <p class="loading" role="status">{t('libraryLoading')}</p>
{:else if status.k === 'noLibrary'}
  <div class="card intro">
    <svg width="28" height="28" viewBox="0 0 28 28" aria-hidden="true"><rect x="4" y="5" width="5" height="18" rx="1" fill="none" stroke="currentColor" stroke-width="1.6" /><rect x="11" y="5" width="5" height="18" rx="1" fill="none" stroke="currentColor" stroke-width="1.6" /><path d="m18.5 6.5 4.6-1.2 4 16-4.6 1.2z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" /></svg>
    <div>
      <h2>{L("Victron's assistant library is needed")}</h2>
      <p>{t('libraryLead')}</p>
      <button type="button" class="btn primary" onclick={() => picker.click()}>{t('chooseLibrary')}</button>
      {#if libraryError}<p class="error" role="alert">{libraryError}</p>{/if}
    </div>
  </div>
{:else if status.k === 'failed'}
  <div class="card intro warn" role="alert">
    <svg width="24" height="24" viewBox="0 0 18 18" aria-hidden="true"><path d="M9 2.5 16.2 15H1.8L9 2.5Z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" /><path d="M9 7.4v3.4M9 12.8v.1" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" /></svg>
    <div>
      <h2>{status.why}</h2>
      <p>{L('The installed library cannot read back the assistant program in this file. You can still change settings on the other pages; the program is kept unchanged.')}</p>
    </div>
  </div>
{:else}
  <div class="card memory">
    <div class="memory-head">
      <span>{L('Assistant memory')}</span>
      <span class="mono">{L('%@ of %@ bytes', n(used), n(capacity))}</span>
    </div>
    <div class="bar" role="meter" aria-label={L('Assistant memory used')} aria-valuemin="0" aria-valuemax={capacity} aria-valuenow={used} aria-valuetext={L('%@ of %@ bytes', String(used), String(capacity))}>
      <span class="fill" class:full={fraction > 0.9} style:width="{fraction * 100}%"></span>
    </div>
  </div>

  <section class="group">
    <h2 class="caps">{L('Installed')}</h2>
    <div class="list">
      {#if installed.length === 0}
        <p class="empty">{L('No assistants are programmed in this configuration.')}</p>
      {/if}
      {#each installed as item (item.id)}
        <article class="assistant">
          <div class="a-head">
            <div class="a-title">
              <h3>{item.title}</h3>
              <span class="mono meta">{L('%@ · version %@', item.package.baseName, item.package.id.toString(16).toUpperCase().padStart(4, '0'))}</span>
            </div>
            <div class="a-actions" data-menu>
              <button type="button" class="btn" onclick={() => configure(item.id)}>{L('Configure…')}</button>
              <button type="button" class="icon-btn" aria-haspopup="menu" aria-expanded={menuFor === item.id} aria-label={L('More actions for %@', item.title)} onclick={() => (menuFor = menuFor === item.id ? undefined : item.id)}>
                <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true"><circle cx="4" cy="9" r="1.4" fill="currentColor" /><circle cx="9" cy="9" r="1.4" fill="currentColor" /><circle cx="14" cy="9" r="1.4" fill="currentColor" /></svg>
              </button>
              {#if menuFor === item.id}
                <div class="menu" role="menu">
                  <button type="button" role="menuitem" disabled={item.id === 0} onclick={() => { menuFor = undefined; model.move(item.id, -1) }}>{L('Move Up')}</button>
                  <button type="button" role="menuitem" disabled={item.id === installed.length - 1} onclick={() => { menuFor = undefined; model.move(item.id, 1) }}>{L('Move Down')}</button>
                  <hr />
                  <button type="button" role="menuitem" class="danger" onclick={() => { menuFor = undefined; model.remove(item.id) }}>{L('Remove')}</button>
                </div>
              {/if}
            </div>
          </div>
          {#if item.summary.length}
            <dl>
              {#each item.summary as s, i (i)}
                <dt>{s.label}</dt>
                <dd>{s.value}</dd>
              {/each}
            </dl>
          {/if}
        </article>
      {/each}
    </div>
  </section>

  <div class="add" data-menu>
    <button type="button" class="btn" aria-haspopup="menu" aria-expanded={addOpen} onclick={() => (addOpen = !addOpen)}>
      <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M7 2v10M2 7h10" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" /></svg>
      {L('Add Assistant…')}
    </button>
    {#if addOpen}
      <div class="menu wide" role="menu">
        {#each available as a (a.package.id)}
          <button type="button" role="menuitem" onclick={() => configure(undefined, a.package)}>
            <span class="m-title">{a.title}</span>
            {#if a.blurb}<span class="m-blurb">{a.blurb}</span>{/if}
          </button>
        {/each}
      </div>
    {/if}
    {#if editor.library}
      <span class="lib">{t('libraryName', { name: editor.library.name })} · <button type="button" class="link" onclick={() => picker.click()}>{t('replaceLibrary')}</button></span>
    {/if}
    {#if libraryError}<p class="error" role="alert">{libraryError}</p>{/if}
  </div>
{/if}

<style>
  .card { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-panel); }
  .intro { display: flex; gap: 16px; padding: 22px; color: var(--accent); }
  .intro.warn { color: var(--changed); }
  .intro h2 { margin: 2px 0 6px; font-size: 16px; font-weight: 600; color: var(--ink); }
  .intro p { margin: 0 0 14px; font-size: 14px; line-height: 1.55; color: var(--ink-2); max-width: 60ch; }
  .intro svg { flex: none; }
  .error { color: var(--danger) !important; margin-top: 10px !important; font-size: 13px !important; }
  .memory { padding: 14px 18px 16px; }
  .memory-head { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; margin-bottom: 10px; font-size: 14px; }
  .mono { font-family: var(--font-mono); font-size: 12.5px; color: var(--muted); font-variant-numeric: tabular-nums; }
  .bar { height: 6px; border-radius: 3px; background: var(--line); overflow: hidden; }
  .fill { display: block; height: 100%; background: var(--accent); border-radius: 3px; transition: width 240ms ease-out; }
  .fill.full { background: var(--changed); }
  .group { display: flex; flex-direction: column; gap: 8px; }
  .caps { margin: 0; padding-left: 2px; font-size: 11.5px; font-weight: 700; letter-spacing: 0.07em; text-transform: uppercase; color: var(--muted); }
  .list { display: flex; flex-direction: column; gap: 10px; }
  .empty { margin: 0; padding: 18px; font-size: 14px; color: var(--muted); background: var(--surface); border: 1px dashed var(--line-strong); border-radius: var(--radius-panel); }
  .assistant { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-panel); padding: 16px 18px; }
  .a-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; }
  .a-title { min-width: 0; }
  h3 { margin: 0; font-size: 16px; font-weight: 600; }
  .meta { display: block; margin-top: 2px; font-size: 11.5px; }
  .a-actions { position: relative; display: flex; align-items: center; gap: 4px; flex: none; }
  dl { display: grid; grid-template-columns: minmax(140px, max-content) minmax(0, 1fr); gap: 6px 18px; margin: 14px 0 0; padding-top: 12px; border-top: 1px solid var(--line-faint); font-size: 13px; }
  dt { color: var(--muted); }
  dd { margin: 0; color: var(--ink); white-space: pre-line; font-variant-numeric: tabular-nums; }
  .add { position: relative; display: flex; flex-wrap: wrap; align-items: center; gap: 12px 16px; }
  .lib { font-size: 12px; color: var(--muted); }
  .link { padding: 0; border: 0; background: none; color: var(--accent); font: inherit; cursor: pointer; text-decoration: underline; text-underline-offset: 2px; }
  .menu {
    position: absolute; z-index: 30; top: calc(100% + 4px); right: 0; min-width: 180px;
    display: flex; flex-direction: column; padding: 4px;
    background: var(--surface); border: 1px solid var(--line-strong); border-radius: var(--radius-panel); box-shadow: var(--shadow-pop);
  }
  .menu.wide { left: 0; right: auto; width: min(460px, calc(100vw - 40px)); max-height: 380px; overflow: auto; }
  .menu button { display: flex; flex-direction: column; align-items: flex-start; gap: 2px; padding: 8px 10px; border: 0; border-radius: 6px; background: none; text-align: left; font: 13.5px var(--font-sans); color: var(--ink); cursor: pointer; }
  .menu button:hover:not(:disabled), .menu button:focus-visible { background: var(--accent-soft); }
  .menu button:disabled { opacity: 0.4; cursor: default; }
  .menu .danger { color: var(--danger); }
  .menu hr { width: 100%; margin: 4px 0; border: 0; border-top: 1px solid var(--line); }
  .m-title { font-weight: 500; }
  .m-blurb { font-size: 12px; line-height: 1.4; color: var(--muted); }
  .loading { color: var(--muted); padding: var(--space-sheet) 0; }
  @media (pointer: coarse) {
    .menu button { min-height: 44px; justify-content: center; }
    .link { display: inline-flex; align-items: center; min-height: 44px; }
  }
  @media (max-width: 480px) {
    .a-head { flex-wrap: wrap; }
    dl { grid-template-columns: minmax(0, 1fr); gap: 2px 0; }
    dd + dt { margin-top: 8px; }
  }
</style>
