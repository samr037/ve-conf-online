// The VLL calculator: tokenizer, syntax check and evaluator
// (port of Sources/VEKit/Assembler/Calculator.swift, docs/re/03-assembler.md §3–§4).
import { latin1Decode, latin1Encode, type Bytes } from '../binary'
import { asText, asTextLimited, isString, sameClass, valueEquals, vBool, vInt, vList, vStr, vString, type Value } from './value'

/** A named value in one of the assembler's label lists. */
export class Label {
  protected stored: Value | undefined

  constructor(
    value: Value | undefined,
    /** bit0 = fixed (.EQU, code labels, .ALD); bit1 = system (assignable); other bits: opaque type tag. */
    public flags: number,
    /** Parameter names when this label is a user function (`Name(` key). */
    public params?: string[],
  ) {
    this.stored = value
  }

  get value(): Value | undefined { return this.stored }
  set value(v: Value | undefined) { this.stored = v }

  get isFixed(): boolean { return (this.flags & 1) !== 0 }
  get isSystem(): boolean { return (this.flags & 2) !== 0 }
}

export type ReadBackResult = { ok: true; value: number } | { ok: false; error: string }

/** What the calculator needs from its environment. */
export interface CalculatorHost {
  /** Label (or user function, key `Name(`) visible from the current scope. */
  lookup(name: string): Label | undefined
  /** `RBn(a)`: n-byte little-endian value at offset a of the reference binary; −1 without one. */
  readBack(bytes: number, address: number): ReadBackResult
  assistantText(key: Value): Bytes | undefined
  assistantLabelValue(name: string): number | undefined
  noteReadBackUsed(): void
}

export const CalcError = {
  dyadic: 'Dyadic operator not suitable for these operands',
  monadic: 'Monadic operator not suitable for this operand',
  paramType: 'The type of one (or more) of the function parameters is not correct',
  paramCount: 'Wrong number of parameters',
  bounds: 'Index out of bounds',
  divZero: 'Division by ZERO',
  /** Not in VE Configure: guards against runaway recursion. */
  tooDeep: 'Expression nesting too deep',
  /** Not in VE Configure: an expression doing more nested evaluations than any real source needs. */
  tooComplex: 'Expression too complex',
  /** Not in VE Configure: caps the memory one value may take. */
  tooLong: 'Result too long',
  /** Decimal literal above 2^31-1. */
  range: 'Range check error',
} as const

export interface Evaluation {
  value: Value | undefined
  error: string | undefined
  warnings: string[]
}

export const evaluationOk = (e: Evaluation) => e.value !== undefined && e.error === undefined

export class Calculator {
  /** User-function parameter frames, innermost last; searched before every other list. */
  private frames: Map<string, Label>[] = []

  static readonly maxDepth = 256
  static readonly maxNestedEvaluations = 10_000
  /** Longest string or list a calculation may produce. */
  static readonly maxLength = 16 << 20

  depth = 0
  nestedEvaluations = 0
  /** Set once a limit is hit; sticky until the outermost evaluation returns so `known()` cannot swallow it. */
  exhausted: string | undefined

  constructor(readonly host: CalculatorHost) {}

  /** Evaluates an expression. Errors make the result undefined; warnings (Div result is zero!) do not. */
  evaluate(text: Bytes | string): Evaluation {
    const bytes = typeof text === 'string' ? latin1Encode(text) : text
    const outermost = this.depth === 0
    if (outermost) { this.nestedEvaluations = 0; this.exhausted = undefined }
    try {
      const run = new Run(this)
      const v = run.evaluate(bytes)
      if (run.error !== undefined) return { value: undefined, error: run.error, warnings: run.warnings }
      return { value: v, error: v === undefined ? 'Error interpreting expression' : undefined, warnings: run.warnings }
    } finally {
      if (outermost) this.exhausted = undefined
    }
  }

  lookup(name: string): Label | undefined {
    for (let i = this.frames.length - 1; i >= 0; i--) {
      const l = this.frames[i]!.get(name)
      if (l) return l
    }
    return this.host.lookup(name)
  }

  push(frame: Map<string, Label>): void { this.frames.push(frame) }
  pop(): void { this.frames.pop() }
}

// MARK: - Tokens

type Callable =
  | { k: 'paren' }
  | { k: 'builtin'; name: string }
  | { k: 'user'; label: Label }
  | { k: 'readBack'; n: number }
  | { k: 'assistantText' }
  | { k: 'assistantLabelValue' }

type OpID = 'pow' | 'mul' | 'div' | 'mod' | 'shl' | 'shr' | 'add' | 'sub' | 'eq' | 'ne' | 'lt' | 'gt' | 'le' | 'ge' | 'and' | 'or' | 'xor' | 'not' | 'at'

interface Operator { id: OpID; priority: number; monadicAllowed: boolean }

const op = (id: OpID, priority: number, monadicAllowed = false): Operator => ({ id, priority, monadicAllowed })

const operatorTable: [string, Operator, boolean][] = [
  ['^', op('pow', 10), false],
  ['*', op('mul', 9), false],
  ['/', op('div', 9), false],
  ['MOD', op('mod', 9), true],
  ['<<', op('shl', 9), false],
  ['>>', op('shr', 9), false],
  ['+', op('add', 8, true), false],
  ['-', op('sub', 8, true), false],
  ['=', op('eq', 6), false],
  ['!=', op('ne', 6), false],
  ['<', op('lt', 6), false],
  ['>', op('gt', 6), false],
  ['<=', op('le', 6), false],
  ['>=', op('ge', 6), false],
  ['AND', op('and', 5), true],
  ['OR', op('or', 4), true],
  ['XOR', op('xor', 3), true],
  ['!', op('not', 9, true), false],
  ['@', op('at', 255), false],
]

type Token =
  | { k: 'open'; c: Callable }
  | { k: 'comma' }
  | { k: 'close' }
  | { k: 'operand'; v: Value }
  | { k: 'op'; op: Operator }
  /** A token that matched but cannot be used (out-of-range literal). */
  | { k: 'invalid'; e: string }

const builtinsInt = ['int(', 'abs(', 'sign(']
const builtinsString = ['copy(', 'err(', 'del(', 'len(', 'pos(', 'ins(', 'val(', 'known(', 'ord(', 'str(', 'hex(']

const isLabelFirst = (c: number) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c === 0x5f || c === 0x24
const isLabelNext = (c: number) =>
  (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c === 0x5f || (c >= 0x30 && c <= 0x39) || c === 0x23
const isDigit = (c: number | undefined) => c !== undefined && c >= 0x30 && c <= 0x39
function hexValue(c: number | undefined): number | undefined {
  if (c === undefined) return undefined
  if (c >= 0x30 && c <= 0x39) return c - 0x30
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10
  return undefined
}

function matchesCI(s: Bytes, i: number, word: string): boolean {
  if (i + word.length > s.length) return false
  for (let k = 0; k < word.length; k++) {
    let a = s[i + k]!, b = word.charCodeAt(k)
    if (a >= 0x61 && a <= 0x7a) a -= 32
    if (b >= 0x61 && b <= 0x7a) b -= 32
    if (a !== b) return false
  }
  return true
}

function matchesExact(s: Bytes, i: number, word: string): boolean {
  if (i + word.length > s.length) return false
  for (let k = 0; k < word.length; k++) if (s[i + k] !== word.charCodeAt(k)) return false
  return true
}

function lexLess(x: Bytes, y: Bytes): boolean {
  const n = Math.min(x.length, y.length)
  for (let i = 0; i < n; i++) if (x[i] !== y[i]) return x[i]! < y[i]!
  return x.length < y.length
}

const bytesEqual = (x: Bytes, y: Bytes) => {
  if (x.length !== y.length) return false
  for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return false
  return true
}

const concatBytes = (x: Bytes, y: Bytes) => {
  const out = new Uint8Array(x.length + y.length)
  out.set(x); out.set(y, x.length)
  return out
}

/** Swift `.rounded(.toNearestOrAwayFromZero)`. */
const roundAway = (x: number) => (x < 0 ? -Math.round(-x) : Math.round(x))

const enum Kind { open, close, comma, operand, monadic, dyadic }

interface OpenFrame { callable: Callable; args: Value[]; operandBase: number; opBase: number }

// MARK: - One evaluation

class Run {
  error: string | undefined
  warnings: string[] = []

  constructor(readonly calc: Calculator) {}

  fail(m: string): void { if (this.error === undefined) this.error = m }

  // MARK: Tokenizer (longest match; ties go to the class registered first)

  tokenize(s: Bytes): Token[] | undefined {
    const tokens: Token[] = []
    let i = 0
    while (i < s.length) {
      if (s[i] === 0x20) { i++; continue }
      let bestLen = 0
      let best: (() => Token | undefined) | undefined
      const offer = (len: number, make: () => Token | undefined) => {
        if (len > 0 && len > bestLen) { bestLen = len; best = make }
      }
      const c = s[i]!
      // 1. ( , )
      if (c === 0x28) offer(1, () => ({ k: 'open', c: { k: 'paren' } }))
      if (c === 0x2c) offer(1, () => ({ k: 'comma' }))
      if (c === 0x29) offer(1, () => ({ k: 'close' }))
      // 2. operators, integer literal, boolean literal, int( abs( sign(
      for (const [text, o, isWord] of operatorTable) {
        if (isWord ? matchesCI(s, i, text) : matchesExact(s, i, text)) offer(text.length, () => ({ k: 'op', op: o }))
      }
      const lit = this.intLiteral(s, i)
      if (lit) offer(lit[0], () => (lit[1] !== undefined ? { k: 'operand', v: vInt(lit[1]) } : { k: 'invalid', e: CalcError.range }))
      if (matchesCI(s, i, 'true')) offer(4, () => ({ k: 'operand', v: vBool(true) }))
      if (matchesCI(s, i, 'false')) offer(5, () => ({ k: 'operand', v: vBool(false) }))
      for (const b of builtinsInt) if (matchesCI(s, i, b)) offer(b.length, () => ({ k: 'open', c: { k: 'builtin', name: b } }))
      // 3. string literal, [], string/list builtins
      const str = this.stringLiteral(s, i)
      if (str) offer(str[0], () => ({ k: 'operand', v: vString(str[1]) }))
      if (matchesExact(s, i, '[]')) offer(2, () => ({ k: 'operand', v: vList([]) }))
      for (const b of builtinsString) if (matchesCI(s, i, b)) offer(b.length, () => ({ k: 'open', c: { k: 'builtin', name: b } }))
      // 4. label reference or user-function call (resolved now: unknown names do not match)
      if (isLabelFirst(c)) {
        let j = i + 1
        while (j < s.length && isLabelNext(s[j]!)) j++
        const name = latin1Decode(s.subarray(i, j))
        const f = j < s.length && s[j] === 0x28 ? this.calc.lookup(name + '(') : undefined
        if (f && f.params !== undefined) {
          offer(j + 1 - i, () => ({ k: 'open', c: { k: 'user', label: f } }))
        } else {
          const l = this.calc.lookup(name)
          if (l) offer(j - i, () => (l.value !== undefined ? { k: 'operand', v: l.value } : undefined))
        }
      }
      // 5. assistant functions
      for (let n = 1; n <= 4; n++) if (matchesExact(s, i, `RB${n}(`)) offer(4, () => ({ k: 'open', c: { k: 'readBack', n } }))
      if (matchesCI(s, i, 'AssistantText(')) offer(14, () => ({ k: 'open', c: { k: 'assistantText' } }))
      if (matchesCI(s, i, 'AssistantLabelValue(')) offer(20, () => ({ k: 'open', c: { k: 'assistantLabelValue' } }))

      if (!best) {
        const rest = latin1Decode(s.subarray(i, Math.min(s.length, i + 50)))
        this.fail(`cannot interpret "${rest}..."`)
        return undefined
      }
      const t = (best as () => Token | undefined)()
      if (!t) { this.fail('label has no value'); return undefined }
      if (t.k === 'invalid') { this.fail(t.e); return undefined }
      tokens.push(t)
      i += bestLen
    }
    return tokens
  }

  /** Length and value of an integer literal; the value is undefined for a decimal literal above 2^31-1. */
  intLiteral(s: Bytes, i: number): [number, number | undefined] | undefined {
    if (i >= s.length || !isDigit(s[i])) return undefined
    if (s[i] === 0x30 && i + 1 < s.length && s[i + 1] === 0x78) { // 0x (case-sensitive)
      let j = i + 2, v = 0
      for (let h = hexValue(s[j]); j < s.length && h !== undefined; h = hexValue(s[++j])) v = ((v << 4) | h) >>> 0
      if (j > i + 2) return [j - i, v | 0]
    }
    if (s[i] === 0x30 && i + 1 < s.length && s[i + 1] === 0x62) { // 0b
      let j = i + 2, v = 0
      while (j < s.length && (s[j] === 0x30 || s[j] === 0x31)) { v = ((v << 1) | (s[j]! - 0x30)) >>> 0; j++ }
      if (j > i + 2) return [j - i, v | 0]
    }
    // Delphi Val reports an overflow that VE Configure ignores: treat it as a range error rather than wrapping.
    let j = i, v = 0
    while (j < s.length && isDigit(s[j])) {
      if (v <= 0x7fffffff) v = v * 10 + (s[j]! - 0x30)
      j++
    }
    return [j - i, v <= 0x7fffffff ? v : undefined]
  }

  stringLiteral(s: Bytes, start: number): [number, Bytes] | undefined {
    let i = start
    const out: number[] = []
    let pieces = 0
    while (i < s.length) {
      if (s[i] === 0x27) {
        let j = i + 1
        let closed = false
        while (j < s.length) {
          if (s[j] === 0x27) {
            if (j + 1 < s.length && s[j + 1] === 0x27) { out.push(0x27); j += 2; continue }
            closed = true; j++; break
          }
          out.push(s[j]!); j++
        }
        if (!closed) break
        i = j; pieces++
      } else if (s[i] === 0x23) {
        // #n (≤3 digits, <256), #0xH[H], #$hex…
        if (i + 2 < s.length && s[i + 1] === 0x30 && s[i + 2] === 0x78) {
          let j = i + 3, v = 0, n = 0
          for (let h = hexValue(s[j]); j < s.length && n < 2 && h !== undefined; h = hexValue(s[j])) { v = v * 16 + h; j++; n++ }
          if (n === 0) break
          out.push(v); i = j; pieces++
        } else if (i + 1 < s.length && s[i + 1] === 0x24) {
          let j = i + 2
          const digits: number[] = []
          for (let h = hexValue(s[j]); j < s.length && h !== undefined; h = hexValue(s[++j])) digits.push(h)
          if (digits.length === 0) break
          if (digits.length % 2 === 1) digits.unshift(0)
          for (let k = 0; k < digits.length; k += 2) out.push(digits[k]! * 16 + digits[k + 1]!)
          i = j; pieces++
        } else if (i + 1 < s.length && isDigit(s[i + 1])) {
          let j = i + 1, v = 0, n = 0
          while (j < s.length && n < 3 && isDigit(s[j])) {
            const nv = v * 10 + (s[j]! - 0x30)
            if (nv >= 256) break
            v = nv; j++; n++
          }
          out.push(v); i = j; pieces++
        } else break
      } else break
    }
    return pieces > 0 ? [i - start, Uint8Array.from(out)] : undefined
  }

  // MARK: Syntax check + evaluation (operator precedence)

  evaluate(text: Bytes): Value | undefined {
    const tokens = this.tokenize(text)
    if (!tokens || this.error !== undefined) return undefined
    // Wrap in an implicit ( … ).
    const all: Token[] = [{ k: 'open', c: { k: 'paren' } }, ...tokens, { k: 'close' }]
    const operands: Value[] = []
    const ops: { op: Operator; monadic: boolean }[] = []
    const opens: OpenFrame[] = []
    let prev: Kind = Kind.comma

    const reduceOne = (): boolean => {
      const { op: o, monadic } = ops.pop()!
      if (monadic) {
        const a = operands.pop()
        if (!a) { this.fail('Internal error: operand/operator stack underflow'); return false }
        const r = this.applyMonadic(o, a)
        if (!r) return false
        operands.push(r)
      } else {
        if (operands.length < 2) { this.fail('Internal error: operand/operator stack underflow'); return false }
        const b = operands.pop()!, a = operands.pop()!
        const r = this.applyDyadic(o, a, b)
        if (!r) return false
        operands.push(r)
      }
      return true
    }

    for (const t of all) {
      switch (t.k) {
        case 'open':
          if (!(prev === Kind.open || prev === Kind.comma || prev === Kind.monadic || prev === Kind.dyadic)) {
            this.fail('"(" is not allowed on that place'); return undefined
          }
          opens.push({ callable: t.c, args: [], operandBase: operands.length, opBase: ops.length })
          prev = Kind.open
          break
        case 'comma':
        case 'close': {
          if (!(prev === Kind.operand || prev === Kind.close)) { this.fail('expression not comlete'); return undefined }
          const frame = opens.pop()
          if (!frame) { this.fail('bracket open/close mismatch'); return undefined }
          while (ops.length > frame.opBase) if (!reduceOne()) return undefined
          if (operands.length !== frame.operandBase + 1) { this.fail('Nr of parameters on stack not OK'); return undefined }
          frame.args.push(operands.pop()!)
          if (t.k === 'comma') {
            opens.push(frame)
            prev = Kind.comma
          } else {
            const r = this.call(frame.callable, frame.args)
            if (!r) return undefined
            operands.push(r)
            prev = Kind.close
          }
          break
        }
        case 'operand':
          if (!(prev === Kind.open || prev === Kind.comma || prev === Kind.monadic || prev === Kind.dyadic)) {
            this.fail(`"${latin1Decode(asText(t.v).subarray(0, 10))}..." is not allowed on that place`); return undefined
          }
          operands.push(t.v)
          prev = Kind.operand
          break
        case 'op':
          if (prev === Kind.operand || prev === Kind.close) {
            for (;;) {
              const top = ops[ops.length - 1]
              if (!top || !(ops.length > (opens[opens.length - 1]?.opBase ?? 0)) || !(top.op.priority >= t.op.priority)) break
              if (!reduceOne()) return undefined
            }
            ops.push({ op: t.op, monadic: false })
            prev = Kind.dyadic
          } else {
            if (!t.op.monadicAllowed) { this.fail('operator is not allowed on that place'); return undefined }
            ops.push({ op: t.op, monadic: true })
            prev = Kind.monadic
          }
          break
        case 'invalid':
          this.fail(t.e); return undefined
      }
    }
    if (opens.length !== 0 || operands.length !== 1) { this.fail('bracket open/close mismatch'); return undefined }
    return operands[0]
  }

  // MARK: Operators

  applyMonadic(o: Operator, a: Value): Value | undefined {
    if (a.t === 'int') {
      if (o.id === 'sub') return vInt(-a.v)
      if (o.id === 'add') return a
      if (o.id === 'not') return vInt(~a.v)
    }
    if (a.t === 'bool' && o.id === 'not') return vBool(!a.v)
    this.fail(CalcError.monadic)
    return undefined
  }

  applyDyadic(o: Operator, a: Value, b: Value): Value | undefined {
    if (o.id === 'at') {
      if (b.t !== 'int') { this.fail(CalcError.dyadic); return undefined }
      const i = b.v
      if (a.t === 'string') {
        if (!(i >= 1 && i <= a.v.length)) { this.fail(CalcError.bounds); return undefined }
        return vString([a.v[i - 1]!])
      }
      if (a.t === 'list') {
        if (!(i >= 0 && i < a.v.length)) { this.fail(CalcError.bounds); return undefined }
        return a.v[i]!
      }
      this.fail(CalcError.dyadic); return undefined
    }
    // Lazy logical operators on strings (§4.3).
    if ((o.id === 'and' || o.id === 'or' || o.id === 'xor') && (isString(a) || isString(b))) return this.lazyLogic(o.id, a, b)
    if (a.t === 'int' && b.t === 'int') return this.intOp(o.id, a.v, b.v)
    if (a.t === 'bool' && b.t === 'bool') {
      const x = a.v, y = b.v
      switch (o.id) {
        case 'and': return vBool(x && y)
        case 'or': return vBool(x || y)
        case 'xor': return vBool(x !== y)
        case 'eq': return vBool(x === y)
        case 'ne': return vBool(x !== y)
        default: this.fail(CalcError.dyadic); return undefined
      }
    }
    if (a.t === 'string' && b.t === 'string') {
      const x = a.v, y = b.v
      switch (o.id) {
        case 'add':
          if (x.length + y.length > Calculator.maxLength) { this.fail(CalcError.tooLong); return undefined }
          return vString(concatBytes(x, y))
        case 'eq': return vBool(bytesEqual(x, y))
        case 'ne': return vBool(!bytesEqual(x, y))
        case 'lt': return vBool(lexLess(x, y))
        case 'gt': return vBool(lexLess(y, x))
        case 'le': return vBool(!lexLess(y, x))
        case 'ge': return vBool(!lexLess(x, y))
        default: this.fail(CalcError.dyadic); return undefined
      }
    }
    if (a.t === 'list' && o.id === 'add') {
      if (a.v.length >= Calculator.maxLength) { this.fail(CalcError.tooLong); return undefined }
      return vList([...a.v, b])
    }
    if (a.t === 'list' && b.t === 'list') {
      switch (o.id) {
        case 'and':
          if (a.v.length + b.v.length > Calculator.maxLength) { this.fail(CalcError.tooLong); return undefined }
          return vList([...a.v, ...b.v])
        case 'eq': return vBool(valueEquals(a, b))
        case 'ne': return vBool(!valueEquals(a, b))
        default: this.fail(CalcError.dyadic); return undefined
      }
    }
    this.fail(CalcError.dyadic)
    return undefined
  }

  intOp(id: OpID, x: number, y: number): Value | undefined {
    switch (id) {
      case 'pow': {
        const r = roundAway(Math.pow(x, y))
        if (!(r >= -2147483648 && r <= 2147483647)) { this.fail('Range check error'); return undefined }
        return vInt(r)
      }
      case 'mul': return vInt(Math.imul(x, y))
      case 'div': {
        if (y === 0) { this.fail(CalcError.divZero); return undefined }
        if (x === -2147483648 && y === -1) return vInt(x)
        const r = Math.trunc(x / y) | 0
        if (r === 0 && x !== 0) this.warnings.push('Div result is zero!')
        return vInt(r)
      }
      case 'mod':
        if (y === 0) { this.fail(CalcError.divZero); return undefined }
        if (y === -1) return vInt(0)
        return vInt(x % y)
      case 'shl': return vInt(x << (y & 31))
      case 'shr': return vInt(x >>> (y & 31))
      case 'add': return vInt(x + y)
      case 'sub': return vInt(x - y)
      case 'eq': return vBool(x === y)
      case 'ne': return vBool(x !== y)
      case 'lt': return vBool(x < y)
      case 'gt': return vBool(x > y)
      case 'le': return vBool(x <= y)
      case 'ge': return vBool(x >= y)
      case 'and': return vInt(x & y)
      case 'or': return vInt(x | y)
      case 'xor': return vInt(x ^ y)
      case 'not':
      case 'at':
        this.fail(CalcError.dyadic); return undefined
    }
  }

  lazyLogic(id: OpID, a: Value, b: Value): Value | undefined {
    const text = (v: Value): Bytes | undefined => (v.t === 'string' ? v.v : v.t === 'bool' ? asText(v) : undefined)
    const lt = text(a), rt = text(b)
    if (!lt || !rt) { this.fail(CalcError.dyadic); return undefined }
    const l = this.sub(lt)
    if (l?.t !== 'bool') { this.fail(CalcError.dyadic); return undefined }
    if (id === 'and' && !l.v) return vBool(false)
    if (id === 'or' && l.v) return vBool(true)
    const r = this.sub(rt)
    if (r?.t !== 'bool') { this.fail(CalcError.dyadic); return undefined }
    return id === 'xor' ? vBool(r.v !== l.v) : vBool(r.v)
  }

  /** Evaluates a nested expression in the same scope; its errors propagate. */
  sub(text: Bytes): Value | undefined {
    const n = this.nested(text)
    if (!n) return undefined
    const [v, inner] = n
    this.warnings.push(...inner.warnings)
    if (inner.error !== undefined) { this.fail(inner.error); return undefined }
    return v
  }

  /** Runs a nested evaluation within the depth and count limits; undefined (with the limit error) when one is hit. */
  nested(text: Bytes): [Value | undefined, Run] | undefined {
    const calc = this.calc
    if (calc.exhausted !== undefined) { this.fail(calc.exhausted); return undefined }
    calc.nestedEvaluations++
    if (calc.depth >= Calculator.maxDepth) calc.exhausted = CalcError.tooDeep
    if (calc.nestedEvaluations > Calculator.maxNestedEvaluations) calc.exhausted = CalcError.tooComplex
    if (calc.exhausted !== undefined) { this.fail(calc.exhausted); return undefined }
    calc.depth++
    try {
      const inner = new Run(calc)
      const v = inner.evaluate(text)
      if (calc.exhausted !== undefined) { this.fail(calc.exhausted); return undefined }
      return [v, inner]
    } finally {
      calc.depth--
    }
  }

  // MARK: Functions

  call(c: Callable, args: Value[]): Value | undefined {
    switch (c.k) {
      case 'paren':
        if (args.length !== 1) { this.fail(CalcError.paramCount); return undefined }
        return args[0]
      case 'builtin': return this.builtin(c.name.toLowerCase(), args)
      case 'user': {
        const params = c.label.params, body = c.label.value
        if (!params || body?.t !== 'string') { this.fail(CalcError.paramType); return undefined }
        if (args.length !== params.length) { this.fail(CalcError.paramCount); return undefined }
        const frame = new Map<string, Label>()
        params.forEach((p, k) => frame.set(p, new Label(args[k], 0)))
        this.calc.push(frame)
        try { return this.sub(body.v) } finally { this.calc.pop() }
      }
      case 'readBack': {
        if (args.length !== 1) { this.fail(CalcError.paramCount); return undefined }
        const a = args[0]!
        if (a.t !== 'int') { this.fail(CalcError.paramType); return undefined }
        this.calc.host.noteReadBackUsed()
        const r = this.calc.host.readBack(c.n, a.v)
        if (r.ok) return vInt(r.value)
        this.fail(r.error); return undefined
      }
      case 'assistantText': {
        if (args.length !== 1) { this.fail(CalcError.paramCount); return undefined }
        const t = this.calc.host.assistantText(args[0]!)
        if (!t || t.length === 0) { this.fail('AssistantText function returned empty string'); return undefined }
        return vString(t)
      }
      case 'assistantLabelValue': {
        if (args.length !== 1) { this.fail(CalcError.paramCount); return undefined }
        const a = args[0]!
        if (a.t !== 'string') { this.fail(CalcError.paramType); return undefined }
        const v = this.calc.host.assistantLabelValue(latin1Decode(a.v))
        if (v === undefined) { this.fail('Unknown assistant label'); return undefined }
        return vInt(v)
      }
    }
  }

  builtin(name: string, a: Value[]): Value | undefined {
    const arity = (...n: number[]) => {
      if (n.includes(a.length)) return true
      this.fail(CalcError.paramCount)
      return false
    }
    const a0 = a[0]!, a1 = a[1]!, a2 = a[2]!
    switch (name) {
      case 'int(':
        if (!arity(1)) return undefined
        if (a0.t === 'int') return a0
        if (a0.t === 'bool') return vInt(a0.v ? 1 : 0)
        this.fail(CalcError.paramType); return undefined
      case 'abs(':
        if (!arity(1)) return undefined
        if (a0.t !== 'int') { this.fail(CalcError.paramType); return undefined }
        return vInt(a0.v < 0 ? -a0.v : a0.v)
      case 'sign(':
        if (!arity(1)) return undefined
        if (a0.t !== 'int') { this.fail(CalcError.paramType); return undefined }
        return vInt(a0.v < 0 ? -1 : 1)
      case 'len(':
        if (!arity(1)) return undefined
        if (a0.t === 'string' || a0.t === 'list') return vInt(a0.v.length)
        this.fail(CalcError.paramType); return undefined
      case 'copy(': {
        if (!arity(3)) return undefined
        if (a1.t !== 'int' || a2.t !== 'int') { this.fail(CalcError.paramType); return undefined }
        let i = a1.v, n = a2.v
        if (a0.t === 'string') {
          if (i < 1) { n -= 1 - i; i = 1 }
          const start = i - 1
          if (!(n > 0 && start < a0.v.length)) return vString([])
          return vString(a0.v.slice(start, Math.min(a0.v.length, start + n)))
        }
        if (a0.t === 'list') {
          const lo = Math.max(0, i), hi = Math.min(a0.v.length, i + n)
          return vList(lo < hi ? a0.v.slice(lo, hi) : [])
        }
        this.fail(CalcError.paramType); return undefined
      }
      case 'del(': {
        if (!arity(3)) return undefined
        if (a1.t !== 'int' || a2.t !== 'int') { this.fail(CalcError.paramType); return undefined }
        let i = a1.v, n = a2.v
        if (a0.t === 'string') {
          if (i < 1) { n -= 1 - i; i = 1 }
          const start = i - 1
          const s = a0.v
          if (n > 0 && start < s.length) return vString(concatBytes(s.subarray(0, start), s.subarray(Math.min(s.length, start + n))))
          return a0
        }
        if (a0.t === 'list') {
          const lo = Math.max(0, i), hi = Math.min(a0.v.length, i + n)
          if (lo < hi) return vList([...a0.v.slice(0, lo), ...a0.v.slice(hi)])
          return a0
        }
        this.fail(CalcError.paramType); return undefined
      }
      case 'ins(': {
        if (!arity(3)) return undefined
        if (a2.t !== 'int') { this.fail(CalcError.paramType); return undefined }
        const i = a2.v
        if (a0.t === 'string' && a1.t === 'string') {
          const s = a0.v, y = a1.v
          if (!(i >= 1 && i <= s.length + 1)) { this.fail(CalcError.bounds); return undefined }
          if (s.length + y.length > Calculator.maxLength) { this.fail(CalcError.tooLong); return undefined }
          return vString(concatBytes(concatBytes(s.subarray(0, i - 1), y), s.subarray(i - 1)))
        }
        if (a0.t === 'list') {
          const l = a0.v
          if (!(i >= 0 && i <= l.length)) { this.fail(CalcError.bounds); return undefined }
          if (l.length >= Calculator.maxLength) { this.fail(CalcError.tooLong); return undefined }
          return vList([...l.slice(0, i), a1, ...l.slice(i)])
        }
        this.fail(CalcError.paramType); return undefined
      }
      case 'pos(': {
        if (!arity(2)) return undefined
        if (a0.t === 'string' && a1.t === 'string') {
          const y = a0.v, x = a1.v
          if (y.length === 0 || y.length > x.length) return vInt(0)
          outer: for (let k = 0; k <= x.length - y.length; k++) {
            for (let m = 0; m < y.length; m++) if (x[k + m] !== y[m]) continue outer
            return vInt(k + 1)
          }
          return vInt(0)
        }
        if (a1.t === 'list') {
          for (let k = a1.v.length - 1; k >= 0; k--) {
            const e = a1.v[k]!
            if (sameClass(e, a0) && valueEquals(e, a0)) return vInt(k)
          }
          return vInt(-1)
        }
        this.fail(CalcError.paramType); return undefined
      }
      case 'ord(':
        if (!arity(1)) return undefined
        if (a0.t !== 'string' || a0.v.length !== 1) { this.fail(CalcError.paramType); return undefined }
        return vInt(a0.v[0]!)
      case 'str(': {
        if (!arity(1)) return undefined
        // Lists can share sub-lists, so their text can be exponentially longer than their memory.
        const t = asTextLimited(a0, Calculator.maxLength)
        if (!t) { this.fail(CalcError.tooLong); return undefined }
        return vString(t)
      }
      case 'val(': {
        if (!arity(1, 2)) return undefined
        if (a0.t !== 'string') { this.fail(CalcError.paramType); return undefined }
        if (a.length === 2) {
          if (a1.t !== 'bool') { this.fail(CalcError.paramType); return undefined }
          const bytes = a0.v.subarray(0, 4)
          let v = 0
          bytes.forEach((b, k) => { v = (v | (b << (8 * k))) >>> 0 })
          const last = bytes[bytes.length - 1]
          if (a1.v && bytes.length < 4 && last !== undefined && (last & 0x80) !== 0) v = (v | (0xffffffff << (8 * bytes.length))) >>> 0
          return vInt(v | 0)
        }
        return this.sub(a0.v)
      }
      case 'known(': {
        if (!arity(1)) return undefined
        if (a0.t !== 'string') { this.fail(CalcError.paramType); return undefined }
        const n = this.nested(a0.v)
        if (!n) return undefined
        return vBool(n[0] !== undefined && n[1].error === undefined)
      }
      case 'err(':
        if (!arity(2)) return undefined
        if (a0.t !== 'bool' || a1.t !== 'string') { this.fail(CalcError.paramType); return undefined }
        if (a0.v) { this.fail('User error: ' + latin1Decode(a1.v)); return undefined }
        return vInt(0)
      case 'hex(': {
        if (!arity(1, 2)) return undefined
        let digits = 1
        if (a.length === 2) {
          if (a1.t !== 'int') { this.fail(CalcError.paramType); return undefined }
          digits = a1.v
        }
        digits = Math.min(digits, 32)
        if (a0.t === 'int') {
          let h = (a0.v >>> 0).toString(16).toUpperCase()
          if (h.length < digits) h = '0'.repeat(digits - h.length) + h
          return vStr(h)
        }
        if (a0.t === 'string') return vStr(Array.from(a0.v, (b) => b.toString(16).toUpperCase().padStart(2, '0')).join(''))
        this.fail(CalcError.paramType); return undefined
      }
      default:
        this.fail('Cannot handle this element'); return undefined
    }
  }
}
