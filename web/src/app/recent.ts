// The last files opened or saved in this browser (names, dates and bytes, in IndexedDB), so one can be reopened
// from the open screen. Every storage access may fail (private mode, blocked storage): the list is then empty.

const dbName = 'shunt.recent'
const store = 'files'
const key = 'list'
const limit = 5

export interface RecentFile { name: string; at: number; bytes: Uint8Array }

function openDB(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(dbName, 1)
    req.onupgradeneeded = () => req.result.createObjectStore(store)
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
}

async function read(): Promise<RecentFile[]> {
  try {
    const db = await openDB()
    return await new Promise((resolve) => {
      const r = db.transaction(store, 'readonly').objectStore(store).get(key)
      r.onsuccess = () => resolve(Array.isArray(r.result) ? (r.result as RecentFile[]) : [])
      r.onerror = () => resolve([])
    })
  } catch {
    return []
  }
}

async function write(list: RecentFile[]): Promise<void> {
  try {
    const db = await openDB()
    await new Promise<void>((resolve) => {
      const tx = db.transaction(store, 'readwrite')
      tx.objectStore(store).put(list, key)
      tx.oncomplete = () => resolve()
      tx.onerror = () => resolve()
    })
  } catch {
    /* nothing kept */
  }
}

export const recentFiles = read

/** Puts a file first (replacing one of the same name) and keeps the newest five. */
export async function rememberFile(name: string, bytes: Uint8Array): Promise<RecentFile[]> {
  const list = [{ name, at: Date.now(), bytes: bytes.slice() }, ...(await read()).filter((f) => f.name !== name)].slice(0, limit)
  await write(list)
  return list
}

export async function forgetFile(name: string): Promise<RecentFile[]> {
  const list = (await read()).filter((f) => f.name !== name)
  await write(list)
  return list
}
