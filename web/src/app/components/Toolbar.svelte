<!-- Language and appearance pickers, shared by the open screen and the editor header. -->
<script lang="ts">
  import { appText } from '../../lib/i18n/app'
  import { languageNames, languages, type Language } from '../../lib/i18n/locale'
  import { editor } from '../store.svelte'

  let { compact = false }: { compact?: boolean } = $props()
  const t = (k: Parameters<typeof appText>[1]) => appText(editor.language, k)
  const nextTheme = { auto: 'light', light: 'dark', dark: 'auto' } as const
  const themeLabel = $derived(t(editor.theme === 'auto' ? 'themeAuto' : editor.theme === 'light' ? 'themeLight' : 'themeDark'))
</script>

<div class="tools" class:compact>
  <label class="lang">
    <span class="visually-hidden">{t('language')}</span>
    <svg width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.3" fill="none" stroke="currentColor" stroke-width="1.2" /><path d="M1.8 8h12.4M8 1.7c2 2 2 10.6 0 12.6M8 1.7c-2 2-2 10.6 0 12.6" fill="none" stroke="currentColor" stroke-width="1.2" /></svg>
    <select value={editor.language} onchange={(e) => editor.setLanguage(e.currentTarget.value as Language)}>
      {#each languages as l (l)}<option value={l}>{languageNames[l]}</option>{/each}
    </select>
  </label>
  <button type="button" class="icon-btn" aria-label="{t('theme')}: {themeLabel}" title="{t('theme')}: {themeLabel}" onclick={() => editor.setTheme(nextTheme[editor.theme])}>
    {#if editor.theme === 'light'}
      <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="3" fill="none" stroke="currentColor" stroke-width="1.4" /><path d="M8 1v2M8 13v2M1 8h2M13 8h2M3 3l1.4 1.4M11.6 11.6 13 13M3 13l1.4-1.4M11.6 4.4 13 3" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" /></svg>
    {:else if editor.theme === 'dark'}
      <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><path d="M13.5 9.6A5.8 5.8 0 0 1 6.4 2.5a5.8 5.8 0 1 0 7.1 7.1Z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round" /></svg>
    {:else}
      <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.4" /><path d="M8 2a6 6 0 0 1 0 12Z" fill="currentColor" /></svg>
    {/if}
  </button>
</div>

<style>
  .tools { display: flex; align-items: center; gap: 4px; }
  .lang { position: relative; display: inline-flex; align-items: center; gap: 6px; height: 34px; padding: 0 8px; border-radius: var(--radius-block); color: var(--muted); }
  .lang:hover { background: var(--line-faint); color: var(--ink); }
  .lang:focus-within { box-shadow: var(--focus); }
  .lang select { appearance: none; border: 0; background: transparent; color: var(--ink-2); font: 500 13px var(--font-sans); cursor: pointer; padding-right: 2px; }
  .lang select:focus { outline: none; }
</style>
