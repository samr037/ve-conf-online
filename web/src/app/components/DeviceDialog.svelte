<!-- "Connect a device" (read-only beta): port picker → VE.Bus discovery → read with progress → read-only document. -->
<script lang="ts">
  import { onDestroy } from 'svelte'
  import { appText } from '../../lib/i18n/app'
  import { L } from '../../lib/rules'
  import { DeviceFlowError, DeviceSession, PickerDismissed } from '../deviceConnect'
  import { editor } from '../store.svelte'
  import Dialog from './Dialog.svelte'

  let { onclose }: { onclose: () => void } = $props()

  type Phase = 'intro' | 'searching' | 'pick' | 'reading' | 'error'
  let phase = $state<Phase>('intro')
  let addresses = $state<number[]>([])
  let chosen = $state(0)
  let done = $state(0)
  let total = $state(192)
  let started = 0
  let now = $state(Date.now())
  let error = $state('')
  let session: DeviceSession | undefined
  let finished = false
  const t = (k: Parameters<typeof appText>[1], v?: Record<string, string | number>) => appText(editor.language, k, v)
  const ticker = setInterval(() => (now = Date.now()), 1000)
  onDestroy(() => { clearInterval(ticker); if (!finished) void session?.close() })

  const percent = $derived(total ? Math.round((done / total) * 100) : 0)
  const secondsLeft = $derived(done > 2 ? Math.max(1, Math.round(((now - started) / done) * (total - done) / 1000)) : undefined)

  function fail(e: unknown) {
    void session?.close()
    session = undefined
    if (e instanceof PickerDismissed) { phase = 'intro'; return }
    if (e instanceof DOMException && e.name === 'AbortError') return
    const f = e instanceof DeviceFlowError ? e : new DeviceFlowError('errDevice', e instanceof Error ? e.message : String(e))
    error = f.key === 'errDevice' ? t('errDevice', { why: f.message }) : t(f.key)
    phase = 'error'
  }

  async function choosePort() {
    session = new DeviceSession()
    try {
      await session.choose()
      phase = 'searching'
      addresses = await session.discover()
      chosen = addresses[0]!
      if (addresses.length === 1) await read(chosen)
      else phase = 'pick'
    } catch (e) {
      fail(e)
    }
  }

  async function read(address: number) {
    if (!session) return
    phase = 'reading'
    done = 0
    started = Date.now()
    try {
      const config = await session.read(address, (d, n) => { done = d; total = n })
      const label = session.label
      finished = true
      await session.close()
      editor.openDevice(config, { portLabel: label, readAt: new Date(), address })
      onclose()
    } catch (e) {
      fail(e)
    }
  }

  async function cancel() {
    finished = true
    session?.cancel()
    await session?.close()
    onclose()
  }

  function retry() {
    error = ''
    phase = 'intro'
  }
</script>

<Dialog title={t('connectDevice')} width={500} oncancel={cancel} initialFocus={phase === 'intro' ? '[data-choose]' : undefined}>
  <div class="device" data-phase={phase}>
    {#if phase === 'intro'}
      <div class="plug" aria-hidden="true">
        <svg width="336" height="72" viewBox="-12 0 336 72">
          <rect x="8" y="14" width="50" height="32" rx="3" class="line" />
          <path d="M2 50h62" class="line" />
          <text x="33" y="66" text-anchor="middle">{t('computer')}</text>
          <path d="M58 30h58" class="cable" />
          <text x="87" y="24" text-anchor="middle" class="small">USB</text>
          <rect x="116" y="18" width="56" height="24" rx="4" class="iface" />
          <text x="144" y="34" text-anchor="middle" class="iface-text">MK3 / MK2</text>
          <path d="M172 30h58" class="cable" />
          <text x="201" y="24" text-anchor="middle" class="small">VE.Bus</text>
          <rect x="230" y="10" width="64" height="40" rx="5" class="unit" />
          <path d="M240 34l8-6 4 4 8-6" class="unit-mark" />
          <rect x="268" y="18" width="18" height="24" rx="2" class="unit-mark" />
          <text x="262" y="66" text-anchor="middle">{t('inverterCharger')}</text>
        </svg>
      </div>
      <p>{t('deviceIntro')}</p>
    {:else if phase === 'searching'}
      <p class="status" role="status"><span class="spinner" aria-hidden="true"></span>{t('deviceSearching')}</p>
    {:else if phase === 'pick'}
      <fieldset>
        <legend>{t('devicePick')}</legend>
        {#each addresses as a (a)}
          <label class="choice"><input type="radio" name="device-address" value={a} bind:group={chosen} />{t('deviceAtAddress', { n: a })}</label>
        {/each}
      </fieldset>
    {:else if phase === 'reading'}
      <div class="progress">
        <div class="bar" role="progressbar" aria-valuemin={0} aria-valuemax={total} aria-valuenow={done} aria-label={t('deviceReading', { done, total })}>
          <span style:width="{percent}%"></span>
        </div>
        <div class="progress-text">
          <span>{t('deviceReading', { done, total })}</span>
          {#if secondsLeft !== undefined}<span class="left">{t('deviceTimeLeft', { n: secondsLeft })}</span>{/if}
        </div>
      </div>
    {:else if phase === 'error'}
      <p class="error" role="alert">{error}</p>
    {/if}
  </div>

  {#snippet footer()}
    {#if phase === 'error'}
      <button type="button" class="btn" onclick={cancel}>{t('close')}</button>
      <button type="button" class="btn primary" onclick={retry}>{t('tryAgain')}</button>
    {:else}
      <button type="button" class="btn" data-cancel onclick={cancel}>{L('Cancel')}</button>
      {#if phase === 'intro'}
        <button type="button" class="btn primary" data-choose onclick={choosePort}>{t('choosePort')}</button>
      {:else if phase === 'pick'}
        <button type="button" class="btn primary" onclick={() => read(chosen)}>{t('readDevice')}</button>
      {/if}
    {/if}
  {/snippet}
</Dialog>

<style>
  .device { min-height: 96px; }
  p { margin: 0; }
  .plug { display: flex; justify-content: center; margin: 4px 0 18px; color: var(--muted); }
  .plug text { font: 500 11px var(--font-sans); fill: var(--muted); }
  .plug .small { font: 500 10px var(--font-mono); }
  .plug .line { fill: none; stroke: var(--ink-2); stroke-width: 1.5; stroke-linecap: round; }
  .plug .cable { fill: none; stroke: var(--muted); stroke-width: 1.5; stroke-dasharray: 3 3; }
  .plug .iface { fill: var(--surface-sunken); stroke: var(--line-strong); stroke-width: 1.5; }
  .plug .iface-text { font: 600 9.5px var(--font-sans); fill: var(--ink-2); }
  .plug .unit { fill: var(--accent); }
  .plug .unit-mark { fill: none; stroke: var(--on-accent); stroke-width: 1.4; stroke-linecap: round; stroke-linejoin: round; }
  .status { display: flex; align-items: center; gap: 10px; padding: 26px 0; color: var(--ink-2); }
  .spinner { width: 16px; height: 16px; border-radius: 50%; border: 2px solid var(--line-strong); border-top-color: var(--accent); animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  fieldset { margin: 0; padding: 0; border: 0; display: grid; gap: 4px; }
  legend { padding: 0; margin-bottom: 10px; color: var(--ink-2); }
  .choice { display: flex; align-items: center; gap: 10px; min-height: 40px; padding: 0 12px; border: 1px solid var(--line); border-radius: var(--radius-block); color: var(--ink); cursor: pointer; }
  .choice:has(input:checked) { border-color: var(--accent); background: var(--accent-soft); }
  .progress { padding: 20px 0 6px; }
  .bar { height: 8px; border-radius: 4px; background: var(--line-faint); overflow: hidden; }
  .bar span { display: block; height: 100%; background: var(--accent); border-radius: 4px; transition: width 300ms ease-out; }
  .progress-text { display: flex; justify-content: space-between; gap: 12px; margin-top: 10px; font-size: 13px; color: var(--ink-2); font-variant-numeric: tabular-nums; }
  .left { color: var(--muted); }
  .error { color: var(--danger); }
</style>
