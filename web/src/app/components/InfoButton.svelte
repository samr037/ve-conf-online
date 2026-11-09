<!-- The ⓘ button: the setting's help text, range, default and what a change implies (port of InfoButton). -->
<script lang="ts">
  import { Access, L, catalogTextOpt, cleanDescription, type RowState } from '../../lib/rules'

  let { row }: { row: RowState } = $props()
  let open = $state(false)
  let root: HTMLElement
  const id = `info-${Math.random().toString(36).slice(2, 8)}`

  const title = $derived(catalogTextOpt(row.control.help?.title) ?? row.label)
  const description = $derived.by(() => { const d = cleanDescription(row.control); return d !== undefined && d !== row.label ? d : undefined })
  const stored = $derived(Access.refs(row.control).map((r) => r.name).filter((n) => n.length > 0))
  const password = $derived((Access.passwordAreas(row.control, row.config) & 1) !== 0 || row.control.name === 'GridCodeComboBox')

  function onWindowPointer(e: PointerEvent) {
    if (open && root && !root.contains(e.target as Node)) open = false
  }
  function onKey(e: KeyboardEvent) {
    if (open && e.key === 'Escape') { open = false; root.querySelector('button')?.focus() }
  }
</script>

<svelte:window onpointerdown={onWindowPointer} onkeydown={onKey} />

<span class="info" bind:this={root}>
  <button type="button" class="icon-btn small" aria-expanded={open} aria-controls={id} aria-label={L('About %@', row.label)} title={L('About this setting')} onclick={() => (open = !open)}>
    <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.4" fill="none" stroke="currentColor" stroke-width="1.3" /><path d="M8 7.2v4M8 4.9v.1" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" /></svg>
  </button>
  {#if open}
    <div class="pop" {id} role="dialog" aria-label={title}>
      <h3>{title}</h3>
      {#if description}<p class="muted">{description}</p>{/if}
      {#if row.rangeDetail}<p class="range">{row.rangeDetail}</p>{/if}
      {#if row.helpText}<p class="help">{row.helpText}</p>{/if}
      {#if row.resetRequired}<p class="note">{L('Changing this setting requires a reset of the device after the file has been uploaded. The GX device does this for you.')}</p>{/if}
      {#if password}<p class="note">{L('Enter the grid code password on the Grid page to edit this setting.')}</p>{/if}
      {#if row.codec && !row.codec.isEditable}<p class="note">{L('This app does not yet reproduce the VE Configure handler that derives this value from several grid words. It is read-only.')}</p>{/if}
      {#if stored.length}<p class="stored">{L('Stored in %@', stored.join(', '))}</p>{/if}
    </div>
  {/if}
</span>

<style>
  .info { position: relative; display: inline-flex; }
  .pop {
    position: absolute; z-index: 20; top: calc(100% + 6px); right: -6px;
    width: min(380px, calc(100vw - 48px)); max-height: 440px; overflow: auto;
    padding: 14px 16px; text-align: left;
    background: var(--surface); border: 1px solid var(--line-strong); border-radius: var(--radius-panel);
    box-shadow: var(--shadow-pop);
  }
  h3 { margin: 0 0 6px; font-size: 14px; font-weight: 600; color: var(--ink); }
  p { margin: 0 0 8px; font-size: 13px; line-height: 1.5; color: var(--ink-2); white-space: pre-line; }
  p:last-child { margin-bottom: 0; }
  .muted { color: var(--muted); }
  .range { font-family: var(--font-mono); font-size: 12.5px; color: var(--ink); }
  .note { padding-left: 10px; border-left: 2px solid var(--line-strong); }
  .stored { font: 11.5px var(--font-mono); color: var(--muted); user-select: text; }
  /* Phones: the help sits at the bottom of the screen, full width, instead of hanging off the button. */
  @media (max-width: 600px) {
    .pop {
      position: fixed; z-index: 40; top: auto; right: max(10px, env(safe-area-inset-right)); left: max(10px, env(safe-area-inset-left));
      bottom: calc(10px + env(safe-area-inset-bottom)); width: auto; max-height: min(60vh, 440px);
      padding: 16px 18px; overscroll-behavior: contain;
    }
    p { font-size: 14px; }
  }
</style>
