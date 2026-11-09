// Ported from Tests/VEKitTests/AssemblerTests.swift (AssemblerCoreTests) and AssemblerHardeningTests.swift.
import { describe, expect, it } from 'vitest'
import { latin1Decode, latin1Encode } from '../src/lib/engine/binary'
import { Assembler, LineList, SourceLine, WizardText, splitTextLines } from '../src/lib/engine/assembler'

/** Assembles `source` as file `main` (and `files` for .SOURCE/.INSERT) through a root ` .SOURCE 'main'`. */
function asm(source: string, files: Record<string, string> = {}, lineBudget = Assembler.maxLines) {
  const a = new Assembler()
  a.lineBudget = lineBudget
  a.sourceProvider = (name) => (name === 'main' ? latin1Encode(source) : files[name] !== undefined ? latin1Encode(files[name]!) : undefined)
  const root = LineList.fromLines('root', [SourceLine.parse(latin1Encode(" .SOURCE 'main'"))])
  const ok = a.assemble(root)
  return Object.assign(a, { ok })
}
const errors = (a: Assembler) => a.messages.filter((m) => m.kind === 'error' || m.kind === 'fatal').map((m) => m.text)
const fatal = (a: Assembler) => a.messages.find((m) => m.kind === 'fatal')
const code = (a: Assembler) => Array.from(a.code)

describe('AssemblerCoreTests', () => {
  it('data, labels and forward references', () => {
    const a = asm(` DATA 1
Start:
 DATA Target
 DATA Start
Target:
 DATA 0xFF`)
    expect(a.ok, JSON.stringify(a.messages)).toBe(true)
    expect(code(a)).toEqual([1, 3, 1, 0xff])
  })

  it('macros, conditionals and while', () => {
    const a = asm(`EMIT .MACRO 1,v,s:name
 .IF Params=2
 DATA len(name)
 .ELSE
 DATA v
 .ENDIF
 .ENDM
Count .SET 0
 .WHILE Count<3
 EMIT Count
Count .SET Count+1
 .ENDW
 EMIT 9,abcd
 .ASSEMBLE ' DATA '+str(40+2)`)
    expect(a.ok, JSON.stringify(a.messages)).toBe(true)
    expect(code(a)).toEqual([0, 1, 2, 4, 42])
  })

  it('macro local labels', () => {
    const a = asm(`LOOP .MACRO
 .LOCAL Here
Here:
 DATA Here
 .ENDM
 LOOP
 LOOP`)
    expect(a.ok, JSON.stringify(a.messages)).toBe(true)
    expect(code(a)).toEqual([0, 1])
  })

  it('fixed label redefinition is an error', () => {
    const a = asm('X .EQU 1\nX .EQU 2')
    expect(a.ok).toBe(false)
    expect(a.messages.some((m) => m.text.startsWith('label value different'))).toBe(true)
  })
})

describe('AssemblerLimitTests', () => {
  it('source including itself is fatal', () => {
    const a = asm(" .SOURCE 'main'")
    expect(fatal(a)?.text.startsWith('nesting too deep')).toBe(true)
    expect(a.messages.length).toBe(1)
  })

  it('insert including itself is fatal', () => {
    expect(fatal(asm(" .INSERT 'main'"))?.text.startsWith('nesting too deep')).toBe(true)
  })

  it('assemble of itself is fatal', () => {
    expect(fatal(asm("S .SET ' .ASSEMBLE S'\n .ASSEMBLE S"))?.text.startsWith('nesting too deep')).toBe(true)
  })

  it('legitimate nesting still works', () => {
    const a = asm(" .SOURCE 'a'\n .ASSEMBLE ' .ASSEMBLE '' DATA 3'''", { a: " .INSERT 'b'", b: ' DATA 1\n DATA 2' })
    expect(errors(a)).toEqual([])
    expect(code(a)).toEqual([1, 2, 3])
  })

  it('recursive macro hits the macro limit', () => {
    expect(errors(asm('M .MACRO\n M\n .ENDM\n M'))).toContain('Macro nesting not allowed deeper than 255')
  })

  it('location counter is capped', () => {
    const a = asm('$ .SET 0x10000000\n DATA 1')
    expect(fatal(a)?.text.startsWith('location counter')).toBe(true)
    expect(code(a)).toEqual([])
    const b = asm('$ .SET 4095\n DATA 1')
    expect(errors(b)).toEqual([])
    expect(b.code.length).toBe(4096)
    expect(b.code[4095]).toBe(1)
  })

  it('nested while loops hit the global budget', () => {
    const a = asm(`I .SET 0
 .WHILE TRUE
J .SET 0
 .WHILE TRUE
K .SET 0
 .WHILE K<1000
K .SET K+1
 .ENDW
 .ENDW
 .ENDW`, {}, 200_000)
    expect(fatal(a)?.text.startsWith('Assembly stopped')).toBe(true)
  })

  it('single while loop keeps the 1024 cap', () => {
    const a = asm(`I .SET 0
 .WHILE TRUE
I .SET I+1
 .ENDW
 DATA I AND 0xFF
 DATA I>>8`)
    expect(errors(a)).toEqual(['while loop must stop within 1024 iterations'])
    expect(code(a)).toEqual([0x01, 0x04]) // the body runs 1025 times
  })
})

describe('AssemblerDirectiveTests', () => {
  it('unset removes a variable', () => {
    const a = asm("X .SET 1\nX .UNSET\n DATA int(Known('X'))\nX .SET 2\n DATA X")
    expect(errors(a)).toEqual([])
    expect(code(a)).toEqual([0, 2])
  })

  it('unset of a fixed label is an error', () => {
    const a = asm('F .EQU 3\nF .UNSET\n DATA F')
    expect(errors(a)).toEqual(['Labeltype (fixed/variable) different from previous pass'])
    expect(code(a)).toEqual([3])
  })

  it('unset of a macro parameter is an error', () => {
    const a = asm('M .MACRO G\nG .UNSET\n DATA G\n .ENDM\n M 7')
    expect(errors(a)).toEqual(['Cannot redefine a macro parameter'])
    expect(code(a)).toEqual([7])
  })

  it('unset follows the set target order', () => {
    const a = asm(` .GLOBAL TRUE
G .SET 6
 .GLOBAL FALSE
M .MACRO G
G .UNSET
 .ENDM
 M 1
 .IFDEF G
 DATA G
 .ELSE
 DATA 0xEE
 .ENDIF`)
    expect(errors(a)).toEqual([])
    expect(code(a)).toEqual([0xee])
  })

  it('unset of a system label and bad arity', () => {
    expect(errors(asm('$ .UNSET'))).toEqual(['Cannot remove a system label'])
    expect(errors(asm('X .SET 1\nX .UNSET 1'))).toEqual(['too many parameters'])
    expect(errors(asm(' .UNSET'))).toEqual(['label expected'])
  })

  it('insert shares the conditional stack', () => {
    const a = asm(" .IF TRUE\n .INSERT 'inc'\n DATA 2", { inc: ' DATA 1\n .ENDIF' })
    expect(errors(a)).toEqual([])
    expect(code(a)).toEqual([1, 2])
    const b = asm(" .INSERT 'inc'\n DATA 2\n .ELSE\n DATA 3\n .ENDIF", { inc: ' .IF TRUE\n DATA 1' })
    expect(errors(b)).toEqual([])
    expect(code(b)).toEqual([1, 2])
    const c = asm(" .INSERT 'inc'\n DATA 2", { inc: ' .IF TRUE\n DATA 1' })
    expect(errors(c)).toEqual(['expected .ENDIF'])
    const d = asm(" .INSERT 'inc'\n DATA 2", { inc: ' .IF FALSE\n DATA 1' })
    expect(errors(d)).toContain('expected .ENDIF')
  })

  it("endw of another list's while is an error", () => {
    const a = asm("I .SET 0\n .WHILE I<2\nI .SET I+1\n .INSERT 'inc'\n DATA I", { inc: ' .ENDW' })
    expect(errors(a)).toContain('internal error with while construction')
  })
})

describe('LineBreakTests', () => {
  const lines = (s: string) => splitTextLines(latin1Encode(s)).map(latin1Decode)

  it('every Delphi line break splits', () => {
    expect(lines('a\rb\r\nc\nd')).toEqual(['a', 'b', 'c', 'd'])
    expect(lines('a\n\rb')).toEqual(['a', '', 'b'])
    expect(lines('a\r\n')).toEqual(['a'])
    expect(lines('a\n\n')).toEqual(['a', ''])
    expect(lines('')).toEqual([])
    expect(lines('a\nb\u0000\nc')).toEqual(['a', 'b'])
  })

  it('lone CR separates source lines', () => {
    const a = asm('X .SET 1\rY .SET 2\r DATA 7\r\n DATA 8\n DATA X+Y+6')
    expect(errors(a)).toEqual([])
    expect(code(a)).toEqual([7, 8, 9])
    expect(LineList.fromText('h', latin1Encode('A .SET 1\r B .SET 2\r\nC .SET 3')).count).toBe(4)
  })

  it('NUL ends a source', () => {
    expect(code(asm(' DATA 1\n\u0000 DATA 2\n DATA 3'))).toEqual([1])
  })

  it('lone CR separates wizard text lines', () => {
    const t = new WizardText(latin1Encode('#StringArray\rk = v\r#X\nTitle\r\n.Option\r'))
    expect(t.lines('StringArray')).toEqual(['k = v'])
    expect(t.lines('X')).toEqual(['Title', '.Option'])
  })
})
