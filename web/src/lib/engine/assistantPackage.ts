// Victron Assistant packages (`.vap`) and the library (`allNNN.vfp`) (port of Sources/VEKit/AssistantPackage.swift).
//
// Package: 4 bytes (unknown, `31 20 57 f6`), `[u16 len]"Victron Energy Assistant Package"`,
// u32 format (1), u32 assistant id, u32 (1), then entries `[u16 len][name][u32 DOS time][u32 attr][u32 size][bytes]`.
// Library: a flat list of `[u16 len][name][u32 DOS time][u32 attr][u32 compressed size][zlib bytes]`.
import { ByteReader, FormatError, inflate, latin1Decode, type Bytes } from './binary'

export const assistantPackageMagic = 'Victron Energy Assistant Package'

export interface PackageEntry {
  name: string
  dosTime: number
  attributes: number
  bytes: Bytes
}

export const entryText = (e: PackageEntry) => latin1Decode(e.bytes)

const extension = (name: string) => {
  const slash = name.lastIndexOf('/')
  const base = name.slice(slash + 1)
  const dot = base.lastIndexOf('.')
  return dot > 0 ? base.slice(dot + 1) : ''
}

const deletingExtension = (name: string) => {
  const slash = name.lastIndexOf('/')
  const dot = name.lastIndexOf('.')
  return dot > slash + 1 ? name.slice(0, dot) : name
}

export class AssistantPackage {
  constructor(
    public leading: Bytes,
    public format: number,
    public id: number,
    public flags: number,
    public entries: PackageEntry[],
    /** File name in the pack without the `_XXXX` id suffix, e.g. "ESS". */
    public baseName: string,
  ) {}

  static parse(bytes: Bytes, fileName = ''): AssistantPackage {
    const r = new ByteReader(bytes)
    const leading = r.bytes(4)
    if (r.shortString() !== assistantPackageMagic) throw new FormatError({ kind: 'badMagic', what: 'Victron assistant package' })
    const format = r.u32()
    const id = r.u32()
    const flags = r.u32()
    const entries: PackageEntry[] = []
    while (r.remaining >= 2) {
      const name = r.shortString()
      const dosTime = r.u32()
      const attributes = r.u32()
      const size = r.u32()
      entries.push({ name, dosTime, attributes, bytes: r.bytes(size) })
    }
    let base = deletingExtension(fileName)
    const underscore = base.lastIndexOf('_')
    if (underscore >= 0) base = base.slice(0, underscore)
    return new AssistantPackage(leading, format, id, flags, entries, base)
  }

  /** The assembler source. */
  get source(): PackageEntry | undefined { return this.entries.find((e) => e.name.toLowerCase().endsWith('.vll')) }

  /** Wizard scripts keyed by language extension ("en", "fr", "de", ...). Later entries win, like the Swift dictionary. */
  get scripts(): Map<string, PackageEntry> {
    const out = new Map<string, PackageEntry>()
    for (const e of this.entries) if (!e.name.toLowerCase().endsWith('.vll')) out.set(extension(e.name).toLowerCase(), e)
    return out
  }

  script(preferring: string[]): PackageEntry | undefined {
    const all = this.scripts
    for (const lang of [...preferring, 'en']) { const s = all.get(lang); if (s) return s }
    return all.values().next().value
  }
}

export class AssistantLibrary {
  constructor(public packages: AssistantPackage[]) {}

  static parse(bytes: Bytes): AssistantLibrary {
    const r = new ByteReader(bytes)
    const packages: AssistantPackage[] = []
    while (r.remaining >= 2) {
      const name = r.shortString()
      r.u32()
      r.u32()
      const size = r.u32()
      const raw = r.bytes(size)
      packages.push(AssistantPackage.parse(inflate(raw, name), name))
    }
    return new AssistantLibrary(packages)
  }

  /** Latest package for each assistant name, sorted case-insensitively. */
  get latest(): AssistantPackage[] {
    const best = new Map<string, AssistantPackage>()
    for (const p of this.packages) {
      const b = best.get(p.baseName)
      if (!b || b.id < p.id) best.set(p.baseName, p)
    }
    return [...best.values()].sort((a, b) => a.baseName.localeCompare(b.baseName, 'en', { sensitivity: 'base' }))
  }

  package(id: number): AssistantPackage | undefined { return this.packages.find((p) => p.id === id) }
}
