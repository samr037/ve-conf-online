<!--
  The header's "⋯" button on narrow windows: the actions that no longer fit in the header.
  A disclosure (button + panel): arrow keys move between items, Escape or a tap outside closes it.
-->
<script lang="ts">
  import type { Snippet } from 'svelte'

  export interface MoreItem {
    label: string
    onclick: () => void
    disabled?: boolean
    /** Shown only on phones, where the header has no room for it. */
    phoneOnly?: boolean
  }

  let { label, items, extra }: { label: string; items: MoreItem[]; extra?: Snippet } = $props()
  let open = $state(false)
  let root: HTMLElement
  let trigger: HTMLButtonElement
  const id = `more-${Math.random().toString(36).slice(2, 8)}`

  const focusables = () => [...root.querySelectorAll<HTMLElement>('.panel button:not(:disabled), .panel select')].filter((e) => e.offsetParent !== null)

  function toggle() {
    open = !open
    if (open) requestAnimationFrame(() => focusables()[0]?.focus())
  }
  function close(refocus: boolean) {
    open = false
    if (refocus) trigger.focus()
  }
  function run(item: MoreItem) {
    close(false)
    item.onclick()
  }
  function onKey(e: KeyboardEvent) {
    if (!open) return
    if (e.key === 'Escape') { e.preventDefault(); close(true); return }
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return
    if ((e.target as HTMLElement).tagName === 'SELECT') return
    const list = focusables()
    if (!list.length) return
    e.preventDefault()
    const at = list.indexOf(document.activeElement as HTMLElement)
    const next = e.key === 'ArrowDown' ? (at + 1) % list.length : (at - 1 + list.length) % list.length
    list[next]?.focus()
  }
</script>

<svelte:window onpointerdown={(e) => { if (open && !root.contains(e.target as Node)) close(false) }} />

<div class="more" bind:this={root} onkeydown={onKey} onfocusout={(e) => { if (open && e.relatedTarget && !root.contains(e.relatedTarget as Node)) close(false) }} role="presentation">
  <button type="button" class="icon-btn" bind:this={trigger} aria-label={label} title={label} aria-expanded={open} aria-controls={id} onclick={toggle}>
    <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true"><circle cx="4" cy="9" r="1.4" fill="currentColor" /><circle cx="9" cy="9" r="1.4" fill="currentColor" /><circle cx="14" cy="9" r="1.4" fill="currentColor" /></svg>
  </button>
  {#if open}
    <div class="panel" {id}>
      {#each items as item (item.label)}
        <button type="button" class="item" class:phone-only={item.phoneOnly} disabled={item.disabled} onclick={() => run(item)}>{item.label}</button>
      {/each}
      {#if extra}<div class="extra phone-only">{@render extra()}</div>{/if}
    </div>
  {/if}
</div>

<style>
  .more { position: relative; display: inline-flex; }
  .panel {
    position: absolute; z-index: 30; top: calc(100% + 6px); right: 0; min-width: 220px; max-width: calc(100vw - 24px);
    display: flex; flex-direction: column; padding: 4px;
    background: var(--surface); border: 1px solid var(--line-strong); border-radius: var(--radius-panel); box-shadow: var(--shadow-pop);
  }
  .item {
    display: flex; align-items: center; min-height: 36px; padding: 0 12px; border: 0; border-radius: 6px;
    background: none; text-align: left; font: 14px var(--font-sans); color: var(--ink); white-space: nowrap; cursor: pointer;
  }
  .item:hover:not(:disabled), .item:focus-visible { background: var(--accent-soft); box-shadow: none; }
  .item:disabled { opacity: 0.45; cursor: default; }
  .extra { margin-top: 4px; padding: 4px 4px 0; border-top: 1px solid var(--line); }
  .phone-only { display: none; }
  @media (max-width: 600px) { .phone-only { display: flex; } }
  @media (pointer: coarse) { .item { min-height: 44px; } }
</style>
