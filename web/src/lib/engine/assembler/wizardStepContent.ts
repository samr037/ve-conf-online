// Turns a wizard step (its text section + the .AUE format list) into displayable content: Delphi Format
// (`%0:s`, `%1:d`, `%s`), inline codes (`\FS:1\`, `\IS\…\IL:url\`, `\TI\`…) and entry fields (`|n`).
// Port of Sources/VEKit/Assembler/WizardStepContent.swift (docs/re/03-assembler.md §12).
//
// Numbers shown with `f`/`n` and decimal fields follow `locale` (the Swift version uses the current locale).
import type { AssistantStepDefinition, StepField } from './types'
import { plainText, type Value } from './value'
import { WizardStepText, type WizardText } from './wizardText'

export interface WizardRun { text: string; bold: boolean; emphasis: boolean; link?: string }

/** One displayed line: a sequence of styled runs. An empty line is a blank spacer. */
export interface WizardLine { runs: WizardRun[] }
export const isBlankLine = (l: WizardLine) => l.runs.every((r) => r.text.replace(/^[\t  ]+|[\t  ]+$/g, '').length === 0)

export type WizardEntryPiece =
  | { k: 'text'; runs: WizardRun[] }
  /** Input field bound to the `index`-th label of the step. */
  | { k: 'field'; index: number; items: string[] | undefined }

/** Swift `split(separator:maxSplits:omittingEmptySubsequences:)` on a string (one character separator). */
export function swiftSplit(s: string, sep: string, maxSplits = Infinity, omitEmpty = true): string[] {
  const result: string[] = []
  let start = 0
  let i = 0
  while (i < s.length) {
    if (s[i] === sep) {
      let appended = false
      if (!(start === i && omitEmpty)) { result.push(s.slice(start, i)); appended = true }
      i++
      start = i
      if (appended && result.length === maxSplits) break
      continue
    }
    i++
  }
  if (start !== s.length || !omitEmpty) result.push(s.slice(start))
  return result
}

/** `Character.wholeNumberValue` for the Latin-1 range: ASCII digits and ¹²³. */
function wholeNumberValue(c: string | undefined): number | undefined {
  if (c === undefined) return undefined
  if (c >= '0' && c <= '9') return c.charCodeAt(0) - 0x30
  return c === '¹' ? 1 : c === '²' ? 2 : c === '³' ? 3 : undefined
}

const asciiDigit = (c: string | undefined) => (c !== undefined && c >= '0' && c <= '9' ? c.charCodeAt(0) - 0x30 : undefined)

const lines = (s: string) => s.split(/\r\n|[\n\r\u000b\u000c\u0085\u2028\u2029]/)

export class WizardStepContent {
  title: string
  description: WizardLine[]
  /** Radio / check button texts (one entry per button, each possibly multi-line). */
  options: WizardLine[][]
  /** Entry steps: the single option line with its input fields, split into lines. */
  entry: WizardEntryPiece[][]

  constructor(step: AssistantStepDefinition, text: WizardText | undefined, format: Value[], locale?: string) {
    let section: WizardStepText | undefined
    const last = format[format.length - 1]
    if (step.stepName.toLowerCase() === 'generic' && last) {
      // Generic steps carry their whole text as the last format argument, inserted as is (§12.3).
      section = new WizardStepText(lines(plainText(last)).filter((l) => l.length > 0))
    } else {
      section = text?.step(step.stepName)
    }
    const s = section ?? new WizardStepText([step.stepName])
    const fmt = (x: string) => WizardStepContent.format(x, format, locale)
    this.title = WizardStepContent.plain(fmt(s.title))
    this.description = s.description.map((l) => WizardStepContent.line(fmt(l)))
    if (step.kind === 'E') {
      this.options = []
      this.entry = (s.options[0] ?? []).map((l) => WizardStepContent.entryPieces(fmt(l), step.fields))
    } else {
      this.options = s.options.map((o) => o.map((l) => WizardStepContent.line(fmt(l))))
      this.entry = []
    }
  }

  // MARK: Delphi Format

  /**
   * Delphi `Format`: `%[index:][-][width][.prec]type` (index, width and prec may be `*`), for d u x s f n and the
   * sources' unknown `k` (shown like `s`). A bad specifier is copied as is, a missing argument is empty, and a
   * mismatched argument is shown as text.
   */
  static format(s: string, args: Value[], locale?: string): string {
    const c = Array.from(s)
    let out = ''
    let i = 0
    let next = 0 // sequential argument index
    let j = 0
    /** Digits or `*` at `j`: undefined = none, null = does not fit an Int32 or `*` has no int. */
    const number = (): number | null | undefined => {
      if (c[j] === '*') {
        j++
        const a = args[next]
        next++
        return a?.t === 'int' ? a.v : null
      }
      let v = 0, any = false
      for (let d = asciiDigit(c[j]); d !== undefined; d = asciiDigit(c[j])) {
        v = v * 10 + d
        any = true
        j++
        if (v > 2147483647) return null
      }
      return any ? v : undefined
    }
    while (i < c.length) {
      if (c[i] !== '%') { out += c[i]; i++; continue }
      if (c[i + 1] === '%') { out += '%'; i += 2; continue }
      j = i + 1
      let valid = true
      let index: number | undefined
      let width: number | undefined
      let precision: number | undefined
      let leftAlign = false
      let first = number()
      if (c[j] === ':') {
        j++
        if (first !== undefined) { if (first !== null) index = first; else valid = false } else index = 0
        first = undefined
      }
      if (first === undefined && c[j] === '-') { leftAlign = true; j++ }
      if (first !== undefined) {
        if (first !== null) width = first; else valid = false
      } else {
        const n = number()
        if (n !== undefined) { if (n !== null) width = n; else valid = false }
      }
      if (c[j] === '.') {
        j++
        const n = number()
        if (n !== undefined) { if (n !== null) precision = n; else valid = false } else precision = 0
      }
      const type = c[j]?.toLowerCase()[0]
      if (!valid || j >= c.length || !type || !'duxsfnk'.includes(type)) { out += '%'; i++; continue }
      if (index !== undefined) next = index
      const arg = args[next]
      next++
      let text = arg ? formatted(arg, type, precision, locale) : ''
      // Delphi pads to any width; a hostile text must not allocate gigabytes.
      const w = Math.min(width ?? 0, 4096)
      const len = Array.from(text).length
      if (len < w) {
        const pad = ' '.repeat(w - len)
        text = leftAlign ? text + pad : pad + text
      }
      out += text
      i = j + 1
    }
    return out
  }

  // MARK: Inline codes

  /** Splits `\CODE[,CODE…]\` sequences from text. */
  static line(s: string): WizardLine { return { runs: WizardStepContent.runs(s === '_' ? '' : s) } }

  static plain(s: string): string { return WizardStepContent.runs(s).map((r) => r.text).join('') }

  static runs(s: string): WizardRun[] {
    const out: WizardRun[] = []
    let bold = false, emphasis = false
    let linkStart: number | undefined
    let buffer = ''
    const flush = () => {
      if (buffer.length > 0) out.push({ text: windows1252(buffer), bold, emphasis })
      buffer = ''
    }
    let rest = s
    for (let open = rest.indexOf('\\'); open >= 0; open = rest.indexOf('\\')) {
      buffer += rest.slice(0, open)
      const after = rest.slice(open + 1)
      const close = after.indexOf('\\')
      if (close < 0) { buffer += rest.slice(open); rest = ''; break }
      const codes = swiftSplit(after.slice(0, close), ',')
      if (codes.length === 0 || !codes.every(isCode)) {
        buffer += '\\'
        rest = after
        continue
      }
      flush()
      for (const code of codes) {
        const parts = swiftSplit(code, ':', 1)
        switch (parts[0]) {
          case 'FS': {
            const n = swiftIntParse(parts.length > 1 ? parts[1]! : '0') ?? 0
            bold = (n & 1) !== 0
            emphasis = (n & 4) !== 0 || (n & 2) !== 0
            break
          }
          case 'IS': linkStart = out.length; break
          case 'IL': {
            const url = parts.length > 1 ? parts[1]! : ''
            for (let k = linkStart ?? out.length; k < out.length; k++) out[k]!.link = url
            linkStart = undefined
            break
          }
          case 'TI': buffer += '\t'; break
          default: break // DY, DX, DXI, SP, FC, X, Y, FN, FH, FI, ABT, DXFW: layout hints
        }
      }
      rest = after.slice(close + 1)
    }
    buffer += rest
    flush()
    return out
  }

  // MARK: Entry fields

  static entryPieces(s: string, fields: StepField[]): WizardEntryPiece[] {
    const pieces: WizardEntryPiece[] = []
    const c = Array.from(s)
    let text = ''
    let i = 0
    while (i < c.length) {
      const n = c[i] === '|' ? wholeNumberValue(c[i + 1]) : undefined
      if (n !== undefined && n <= 3) {
        if (text.length > 0) { pieces.push({ k: 'text', runs: WizardStepContent.runs(text) }); text = '' }
        let j = i + 2
        const end = c.indexOf('|', j)
        if (n < fields.length && fields[n]!.precision.k === 'list' && end >= 0) {
          const items = swiftSplit(c.slice(j, end).join(''), '@', Infinity, false).map(WizardStepContent.plain)
          pieces.push({ k: 'field', index: n, items })
          j = end + 1
        } else {
          pieces.push({ k: 'field', index: n, items: undefined })
        }
        i = j
        continue
      }
      text += c[i]
      i++
    }
    if (text.length > 0) pieces.push({ k: 'text', runs: WizardStepContent.runs(text) })
    return pieces
  }
}

function isCode(c: string): boolean {
  const name = swiftSplit(c, ':', 1)[0] ?? c
  const chars = Array.from(name)
  return chars.length > 0 && chars.length <= 4 && chars.every((x) => x.toUpperCase() === x && x.toLowerCase() !== x)
}

/** Swift `Int(String)`: optional sign then decimal digits. */
function swiftIntParse(s: string): number | undefined {
  return /^[+-]?[0-9]+$/.test(s) ? Number(s) : undefined
}

function numberFormat(value: number, fraction: number, grouping: boolean, locale?: string): string {
  return new Intl.NumberFormat(locale, {
    minimumFractionDigits: fraction, maximumFractionDigits: fraction, useGrouping: grouping, roundingMode: 'halfEven',
  } as Intl.NumberFormatOptions).format(value)
}

function formatted(v: Value, type: string, precision: number | undefined, locale?: string): string {
  const p = precision === undefined ? undefined : Math.min(precision, 64)
  const zeros = (digits: string) => '0'.repeat(Math.max(0, (p ?? 0) - digits.length)) + digits
  if (v.t === 'int') {
    const n = v.v
    switch (type) {
      case 'd': return (n < 0 ? '-' : '') + zeros(String(Math.abs(n)))
      case 'u': return zeros(String(n >>> 0))
      case 'x': return zeros((n >>> 0).toString(16).toUpperCase())
      case 'f': return numberFormat(n, Math.min(p ?? 2, 100), false, locale)
      case 'n': return numberFormat(n, Math.min(p ?? 2, 100), true, locale)
    }
  }
  if (type === 's' || type === 'k') {
    const t = plainText(v)
    return p === undefined ? t : Array.from(t).slice(0, p).join('')
  }
  return plainText(v)
}

/** Display text of a raw answer for this field (decimals scaled by 10^P, times as [-]hh:mm), without grouping. */
export function fieldDisplay(f: StepField, raw: number, locale?: string): string {
  switch (f.precision.k) {
    case 'decimals': {
      const d = f.precision.d
      if (!(d > 0)) return String(raw)
      return numberFormat(raw / Math.pow(10, d), d, false, locale)
    }
    case 'time': {
      const r = Math.abs(raw)
      const two = (x: number) => String(x).padStart(2, '0')
      return (raw < 0 ? '-' : '') + `${two(Math.floor(r / 60))}:${two(r % 60)}`
    }
    case 'list': return String(raw)
  }
}

const roundAway = (x: number) => (x < 0 ? -Math.round(-x) : Math.round(x))

/**
 * Parses user input back to a raw value, clamped to the field range; undefined when not a plain number (or time).
 * Accepts `,` or `.` as the decimal mark and ignores grouping (spaces, no-break spaces, `'`, or the other mark).
 */
export function fieldParse(f: StepField, text: string): number | undefined {
  let raw: number
  switch (f.precision.k) {
    case 'time': {
      const t = text.replace(/^[\t   -   　 ]+|[\t   -   　 ]+$/g, '')
      const parts = swiftSplit(t, ':', Infinity, false)
      if (parts.length !== 2) return undefined
      const h = plainNumber(parts[0]!, true), m = plainNumber(parts[1]!, false)
      if (h === undefined || m === undefined) return undefined
      // The sign applies to the whole time: -1:30 is -90 minutes.
      const negative = parts[0]!.startsWith('-')
      raw = (Math.abs(h) * 60 + m) * (negative ? -1 : 1)
      break
    }
    case 'decimals': {
      const v = parseNumber(text)
      if (v === undefined) return undefined
      raw = roundAway(v * Math.pow(10, f.precision.d))
      break
    }
    case 'list': {
      const v = parseNumber(text)
      if (v === undefined) return undefined
      raw = roundAway(v)
      break
    }
  }
  if (!Number.isFinite(raw)) return undefined
  return Math.trunc(Math.min(Math.max(raw, f.min), f.max))
}

export const fieldStep = (f: StepField) => (f.precision.k === 'decimals' ? Math.pow(10, -f.precision.d) : 1)

/** A decimal number with an optional sign, tolerant of grouping; undefined for anything else. */
export function parseNumber(text: string): number | undefined {
  let t = text.replace(/[\t    -   　'’]/g, '')
  const comma = t.lastIndexOf(','), dot = t.lastIndexOf('.')
  const count = (ch: string) => t.split(ch).length - 1
  if (comma >= 0 && dot >= 0) {
    const [group, mark] = comma > dot ? ['.', ','] : [',', '.']
    if (count(mark) > 1) return undefined
    t = t.split(group).join('').split(mark).join('.')
  } else if (comma >= 0) {
    t = count(',') > 1 ? t.split(',').join('') : t.split(',').join('.')
  } else if (dot >= 0) {
    if (count('.') > 1) t = t.split('.').join('')
  }
  return plainNumber(t, true, true)
}

/** `[sign]digits[.digits]` only; undefined otherwise or when not finite. */
export function plainNumber(t: string, signed: boolean, fraction = false): number | undefined {
  let body = t
  if (signed && (body[0] === '-' || body[0] === '+')) body = body.slice(1)
  const parts = body.split('.')
  if (body.length === 0 || parts.length > (fraction ? 2 : 1)) return undefined
  if (!parts.every((p) => /^[0-9]*$/.test(p)) || !parts.some((p) => p.length > 0)) return undefined
  const v = Number(t)
  return Number.isFinite(v) ? v : undefined
}

const cp1252: Record<number, number> = {
  0x80: 0x20ac, 0x82: 0x201a, 0x83: 0x0192, 0x84: 0x201e, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
  0x88: 0x02c6, 0x89: 0x2030, 0x8a: 0x0160, 0x8b: 0x2039, 0x8c: 0x0152, 0x8e: 0x017d, 0x91: 0x2018,
  0x92: 0x2019, 0x93: 0x201c, 0x94: 0x201d, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02dc,
  0x99: 0x2122, 0x9a: 0x0161, 0x9b: 0x203a, 0x9c: 0x0153, 0x9e: 0x017e, 0x9f: 0x0178,
}

/** Assistant texts are Windows-1252, decoded byte for byte; for display map the C1 range to its characters. */
export function windows1252(s: string): string {
  if (!/[\u0080-\u009f]/.test(s)) return s
  return s.replace(/[\u0080-\u009f]/g, (ch) => String.fromCharCode(cp1252[ch.charCodeAt(0)] ?? ch.charCodeAt(0)))
}
