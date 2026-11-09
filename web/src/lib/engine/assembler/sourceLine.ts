// Line structure of VLL sources (port of Sources/VEKit/Assembler/SourceLine.swift).
import { latin1Decode, type Bytes } from '../binary'

const isBlank = (c: number) => c === 0x20 || c === 0x09

export function trimBytes(s: Bytes): Bytes {
  let a = 0, b = s.length
  while (a < b && isBlank(s[a]!)) a++
  while (b > a && isBlank(s[b - 1]!)) b--
  return s.subarray(a, b)
}

export class SourceLine {
  constructor(
    readonly label: string,
    readonly opcode: string,
    /** Raw parameter texts, trimmed of TAB/SPACE; evaluated later by the directive or macro binding. */
    readonly params: Bytes[],
    readonly error?: string,
  ) {}

  static readonly empty = new SourceLine('', '', [])

  static parse(raw: Bytes): SourceLine {
    const line = stripComment(raw)
    let i = 0
    let label = ''
    if (line.length > 0 && !isBlank(line[0]!)) {
      while (i < line.length && !isBlank(line[i]!)) i++
      label = latin1Decode(line.subarray(0, i))
    }
    while (i < line.length && isBlank(line[i]!)) i++
    const opStart = i
    while (i < line.length && !isBlank(line[i]!)) i++
    const opcode = latin1Decode(line.subarray(opStart, i))
    const [params, error] = splitParams(line.subarray(i))
    return new SourceLine(label, opcode, params, error)
  }

  equals(o: SourceLine): boolean {
    if (this.label !== o.label || this.opcode !== o.opcode || this.error !== o.error || this.params.length !== o.params.length) return false
    for (let k = 0; k < this.params.length; k++) {
      const a = this.params[k]!, b = o.params[k]!
      if (a.length !== b.length) return false
      for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
    }
    return true
  }
}

/** Cut at the first `;` outside `"…"`, `'…'` and nested `(…)` (inside parentheses only parentheses count). */
export function stripComment(s: Bytes): Bytes {
  let quote: number | undefined
  let depth = 0
  for (let k = 0; k < s.length; k++) {
    const c = s[k]!
    if (depth > 0) {
      if (c === 0x28) depth++
      else if (c === 0x29) depth--
      continue
    }
    if (quote !== undefined) {
      if (c === quote) quote = undefined
      continue
    }
    if (c === 0x22 || c === 0x27) quote = c
    else if (c === 0x28) depth = 1
    else if (c === 0x3b) return s.subarray(0, k)
  }
  return s
}

/** Split on `,` honouring the same pairs. Leading separators are skipped; a trailing empty token is an error. */
export function splitParams(s: Bytes): [Bytes[], string | undefined] {
  const out: Bytes[] = []
  let start = 0
  let quote: number | undefined
  let depth = 0
  let sawSeparator = false
  const flush = (end: number) => {
    const t = trimBytes(s.subarray(start, end))
    if (t.length > 0) out.push(t.slice())
  }
  for (let k = 0; k < s.length; k++) {
    const c = s[k]!
    if (depth > 0) {
      if (c === 0x28) depth++
      else if (c === 0x29) depth--
      continue
    }
    if (quote !== undefined) {
      if (c === quote) quote = undefined
      continue
    }
    if (c === 0x22 || c === 0x27) quote = c
    else if (c === 0x28) depth = 1
    else if (c === 0x2c) { flush(k); start = k + 1; sawSeparator = true }
  }
  const last = trimBytes(s.subarray(start))
  if (last.length > 0) out.push(last.slice())
  else if (sawSeparator) return [out, 'Improper parameter list'] // trailing "a,"
  if (out.length > 10) return [out, 'Maximum nr of parameters for this assembler is 10!']
  return [out, undefined]
}

/**
 * Line splitting of Delphi `TStrings.Text`: CR, LF and CRLF each end a line (so do LF CR: two breaks),
 * a NUL ends the text, and a final line break adds no empty line.
 */
export function splitTextLines(text: Bytes): Bytes[] {
  const lines: Bytes[] = []
  let i = 0
  while (i < text.length && text[i] !== 0) {
    const start = i
    while (i < text.length && text[i] !== 0 && text[i] !== 0x0a && text[i] !== 0x0d) i++
    lines.push(text.subarray(start, i))
    if (i < text.length && text[i] === 0x0d) i++
    if (i < text.length && text[i] === 0x0a) i++
  }
  return lines
}

/** A list of lines with a header at index 0 (never assembled). */
export class LineList {
  private readonly raw: Bytes[]
  private readonly parsed: (SourceLine | undefined)[]

  private constructor(readonly header: string, raw: Bytes[], parsed: (SourceLine | undefined)[]) {
    this.raw = raw
    this.parsed = parsed
  }

  static fromText(header: string, text: Bytes): LineList {
    const lines = [new Uint8Array(), ...splitTextLines(text)]
    return new LineList(header, lines, new Array(lines.length).fill(undefined))
  }

  static fromLines(header: string, lines: SourceLine[]): LineList {
    return new LineList(header, [], [SourceLine.empty, ...lines])
  }

  get count(): number { return this.parsed.length }

  line(i: number): SourceLine {
    const p = this.parsed[i]
    if (p) return p
    const q = SourceLine.parse(this.raw[i]!)
    this.parsed[i] = q
    return q
  }
}
