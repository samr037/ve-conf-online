<!-- Every difference from the loaded file, revertible one by one, and the save action (port of ChangeList.swift). -->
<script lang="ts">
  import { appText } from '../../lib/i18n/app'
  import { L, targetKey } from '../../lib/rules'
  import { restoreAll } from '../editorActions'
  import { editor } from '../store.svelte'

  let { onsave }: { onsave: () => void } = $props()

  const doc = $derived(editor.doc!)
  const changes = $derived((editor.rev, doc.changes))
  const integrity = $derived((editor.rev, doc.integrityProblem))
</script>

<aside class="changes" aria-labelledby="changes-title">
  <header>
    <h2 id="changes-title">{L('Changes')}</h2>
    {#if changes.length > 1}
      <button type="button" class="btn small quiet restore-all" onclick={restoreAll}>{appText(editor.language, 'restoreAll')}</button>
    {/if}
    <span class="count" class:some={changes.length > 0}>{changes.length === 0 ? L('None') : changes.length}</span>
  </header>

  {#if changes.length === 0}
    <div class="empty">
      <p class="strong">{L('No changes yet')}</p>
    </div>
  {:else}
    <ul>
      {#each changes as c (targetKey(c.target))}
        <li>
          <div class="what">
            <span class="label">{c.label}</span>
            <span class="values">
              {#if c.before}<s>{c.before}</s><span class="arrow" aria-label={L('changed to')}>→</span>{/if}
              <span class="after">{c.after}</span>
            </span>
          </div>
          {#if c.target.t !== 'assistants'}
            <button type="button" class="btn small quiet" aria-label={appText(editor.language, 'restoreLabel', { label: c.label })} title={L('Restore Loaded Value')} onclick={() => doc.revert(c)}>
              {appText(editor.language, 'restore')}
            </button>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}

  <footer>
    {#if integrity}
      <p class="blocked" role="status">
        <svg width="14" height="14" viewBox="0 0 18 18" aria-hidden="true"><path d="M9 2.5 16.2 15H1.8L9 2.5Z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" /><path d="M9 7.4v3.4M9 12.8v.1" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" /></svg>
        <span>{integrity}</span>
      </p>
    {/if}
    <button type="button" class="btn primary large save" onclick={onsave}>
      {appText(editor.language, 'saveAs')}
    </button>
  </footer>
</aside>

<style>
  .changes { display: flex; flex-direction: column; min-height: 0; height: 100%; background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-panel); }
  header { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; padding: 16px 18px 12px; border-bottom: 1px solid var(--line-faint); }
  h2 { margin: 0; font-size: 15px; font-weight: 600; }
  .count { font: 500 13px var(--font-mono); color: var(--muted); }
  .restore-all { margin: -4px 0 -4px auto; }
  .count.some { color: var(--changed); }
  .empty { padding: 28px 22px; text-align: center; }
  .empty p { margin: 4px 0; font-size: 12.5px; line-height: 1.5; color: var(--muted); }
  .empty .strong { font-size: 13.5px; font-weight: 500; color: var(--ink); }
  ul { list-style: none; margin: 0; padding: 6px 0; overflow: auto; flex: 1 1 auto; }
  li { display: flex; align-items: flex-start; gap: 8px; padding: 9px 12px 9px 18px; }
  li + li { border-top: 1px solid var(--line-faint); }
  li .btn { opacity: 0.0; margin-top: -2px; }
  li:hover .btn, li:focus-within .btn { opacity: 1; }
  .what { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
  .label { font-size: 13px; line-height: 1.35; color: var(--ink); overflow-wrap: anywhere; }
  .values { display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px; font: 12.5px var(--font-mono); font-variant-numeric: tabular-nums; }
  s { color: var(--muted); text-decoration-color: color-mix(in srgb, var(--muted) 70%, transparent); }
  .arrow { color: var(--muted); font-family: var(--font-sans); }
  .after { color: var(--changed); font-weight: 500; }
  footer { margin-top: auto; display: flex; flex-direction: column; gap: 10px; padding: 14px 16px 16px; border-top: 1px solid var(--line-faint); }
  .blocked { display: flex; gap: 8px; margin: 0; font-size: 12px; line-height: 1.45; color: var(--changed); }
  .blocked svg { flex: none; margin-top: 2px; }
  .blocked span { color: var(--ink-2); }
  .save { width: 100%; }
  @media (hover: none) { li .btn { opacity: 1; } }
</style>
