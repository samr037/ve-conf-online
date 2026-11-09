// Victron's assistant library (`allNNN.vfp`): the copy that ships with the site, or a newer one the user imported
// (kept in this browser, IndexedDB).
// Every storage access may fail (private mode, blocked storage): the app then keeps the library for this page only.
import { AssistantLibrary } from '../lib/engine/assistantPackage'
import bundledURL from '../data/assistants/all112.vfp?url'

const dbName = 'shunt.library'
const store = 'library'
const key = 'current'

interface Stored { name: string; bytes: Uint8Array }

function openDB(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(dbName, 1)
    req.onupgradeneeded = () => req.result.createObjectStore(store)
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
}

async function read(): Promise<Stored | undefined> {
  try {
    const db = await openDB()
    return await new Promise((resolve) => {
      const r = db.transaction(store, 'readonly').objectStore(store).get(key)
      r.onsuccess = () => resolve(r.result as Stored | undefined)
      r.onerror = () => resolve(undefined)
    })
  } catch {
    return undefined
  }
}

async function write(v: Stored): Promise<void> {
  try {
    const db = await openDB()
    await new Promise<void>((resolve) => {
      const tx = db.transaction(store, 'readwrite')
      tx.objectStore(store).put(v, key)
      tx.oncomplete = () => resolve()
      tx.onerror = () => resolve()
    })
  } catch {
    /* kept in memory only */
  }
}

export interface LoadedLibrary { name: string; library: AssistantLibrary }

/** The library saved in this browser, if any and if it still parses. */
export async function loadStoredLibrary(): Promise<LoadedLibrary | undefined> {
  const s = await read()
  if (!s) return undefined
  try {
    return { name: s.name, library: AssistantLibrary.parse(s.bytes) }
  } catch {
    return undefined
  }
}

/** Parses a user-chosen library; saved only once it parses. Throws the parse error otherwise. */
export async function importLibrary(name: string, bytes: Uint8Array): Promise<LoadedLibrary> {
  const library = AssistantLibrary.parse(bytes)
  if (library.packages.length === 0) throw new Error('This file holds no assistants.')
  await write({ name, bytes })
  return { name, library }
}

/** Library languages: the interface language first, then the browser's, then English. */
export function libraryLanguages(language: string): string[] {
  const nav = typeof navigator === 'undefined' ? [] : (navigator.languages ?? [navigator.language])
  return [language, ...nav.map((l) => l.slice(0, 2).toLowerCase()), 'en']
}

/** The library that ships with the site. */
export async function loadBundledLibrary(): Promise<LoadedLibrary> {
  const r = await fetch(bundledURL)
  if (!r.ok) throw new Error(`${r.status}`)
  return { name: 'all112.vfp', library: AssistantLibrary.parse(new Uint8Array(await r.arrayBuffer())) }
}
