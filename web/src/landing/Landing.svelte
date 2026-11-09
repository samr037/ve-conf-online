<script lang="ts">
  import { onMount } from 'svelte'
  import { DeviceConfiguration } from '../lib/engine/deviceConfiguration'
  import { containerImage, productName, repositoryUrl } from '../lib/brand'
  import { editorOpenUrl, editorUrl, stashFile } from '../lib/handoff'
  import { landing, type LandingKey } from '../lib/i18n/landing'
  import { initialLanguage, languageNames, languages, saveLanguage, translate, type Language } from '../lib/i18n/locale'
  import HeroDiagram from './HeroDiagram.svelte'
  import EditorPreview from './EditorPreview.svelte'

  let lang = $state<Language>(initialLanguage())
  const t = (key: LandingKey, vars?: Record<string, string | number>) => translate(landing, lang, key, vars)
  const decimal = $derived(lang === 'en' ? '.' : ',')

  let dragging = $state(false)
  let busy = $state(false)
  let error = $state<{ message: string; detail?: string } | undefined>()
  let copied = $state(false)
  let fileInput: HTMLInputElement | undefined = $state()
  /** Web Serial exists only in Chromium browsers; elsewhere the device line is not shown. */
  const hasSerial = typeof navigator !== 'undefined' && (navigator as Navigator & { serial?: unknown }).serial !== undefined

  const command = `docker run -p 8080:8080 ${containerImage}`

  // First bytes and checksum of the ESS program in a configuration file written by VE Configure
  // (samples/s2.rvsc). The browser rebuilds that file identically (web/test/assemblerGolden.test.ts).
  const programRows = [
    ['0000', 'd4 d0 d2 ca cc ce'],
    ['0006', '5a 18 11 ff 16 82'],
    ['000c', '25 d5 20 ff 16 51'],
    ['0012', '00 ff f6 46 fe 16'],
  ]
  const checksum = '2a 58 4e 45'

  $effect(() => {
    document.documentElement.lang = lang
    document.title = `${productName} · ${t('heroTitle')}`
    document.querySelector('meta[name="description"]')?.setAttribute('content', t('metaDescription'))
  })

  function setLanguage(value: string) {
    lang = value as Language
    saveLanguage(lang)
  }

  async function open(file: File | undefined) {
    if (!file || busy) return
    error = undefined
    if (file.size > 1 << 20) {
      error = { message: t('errNotConfig') }
      return
    }
    busy = true
    try {
      const bytes = new Uint8Array(await file.arrayBuffer())
      try {
        DeviceConfiguration.parse(bytes)
      } catch (e) {
        error = { message: t('errNotConfig'), detail: e instanceof Error ? e.message : undefined }
        return
      }
      if (!stashFile(file.name, bytes)) {
        error = { message: t('errStorage') }
        return
      }
      location.assign(editorOpenUrl)
    } finally {
      busy = false
    }
  }

  function choose() {
    fileInput?.click()
  }

  async function copyCommand() {
    try {
      await navigator.clipboard.writeText(command)
      copied = true
      setTimeout(() => (copied = false), 1800)
    } catch {
      copied = false
    }
  }

  onMount(() => {
    const hasFiles = (e: DragEvent) => !!e.dataTransfer && Array.from(e.dataTransfer.types).includes('Files')
    const over = (e: DragEvent) => {
      if (!hasFiles(e)) return
      e.preventDefault()
      dragging = true
    }
    const leave = (e: DragEvent) => {
      if (e.relatedTarget === null) dragging = false
    }
    const drop = (e: DragEvent) => {
      if (!hasFiles(e)) return
      e.preventDefault()
      dragging = false
      void open(e.dataTransfer?.files[0])
    }
    window.addEventListener('dragover', over)
    window.addEventListener('dragleave', leave)
    window.addEventListener('drop', drop)
    return () => {
      window.removeEventListener('dragover', over)
      window.removeEventListener('dragleave', leave)
      window.removeEventListener('drop', drop)
    }
  })
</script>

<header class="top">
  <div class="wrap top-inner">
    <a class="mark" href="./">
      <svg viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="7" /><path d="M18 5 9 18h7l-2 9 9-13h-7l2-9Z" /></svg>
      <span>{productName}</span>
    </a>
    <nav aria-label={productName} class="links">
      <a href="#how">{t('navHow')}</a>
      <a href="#assistants">{t('navAssistants')}</a>
      <a href="#selfhost">{t('navSelfHost')}</a>
      {#if repositoryUrl}<a href={repositoryUrl}>{t('navSource')}</a>{/if}
    </nav>
    <label class="lang">
      <span class="visually-hidden">{t('language')}</span>
      <select value={lang} onchange={(e) => setLanguage(e.currentTarget.value)}>
        {#each languages as l (l)}<option value={l}>{languageNames[l]}</option>{/each}
      </select>
    </label>
  </div>
</header>

<main>
  <section class="hero" aria-labelledby="hero-title">
    <div class="wrap hero-inner">
      <h1 id="hero-title">{t('heroTitle')}</h1>
      <p class="lead">{t('heroLead')} <span class="compat">{t('heroCompat')}</span></p>

      <HeroDiagram
        grid={t('grid')}
        loads={t('loads')}
        battery={t('battery')}
        label={t('diagramLabel')}
        dropTitle={t('dropTitle')}
        dropHint={t('dropHint')}
        dropRelease={t('dropRelease')}
        dropOpening={t('dropOpening')}
        {dragging}
        {busy}
        onchoose={choose}
      />
      <input
        bind:this={fileInput}
        class="visually-hidden"
        type="file"
        accept=".rvsc,.vsc"
        tabindex="-1"
        aria-hidden="true"
        onchange={(e) => open(e.currentTarget.files?.[0])}
      />

      {#if error}
        <p class="error" role="alert">
          {error.message}
          {#if error.detail}<span class="error-detail">{error.detail}</span>{/if}
        </p>
      {/if}

      <div class="actions">
        <button type="button" class="button primary" onclick={choose} disabled={busy}>{t('openFile')}</button>
        <a class="button secondary" href="#selfhost">{t('hostIt')}</a>
      </div>
      {#if hasSerial}
        <p class="device"><a href="{editorUrl}?connect=1">{t('connectDevice')}</a> <span class="beta">{t('beta')}</span></p>
      {/if}
    </div>
  </section>

  <section id="how" class="wrap section" aria-labelledby="how-title">
    <h2 id="how-title">{t('howTitle')}</h2>
    <ol class="steps">
      <li>
        <span class="node" aria-hidden="true">1</span>
        <h3>{t('step1Title')}</h3>
        <p>{t('step1Body')}</p>
      </li>
      <li>
        <span class="node" aria-hidden="true">2</span>
        <h3>{t('step2Title')}</h3>
        <p>{t('step2Body')}</p>
      </li>
      <li>
        <span class="node" aria-hidden="true">3</span>
        <h3>{t('step3Title')}</h3>
        <p>{t('step3Body')}</p>
      </li>
    </ol>
  </section>

  <section class="wrap section" aria-labelledby="editor-title">
    <div class="section-head">
      <h2 id="editor-title">{t('editorTitle')}</h2>
      <p>{t('editorBody')}</p>
    </div>
    <EditorPreview {t} {decimal} />
  </section>

  <section id="assistants" class="assistants" aria-labelledby="asst-title">
    <div class="wrap asst-inner">
      <div class="asst-copy">
        <h2 id="asst-title">{t('asstTitle')}</h2>
        <p>{t('asstBody')}</p>
        <p class="asst-note">{t('asstLibrary')}</p>
      </div>
      <div class="bytes">
        <div class="dump">
          <div class="dump-head">{t('asstLeft')}</div>
          {#each programRows as [offset, hex] (offset)}<div class="dump-row"><span class="offset">{offset}</span>{hex}</div>{/each}
          <div class="dump-row sum"><span class="offset">{t('asstSum')}</span>{checksum}</div>
        </div>
        <div class="dump ours">
          <div class="dump-head">{t('asstRight')}</div>
          {#each programRows as [offset, hex] (offset)}<div class="dump-row"><span class="offset">{offset}</span>{hex}</div>{/each}
          <div class="dump-row sum"><span class="offset">{t('asstSum')}</span>{checksum}</div>
        </div>
        <div class="match">
          <svg viewBox="0 0 20 20" aria-hidden="true"><path d="m5 10.5 3.2 3.2L15 7" /></svg>
          {t('asstMatch')}
        </div>
      </div>
    </div>
  </section>

  <section class="wrap section" aria-labelledby="feat-title">
    <h2 id="feat-title">{t('featTitle')}</h2>
    <dl class="spec">
      <div><dt>{t('fTabs')}</dt><dd>{t('fTabsBody')}</dd></div>
      <div><dt>{t('fGrid')}</dt><dd>{t('fGridBody')}</dd></div>
      <div><dt>{t('fLang')}</dt><dd>{t('fLangBody')}</dd></div>
      <div><dt>{t('fUndo')}</dt><dd>{t('fUndoBody')}</dd></div>
      <div><dt>{t('fPresets')}</dt><dd>{t('fPresetsBody')}</dd></div>
      <div><dt>{t('fExport')}</dt><dd>{t('fExportBody')}</dd></div>
    </dl>
  </section>

  <section id="selfhost" class="wrap section selfhost" aria-labelledby="self-title">
    <div class="self-copy">
      <h2 id="self-title">{t('selfTitle')}</h2>
      <p>{t('selfBody')}</p>
    </div>
    <div class="terminal">
      <code><span class="prompt" aria-hidden="true">$</span> {command}</code>
      <button type="button" class="copy" onclick={copyCommand} aria-label={t('copyLabel')}>
        {copied ? t('copied') : t('copy')}
      </button>
      <span class="visually-hidden" role="status">{copied ? t('copied') : ''}</span>
    </div>
  </section>
</main>

<footer class="foot">
  <div class="wrap foot-inner">
    <p>{t('footer')}</p>
    {#if repositoryUrl}<a href={repositoryUrl}>{t('navSource')}</a>{/if}
  </div>
</footer>

<style>
  :global(::selection) { background: color-mix(in srgb, var(--accent) 22%, transparent); }
  :global(html) { scroll-behavior: smooth; scrollbar-color: var(--line-strong) var(--ground); }
  @media (prefers-reduced-motion: reduce) { :global(html) { scroll-behavior: auto; } }
  :global(body) { font-size: 16px; }

  .wrap { max-width: 1200px; margin: 0 auto; padding-left: 32px; padding-right: 32px; }

  .top { position: relative; z-index: 1; }
  .top-inner { display: flex; flex-wrap: wrap; align-items: center; gap: 12px 28px; padding-top: 18px; padding-bottom: 18px; }
  .mark { display: flex; align-items: center; gap: 10px; color: var(--ink); text-decoration: none; font-weight: 600; font-size: 16px; margin-right: auto; }
  .mark svg { width: 30px; height: 30px; }
  .mark rect { fill: var(--accent); }
  .mark path { fill: none; stroke: var(--on-accent); stroke-width: 2.2; stroke-linejoin: round; }
  .links { display: flex; flex-wrap: wrap; gap: 6px 24px; }
  .links a { color: var(--ink-2); text-decoration: none; font-size: 15px; padding: 6px 0; }
  .links a:hover { color: var(--ink); text-decoration: underline; text-underline-offset: 5px; text-decoration-thickness: 1px; }
  .lang select {
    height: 36px;
    padding: 0 30px 0 10px;
    border: 1px solid var(--line-strong);
    border-radius: var(--radius-block);
    background: var(--surface) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'%3E%3Cpath d='M3 4.5 6 7.5 9 4.5' fill='none' stroke='%235b6570' stroke-width='1.5'/%3E%3C/svg%3E") no-repeat right 10px center / 12px;
    color: var(--ink);
    font: inherit;
    font-size: 14px;
    appearance: none;
    cursor: pointer;
  }

  .hero {
    border-top: 1px solid var(--line);
    border-bottom: 1px solid var(--line);
    background-color: var(--ground);
    background-image: linear-gradient(var(--ground-grid) 1px, transparent 1px), linear-gradient(90deg, var(--ground-grid) 1px, transparent 1px);
    background-size: 16px 16px;
    background-position: center top;
  }
  .hero-inner { display: flex; flex-direction: column; align-items: center; text-align: center; padding-top: 96px; padding-bottom: 80px; }
  h1 {
    margin: 0;
    max-width: 19ch;
    font-size: clamp(2.5rem, 6vw, 4.5rem);
    line-height: 1.02;
    font-weight: 600;
    letter-spacing: -0.035em;
    text-wrap: balance;
  }
  .lead {
    margin: 24px 0 52px;
    max-width: 58ch;
    font-size: clamp(1.05rem, 1.6vw, 1.25rem);
    line-height: 1.55;
    color: var(--ink-2);
    text-wrap: pretty;
  }
  .compat { display: block; margin-top: 6px; color: var(--muted); font-size: 0.85em; }
  .actions { display: flex; flex-wrap: wrap; justify-content: center; gap: 12px; margin-top: 44px; }
  .device { margin: 16px 0 0; font-size: 14px; color: var(--muted); display: flex; align-items: center; justify-content: center; gap: 8px; }
  .device a { color: var(--ink-2); text-underline-offset: 3px; }
  .device a:hover { color: var(--accent); }
  .beta { font-size: 10px; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); border: 1px solid var(--line-strong); border-radius: 999px; padding: 1px 7px; }
  .button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-height: 48px;
    padding: 0 24px;
    border-radius: 8px;
    font: inherit;
    font-size: 16px;
    font-weight: 600;
    text-decoration: none;
    cursor: pointer;
    transition: background-color 0.15s ease, border-color 0.15s ease;
  }
  .primary { border: 0; background: var(--accent); color: var(--on-accent); }
  .primary:hover { background: var(--accent-hover); }
  .primary:disabled { opacity: 0.6; cursor: progress; }
  .secondary { border: 1px solid var(--line-strong); background: var(--surface); color: var(--ink); font-weight: 500; }
  .secondary:hover { border-color: var(--muted); }
  .error {
    margin: 28px 0 0;
    padding: 12px 16px;
    max-width: 560px;
    border-radius: var(--radius-panel);
    background: var(--danger-soft);
    color: var(--danger);
    font-size: 15px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .error-detail { font: 12px var(--font-mono); opacity: 0.85; }

  .section { padding-top: 112px; padding-bottom: 16px; }
  h2 {
    margin: 0;
    font-size: clamp(1.75rem, 3.2vw, 2.5rem);
    line-height: 1.12;
    font-weight: 600;
    letter-spacing: -0.025em;
    text-wrap: balance;
  }
  .section > h2 { margin-bottom: 48px; }
  .section-head { display: flex; flex-wrap: wrap; align-items: end; gap: 16px 48px; margin-bottom: 44px; }
  .section-head h2 { flex: 1 1 420px; max-width: 18ch; }
  .section-head p { flex: 1 1 340px; margin: 0; max-width: 52ch; color: var(--ink-2); font-size: 17px; line-height: 1.6; }

  /* Steps drawn as one conductor with three terminals. */
  .steps {
    list-style: none;
    margin: 0;
    padding: 0;
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 40px;
    position: relative;
  }
  .steps::before {
    content: '';
    position: absolute;
    top: 17px;
    left: 18px;
    right: 18px;
    border-top: 2px solid var(--line-strong);
  }
  .steps li { position: relative; }
  .node {
    position: relative;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 36px;
    height: 36px;
    border-radius: 50%;
    background: var(--ground);
    border: 2px solid var(--accent);
    color: var(--accent);
    font: 600 15px var(--font-sans);
    font-variant-numeric: tabular-nums;
  }
  .steps h3 { margin: 22px 0 8px; font-size: 20px; font-weight: 600; letter-spacing: -0.01em; }
  .steps p { margin: 0; max-width: 34ch; color: var(--ink-2); line-height: 1.6; }

  .assistants { margin-top: 128px; background: #111418; color: #e8ecf1; border-block: 1px solid #111418; }
  @media (prefers-color-scheme: dark) { :global(:root:not([data-theme='light'])) .assistants { background: #0e1115; border-color: #262d36; } }
  .asst-inner { display: flex; flex-wrap: wrap; align-items: center; gap: 48px 72px; padding-top: 112px; padding-bottom: 112px; }
  .asst-copy { flex: 1 1 380px; }
  .asst-copy h2 { max-width: 16ch; }
  .asst-copy p { margin: 22px 0 0; max-width: 50ch; font-size: 17px; line-height: 1.65; color: #b4bdc8; }
  .asst-copy .asst-note { margin-top: 14px; font-size: 15px; color: #8d98a5; }
  .bytes {
    flex: 1 1 460px;
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 14px;
    font: 14px/2 var(--font-mono);
  }
  .dump { padding: 18px 20px; border: 1px solid #2a323c; border-radius: var(--radius-card); background: #181d23; color: #d3dae2; }
  .dump.ours { border-color: #2f5f49; }
  .dump-head { margin-bottom: 8px; font: 500 13px var(--font-sans); color: #8d98a5; }
  .ours .dump-head { color: #86d6ad; }
  .dump-row { display: grid; grid-template-columns: 6.2em minmax(0, 1fr); white-space: nowrap; }
  .offset { color: #6f7a87; }
  .sum { margin-top: 6px; padding-top: 6px; border-top: 1px dashed #2f3843; color: #f0f3f6; }
  .ours .sum { color: #86d6ad; }
  .match {
    grid-column: 1 / -1;
    justify-self: center;
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 6px 14px 6px 10px;
    border-radius: 999px;
    background: #17291f;
    color: #86d6ad;
    font: 500 14px var(--font-sans);
  }
  .match svg { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }

  .spec {
    margin: 0;
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    column-gap: 56px;
    border-top: 1px solid var(--ink);
  }
  .spec div { display: grid; grid-template-columns: minmax(0, 13rem) minmax(0, 1fr); gap: 4px 24px; padding: 22px 0; border-bottom: 1px solid var(--line); }
  .spec dt { font-weight: 600; font-size: 16px; }
  .spec dd { margin: 0; color: var(--ink-2); line-height: 1.55; }

  .selfhost { display: flex; flex-wrap: wrap; align-items: center; gap: 28px 56px; padding-bottom: 120px; }
  .self-copy { flex: 1 1 320px; }
  .self-copy p { margin: 14px 0 0; max-width: 46ch; color: var(--ink-2); font-size: 17px; line-height: 1.6; }
  .terminal {
    flex: 1 1 480px;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 16px 16px 16px 22px;
    border-radius: var(--radius-card);
    background: #111418;
  }
  .terminal code { flex: 1; min-width: 0; overflow-x: auto; white-space: nowrap; font: 15px var(--font-mono); color: #e8ecf1; scrollbar-width: thin; }
  .prompt { color: #86d6ad; }
  .copy {
    flex: none;
    min-height: 40px;
    min-width: 84px;
    padding: 0 14px;
    border: 1px solid #3a434f;
    border-radius: var(--radius-block);
    background: transparent;
    color: #e8ecf1;
    font: inherit;
    font-size: 14px;
    cursor: pointer;
  }
  .copy:hover { border-color: #6f7a87; }

  .foot { border-top: 1px solid var(--line); background: var(--surface); }
  .foot-inner { display: flex; flex-wrap: wrap; gap: 12px 32px; align-items: baseline; padding-top: 28px; padding-bottom: 32px; font-size: 13px; color: var(--muted); }
  .foot-inner p { flex: 1 1 480px; margin: 0; max-width: 90ch; line-height: 1.6; }
  .foot-inner a { color: var(--muted); }

  @media (max-width: 860px) {
    .spec { grid-template-columns: minmax(0, 1fr); }
    .steps { grid-template-columns: minmax(0, 1fr); gap: 32px; padding-left: 56px; }
    .steps::before { top: 18px; bottom: 18px; left: 17px; right: auto; border-top: 0; border-left: 2px solid var(--line-strong); }
    .node { position: absolute; left: -56px; top: 0; }
    .steps h3 { margin-top: 4px; }
  }
  @media (max-width: 560px) {
    .wrap { padding-left: 20px; padding-right: 20px; }
    .terminal { flex-wrap: wrap; padding: 16px; }
    .terminal code { flex: 1 1 100%; white-space: pre-wrap; word-break: break-all; overflow: visible; }
    .copy { flex: 1 1 100%; }
    .hero-inner { padding-top: 56px; padding-bottom: 56px; }
    .links { display: none; }
    .section { padding-top: 80px; }
    .spec div { grid-template-columns: minmax(0, 1fr); }
    .bytes { grid-template-columns: minmax(0, 1fr); font-size: 13px; }
    .actions { width: 100%; }
    .actions .button { flex: 1 1 100%; }
  }
</style>
