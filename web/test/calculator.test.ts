// Ported from Tests/VEKitTests/AssemblerTests.swift (CalculatorTests) and CalculatorHardeningTests.swift.
import { describe, expect, it } from 'vitest'
import { CalcError, Calculator, Label, vInt, vList, vStr, vString, valueEquals, type CalculatorHost, type Value } from '../src/lib/engine/assembler'

class Env implements CalculatorHost {
  labels = new Map<string, Label>()
  lookup(name: string) { return this.labels.get(name) }
  readBack() { return { ok: true as const, value: -1 } }
  assistantText() { return undefined }
  assistantLabelValue() { return undefined }
  noteReadBackUsed() {}
}

const ev = (s: string, env = new Env()) => new Calculator(env).evaluate(s)
const value = (s: string, env = new Env()) => ev(s, env).value

/** Value equality like Swift's `==` on `Value?`. */
function same(a: Value | undefined, b: Value | undefined) {
  expect(a === undefined || b === undefined ? a === b : valueEquals(a, b), `${JSON.stringify(a, rep)} vs ${JSON.stringify(b, rep)}`).toBe(true)
}
function rep(_k: string, v: unknown) { return v instanceof Uint8Array ? Array.from(v) : v }
const bool = (b: boolean): Value => ({ t: 'bool', v: b })

describe('CalculatorTests', () => {
  it('arithmetic and precedence', () => {
    same(value('1+2*3'), vInt(7))
    same(value('-2*3'), vInt(-6))
    same(value('0x10+0b11'), vInt(19))
    same(value('7/2'), vInt(3))
    same(value('-7/2'), vInt(-3))
    same(value('1<<4>>2'), vInt(4))
    same(value('(-1)>>28'), vInt(15))
    same(value('-1>>28'), vInt(0))
    same(value('1=1 AND 2=2'), bool(true))
    same(value('6 AND 3'), vInt(2))
    same(value('!0'), vInt(-1))
    same(value('!true'), bool(false))
  })

  it('strings', () => {
    same(value("'it''s'"), vStr("it's"))
    same(value("'a'#13'b'"), vString([0x61, 13, 0x62]))
    same(value("'ab'+'cd'"), vStr('abcd'))
    same(value('str(5)'), vStr('5'))
    same(value("str('a')"), vStr("'a'"))
    same(value("copy('hello',2,3)"), vStr('ell'))
    same(value("pos('l','hello')"), vInt(3))
    same(value("len('abc')"), vInt(3))
    same(value("'abc'@2"), vStr('b'))
    same(value("val('3*4')"), vInt(12))
  })

  it('lists', () => {
    same(value("[]+1+'x'"), vList([vInt(1), vStr('x')]))
    same(value('([]+1+2)@1'), vInt(2))
    same(value('len([]+1+2+3)'), vInt(3))
    same(value("str([]+1+'a')"), vStr("([]+1+'a')"))
  })

  it('known and lazy logic', () => {
    const env = new Env()
    same(value("Known('X')", env), bool(false))
    same(value("!Known('X') OR 'X>5'", env), bool(true))
    env.labels.set('X', new Label(vInt(9), 1))
    same(value("Known('X')", env), bool(true))
    same(value("!Known('X') OR 'X>5'", env), bool(true))
    same(value('X+1', env), vInt(10))
  })

  it('user functions', () => {
    const env = new Env()
    env.labels.set('ROUNDDIV(', new Label(vStr('((a+(b>>1))/b)'), 1, ['a', 'b']))
    same(value('ROUNDDIV(7,2)', env), vInt(4))
    same(value('ROUNDDIV(ROUNDDIV(9,2),2)', env), vInt(3))
  })

  it('errors', () => {
    same(value('1+'), undefined)
    same(value('1/0'), undefined)
    same(value("1+'a'"), undefined)
    same(value("err(true,'boom')"), undefined)
    same(value("err(false,'boom')"), vInt(0))
  })
})

describe('CalculatorHardeningTests', () => {
  it('copy and del clip without overflow', () => {
    same(value("copy('abc',0-2147483647-1,1)"), vStr(''))
    same(value("copy('abc',0,0-2147483647-1)"), vStr(''))
    same(value("copy('abc',2,2147483647)"), vStr('bc'))
    same(value("copy('abc',-5,8)"), vStr('ab'))
    same(value("del('abc',0-2147483647-1,1)"), vStr('abc'))
    same(value("del('abc',2,2147483647)"), vStr('a'))
    same(value('copy([]+1+2+3,1,2147483647)'), vList([vInt(2), vInt(3)]))
    same(value('del([]+1+2+3,2147483647,2147483647)'), vList([vInt(1), vInt(2), vInt(3)]))
  })

  it('user function recursion is an error', () => {
    const env = new Env()
    env.labels.set('F(', new Label(vStr('F(x)'), 1, ['x']))
    const r = ev('F(1)', env)
    expect(r.value).toBeUndefined()
    expect(r.error).toBe(CalcError.tooDeep)
    // Bounded recursion still works (each level is a function call plus a lazy OR operand).
    env.labels.set('G(', new Label(vStr("n<1 OR 'G(n-1)'"), 1, ['n']))
    same(ev('G(100)', env).value, bool(true))
    expect(ev('G(200)', env).error).toBe(CalcError.tooDeep)
  })

  it('val recursion is an error', () => {
    const env = new Env()
    env.labels.set('X', new Label(vStr('val(X)'), 0))
    expect(ev('val(X)', env).error).toBe(CalcError.tooDeep)
  })

  it('lazy logic recursion is an error', () => {
    const env = new Env()
    env.labels.set('X', new Label(vStr('X OR TRUE'), 0))
    expect(ev('X OR TRUE', env).error).toBe(CalcError.tooDeep)
  })

  it('known cannot swallow the limit', () => {
    const env = new Env()
    env.labels.set('K', new Label(vStr('known(K) OR known(K)'), 0))
    const r = ev('known(K)', env)
    expect(r.value).toBeUndefined()
    expect(r.error).toBe(CalcError.tooDeep)
    same(ev("known('1/0')", env).value, bool(false))
  })

  it('exponential fan-out is bounded', () => {
    const env = new Env()
    env.labels.set('F0(', new Label(vStr('x'), 1, ['x']))
    for (let k = 1; k <= 40; k++) env.labels.set(`F${k}(`, new Label(vStr(`F${k - 1}(x)+F${k - 1}(x)`), 1, ['x']))
    same(ev('F10(1)', env).value, vInt(1024))
    expect(ev('F40(1)', env).error).toBe(CalcError.tooComplex)
  })

  it('hex digits are capped', () => {
    same(value('hex(255,4)'), vStr('00FF'))
    same(value('hex(255,10)'), vStr('00000000FF'))
    const v = value('hex(1,2147483647)')
    expect(v?.t === 'string' && v.v.length).toBe(32)
  })

  it('strings and lists are capped', () => {
    const env = new Env()
    env.labels.set('S', new Label(vString(new Uint8Array(Calculator.maxLength).fill(0x41)), 0))
    expect(ev("S+'x'", env).error).toBe(CalcError.tooLong)
    expect(ev("ins(S,'x',1)", env).error).toBe(CalcError.tooLong)
    expect(ev('str(S)', env).error).toBe(CalcError.tooLong)
    // A list sharing itself 40 times would print 2^40 elements.
    let l: Value = vList([vInt(1)])
    for (let i = 0; i < 40; i++) l = vList([l, l])
    env.labels.set('L', new Label(l, 0))
    expect(ev('str(L)', env).error).toBe(CalcError.tooLong)
    same(ev('len(L)', env).value, vInt(2))
  })

  it('decimal literals above 32 bits are range errors', () => {
    same(value('2147483647'), vInt(2147483647))
    same(value('0-2147483647-1'), vInt(-2147483648))
    expect(ev('2147483648').error).toBe(CalcError.range)
    expect(ev('99999999999999999999999999').error).toBe(CalcError.range)
    same(value('0xFFFFFFFF'), vInt(-1))
    same(value("known('4294967295')"), bool(false))
  })

  it('probes from the audit still evaluate', () => {
    same(value("'b'>'B'"), bool(true))
    same(value('1=true'), undefined)
    same(value('[]=[]'), bool(true))
    same(value('sign(0)'), vInt(1))
    same(value('abs(0-2147483647-1)'), vInt(-2147483648))
    same(value('1<<32'), vInt(1))
    same(value('5 MOD 0'), undefined)
    same(value("known('1/0')"), bool(false))
  })
})
