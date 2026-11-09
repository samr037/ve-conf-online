<!--
  A modal built on the native <dialog>: focus stays inside, Escape cancels, the page behind is inert.
-->
<script lang="ts">
  import type { Snippet } from 'svelte'
  import { onMount } from 'svelte'

  interface Props {
    title: string
    /** Called on Escape or a click outside the panel. */
    oncancel: () => void
    width?: number
    tone?: 'normal' | 'warning'
    children: Snippet
    footer?: Snippet
    /** Element to focus when the dialog opens (defaults to the first focusable control). */
    initialFocus?: string
  }

  let { title, oncancel, width = 460, tone = 'normal', children, footer, initialFocus }: Props = $props()
  let el: HTMLDialogElement
  const id = `dlg-${Math.random().toString(36).slice(2, 8)}`

  onMount(() => {
    el.showModal()
    const target = initialFocus ? el.querySelector<HTMLElement>(initialFocus) : null
    target?.focus()
    return () => { if (el.open) el.close() }
  })

  function cancel(e: Event) {
    e.preventDefault()
    oncancel()
  }
</script>

<dialog
  bind:this={el}
  aria-labelledby={id}
  style:--dialog-width="{width}px"
  oncancel={cancel}
  onclick={(e) => { if (e.target === el) oncancel() }}
>
  <div class="panel" class:warning={tone === 'warning'}>
    <header>
      {#if tone === 'warning'}
        <svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true"><path d="M10 2.5 18 17H2L10 2.5Z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" /><path d="M10 8v4.2M10 14.6v.1" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" /></svg>
      {/if}
      <h2 {id}>{title}</h2>
    </header>
    <div class="body">{@render children()}</div>
    {#if footer}<footer>{@render footer()}</footer>{/if}
  </div>
</dialog>

<style>
  dialog {
    --dialog-max-height: calc(100vh - 48px);
    width: min(var(--dialog-width), calc(100vw - 32px));
    max-width: calc(100vw - 32px);
    padding: 0;
    border: 1px solid var(--line-strong);
    border-radius: var(--radius-card);
    background: var(--surface);
    color: var(--ink);
    box-shadow: var(--shadow-pop);
    max-height: var(--dialog-max-height);
  }
  @supports (height: 100dvh) { dialog { --dialog-max-height: calc(100dvh - 48px); } }
  dialog::backdrop { background: rgba(20, 24, 29, 0.32); }
  .panel { display: flex; flex-direction: column; max-height: calc(var(--dialog-max-height) - 2px); }
  header { display: flex; align-items: center; gap: 10px; padding: 20px 22px 6px; }
  .warning header { color: var(--changed); }
  h2 { margin: 0; font-size: 16px; font-weight: 600; color: var(--ink); line-height: 1.3; }
  .body { min-height: 0; padding: 8px 22px 18px; overflow: auto; overscroll-behavior: contain; font-size: 14px; line-height: 1.55; color: var(--ink-2); }
  footer {
    display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 8px;
    padding: 14px 22px; border-top: 1px solid var(--line); background: var(--surface-sunken);
    border-radius: 0 0 var(--radius-card) var(--radius-card);
  }

  /* Short windows (a phone on its side): use the height there is. */
  @media (max-height: 500px) {
    dialog { --dialog-max-height: calc(100vh - 16px); }
    @supports (height: 100dvh) { dialog { --dialog-max-height: calc(100dvh - 16px); } }
    header { padding-top: 14px; }
    footer { padding-top: 10px; padding-bottom: 10px; }
  }

  /* Phones: a sheet from the bottom edge, full width; the body scrolls, the buttons stay in reach. */
  @media (max-width: 600px) {
    dialog {
      --dialog-max-height: calc(100vh - max(16px, env(safe-area-inset-top)));
      width: 100%; max-width: 100%; margin: auto 0 0;
      border-width: 1px 0 0; border-radius: 14px 14px 0 0;
      animation: sheet-in 220ms cubic-bezier(0.2, 0.8, 0.2, 1);
    }
    @supports (height: 100dvh) { dialog { --dialog-max-height: calc(100dvh - max(16px, env(safe-area-inset-top))); } }
    header { padding: 18px max(18px, env(safe-area-inset-right)) 4px max(18px, env(safe-area-inset-left)); }
    h2 { font-size: 17px; }
    .body { padding: 8px max(18px, env(safe-area-inset-right)) 18px max(18px, env(safe-area-inset-left)); font-size: 15px; }
    footer {
      padding: 12px max(16px, env(safe-area-inset-right)) calc(12px + env(safe-area-inset-bottom)) max(16px, env(safe-area-inset-left));
      border-radius: 0;
    }
    footer > :global(.btn) { flex: 1 1 0; }
  }
  @keyframes sheet-in { from { transform: translateY(24px); opacity: 0.6; } }
  @media (prefers-reduced-motion: reduce) { dialog { animation: none; } }
</style>
