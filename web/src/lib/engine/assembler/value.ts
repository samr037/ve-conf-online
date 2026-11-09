// Values of the VLL assembler's calculator (port of Sources/VEKit/Assembler/Value.swift).
// Values are immutable: operations always build new arrays.
import { latin1Decode, latin1Encode, type Bytes } from '../binary'

export type Value =
  /** 32-bit signed, wrapping arithmetic. */
  | { readonly t: 'int'; readonly v: number }
  | { readonly t: 'bool'; readonly v: boolean }
  /** Byte string (Latin-1); indexing is 1-based. */
  | { readonly t: 'string'; readonly v: Bytes }
  /** Heterogeneous list; indexing is 0-based. */
  | { readonly t: 'list'; readonly v: readonly Value[] }

export const vInt = (n: number): Value => ({ t: 'int', v: n | 0 })
export const vBool = (b: boolean): Value => ({ t: 'bool', v: b })
export const vString = (b: Bytes | readonly number[]): Value => ({ t: 'string', v: b instanceof Uint8Array ? b : Uint8Array.from(b) })
export const vList = (l: readonly Value[]): Value => ({ t: 'list', v: l })
/** Latin-1 string value. */
export const vStr = (s: string): Value => vString(latin1Encode(s))

export function valueEquals(a: Value, b: Value): boolean {
  if (a.t !== b.t) return false
  switch (a.t) {
    case 'int':
    case 'bool':
      return a.v === b.v
    case 'string': {
      const x = a.v, y = (b as typeof a).v
      if (x.length !== y.length) return false
      for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return false
      return true
    }
    case 'list': {
      const x = a.v, y = (b as typeof a).v
      if (x.length !== y.length) return false
      for (let i = 0; i < x.length; i++) if (!valueEquals(x[i]!, y[i]!)) return false
      return true
    }
  }
}

export const optionalValueEquals = (a: Value | undefined, b: Value | undefined) =>
  a === undefined || b === undefined ? a === b : valueEquals(a, b)

export const sameClass = (a: Value, b: Value) => a.t === b.t
export const isString = (a: Value) => a.t === 'string'

const ascii = (s: string, out: number[]) => { for (let i = 0; i < s.length; i++) out.push(s.charCodeAt(i)) }

function append(v: Value, out: number[], limit: number): boolean {
  switch (v.t) {
    case 'int': ascii(String(v.v), out); break
    case 'bool': ascii(v.v ? 'TRUE' : 'FALSE', out); break
    case 'string':
      if (v.v.length > limit - out.length) return false
      out.push(0x27)
      for (const c of v.v) { out.push(c); if (c === 0x27) out.push(0x27) }
      out.push(0x27)
      break
    case 'list':
      ascii('([]', out)
      for (const e of v.v) {
        out.push(0x2b)
        if (!(out.length <= limit && append(e, out, limit))) return false
      }
      out.push(0x29)
      break
  }
  return out.length <= limit
}

/** Re-parseable text form (Delphi AsText): ints decimal, TRUE/FALSE, Pascal-quoted strings, `([]+a+b)` lists. */
export function asText(v: Value): Bytes {
  const out: number[] = []
  append(v, out, Number.MAX_SAFE_INTEGER)
  return Uint8Array.from(out)
}

/** `asText`, or undefined as soon as it would exceed `limit` bytes. */
export function asTextLimited(v: Value, limit: number): Bytes | undefined {
  const out: number[] = []
  return append(v, out, limit) ? Uint8Array.from(out) : undefined
}

export const valueText = (v: Value): string => latin1Decode(asText(v))

/** Text for display (strings unquoted, unlike `asText`). */
export function plainText(v: Value): string {
  switch (v.t) {
    case 'string': return latin1Decode(v.v)
    case 'int': return String(v.v)
    case 'bool': return v.v ? 'TRUE' : 'FALSE'
    case 'list': return valueText(v)
  }
}
