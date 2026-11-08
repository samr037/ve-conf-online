// Hands a file chosen on the landing page to the editor (app.html) without a server.
//
// Contract: the landing page calls `stashFile(name, bytes)` and navigates to `app.html?open=session`.
// The editor calls `takeStashedFile()` once at start-up; it returns the file and clears it, or
// `undefined` when nothing is waiting. Storage is sessionStorage (per tab, survives the navigation),
// base64-encoded; every access is guarded because storage can be disabled or full.

const key = 'handoff.file'

export interface StashedFile {
  name: string
  bytes: Uint8Array
}

function toBase64(bytes: Uint8Array): string {
  let s = ''
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}

function fromBase64(text: string): Uint8Array {
  const s = atob(text)
  const out = new Uint8Array(s.length)
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i)
  return out
}

/** Stores the file for the editor. Returns false when the browser refuses (storage off or full). */
export function stashFile(name: string, bytes: Uint8Array): boolean {
  try {
    sessionStorage.setItem(key, JSON.stringify({ name, data: toBase64(bytes) }))
    return true
  } catch {
    return false
  }
}

/** The file stashed by the landing page, removed from storage; `undefined` if there is none. */
export function takeStashedFile(): StashedFile | undefined {
  try {
    const raw = sessionStorage.getItem(key)
    if (raw === null) return undefined
    sessionStorage.removeItem(key)
    const v = JSON.parse(raw) as { name?: unknown; data?: unknown }
    if (typeof v.name !== 'string' || typeof v.data !== 'string') return undefined
    return { name: v.name, bytes: fromBase64(v.data) }
  } catch {
    return undefined
  }
}

/** URL of the editor, relative so the site also works under a sub-path. */
export const editorUrl = 'app.html'
export const editorOpenUrl = `${editorUrl}?open=session`
