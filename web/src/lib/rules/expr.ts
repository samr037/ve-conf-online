// The catalog's `enabledWhen` / `visibleWhen` / rule expression language.
// Identifiers `EPROM_*`, `EBIT_*`, `ctl.X`, `device.x`, `app.x`, `original.X`; operators
// `! && || == != < <= > >= + - * / &`, `x in [a, b]`, parentheses; numbers, strings, true/false.

export type Expr =
  | { t: 'number'; v: number }
  | { t: 'string'; v: string }
  | { t: 'ident'; name: string }
  | { t: 'call'; name: string; args: Expr[] }
  | { t: 'list'; items: Expr[] }
  | { t: 'not'; x: Expr }
  | { t: 'negate'; x: Expr }
  | { t: 'binary'; op: string; a: Expr; b: Expr }

export type EValue = { t: 'number'; v: number } | { t: 'string'; v: string } | { t: 'list'; v: EValue[] }

export const num = (v: number): EValue => ({ t: 'number', v })
export const boolValue = (b: boolean): EValue => num(b ? 1 : 0)
export const numberOf = (e: EValue | undefined): number | undefined => (e?.t === 'number' ? e.v : undefined)
export function truthy(e: EValue): boolean {
  return e.t === 'number' ? e.v !== 0 : e.t === 'string' ? e.v !== '' : e.v.length > 0
}

export function valueEquals(a: EValue, b: EValue): boolean {
  if (a.t !== b.t) return false
  if (a.t === 'list') {
    const l = b.v as EValue[]
    return a.v.length === l.length && a.v.every((x, i) => valueEquals(x, l[i]!))
  }
  return a.v === b.v
}

type Token = { t: 'num'; v: number } | { t: 'str'; v: string } | { t: 'ident'; v: string } | { t: 'op'; v: string }

const isNumberChar = (c: string | undefined) => c !== undefined && /^\p{N}$/u.test(c)
const isLetter = (c: string | undefined) => c !== undefined && /^\p{L}$/u.test(c)
const isHexDigit = (c: string | undefined) => c !== undefined && /^[0-9a-fA-F]$/.test(c)
const isSpace = (c: string) => /^\s$/u.test(c)

/** Swift `Double(String)`: nil (here NaN) unless the whole text is a decimal number. */
function parseDouble(s: string): number {
  return /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s) ? Number(s) : NaN
}

export function tokenize(s: string): Token[] {
  const out: Token[] = []
  const chars = [...s]
  let i = 0
  const peek = (o = 0) => chars[i + o]
  while (i < chars.length) {
    const c = chars[i]!
    if (isSpace(c)) { i++; continue }
    if (isNumberChar(c) || (c === '.' && isNumberChar(peek(1)))) {
      let j = i
      if (c === '0' && (peek(1) === 'x' || peek(1) === 'X')) {
        j = i + 2
        while (j < chars.length && isHexDigit(chars[j])) j++
        const h = chars.slice(i + 2, j).join('')
        out.push({ t: 'num', v: h === '' ? 0 : parseInt(h, 16) })
      } else {
        while (j < chars.length && (isNumberChar(chars[j]) || chars[j] === '.' || chars[j] === 'e')) j++
        out.push({ t: 'num', v: parseDouble(chars.slice(i, j).join('')) })
      }
      i = j
      continue
    }
    if (isLetter(c) || c === '_') {
      let j = i
      while (j < chars.length && (isLetter(chars[j]) || isNumberChar(chars[j]) || chars[j] === '_' || chars[j] === '.')) j++
      out.push({ t: 'ident', v: chars.slice(i, j).join('') })
      i = j
      continue
    }
    if (c === '"') {
      let j = i + 1
      while (j < chars.length && chars[j] !== '"') j++
      out.push({ t: 'str', v: chars.slice(i + 1, Math.min(j, chars.length)).join('') })
      i = j + 1
      continue
    }
    const n = peek(1)
    const two = n !== undefined ? c + n : ''
    if (['&&', '||', '==', '!=', '<=', '>=', '->'].includes(two)) { out.push({ t: 'op', v: two }); i += 2; continue }
    out.push({ t: 'op', v: c })
    i++
  }
  return out
}

class Parser {
  pos = 0
  constructor(readonly tokens: Token[]) {}
  get atEnd() { return this.pos === this.tokens.length }
  peek(): Token | undefined { return this.tokens[this.pos] }
  isOp(op: string) { const t = this.peek(); return t?.t === 'op' && t.v === op }
  eat(op: string): boolean { if (this.isOp(op)) { this.pos++; return true } return false }

  expression(): Expr | undefined { return this.or() }

  or(): Expr | undefined {
    let l = this.and()
    if (!l) return undefined
    while (this.eat('||')) { const r = this.and(); if (!r) return undefined; l = { t: 'binary', op: '||', a: l, b: r } }
    return l
  }
  and(): Expr | undefined {
    let l = this.equality()
    if (!l) return undefined
    while (this.eat('&&')) { const r = this.equality(); if (!r) return undefined; l = { t: 'binary', op: '&&', a: l, b: r } }
    return l
  }
  equality(): Expr | undefined {
    let l = this.relational()
    if (!l) return undefined
    for (;;) {
      const op = this.eat('==') ? '==' : this.eat('!=') ? '!=' : undefined
      if (!op) return l
      const r = this.relational()
      if (!r) return undefined
      l = { t: 'binary', op, a: l, b: r }
    }
  }
  relational(): Expr | undefined {
    let l = this.bitAnd()
    if (!l) return undefined
    for (;;) {
      let matched = false
      for (const op of ['<=', '>=', '<', '>']) {
        if (!this.eat(op)) continue
        const r = this.bitAnd()
        if (!r) return undefined
        l = { t: 'binary', op, a: l, b: r }
        matched = true
        break
      }
      const t = this.peek()
      if (!matched && t?.t === 'ident' && t.v === 'in') {
        this.pos++
        const r = this.bitAnd()
        if (!r) return undefined
        l = { t: 'binary', op: 'in', a: l, b: r }
        matched = true
      }
      if (!matched) return l
    }
  }
  bitAnd(): Expr | undefined {
    let l = this.additive()
    if (!l) return undefined
    while (this.isOp('&')) { this.pos++; const r = this.additive(); if (!r) return undefined; l = { t: 'binary', op: '&', a: l, b: r } }
    return l
  }
  additive(): Expr | undefined {
    let l = this.multiplicative()
    if (!l) return undefined
    for (;;) {
      const op = this.eat('+') ? '+' : this.eat('-') ? '-' : undefined
      if (!op) return l
      const r = this.multiplicative()
      if (!r) return undefined
      l = { t: 'binary', op, a: l, b: r }
    }
  }
  multiplicative(): Expr | undefined {
    let l = this.unary()
    if (!l) return undefined
    for (;;) {
      const op = this.eat('*') ? '*' : this.eat('/') ? '/' : undefined
      if (!op) return l
      const r = this.unary()
      if (!r) return undefined
      l = { t: 'binary', op, a: l, b: r }
    }
  }
  unary(): Expr | undefined {
    if (this.eat('!')) { const x = this.unary(); return x && { t: 'not', x } }
    if (this.eat('-')) { const x = this.unary(); return x && { t: 'negate', x } }
    return this.primary()
  }
  primary(): Expr | undefined {
    const t = this.peek()
    if (!t) return undefined
    this.pos++
    switch (t.t) {
      case 'num': return { t: 'number', v: t.v }
      case 'str': return { t: 'string', v: t.v }
      case 'ident': {
        if (t.v === 'true') return { t: 'number', v: 1 }
        if (t.v === 'false') return { t: 'number', v: 0 }
        if (this.eat('(')) {
          const args: Expr[] = []
          if (!this.eat(')')) {
            do { const a = this.expression(); if (!a) return undefined; args.push(a) } while (this.eat(','))
            if (!this.eat(')')) return undefined
          }
          return { t: 'call', name: t.v, args }
        }
        return { t: 'ident', name: t.v }
      }
      case 'op':
        if (t.v === '(') {
          const e = this.expression()
          if (!e || !this.eat(')')) return undefined
          return e
        }
        if (t.v === '[') {
          const items: Expr[] = []
          if (!this.eat(']')) {
            do { const a = this.expression(); if (!a) return undefined; items.push(a) } while (this.eat(','))
            if (!this.eat(']')) return undefined
          }
          return { t: 'list', items }
        }
        return undefined
    }
  }
}

const cache = new Map<string, Expr | null>()

/** Parses a whole expression; `undefined` if it is malformed (cached). */
export function parseExpr(source: string): Expr | undefined {
  const hit = cache.get(source)
  if (hit !== undefined) return hit ?? undefined
  const p = new Parser(tokenize(source))
  const e = p.expression()
  const result = e && p.atEnd ? e : undefined
  cache.set(source, result ?? null)
  return result
}

export const parses = (s: string) => parseExpr(s) !== undefined
