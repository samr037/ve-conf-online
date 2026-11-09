// Interface language shared by the landing page and the editor: English by default,
// French, German and Spanish when the browser asks for them or the user picks one.
export const languages = ['en', 'fr', 'de', 'es'] as const
export type Language = (typeof languages)[number]

export const languageNames: Record<Language, string> = { en: 'English', fr: 'Français', de: 'Deutsch', es: 'Español' }

const storageKey = 'shunt.language'

function stored(): Language | undefined {
  try {
    const v = localStorage.getItem(storageKey)
    return (languages as readonly string[]).includes(v ?? '') ? (v as Language) : undefined
  } catch {
    return undefined
  }
}

/** The saved choice, else the first browser language we support, else English. */
export function initialLanguage(): Language {
  const s = stored()
  if (s) return s
  for (const tag of typeof navigator === 'undefined' ? [] : navigator.languages ?? [navigator.language]) {
    const base = tag.toLowerCase().split('-')[0]
    if ((languages as readonly string[]).includes(base ?? '')) return base as Language
  }
  return 'en'
}

export function saveLanguage(l: Language): void {
  try { localStorage.setItem(storageKey, l) } catch { /* private mode: keep it for this page only */ }
  document.documentElement.lang = l
}

/** A tiny typed dictionary helper: `t(dict, lang, key, {n: 3})` with `{n}` placeholders, English fallback. */
export type Dictionary<K extends string> = Record<Language, Partial<Record<K, string>>> & { en: Record<K, string> }

export function translate<K extends string>(dict: Dictionary<K>, lang: Language, key: K, vars?: Record<string, string | number>): string {
  let s: string = (dict[lang][key] ?? dict.en[key]) as string
  if (vars) for (const [k, v] of Object.entries(vars)) s = s.replaceAll(`{${k}}`, String(v))
  return s
}
