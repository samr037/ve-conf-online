// Wizard text files inside a .vap (`<name>.en/.fr/.de/.es`), port of Sources/VEKit/Assembler/WizardText.swift.
import { latin1Decode, latin1Encode, type Bytes } from '../binary'
import { splitTextLines } from './sourceLine'
import type { Value } from './value'

/** Swift `trimmingCharacters(in: .whitespaces)`: tab and the Unicode space separators (Latin-1: space, NBSP). */
export const trimWhitespace = (s: string) => s.replace(/^[\t    -   　]+|[\t    -   　]+$/g, '')

/** One language's wizard texts: sections `#Name` → raw lines. */
export class WizardText {
  /** Section name (lowercased) → raw lines, in order. Comments (`;` at column 1) and empty lines removed. */
  readonly sections = new Map<string, string[]>()
  /** Original-case section names in file order. */
  readonly order: string[] = []

  constructor(bytes: Bytes) {
    let current: string | undefined
    for (const lineBytes of splitTextLines(bytes)) {
      const line = latin1Decode(lineBytes)
      if (line.length === 0 || line.startsWith(';')) continue
      if (line.startsWith('#')) {
        const name = trimWhitespace(line.slice(1))
        current = name.toLowerCase()
        if (!this.sections.has(current)) { this.sections.set(current, []); this.order.push(name) }
        continue
      }
      if (current !== undefined) this.sections.get(current)!.push(line)
    }
  }

  lines(section: string): string[] | undefined { return this.sections.get(section.toLowerCase()) }

  /** A normal section normalised into title, description and option entries. */
  step(name: string): WizardStepText | undefined {
    const l = this.lines(name)
    return l && l.length > 0 ? new WizardStepText(l) : undefined
  }

  /** `AssistantText(k)` lookup in one language, before unescaping. */
  assistantText(key: Value): string | undefined {
    if (key.t === 'string') {
      const k = latin1Decode(key.v)
      if (k.startsWith('#')) return this.lines(k.slice(1))?.join('\n')
      const array = this.lines('StringArray')
      if (!array) return undefined
      for (const line of array) {
        const eq = line.indexOf('=')
        if (eq < 0) continue
        const name = trimWhitespace(line.slice(0, eq))
        if (name.toLowerCase() === k.toLowerCase()) return trimWhitespace(line.slice(eq + 1))
      }
      return undefined
    }
    if (key.t === 'int') {
      const array = this.lines('StringArray')
      if (!array || key.v < 0 || key.v >= array.length) return undefined
      return array[key.v]
    }
    return undefined
  }

  /** `|n` line break, `|t` tab, `|xHH` char, `||` pipe; any other `|c` is dropped. */
  static unescape(s: string): Bytes {
    const b = latin1Encode(s)
    const out: number[] = []
    let i = 0
    while (i < b.length) {
      if (b[i] === 0x7c && i + 1 < b.length) {
        const c = b[i + 1]!
        if (c === 0x6e) { out.push(13, 10); i += 2 }
        else if (c === 0x74) { out.push(9); i += 2 }
        else if (c === 0x7c) { out.push(0x7c); i += 2 }
        else if (c === 0x78 && i + 3 < b.length) {
          const h = String.fromCharCode(b[i + 2]!, b[i + 3]!)
          out.push(/^\+?[0-9a-fA-F]{1,2}$/.test(h) ? parseInt(h, 16) : h === '-0' ? 0 : 0x3f) // Swift UInt8(_:radix:) accepts a sign
          i += 4
        } else i += 2
      } else {
        out.push(b[i]!); i++
      }
    }
    return Uint8Array.from(out)
  }
}

export class WizardStepText {
  title: string
  description: string[]
  /** Option entries (radio/check button texts, or the single input line of an entry step). */
  options: string[][]

  constructor(lines: string[]) {
    this.title = lines[0] ?? ''
    const desc: string[] = []
    const opts: string[][] = []
    for (const line of lines.slice(1)) {
      if (line.startsWith('.')) opts.push([line.slice(1)])
      else if (opts.length === 0) desc.push(line)
      else opts[opts.length - 1]!.push(line)
    }
    this.description = desc
    this.options = opts
  }

  /** Lines joined with the internal break char, after `_` placeholders become empty lines. */
  static join(lines: string[]): string { return lines.map((l) => (l === '_' ? '' : l)).join('\n') }
}
