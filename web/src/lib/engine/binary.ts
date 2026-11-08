// Little-endian byte I/O, Latin-1 text and zlib inflate (port of Sources/VEKit/Binary.swift).
import { Unzlib } from 'fflate'

export type FormatErrorKind =
  | { kind: 'truncated'; at: number }
  | { kind: 'badMagic'; what: string }
  | { kind: 'badChecksum'; section: string }
  | { kind: 'decompression'; name: string }
  | { kind: 'duplicateSection'; name: string }
  | { kind: 'tooLarge'; what: string; limit: number }
  | { kind: 'unsupportedVersion'; section: string; version: number }
  | { kind: 'malformed'; why: string }

function describe(e: FormatErrorKind): string {
  switch (e.kind) {
    case 'truncated': return `File ends unexpectedly at byte ${e.at}.`
    case 'badMagic': return `Not a ${e.what}.`
    case 'badChecksum': return `Section ${e.section} is corrupt (checksum mismatch).`
    case 'decompression': return `Cannot decompress ${e.name}.`
    case 'duplicateSection': return `Section ${e.name} appears more than once; the file is ambiguous.`
    case 'tooLarge': return `${e.what} is larger than ${e.limit} bytes.`
    case 'unsupportedVersion':
      return `Section ${e.section} has version ${e.version}, which this program does not know how to read.`
    case 'malformed': return e.why
  }
}

export class FormatError extends Error {
  constructor(readonly detail: FormatErrorKind) {
    super(describe(detail))
    this.name = 'FormatError'
  }
}

export type Bytes = Uint8Array

/** Little-endian cursor over a byte buffer. All VE Configure files are little-endian (Delphi on x86). */
export class ByteReader {
  constructor(readonly data: Bytes, public offset = 0) {}

  get isAtEnd(): boolean { return this.offset >= this.data.length }
  get remaining(): number { return this.data.length - this.offset }

  bytes(count: number): Bytes {
    if (count < 0 || this.offset + count > this.data.length) throw new FormatError({ kind: 'truncated', at: this.offset })
    const out = this.data.slice(this.offset, this.offset + count)
    this.offset += count
    return out
  }

  u8(): number { return this.bytes(1)[0]! }

  u16(): number {
    const b = this.bytes(2)
    return b[0]! | (b[1]! << 8)
  }

  u32(): number {
    const b = this.bytes(4)
    return (b[0]! | (b[1]! << 8) | (b[2]! << 16) | (b[3]! << 24)) >>> 0
  }

  /** Delphi-style string: u16 length then Latin-1 bytes. */
  shortString(): string { return latin1Decode(this.bytes(this.u16())) }
}

export class ByteWriter {
  private buf: number[] = []

  get length(): number { return this.buf.length }
  get data(): Bytes { return Uint8Array.from(this.buf) }

  u8(v: number): void { this.buf.push(v & 0xff) }
  u16(v: number): void { this.buf.push(v & 0xff, (v >>> 8) & 0xff) }
  u32(v: number): void { this.buf.push(v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff) }
  bytes(b: ArrayLike<number>): void { for (let i = 0; i < b.length; i++) this.buf.push(b[i]!) }
  shortString(s: string): void {
    const b = latin1Encode(s)
    this.u16(b.length)
    this.bytes(b)
  }
  patchU32(at: number, v: number): void {
    this.buf[at] = v & 0xff
    this.buf[at + 1] = (v >>> 8) & 0xff
    this.buf[at + 2] = (v >>> 16) & 0xff
    this.buf[at + 3] = (v >>> 24) & 0xff
  }
  /** Bytes from `start` to the end (for checksums). */
  slice(start: number): number[] { return this.buf.slice(start) }
}

/** Latin-1: each byte is one code point (assistants are written in ANSI). */
export function latin1Decode(b: ArrayLike<number>): string {
  let s = ''
  for (let i = 0; i < b.length; i += 4096) s += String.fromCharCode(...Array.prototype.slice.call(b, i, i + 4096))
  return s
}

/** Code points above 255 become `?`, like the Swift `Latin1.encode`. */
export function latin1Encode(s: string): Bytes {
  const out: number[] = []
  for (const ch of s) {
    const c = ch.codePointAt(0)!
    out.push(c < 256 ? c : 0x3f)
  }
  return Uint8Array.from(out)
}

export function concat(...parts: ArrayLike<number>[]): Bytes {
  const n = parts.reduce((a, p) => a + p.length, 0)
  const out = new Uint8Array(n)
  let o = 0
  for (const p of parts) { out.set(p, o); o += p.length }
  return out
}

export function equalBytes(a: ArrayLike<number>, b: ArrayLike<number>): boolean {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

/** Upper bound for one decompressed library entry. Real `.vap` files are a few hundred KB. */
export const inflateLimit = 16 << 20

/** Streams so a compression bomb is refused as soon as the output passes `limit`. */
export function inflate(input: Bytes, name: string, limit = inflateLimit): Bytes {
  const chunks: Bytes[] = []
  let total = 0
  let ended = false
  const tooLarge = new FormatError({ kind: 'tooLarge', what: `Decompressed ${name}`, limit })
  const z = new Unzlib((chunk, final) => {
    total += chunk.length
    if (total > limit) throw tooLarge
    chunks.push(chunk)
    if (final) ended = true
  })
  try {
    for (let i = 0; i < input.length && !ended; i += 65536) z.push(input.subarray(i, i + 65536), i + 65536 >= input.length)
  } catch (e) {
    if (e === tooLarge) throw e
    throw new FormatError({ kind: 'decompression', name })
  }
  if (!ended) throw new FormatError({ kind: 'decompression', name })
  return concat(...chunks)
}
