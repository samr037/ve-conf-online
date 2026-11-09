<!-- The wizard: one decision at a time, in the assistant's own words. -->
<script lang="ts">
  import { fieldDisplay, isBlankLine, type WizardLine, type WizardRun } from '../../lib/engine/assembler'
  import { L, currentLocale } from '../../lib/rules'
  import type { WizardSession } from '../assistants'
  import { editor } from '../store.svelte'
  import Dialog from './Dialog.svelte'

  let { session, onclose }: { session: WizardSession; onclose: () => void } = $props()

  let tick = $state(0)
  /** A fresh snapshot of the session on every tick (the session itself is a plain object). */
  const s = $derived.by(() => {
    void tick
    return {
      error: session.error, progress: session.progress, canGoBack: session.canGoBack, canGoForward: session.canGoForward,
      values: [...session.values], texts: [...session.texts],
    }
  })
  const step = $derived.by(() => { void tick; return session.step })
  const content = $derived.by(() => { void tick; return session.content })
  let body: HTMLElement | undefined = $state()

  function refresh() {
    tick++
    if (session.finished) onclose()
    queueMicrotask(() => body?.querySelector<HTMLElement>('input, button')?.focus())
  }
  function next() { session.next(); refresh() }
  function previous() { session.previous(); refresh() }
  function cancel() { session.cancel(); onclose() }

  function setRadio(i: number) { session.values = [i]; tick++ }
  function setCheck(i: number, on: boolean) {
    let m = BigInt(session.values[0] ?? 0)
    m = on ? m | (1n << BigInt(i)) : m & ~(1n << BigInt(i))
    session.values = [Number(BigInt.asIntN(32, m))]
    tick++
  }
  const checked = (i: number) => ((BigInt(s.values[0] ?? 0) >> BigInt(i)) & 1n) === 1n
  const id = `wz-${Math.random().toString(36).slice(2, 7)}`
</script>

{#snippet runs(rs: WizardRun[])}
  {#each rs as r, i (i)}{#if r.link}<a href={r.link} target="_blank" rel="noreferrer noopener">{r.text}</a>{:else if r.bold}<strong>{r.text}</strong>{:else if r.emphasis}<em>{r.text}</em>{:else}{r.text}{/if}{/each}
{/snippet}

{#snippet option(lines: WizardLine[])}
  <span class="opt">
    {#each lines as l, k (k)}<span class={k === 0 ? 'opt-main' : 'opt-sub'}>{@render runs(l.runs)}</span>{/each}
  </span>
{/snippet}

<Dialog title={content?.title ?? session.title} width={640} oncancel={cancel}>
  <div class="wizard" bind:this={body}>
    {#if content}
      <div class="desc">
        {#each content.description as line, i (i)}
          {#if isBlankLine(line)}<span class="gap"></span>{:else}<p>{@render runs(line.runs)}</p>{/if}
        {/each}
      </div>
      {#if step}
        {#if step.step.kind === 'R'}
          <div class="choices" role="radiogroup" aria-label={content.title}>
            {#each content.options as lines, i (i)}
              <label class="choice" class:on={s.values[0] === i}>
                <input type="radio" name={id} checked={s.values[0] === i} onchange={() => setRadio(i)} />
                {@render option(lines)}
              </label>
            {/each}
          </div>
        {:else if step.step.kind === 'C'}
          <div class="choices">
            {#each content.options as lines, i (i)}
              <label class="choice" class:on={checked(i)}>
                <input type="checkbox" checked={checked(i)} onchange={(e) => setCheck(i, e.currentTarget.checked)} />
                {@render option(lines)}
              </label>
            {/each}
          </div>
        {:else}
          <form class="entry" onsubmit={(e) => { e.preventDefault(); next() }}>
            {#each content.entry as pieces, li (li)}
              <div class="entry-line">
                {#each pieces as piece, pi (pi)}
                  {#if piece.k === 'text'}
                    <span>{@render runs(piece.runs)}</span>
                  {:else if step.step.fields[piece.index]}
                    {@const f = step.step.fields[piece.index]!}
                    {#if piece.items}
                      <select class="field" aria-label={step.labels[piece.index] ?? ''} value={s.values[piece.index] ?? f.defaultValue}
                        onchange={(e) => { session.values[piece.index] = Number(e.currentTarget.value); tick++ }}>
                        {#each piece.items as item, k (k)}<option value={f.min + k}>{item}</option>{/each}
                      </select>
                    {:else}
                      <input class="field value" inputmode="decimal" autocomplete="off" spellcheck="false"
                        aria-label={step.labels[piece.index] ?? ''}
                        title={L('Range %@ – %@, default %@', fieldDisplay(f, f.min, currentLocale()), fieldDisplay(f, f.max, currentLocale()), fieldDisplay(f, f.defaultValue, currentLocale()))}
                        value={s.texts[piece.index] ?? ''}
                        oninput={(e) => { session.texts[piece.index] = e.currentTarget.value }} />
                    {/if}
                  {/if}
                {/each}
              </div>
            {/each}
            <button type="submit" hidden aria-hidden="true" tabindex="-1"></button>
          </form>
        {/if}
      {/if}
    {/if}
    {#if s.error}
      <p class="error" role="alert">{s.error}</p>
    {/if}
  </div>
  {#snippet footer()}
    <span class="progress">{session.title} · {s.progress}</span>
    <button type="button" class="btn" onclick={cancel}>{L('Cancel')}</button>
    <button type="button" class="btn" disabled={!s.canGoBack} onclick={previous}>{L('Previous')}</button>
    <button type="button" class="btn primary" disabled={!s.canGoForward} onclick={next}>{L('Next')}</button>
  {/snippet}
</Dialog>

<style>
  .wizard { display: flex; flex-direction: column; gap: 16px; min-height: 220px; }
  .desc p { margin: 0 0 8px; color: var(--ink); }
  .desc .gap { display: block; height: 6px; }
  .desc a, .opt a { color: var(--accent); }
  .choices { display: flex; flex-direction: column; gap: 6px; }
  .choice { display: flex; align-items: flex-start; gap: 12px; padding: 10px 12px; border: 1px solid var(--line); border-radius: var(--radius-panel); cursor: pointer; transition: border-color 120ms, background-color 120ms; }
  .choice:hover { border-color: var(--line-strong); }
  .choice.on { border-color: var(--accent); background: var(--accent-soft); }
  .choice input { margin: 3px 0 0; accent-color: var(--accent); flex: none; }
  .opt { display: flex; flex-direction: column; gap: 2px; }
  .opt-main { color: var(--ink); font-size: 14px; }
  .opt-sub { color: var(--muted); font-size: 13px; }
  .entry { display: flex; flex-direction: column; gap: 10px; padding: 16px; border-radius: var(--radius-panel); background: var(--ground); border: 1px solid var(--line); }
  .entry-line { display: flex; flex-wrap: wrap; align-items: baseline; gap: 8px; color: var(--ink); }
  .error { margin: 0; font-size: 13px; color: var(--danger); }
  .progress { margin-right: auto; align-self: center; font: 12px var(--font-mono); color: var(--muted); }
  .entry .field.value { width: 110px; }
  @media (pointer: coarse) { .choice { min-height: 44px; } .choice input { margin-top: 2px; } }
  @media (max-width: 600px) {
    .wizard { min-height: 0; }
    .progress { flex: 1 1 100%; margin: 0 0 2px; }
  }
</style>
