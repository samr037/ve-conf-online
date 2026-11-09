// Interface language and number formatting.
//
// - App chrome: `L("English text")` looks the text up in the UI table (from `<lang>.lproj/Localizable.strings`).
// - Catalog text (labels, items, help from VE Configure): `catalogText()` looks it up in `catalog-strings.json`.
// - Numbers and dates use `locale` (the Swift app uses the system locale, e.g. "en-FR").

export const supportedLanguages = ['en', 'fr', 'de', 'es'] as const

interface L10nState {
  language: string
  /** BCP 47 locale for numbers and dates. */
  locale: string
  ui: Record<string, string>
  catalog: Record<string, string>
}

const state: L10nState = { language: 'en', locale: 'en-US', ui: {}, catalog: {} }

export interface L10nConfig {
  language?: string
  locale?: string
  /** Parsed `Localizable.strings` of the language (empty for English). */
  ui?: Record<string, string>
  /** `catalog-strings.json` entry of the language (`{english: translation}`). */
  catalog?: Record<string, string>
}

export function configureL10n(cfg: L10nConfig): void {
  if (cfg.language) state.language = cfg.language
  if (cfg.locale) state.locale = cfg.locale.replace('_', '-')
  state.ui = state.language === 'en' ? {} : (cfg.ui ?? {})
  state.catalog = state.language === 'en' ? {} : (cfg.catalog ?? {})
  numberFormats.clear()
}

export const currentLanguage = () => state.language
export const currentLocale = () => state.locale

/** Parses Apple `.strings` files: `"key" = "value";` lines, block comments ignored. */
export function parseStrings(text: string): Record<string, string> {
  const out: Record<string, string> = {}
  const re = /"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;/g
  const unescape = (s: string) =>
    s.replace(/\\(u[0-9a-fA-F]{4}|.)/g, (_, e: string) =>
      e[0] === 'u' ? String.fromCharCode(parseInt(e.slice(1), 16)) : e === 'n' ? '\n' : e === 't' ? '\t' : e === 'r' ? '\r' : e)
  const stripped = text.replace(/\/\*[\s\S]*?\*\//g, '')
  for (const m of stripped.matchAll(re)) out[unescape(m[1]!)] = unescape(m[2]!)
  return out
}

const numberFormats = new Map<string, Intl.NumberFormat>()

function nf(key: string, make: () => Intl.NumberFormat): Intl.NumberFormat {
  let f = numberFormats.get(key)
  if (!f) { f = make(); numberFormats.set(key, f) }
  return f
}

/** Swift `v.formatted(.number.precision(.fractionLength(n)))`, with or without grouping (ICU, round half even). */
export function formatFixed(v: number, digits: number, grouping = true): string {
  const f = nf(`fixed:${digits}:${grouping}`, () => new Intl.NumberFormat(state.locale, {
    minimumFractionDigits: digits, maximumFractionDigits: digits, useGrouping: grouping, roundingMode: 'halfEven',
  } as Intl.NumberFormatOptions))
  return f.format(v)
}

/** Swift `v.formatted()` for the short values the messages use. */
export function formatDefault(v: number): string {
  return nf('default', () => new Intl.NumberFormat(state.locale, { maximumSignificantDigits: 15 })).format(v)
}

/** Swift `d.formatted(date: .long, time: .shortened)`. */
export function formatDateTime(d: Date): string {
  return new Intl.DateTimeFormat(state.locale, { dateStyle: 'long', timeStyle: 'short' }).format(d)
}

/** `String(format:locale:)` for `%@`, `%d`, `%ld`, `%n$@`, `%%` (integers grouped like Foundation does). */
export function format(fmt: string, args: readonly unknown[]): string {
  let next = 0
  return fmt.replace(/%(?:(\d+)\$)?(@|l?d|%)/g, (_, pos: string | undefined, spec: string) => {
    if (spec === '%') return '%'
    const i = pos ? Number(pos) - 1 : next++
    const a = args[i]
    if (spec === '@') return String(a)
    return nf(`int:${state.language}`, () => new Intl.NumberFormat(state.language, { maximumFractionDigits: 0 })).format(Number(a))
  })
}

/** Localised app text. */
export function L(key: string, ...args: unknown[]): string {
  const t = state.ui[key] ?? key
  return args.length ? format(t, args) : t
}

/** Removes VE Configure's THandyLabel markup (\FS:1\, \IS\, \IL:url\ …). */
export function stripMarkup(s: string): string {
  return s.replace(/\\[A-Z]{2}(:[^\\]*)?\\/g, '')
}

let cleanCaptionImpl: (s: string) => string = (s) => s
/** Set by catalog.ts (avoids an import cycle). */
export function setCleanCaption(f: (s: string) => string): void { cleanCaptionImpl = f }

/** A catalog string as displayed: exact match, then its cleaned form; English when untranslated. */
export function catalogText(s: string): string {
  const table = state.catalog
  if (s === '' || Object.keys(table).length === 0) return s
  const t = table[s]
  if (t !== undefined) return t
  const n = cleanCaptionImpl(stripMarkup(s))
  return table[n] ?? s
}

export function catalogTextOpt(s: string | undefined): string | undefined {
  return s === undefined ? undefined : catalogText(s)
}
