<!-- Shows the editor's dialogs one at a time (the oldest first). -->
<script lang="ts">
  import { appText } from '../../lib/i18n/app'
  import { Confirmations, L } from '../../lib/rules'
  import { editor, type DialogRequest } from '../store.svelte'
  import Dialog from './Dialog.svelte'
  import PresetDialog from './PresetDialog.svelte'
  import WizardDialog from './WizardDialog.svelte'

  const current = $derived(editor.dialogs[0])

  let password = $state('')
  let incorrect = $state(false)

  function done(d: DialogRequest) {
    editor.pop(d)
    password = ''
    incorrect = false
  }

  function unlock(d: DialogRequest) {
    if (editor.doc?.unlockGrid(password)) { done(d); return }
    incorrect = true
    password = ''
  }

  const gridTitle = (d: Extract<DialogRequest, { k: 'gridChoice' }>) => (d.choice.t === 'reject' ? L('Grid code not changed') : L('Grid code'))
</script>

{#if current}
  {#key current}
    {#if current.k === 'confirm'}
      {@const d = current}
      <Dialog title={d.confirmation.title} tone="warning" width={520} oncancel={() => { done(d); d.resolve(false) }} initialFocus="[data-cancel]">
        <p class="message">{d.confirmation.message}</p>
        {#snippet footer()}
          <button type="button" class="btn" data-cancel onclick={() => { done(d); d.resolve(false) }}>{L('Cancel')}</button>
          <button type="button" class="btn primary" onclick={() => { done(d); d.resolve(true) }}>{d.confirmation.continueTitle}</button>
        {/snippet}
      </Dialog>
    {:else if current.k === 'notice'}
      {@const d = current}
      <Dialog title={d.notice.title} width={480} oncancel={() => { done(d); d.resolve(false) }} initialFocus="[data-ok]">
        <p class="message">{d.notice.message}</p>
        {#snippet footer()}
          {#if d.notice.action === 'openBatteryPresets' && d.notice.actionTitle}
            <button type="button" class="btn" onclick={() => { done(d); d.resolve(true) }}>{d.notice.actionTitle}</button>
          {/if}
          <button type="button" class="btn primary" data-ok onclick={() => { done(d); d.resolve(false) }}>{L('OK')}</button>
        {/snippet}
      </Dialog>
    {:else if current.k === 'message'}
      {@const d = current}
      <Dialog title={d.title || L('Assistants')} width={500} oncancel={() => done(d)} initialFocus="[data-ok]">
        <p class="message">{d.message}</p>
        {#snippet footer()}<button type="button" class="btn primary" data-ok onclick={() => done(d)}>{L('OK')}</button>{/snippet}
      </Dialog>
    {:else if current.k === 'saveBlocked'}
      {@const d = current}
      <Dialog title={L("This configuration can't be saved yet")} tone="warning" width={480} oncancel={() => done(d)} initialFocus="[data-ok]">
        <p class="message">{d.reason}</p>
        {#snippet footer()}<button type="button" class="btn primary" data-ok onclick={() => done(d)}>{L('OK')}</button>{/snippet}
      </Dialog>
    {:else if current.k === 'gridChoice'}
      {@const d = current}
      {@const c = d.choice}
      {@const buttons = Confirmations.gridButtons(c)}
      <Dialog title={gridTitle(d)} tone="warning" width={520} oncancel={() => { done(d); d.resolve(undefined) }}>
        {#if c.t !== 'accept'}<p class="message">{c.message}</p>{/if}
        {#snippet footer()}
          {#if c.t === 'reject'}
            <button type="button" class="btn primary" onclick={() => { done(d); d.resolve(undefined) }}>{buttons[0]}</button>
          {:else if c.t === 'propose'}
            <button type="button" class="btn" onclick={() => { done(d); d.resolve(undefined) }}>{L('Cancel')}</button>
            {#if c.keep !== undefined}
              <button type="button" class="btn" onclick={() => { done(d); d.resolve(c.keep) }}>{L('Keep Option %d', c.keep)}</button>
            {/if}
            <button type="button" class="btn primary" onclick={() => { done(d); d.resolve(c.alternative) }}>{c.button}</button>
          {:else if c.t === 'confirm'}
            <button type="button" class="btn" onclick={() => { done(d); d.resolve(undefined) }}>{L('Cancel')}</button>
            <button type="button" class="btn primary" onclick={async () => { done(d); d.resolve(await editor.gridChoice(c.then)) }}>{c.button}</button>
          {/if}
        {/snippet}
      </Dialog>
    {:else if current.k === 'gridPassword'}
      {@const d = current}
      <Dialog title={L('Unlock grid settings')} width={420} oncancel={() => done(d)} initialFocus="input">
        <form id="grid-unlock" onsubmit={(e) => { e.preventDefault(); unlock(d) }}>
          <p class="message">{L('This unlocks only this document, until you close it.')}</p>
          <label class="pw">
            <span>{L('Grid code password')}</span>
            <input class="field" type="password" autocomplete="off" spellcheck="false" bind:value={password} aria-invalid={incorrect} aria-describedby={incorrect ? 'pw-error' : undefined} />
          </label>
          {#if incorrect}<p id="pw-error" class="error" role="alert">{L('Incorrect password. Try again.')}</p>{/if}
        </form>
        {#snippet footer()}
          <button type="button" class="btn" onclick={() => done(d)}>{L('Cancel')}</button>
          <button type="submit" form="grid-unlock" class="btn primary" disabled={password.trim().length === 0}>{L('Unlock')}</button>
        {/snippet}
      </Dialog>
    {:else if current.k === 'presets'}
      {@const d = current}
      <PresetDialog onclose={() => done(d)} />
    {:else if current.k === 'wizard'}
      {@const d = current}
      <WizardDialog session={d.session} onclose={() => { done(d); editor.bump() }} />
    {/if}
  {/key}
{/if}

<style>
  .message { margin: 0; white-space: pre-line; }
  .pw { display: flex; flex-direction: column; gap: 6px; margin-top: 14px; font-size: 13px; color: var(--ink); }
  .pw .field { width: 100%; font-family: var(--font-mono); letter-spacing: 0.08em; }
  .error { margin: 8px 0 0; font-size: 13px; color: var(--danger); }
</style>
