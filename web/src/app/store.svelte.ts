// Editor state: the open document, the reactive revision counter, navigation, the language and the dialogs.
// The engine and rules objects are plain classes; `rev` is bumped on every change so `$derived` values recompute.
import catalogURL from '../data/catalog.json?url'
import catalogStringsURL from '../data/catalog-strings.json?url'
import { MetaGenerator } from '../lib/engine/assembler'
import type { AssistantLibrary } from '../lib/engine/assistantPackage'
import type { DeviceConfiguration } from '../lib/engine/deviceConfiguration'
import { initialLanguage, saveLanguage, type Language } from '../lib/i18n/locale'
import {
  ConfigDocument, buildCatalog, configureL10n, parseStrings, useCatalog, type Confirmation, type GridChoice, type Notice, type Section,
} from '../lib/rules'
import { AssistantsModel, WizardSession } from './assistants'
import { libraryLanguages, loadBundledLibrary, loadStoredLibrary } from './library'
import { clearSession, flushSession, loadSession, scheduleSave } from './persist'
import { forgetFile, recentFiles, rememberFile, type RecentFile } from './recent'

const uiStrings: Record<Exclude<Language, 'en'>, () => Promise<string>> = {
  fr: () => import('../data/l10n/fr.strings?raw').then((m) => m.default),
  de: () => import('../data/l10n/de.strings?raw').then((m) => m.default),
  es: () => import('../data/l10n/es.strings?raw').then((m) => m.default),
}

/** Where a read-only device document came from. */
export interface DeviceSource { portLabel: string; readAt: Date; address: number }

/** A modal the editor shows; `resolve` receives the index of the button chosen (or -1 for Cancel / Escape). */
export type DialogRequest =
  | { k: 'confirm'; confirmation: Confirmation; resolve: (ok: boolean) => void }
  | { k: 'notice'; notice: Notice; resolve: (openPresets: boolean) => void }
  | { k: 'gridChoice'; choice: GridChoice; resolve: (code: number | undefined) => void }
  | { k: 'gridPassword' }
  | { k: 'presets' }
  | { k: 'wizard'; session: WizardSession }
  | { k: 'message'; title: string; message: string }
  | { k: 'saveBlocked'; reason: string }
  | { k: 'saveName'; suggested: string; resolve: (name: string | undefined) => void }

/** Locale for numbers and dates: the interface language with the browser's region when it has one for it. */
function localeFor(language: Language): string {
  const nav = typeof navigator === 'undefined' ? [] : (navigator.languages ?? [navigator.language])
  return nav.find((l) => l.toLowerCase().startsWith(language)) ?? { en: 'en-GB', fr: 'fr-FR', de: 'de-DE', es: 'es-ES' }[language]
}

function readTheme(): 'auto' | 'light' | 'dark' {
  try {
    const t = localStorage.getItem('shunt.theme')
    return t === 'light' || t === 'dark' ? t : 'auto'
  } catch {
    return 'auto'
  }
}

export function applyTheme(t: 'auto' | 'light' | 'dark'): void {
  if (t === 'auto') delete document.documentElement.dataset.theme
  else document.documentElement.dataset.theme = t
}

class EditorStore {
  ready = $state(false)
  loadError = $state<string | undefined>(undefined)
  language = $state<Language>(initialLanguage())
  /** Bumped on every document, assistants or language change. Read it to subscribe. */
  rev = $state(0)
  doc = $state.raw<ConfigDocument | undefined>(undefined)
  assistants = $state.raw<AssistantsModel | undefined>(undefined)
  library = $state.raw<{ name: string; library: AssistantLibrary } | undefined>(undefined)
  /** True while the bundled library downloads; the manual import shows only if that fails. */
  libraryLoading = $state(true)
  /** Files opened or saved lately in this browser, newest first. */
  recents = $state.raw<RecentFile[]>([])
  /** Set while the open document was read from a device (beta): it is read-only and never kept across a reload. */
  device = $state.raw<DeviceSource | undefined>(undefined)
  /** The editor was opened from the landing page's device link: show the connect dialog once. */
  connectRequested = $state(false)
  section = $state<Section>('general')
  subpage = $state<Partial<Record<Section, string>>>({})
  /** Diagram parts lit by the group under the pointer. */
  hovered = $state.raw<Set<string> | undefined>(undefined)
  /** Diagram parts of the page shown (union of its sections). */
  pageLit = $state.raw<Set<string>>(new Set())
  showsChanges = $state(true)
  dialogs = $state.raw<DialogRequest[]>([])
  /** Short status line shown at the bottom (e.g. the saved file name). */
  toastText = $state<string | undefined>(undefined)
  theme = $state<'auto' | 'light' | 'dark'>(readTheme())
  private toastTimer: ReturnType<typeof setTimeout> | undefined
  private catalogStrings: Record<string, Record<string, string>> = {}

  async start(): Promise<void> {
    try {
      const [cat, strings] = await Promise.all([
        fetch(catalogURL).then((r) => { if (!r.ok) throw new Error(`${r.status}`); return r.json() }),
        fetch(catalogStringsURL).then((r) => { if (!r.ok) throw new Error(`${r.status}`); return r.json() }),
      ])
      useCatalog(buildCatalog(cat))
      this.catalogStrings = strings
      await this.setLanguage(this.language, false)
      this.ready = true
      void this.loadLibrary()
      void recentFiles().then((r) => (this.recents = r))
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : String(e)
    }
  }

  async setLanguage(l: Language, persist = true): Promise<void> {
    const ui = l === 'en' ? {} : parseStrings(await uiStrings[l]())
    configureL10n({ language: l, locale: localeFor(l), ui, catalog: l === 'en' ? {} : this.catalogStrings[l] ?? {} })
    this.language = l
    if (persist) saveLanguage(l)
    else document.documentElement.lang = l
    if (this.assistants) {
      this.assistants.languages = libraryLanguages(l)
      this.assistants.refresh()
    }
    this.bump()
  }

  bump(): void {
    this.rev++
    const doc = this.doc
    if (doc && !this.device) scheduleSave(() => ({ snapshot: doc.snapshot(), section: this.section, subpage: { ...this.subpage } as Record<string, string> }))
  }

  /** Writes the session now, with the page shown (called when the page is hidden or reloads). */
  persistNow(): void {
    const doc = this.doc
    if (!doc || this.device) return
    scheduleSave(() => ({ snapshot: doc.snapshot(), section: this.section, subpage: { ...this.subpage } as Record<string, string> }))
    flushSession()
  }

  /** Brings back the document that was open before the page reloaded. False when there is none. */
  async resume(): Promise<boolean> {
    const saved = loadSession()
    if (!saved) return false
    try {
      this.attach(ConfigDocument.restore(saved.snapshot, { ratings: MetaGenerator.ratings }))
      this.section = saved.section as Section
      this.subpage = saved.subpage as Partial<Record<Section, string>>
      this.bump()
      return true
    } catch {
      clearSession()
      return false
    }
  }

  toast(text: string): void {
    this.toastText = text
    clearTimeout(this.toastTimer)
    this.toastTimer = setTimeout(() => (this.toastText = undefined), 4000)
  }

  setTheme(t: 'auto' | 'light' | 'dark'): void {
    this.theme = t
    applyTheme(t)
    try { localStorage.setItem('shunt.theme', t) } catch { /* this page only */ }
  }

  open(bytes: Uint8Array, fileName: string): void {
    this.attach(ConfigDocument.open(bytes, fileName, { ratings: MetaGenerator.ratings }))
    this.device = undefined
    this.section = 'general'
    this.subpage = {}
    this.bump()
  }

  private attach(doc: ConfigDocument): void {
    const model = new AssistantsModel(doc, this.library?.library, libraryLanguages(this.language))
    doc.onChange = () => { model.documentChanged(); this.bump(); this.drainNotices() }
    model.onChange = () => { this.bump(); this.drainMessages() }
    this.doc = doc
    this.assistants = model
    this.hovered = undefined
    this.dialogs = []
  }

  /** Opens a configuration read from a device, read-only. A reload goes back to the open screen. */
  openDevice(config: DeviceConfiguration, source: DeviceSource): void {
    clearSession()
    this.attach(ConfigDocument.fromDevice(config, { ratings: MetaGenerator.ratings }))
    this.device = source
    this.section = 'general'
    this.subpage = {}
    this.bump()
  }

  close(): void {
    clearSession()
    this.device = undefined
    this.doc = undefined
    this.assistants = undefined
    this.dialogs = []
    this.bump()
  }

  /** A library the user imported earlier wins; otherwise the one that ships with the site. */
  private async loadLibrary(): Promise<void> {
    try {
      const lib = (await loadStoredLibrary()) ?? (await loadBundledLibrary())
      if (!this.library) this.setLibrary(lib)
    } catch {
      /* the Assistants page offers the manual import */
    } finally {
      this.libraryLoading = false
      this.bump()
    }
  }

  setLibrary(lib: { name: string; library: AssistantLibrary }): void {
    this.library = lib
    this.assistants?.setLibrary(lib.library)
    this.bump()
  }

  // MARK: Dialogs

  push(d: DialogRequest): void { this.dialogs = [...this.dialogs, d] }
  pop(d: DialogRequest): void { this.dialogs = this.dialogs.filter((x) => x !== d) }

  askSaveName(suggested: string): Promise<string | undefined> {
    return new Promise((resolve) => this.push({ k: 'saveName', suggested, resolve }))
  }

  async rememberRecent(name: string, bytes: Uint8Array): Promise<void> {
    this.recents = await rememberFile(name, bytes)
  }

  async forgetRecent(name: string): Promise<void> {
    this.recents = await forgetFile(name)
  }

  confirm(c: Confirmation): Promise<boolean> {
    return new Promise((resolve) => this.push({ k: 'confirm', confirmation: c, resolve }))
  }

  gridChoice(choice: GridChoice): Promise<number | undefined> {
    if (choice.t === 'accept') return Promise.resolve(choice.code)
    return new Promise((resolve) => this.push({ k: 'gridChoice', choice, resolve }))
  }

  /** The document's notices (VE Configure's info boxes) become dialogs, one at a time. */
  private drainNotices(): void {
    const doc = this.doc
    if (!doc) return
    while (doc.notices.length) {
      const notice = doc.notices.shift()!
      this.push({ k: 'notice', notice, resolve: (openPresets) => { if (openPresets) this.push({ k: 'presets' }) } })
    }
  }

  private drainMessages(): void {
    const m = this.assistants?.message
    if (m === undefined || !this.assistants) return
    this.assistants.message = undefined
    this.push({ k: 'message', title: '', message: m })
  }
}

export const editor = new EditorStore()
