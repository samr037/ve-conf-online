// A VE Configure "setting section file": `.rvsc` and `.vsc` (port of Sources/VEKit/SettingFile.swift).
//
// Layout: `[u16 len]"VEConfig setting section file"`, then sections
// `[u16 len][name][u32 absolute end offset][body][u32 checksum]`.
// The checksum adds every byte shifted left by `8 * (i % 4)`,
// from the section's name-length field up to the checksum itself.
import { ByteReader, ByteWriter, FormatError, type Bytes } from './binary'

export interface Section {
  name: string
  body: Bytes
}

export const settingFileMagic = 'VEConfig setting section file'

export function checksum(bytes: ArrayLike<number>): number {
  let sum = 0
  for (let i = 0; i < bytes.length; i++) sum = (sum + ((bytes[i]! << (8 * (i % 4))) >>> 0)) >>> 0
  return sum
}

export class SettingFile {
  constructor(public sections: Section[]) {}

  static parse(bytes: Bytes): SettingFile {
    const r = new ByteReader(bytes)
    let magic: string | undefined
    try { magic = r.shortString() } catch { magic = undefined }
    if (magic !== settingFileMagic) throw new FormatError({ kind: 'badMagic', what: 'VE Configure setting file' })
    const sections: Section[] = []
    while (!r.isAtEnd) {
      const start = r.offset
      const name = r.shortString()
      const end = r.u32()
      if (end - 4 < r.offset || end > bytes.length) throw new FormatError({ kind: 'truncated', at: r.offset })
      const body = r.bytes(end - 4 - r.offset)
      const stored = r.u32()
      if (stored !== checksum(bytes.subarray(start, end - 4))) throw new FormatError({ kind: 'badChecksum', section: name })
      // Lookups take the first match by name; a second copy would be written back unedited.
      if (sections.some((s) => s.name === name)) throw new FormatError({ kind: 'duplicateSection', name })
      sections.push({ name, body })
    }
    return new SettingFile(sections)
  }

  get(name: string): Bytes | undefined {
    return this.sections.find((s) => s.name === name)?.body
  }

  /** Replaces the first section of that name, removes it (`undefined`), or appends a new one. */
  set(name: string, body: Bytes | undefined): void {
    const i = this.sections.findIndex((s) => s.name === name)
    if (i >= 0) {
      if (body) this.sections[i] = { name, body }
      else this.sections.splice(i, 1)
    } else if (body) {
      this.sections.push({ name, body })
    }
  }

  clone(): SettingFile {
    return new SettingFile(this.sections.map((s) => ({ name: s.name, body: s.body })))
  }

  encoded(): Bytes {
    const w = new ByteWriter()
    w.shortString(settingFileMagic)
    for (const section of this.sections) {
      const start = w.length
      w.shortString(section.name)
      const endField = w.length
      w.u32(0)
      w.bytes(section.body)
      w.patchU32(endField, w.length + 4)
      w.u32(checksum(w.slice(start)))
    }
    return w.data
  }
}
