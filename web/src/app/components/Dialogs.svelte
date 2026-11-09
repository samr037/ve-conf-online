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
  let fileName = $state('')
  let nameMissing = $state(false)
  const t = (k: Parameters<typeof appText>[1]) => appText(editor.language, k)

  function submitName(d: Extract<DialogRequest, { k: 'saveName' }>) {
    const name = fileName.trim()
    if (!name) { nameMissing = true; return }
    finish(d, name)
  }

  function done(d: DialogRequest) {
    editor.pop(d)
    password = ''
    incorrect = false
    nameMissing = false
  }

  /** Closes a dialog and answers it. `d` is passed in: once the dialog is closed, the `{@const}` in the markup
   * already names the next dialog. */
  function finish<T>(d: { resolve: (v: T) => void } & DialogRequest, value: T) {
    done(d)
    d.resolve(value)
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
      <Dialog title={d.confirmation.title} tone="warning" width={520} oncancel={() => finish(d, false)} initialFocus="[data-cancel]">
        <p class="message">{d.confirmation.message}</p>
        {#snippet footer()}
          <button type="button" class="btn" data-cancel onclick={() => finish(d, false)}>{L('Cancel')}</button>
          <button type="button" class="btn primary" onclick={() => finish(d, true)}>{d.confirmation.continueTitle}</button>
        {/snippet}
      </Dialog>
    {:else if current.k === 'notice'}
      {@const d = current}
      <Dialog title={d.notice.title} width={480} oncancel={() => finish(d, false)} initialFocus="[data-ok]">
        <p class="message">{d.notice.message}</p>
        {#snippet footer()}
          {#if d.notice.action === 'openBatteryPresets' && d.notice.actionTitle}
            <button type="button" class="btn" onclick={() => finish(d, true)}>{d.notice.actionTitle}</button>
          {/if}
          <button type="button" class="btn primary" data-ok onclick={() => finish(d, false)}>{L('OK')}</button>
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
    {:else if current.k === 'saveName'}
      {@const d = current}
      <Dialog title={t('saveTitle')} width={440} oncancel={() => finish(d, undefined)} initialFocus="input">
        <form id="save-name" onsubmit={(e) => { e.preventDefault(); submitName(d) }}>
          <label class="pw">
            <span>{t('fileName')}</span>
            <input class="field name" type="text" autocomplete="off" spellcheck="false" value={d.suggested}
              oninput={(e) => { fileName = e.currentTarget.value; nameMissing = false }}
              onfocus={(e) => { fileName = e.currentTarget.value; const v = e.currentTarget.value; const dot = v.lastIndexOf('.'); e.currentTarget.setSelectionRange(0, dot > 0 ? dot : v.length) }}
              aria-invalid={nameMissing} aria-describedby={nameMissing ? 'name-error' : undefined} />
          </label>
          {#if nameMissing}<p id="name-error" class="error" role="alert">{t('nameNeeded')}</p>{/if}
        </form>
        {#snippet footer()}
          <button type="button" class="btn" onclick={() => finish(d, undefined)}>{L('Cancel')}</button>
          <button type="submit" form="save-name" class="btn primary">{t('save')}</button>
        {/snippet}
      </Dialog>
    {:else if current.k === 'gridChoice'}
      {@const d = current}
      {@const c = d.choice}
      {@const buttons = Confirmations.gridButtons(c)}
      <Dialog title={gridTitle(d)} tone="warning" width={520} oncancel={() => finish(d, undefined)}>
        {#if c.t !== 'accept'}<p class="message">{c.message}</p>{/if}
        {#snippet footer()}
          {#if c.t === 'reject'}
            <button type="button" class="btn primary" onclick={() => finish(d, undefined)}>{buttons[0]}</button>
          {:else if c.t === 'propose'}
            <button type="button" class="btn" onclick={() => finish(d, undefined)}>{L('Cancel')}</button>
            {#if c.keep !== undefined}
              <button type="button" class="btn" onclick={() => finish(d, c.keep)}>{L('Keep Option %d', c.keep)}</button>
            {/if}
            <button type="button" class="btn primary" onclick={() => finish(d, c.alternative)}>{c.button}</button>
          {:else if c.t === 'confirm'}
            <button type="button" class="btn" onclick={() => finish(d, undefined)}>{L('Cancel')}</button>
            <button type="button" class="btn primary" onclick={async () => { const req = d, then = c.then; done(req); req.resolve(await editor.gridChoice(then)) }}>{c.button}</button>
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
  .pw .field.name { letter-spacing: 0; }
  .error { margin: 8px 0 0; font-size: 13px; color: var(--danger); }
</style>
