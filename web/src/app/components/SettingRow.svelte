<!-- One catalog control as a form row. -->
<script lang="ts">
  import { appText } from '../../lib/i18n/app'
  import {
    BatteryPresets, L, LocalControls, catalogText, choiceOptions, choiceSelection, cleanCaption, fallbackText, noteText, type RowState,
  } from '../../lib/rules'
  import * as act from '../actions'
  import { editor } from '../store.svelte'
  import ChargeCurve from './ChargeCurve.svelte'
  import InfoButton from './InfoButton.svelte'

  let { row }: { row: RowState } = $props()

  const kind = $derived(row.control.kind)
  const editable = $derived(row.editable)
  const dim = $derived(!row.enabled)
  const fieldID = `f-${Math.random().toString(36).slice(2, 9)}`

  // Number rows: the text being typed (undefined shows the stored value).
  let draft = $state<string | undefined>(undefined)
  let invalid = $state(false)
  const shown = $derived.by(() => {
    const k = row.codec
    const v = k?.display(row.config)
    return v === undefined || !k ? '—' : k.format(v, row.config)
  })

  function commit() {
    if (draft === undefined) return
    const text = draft
    draft = undefined
    if (text === shown) return
    if (!act.commitNumber(row, text)) flagInvalid()
  }
  function flagInvalid() {
    invalid = true
    setTimeout(() => (invalid = false), 900)
  }
  function stepBy(d: 1 | -1) {
    draft = undefined
    if (!act.step(row, d)) flagInvalid()
  }
  function numberKey(e: KeyboardEvent) {
    if (e.key === 'Enter') { e.preventDefault(); commit() }
    else if (e.key === 'Escape') { draft = undefined; (e.target as HTMLInputElement).value = shown }
    else if (e.key === 'ArrowUp') { e.preventDefault(); stepBy(1) }
    else if (e.key === 'ArrowDown') { e.preventDefault(); stepBy(-1) }
  }

  /** Puts the radio buttons back on the stored value; the edit (if accepted) then moves the selection. */
  function resetRadios() {
    for (const r of document.getElementsByName(fieldID)) (r as HTMLInputElement).checked = Number((r as HTMLInputElement).value) === selection
  }

  const options = $derived(kind === 'choice' ? choiceOptions(row) : [])
  const selection = $derived(kind === 'choice' ? choiceSelection(row) : 0)
  const style = $derived.by(() => {
    if (row.control.class !== 'TSettingRadioGroup') return 'menu'
    if (options.length <= 3 && options.every((o) => [...o.title].length < 14)) return 'segmented'
    return 'radio'
  })
  const note = $derived(kind === 'text' ? catalogText(cleanCaption(noteText(row))) : '')
  const warningNote = $derived(kind === 'text' && (/warning/i.test(row.control.name) || row.control.name.includes('Error') || (/not /i.test(note) && note.length < 80)))
  const preset = $derived(row.control.name === 'BatteryTypeButton' ? BatteryPresets.matching(row.config) : undefined)
</script>

{#snippet label()}
  <span class="label-line">
    <span class="text">{row.label}</span>
    {#if row.locked && row.showsLock && !editor.doc?.readOnly}
      <svg class="mark" width="12" height="12" viewBox="0 0 12 12" role="img" aria-label={L('Locked, grid code password required')}><title>{L('Protected by the grid code password')}</title><rect x="2" y="5.5" width="8" height="5.5" rx="1" fill="currentColor" /><path d="M4 5.5V4a2 2 0 0 1 4 0v1.5" fill="none" stroke="currentColor" stroke-width="1.3" /></svg>
    {/if}
    {#if row.resetRequired && row.showsResetMark}
      <svg class="mark reset" width="12" height="12" viewBox="0 0 12 12" role="img" aria-label={L('Requires reset')}><title>{L('A change requires a device reset after upload')}</title><path d="M9.6 6A3.6 3.6 0 1 1 8.5 3.4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" /><path d="M9.6 1.6v2.6H7" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" /></svg>
    {/if}
    {#if row.changed}<span class="changed-tag">{L('changed')}</span>{/if}
  </span>
{/snippet}

{#snippet restoreButton()}
  {#if row.changed}
    <button type="button" class="icon-btn small restore" aria-label={appText(editor.language, 'restoreLabel', { label: row.label })} title={L('Restore Loaded Value')} onclick={() => act.restore(row)}>
      <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M3 5.5h5.5a3 3 0 0 1 0 6H6" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" /><path d="M5.5 3 3 5.5 5.5 8" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" /></svg>
    </button>
  {/if}
{/snippet}

{#if kind === 'canvas'}
  <div class="row curve"><ChargeCurve config={row.config} baseline={row.ctx.baseline} /></div>
{:else if kind === 'text'}
  <div class="row note" class:warning={warningNote}>
    <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
      {#if warningNote}<path d="M8 2 14.5 13.5h-13L8 2Z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round" /><path d="M8 6.5v3.2M8 11.6v.1" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
      {:else}<circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.3" /><path d="M8 7.2v4M8 4.9v.1" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />{/if}
    </svg>
    <p>{note}</p>
  </div>
{:else if kind === 'number'}
  <div class="row" class:dim title={row.tooltip} data-control={row.control.name}>
    <label class="lbl" for={fieldID}>{@render label()}</label>
    <div class="ctl">
      {@render restoreButton()}
      <div class="stepper">
        <button type="button" class="tstep" tabindex="-1" aria-label={appText(editor.language, 'decrease', { label: row.label })} disabled={!editable} onclick={() => stepBy(-1)}>
          <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M3 7h8" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" /></svg>
        </button>
        <input
          id={fieldID}
          class="field value"
          class:changed={row.changed}
          class:invalid
          inputmode="decimal"
          enterkeyhint="done"
          autocomplete="off"
          spellcheck="false"
          value={draft ?? shown}
          disabled={!editable}
          oninput={(e) => (draft = e.currentTarget.value)}
          onkeydown={numberKey}
          onblur={commit}
        />
        <span class="arrows">
          <button type="button" tabindex="-1" aria-label={appText(editor.language, 'increase', { label: row.label })} disabled={!editable} onclick={() => stepBy(1)}>
            <svg width="9" height="6" viewBox="0 0 9 6" aria-hidden="true"><path d="M1 5 4.5 1.5 8 5" fill="none" stroke="currentColor" stroke-width="1.4" /></svg>
          </button>
          <button type="button" tabindex="-1" aria-label={appText(editor.language, 'decrease', { label: row.label })} disabled={!editable} onclick={() => stepBy(-1)}>
            <svg width="9" height="6" viewBox="0 0 9 6" aria-hidden="true"><path d="M1 1 4.5 4.5 8 1" fill="none" stroke="currentColor" stroke-width="1.4" /></svg>
          </button>
        </span>
        <button type="button" class="tstep" tabindex="-1" aria-label={appText(editor.language, 'increase', { label: row.label })} disabled={!editable} onclick={() => stepBy(1)}>
          <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M3 7h8M7 3v8" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" /></svg>
        </button>
      </div>
      <span class="unit">{row.unit ?? ''}</span>
      <InfoButton {row} />
    </div>
  </div>
{:else if kind === 'toggle' || kind === 'localToggle'}
  {@const on = kind === 'toggle' ? act.toggleIsOn(row) : (LocalControls.isChecked(row.control.name, row.config) ?? false)}
  <div class="row" class:dim title={row.tooltip} data-control={row.control.name}>
    <label class="lbl" for={fieldID}>{@render label()}</label>
    <div class="ctl">
      {@render restoreButton()}
      <span class="switch" class:changed={row.changed}>
        <input id={fieldID} type="checkbox" role="switch" checked={on} disabled={!editable || (kind === 'toggle' && row.codec?.isEditable === false)}
          onchange={(e) => { const v = e.currentTarget.checked; e.currentTarget.checked = on; if (kind === 'toggle') act.toggle(row, v); else act.localToggle(row, v) }} />
        <span class="track"></span><span class="thumb"></span>
      </span>
      <span class="unit"></span>
      <InfoButton {row} />
    </div>
  </div>
{:else if kind === 'localChoice'}
  <div class="row" class:dim data-control={row.control.name}>
    <label class="lbl" for={fieldID}>{L('Stop condition')}</label>
    <div class="ctl">
      <select id={fieldID} class="field" disabled={!editable} value={LocalControls.vs2OffAction(row.config)} onchange={(e) => { const v = Number(e.currentTarget.value); e.currentTarget.value = String(LocalControls.vs2OffAction(row.config)); act.localChoice(row, v) }}>
        {#each row.control.items ?? [] as item, i (i)}<option value={i}>{catalogText(fallbackText(item.text))}</option>{/each}
      </select>
      <span class="unit"></span>
      <span class="info-gap"></span>
    </div>
  </div>
{:else if kind === 'choice' && style === 'radio'}
  <fieldset class="row radio" class:dim title={row.tooltip} data-control={row.control.name}>
    <div class="radio-head">
      <legend class="lbl">{@render label()}</legend>
      <span class="ctl">{@render restoreButton()}<InfoButton {row} /></span>
    </div>
    <div class="radios">
      {#each options as o (o.value)}
        <label class="radio-option" class:selected={o.value === selection}>
          <input type="radio" name={fieldID} value={o.value} checked={o.value === selection} disabled={!editable || !o.enabled} onchange={() => { resetRadios(); act.choose(row, o.value) }} />
          <span>{o.title}</span>
        </label>
      {/each}
    </div>
  </fieldset>
{:else if kind === 'choice'}
  <div class="row" class:dim title={row.tooltip} data-control={row.control.name}>
    {#if style === 'segmented'}
      <span class="lbl" id="{fieldID}-l">{@render label()}</span>
    {:else}
      <label class="lbl" for={fieldID}>{@render label()}</label>
    {/if}
    <div class="ctl">
      {@render restoreButton()}
      {#if style === 'segmented'}
        <div class="segmented" role="group" aria-labelledby="{fieldID}-l">
          {#each options as o (o.value)}
            <button type="button" aria-pressed={o.value === selection} disabled={!editable || !o.enabled} onclick={() => { if (o.value !== selection) act.choose(row, o.value) }}>{o.title}</button>
          {/each}
        </div>
      {:else}
        <select id={fieldID} class="field" class:changed={row.changed} class:wide={row.control.name === 'GridCodeComboBox'} disabled={!editable} value={selection}
          onchange={(e) => { const v = Number(e.currentTarget.value); e.currentTarget.value = String(selection); act.choose(row, v) }}>
          {#each options as o (o.value)}<option value={o.value} disabled={!o.enabled}>{o.title}</option>{/each}
        </select>
      {/if}
      <span class="unit"></span>
      <InfoButton {row} />
    </div>
  </div>
{:else if kind === 'button' && row.control.name === 'BatteryTypeButton'}
  <div class="row" class:dim data-control={row.control.name}>
    <div class="lbl">
      <span class="label-line"><span class="text">{L('Battery type')}</span></span>
      <span class="sub">{preset ? catalogText(preset.name) : L('No corresponding preset')}</span>
    </div>
    <div class="ctl">
      <button type="button" class="btn" disabled={!row.enabled || editor.doc?.readOnly} onclick={() => editor.push({ k: 'presets' })}>{L('Battery Presets…')}</button>
      <span class="unit"></span>
      <InfoButton {row} />
    </div>
  </div>
{:else if kind === 'button' && row.control.name === 'HideInverterWarningButton'}
  <div class="row">
    <span></span>
    <div class="ctl"><button type="button" class="btn" onclick={() => editor.doc?.unhideCharger()}>{row.label}</button></div>
  </div>
{/if}

<style>
  .row {
    display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; gap: 6px 16px;
    min-height: 48px; padding: 7px 14px 7px 18px;
    border-top: 1px solid var(--line-faint);
  }
  .row:first-child { border-top: 0; }
  .row:hover .restore, .row:focus-within .restore { opacity: 1; }
  .dim { opacity: 0.55; }
  .lbl { min-width: 0; font-size: 14px; color: var(--ink); }
  .label-line { display: inline-flex; flex-wrap: wrap; align-items: center; gap: 6px; }
  .text { line-height: 1.35; }
  .sub { display: block; font-size: 12px; color: var(--muted); margin-top: 1px; }
  .mark { color: var(--muted); flex: none; }
  .mark.reset { color: var(--ink-2); }
  .changed-tag { font: 600 10.5px var(--font-sans); letter-spacing: 0.02em; color: var(--changed); text-transform: lowercase; }
  .ctl { display: flex; align-items: center; justify-content: flex-end; gap: 6px; }
  .unit { width: 40px; font-size: 13px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .info-gap { width: 26px; }
  .restore { opacity: 0; transition: opacity 120ms; color: var(--changed); }
  .restore:focus-visible { opacity: 1; }

  .stepper { display: inline-flex; align-items: stretch; }
  .stepper .field { border-top-right-radius: 0; border-bottom-right-radius: 0; }
  .arrows { display: inline-flex; flex-direction: column; border: 1px solid var(--line-strong); border-left: 0; border-radius: 0 var(--radius-block) var(--radius-block) 0; overflow: hidden; }
  .arrows button { flex: 1; width: 22px; display: flex; align-items: center; justify-content: center; padding: 0; border: 0; background: var(--surface); color: var(--muted); cursor: pointer; }
  .arrows button + button { border-top: 1px solid var(--line-faint); }
  .arrows button:hover:not(:disabled) { background: var(--line-faint); color: var(--ink); }
  .arrows button:disabled { cursor: default; opacity: 0.5; }
  select.wide { width: min(420px, 52vw); }
  .tstep { display: none; }

  /* Touch: the tiny arrows give way to − and + buttons either side of the field. */
  @media (pointer: coarse) {
    .arrows { display: none; }
    .stepper .field { border-radius: 0; border-left: 0; border-right: 0; }
    .tstep {
      display: flex; align-items: center; justify-content: center; width: 44px; height: 44px; padding: 0;
      border: 1px solid var(--line-strong); background: var(--surface-sunken); color: var(--ink-2); cursor: pointer;
      -webkit-tap-highlight-color: transparent; touch-action: manipulation;
    }
    .tstep:first-child { border-radius: var(--radius-block) 0 0 var(--radius-block); }
    .tstep:last-child { border-radius: 0 var(--radius-block) var(--radius-block) 0; }
    .tstep:active:not(:disabled) { background: var(--line-faint); }
    .tstep:disabled { opacity: 0.45; cursor: default; }
    .stepper:has(.field.changed) .tstep { border-color: var(--changed); }
    .stepper:has(.field:focus) .tstep { border-color: var(--accent); }
    .radio-option { min-height: 44px; align-items: center; padding: 8px 10px; }
    .radio-option input { margin: 0; }
  }

  .note { grid-template-columns: auto minmax(0, 1fr); align-items: start; color: var(--muted); }
  .note svg { margin-top: 2px; }
  .note p { margin: 0; font-size: 13px; line-height: 1.5; color: var(--ink-2); white-space: pre-line; }
  .note.warning { color: var(--changed); }
  .note.warning p { color: var(--ink); }
  .curve { display: block; padding: 12px 18px 8px; }

  fieldset.radio { display: block; margin: 0; min-inline-size: 0; border: 0; border-top: 1px solid var(--line-faint); }
  fieldset.radio:first-child { border-top: 0; }
  .radio-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
  legend.lbl { float: left; padding: 0; }
  .radios { clear: both; display: flex; flex-direction: column; gap: 2px; padding: 6px 0 2px; }
  .radio-option { display: flex; align-items: flex-start; gap: 10px; padding: 6px 8px; border-radius: var(--radius-block); font-size: 13.5px; color: var(--ink-2); cursor: pointer; }
  .radio-option:hover { background: var(--line-faint); }
  .radio-option.selected { color: var(--ink); }
  .radio-option input { margin: 3px 0 0; accent-color: var(--accent); }

  @media (max-width: 640px) {
    .row { padding-left: 14px; gap: 6px 10px; }
    .unit { width: auto; min-width: 0; }
    .unit:empty { display: none; }
  }
  @media (max-width: 480px) {
    .row:has(.ctl > .btn) { grid-template-columns: minmax(0, 1fr); }
    .row:has(.ctl > .btn) .ctl { justify-content: space-between; }
    .row:has(.stepper), .row:has(select.field) { grid-template-columns: minmax(0, 1fr); padding-top: 10px; padding-bottom: 10px; }
    .row:has(.stepper) .ctl, .row:has(select.field) .ctl { justify-content: flex-start; min-width: 0; }
    .row:has(select.field) select.field { flex: 1 1 0; min-width: 0; width: 0; text-overflow: ellipsis; }
    .row:has(.stepper) .unit { flex: 1; }
  }
</style>
