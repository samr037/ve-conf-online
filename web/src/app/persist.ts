// The open document survives a page reload: its snapshot is kept in this browser after every change and brought
// back at start-up. Closing the document or opening another one replaces it.
// localStorage, because it is synchronous: the last edit is still written when the page unloads right after it.
// Every access may fail (private mode, blocked or full storage): the editor then simply starts empty.
import type { DocumentSnapshot } from '../lib/rules'

const key = 'shunt.session'
/** Undo steps kept across a reload; older ones are dropped to stay well inside the storage quota. */
const maxSteps = 100

export interface SavedSession {
  snapshot: DocumentSnapshot
  section: string
  subpage: Record<string, string>
}

const b64 = (b: Uint8Array) => {
  let s = ''
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000))
  return btoa(s)
}
const bytes = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0))

type Step = { name: string; config: string }
interface Stored {
  v: 1
  fileName?: string
  baseline: string
  config: string
  undo: Step[]
  redo: Step[]
  chargerUnhidden: boolean
  section: string
  subpage: Record<string, string>
}

function encode(s: SavedSession): Stored {
  const step = (e: { name: string; config: Uint8Array }) => ({ name: e.name, config: b64(e.config) })
  const snap = s.snapshot
  return {
    v: 1,
    fileName: snap.fileName,
    baseline: b64(snap.baseline),
    config: b64(snap.config),
    undo: snap.undo.slice(-maxSteps).map(step),
    redo: snap.redo.slice(-maxSteps).map(step),
    chargerUnhidden: snap.chargerUnhidden,
    section: s.section,
    subpage: s.subpage,
  }
}

function decode(s: Stored): SavedSession {
  const step = (e: Step) => ({ name: e.name, config: bytes(e.config) })
  return {
    snapshot: {
      fileName: s.fileName,
      baseline: bytes(s.baseline),
      config: bytes(s.config),
      undo: s.undo.map(step),
      redo: s.redo.map(step),
      chargerUnhidden: s.chargerUnhidden,
    },
    section: s.section,
    subpage: s.subpage,
  }
}

export function loadSession(): SavedSession | undefined {
  try {
    const raw = localStorage.getItem(key)
    if (!raw) return undefined
    const s = JSON.parse(raw) as Stored
    return s.v === 1 ? decode(s) : undefined
  } catch {
    return undefined
  }
}

export function clearSession(): void {
  cancelSave()
  try { localStorage.removeItem(key) } catch { /* nothing kept */ }
}

let timer: ReturnType<typeof setTimeout> | undefined
let pending: (() => SavedSession) | undefined

/** Saves shortly after the last change, so a burst of edits writes once. */
export function scheduleSave(make: () => SavedSession): void {
  pending = make
  clearTimeout(timer)
  timer = setTimeout(flushSession, 250)
}

/** Writes a pending save now (page hidden or unloading). */
export function flushSession(): void {
  clearTimeout(timer)
  const make = pending
  pending = undefined
  if (!make) return
  try {
    localStorage.setItem(key, JSON.stringify(encode(make())))
  } catch {
    /* quota or blocked storage: the reload starts empty */
  }
}

/** Drops a pending save without writing it (the document is being closed). */
export function cancelSave(): void {
  clearTimeout(timer)
  pending = undefined
}
