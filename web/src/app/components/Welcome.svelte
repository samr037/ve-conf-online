<!-- The open screen: drop a .rvsc or choose one. Room is kept for a second source (a connected device) later. -->
<script lang="ts">
  import { productName } from '../../lib/brand'
  import { appText } from '../../lib/i18n/app'
  import { editor } from '../store.svelte'
  import Diagram from './Diagram.svelte'
  import Toolbar from './Toolbar.svelte'

  let { onfile, error }: { onfile: (f: File) => void; error?: string } = $props()
  let picker: HTMLInputElement
  let over = $state(false)
  const t = (k: Parameters<typeof appText>[1]) => appText(editor.language, k)

  function drop(e: DragEvent) {
    e.preventDefault()
    over = false
    const f = e.dataTransfer?.files?.[0]
    if (f) onfile(f)
  }
</script>

<div class="welcome">
  <header class="top">
    <div class="brand">
      <span class="mark" aria-hidden="true"><svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M9 1 3 9h5l-1 6 6-8H8l1-6Z" /></svg></span>
      <span class="name">{productName}</span>
    </div>
    <Toolbar compact />
  </header>

  <main>
    <section class="card" aria-labelledby="open-title">
      <div class="art"><Diagram lit={new Set(['charger', 'battery'])} model="MultiPlus-II" hasSecondInput={false} showsRelay={false} height={150} decorative /></div>
      <div class="content">
        <h1 id="open-title">{t('openTitle')}</h1>
        <p class="lead">{t('openLead')}</p>

        <div class="sources">
          <div
            class="drop"
            class:over
            role="group"
            aria-label={t('dropHint')}
            ondragenter={(e) => { e.preventDefault(); over = true }}
            ondragover={(e) => { e.preventDefault(); over = true }}
            ondragleave={() => (over = false)}
            ondrop={drop}
          >
            <svg width="28" height="28" viewBox="0 0 28 28" aria-hidden="true"><path d="M8 4h8l6 6v14H8z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" /><path d="M16 4v6h6" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" /><path d="M15 13v7M12 17l3 3 3-3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" /></svg>
            <span class="drop-text">{over ? t('dropToOpen') : t('dropHint')}</span>
            <button type="button" class="btn primary large" onclick={() => picker.click()}>{t('chooseFile')}</button>
            <input type="file" accept=".rvsc,.vsc,application/octet-stream" class="visually-hidden" bind:this={picker} tabindex="-1" aria-hidden="true"
              onchange={(e) => { const f = e.currentTarget.files?.[0]; e.currentTarget.value = ''; if (f) onfile(f) }} />
          </div>
        </div>
        {#if error}<p class="error" role="alert">{error}</p>{/if}
        <p class="where">{t('whereFrom')}</p>
      </div>
    </section>
  </main>
</div>

<style>
  .welcome { min-height: 100vh; display: flex; flex-direction: column; }
  .top { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 14px 24px; }
  .brand { display: flex; align-items: center; gap: 10px; }
  .mark { width: 28px; height: 28px; border-radius: 6px; background: var(--accent); color: var(--on-accent); display: flex; align-items: center; justify-content: center; }
  .name { font-weight: 600; font-size: 15px; }
  main { flex: 1; display: flex; align-items: center; justify-content: center; padding: 24px 16px 64px; }
  .card { width: min(640px, 100%); background: var(--surface); border: 1px solid var(--line); border-radius: 14px; overflow: hidden; box-shadow: 0 30px 60px -40px rgba(20, 24, 29, 0.35); }
  .art { border-bottom: 1px solid var(--line); }
  .content { padding: 28px 32px 30px; }
  h1 { margin: 0; font-size: 26px; font-weight: 600; letter-spacing: -0.015em; }
  .lead { margin: 6px 0 22px; font-size: 15px; color: var(--muted); }
  .sources { display: grid; gap: 12px; }
  .drop {
    display: flex; flex-direction: column; align-items: center; gap: 12px;
    padding: 28px 20px; border: 1.5px dashed var(--line-strong); border-radius: 12px;
    color: var(--muted); background: var(--surface-sunken); text-align: center;
    transition: border-color 140ms, background-color 140ms, color 140ms;
  }
  .drop.over { border-color: var(--accent); background: var(--accent-soft); color: var(--accent); }
  .drop-text { font-size: 14px; color: var(--ink-2); }
  .drop.over .drop-text { color: var(--accent); }
  .error { margin: 14px 0 0; font-size: 13.5px; color: var(--danger); }
  .where { margin: 18px 0 0; font-size: 13px; color: var(--muted); }
  @media (max-width: 520px) { .content { padding: 22px 20px; } h1 { font-size: 22px; } }
</style>
