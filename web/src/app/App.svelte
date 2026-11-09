<!-- The editor page: loading, then the open screen or the open document. -->
<script lang="ts">
  import { onMount } from 'svelte'
  import { takeStashedFile } from '../lib/handoff'
  import { appText } from '../lib/i18n/app'
  import { L } from '../lib/rules'
  import Dialogs from './components/Dialogs.svelte'
  import Editor from './components/Editor.svelte'
  import Welcome from './components/Welcome.svelte'
  import { editor } from './store.svelte'

  let openError = $state<string | undefined>(undefined)
  let picker: HTMLInputElement
  const t = (k: Parameters<typeof appText>[1]) => appText(editor.language, k)

  function openBytes(bytes: Uint8Array, name: string): boolean {
    try {
      editor.open(bytes, name)
      void editor.rememberRecent(name, bytes)
      openError = undefined
      return true
    } catch (e) {
      openError = `${t('openFailed')} ${e instanceof Error ? e.message : ''}`.trim()
      return false
    }
  }

  /** A real .rvsc is a few KB; anything bigger than this is not one. */
  const maxFileSize = 1 << 20

  async function openFile(f: File) {
    if (f.size > maxFileSize) {
      openError = t('openFailed')
      if (editor.doc) editor.push({ k: 'message', title: t('openFailed'), message: '' })
      return
    }
    const bytes = new Uint8Array(await f.arrayBuffer())
    if (editor.doc?.isEdited && !(await confirmDiscard())) return
    if (!openBytes(bytes, f.name) && editor.doc) editor.push({ k: 'message', title: t('openFailed'), message: openError ?? '' })
  }

  /** "Open another file…": back to the open screen (drop, choose, or a recent file). Edits not saved are lost: ask first. */
  async function toOpenScreen() {
    if (editor.doc?.isEdited && !(await confirmDiscard())) return
    editor.close()
  }

  /** Opening another file drops the edits of this one: ask first, like the Mac app's close prompt. */
  function confirmDiscard(): Promise<boolean> {
    const doc = editor.doc!
    return editor.confirm({
      title: L('Save the changes to “%@”?', doc.fileName ?? L('Configuration')),
      message: L("%@ settings were changed. If you don't save, they're lost.", String(doc.changes.length)),
      continueTitle: L("Don't Save"),
    })
  }

  onMount(async () => {
    await editor.start()
    const f = new URLSearchParams(location.search).get('open') === 'session' ? takeStashedFile() : undefined
    if (f) openBytes(f.bytes, f.name)
    else await editor.resume()
    history.replaceState(null, '', location.pathname)
  })
</script>

<input type="file" accept=".rvsc,.vsc,application/octet-stream" class="visually-hidden" bind:this={picker} tabindex="-1" aria-hidden="true"
  onchange={(e) => { const f = e.currentTarget.files?.[0]; e.currentTarget.value = ''; if (f) openFile(f) }} />

{#key editor.language}
{#if editor.loadError}
  <div class="state" role="alert"><p>{t('loadFailed')}</p></div>
{:else if !editor.ready}
  <div class="state" aria-live="polite"><span class="spinner" aria-hidden="true"></span><p>{t('loading')}</p></div>
{:else if editor.doc}
  <Editor onopen={toOpenScreen} />
{:else}
  <Welcome onfile={openFile} onrecent={(name, bytes) => openBytes(bytes, name)} error={openError} />
{/if}

<Dialogs />
{/key}

{#if editor.toastText}
  <div class="toast" role="status">{editor.toastText}</div>
{/if}

<style>
  .state { min-height: 100vh; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 14px; color: var(--muted); font-size: 14px; }
  .state p { margin: 0; }
  .spinner { width: 22px; height: 22px; border-radius: 50%; border: 2px solid var(--line-strong); border-top-color: var(--accent); animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .toast {
    position: fixed; left: 50%; bottom: 22px; transform: translateX(-50%); z-index: 50;
    padding: 10px 16px; border-radius: 999px; background: var(--ink); color: var(--surface);
    font-size: 13px; box-shadow: var(--shadow-pop);
  }
</style>
