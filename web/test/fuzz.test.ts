// Fuzz tests (fast-check): everything Shunt reads from outside — .rvsc files, the Assistant library, assembler
// sources, calculator expressions, serial frames, the grid password field — must refuse bad input cleanly:
// a FormatError (or a reported assembler error), never a crash, a hang or an out-of-bounds read.
// FUZZ_RUNS raises the number of cases (default keeps `vitest run` fast).
import fc from 'fast-check'
import { describe, expect, it } from 'vitest'
import { ByteWriter, FormatError, inflate, latin1Encode } from '../src/lib/engine/binary'
import { DeviceConfiguration, RLE } from '../src/lib/engine/deviceConfiguration'
import { AssistantLibrary, AssistantPackage } from '../src/lib/engine/assistantPackage'
import { SettingFile } from '../src/lib/engine/settingFile'
import { GridPassword } from '../src/lib/engine/gridPassword'
import { Assembler, Calculator, LineList, SourceLine, type CalculatorHost, type Label } from '../src/lib/engine/assembler'
import { FrameReader, checksum } from '../src/lib/device/frame'
import { bytes, samplePath } from './fixtures'
import { existsSync } from 'node:fs'

const runs = Number(process.env.FUZZ_RUNS ?? 300)
const fcOpts = { numRuns: runs }

/** A small but complete .rvsc (Mk2vscInfo, BareSettingInfo v2, BareSettingData v2), built without private files. */
function syntheticFile(): Uint8Array {
  const n = 96
  const mk = new ByteWriter()
  mk.u32(1); mk.shortString('3')
  const info = new ByteWriter()
  info.u32(2); info.u32(2623556); info.u8(0x31)
  info.u16(n * 10)
  for (let i = 0; i < n; i++) { info.u16(i % 7 === 0 ? 0 : 1); info.u16(0); info.u16(10); info.u16(0); info.u16(1000) }
  info.u16(n); info.bytes(new Uint8Array(n).fill(0))
  info.u16(n); info.bytes(new Uint8Array(n).fill(0))
  const data = new ByteWriter()
  data.u32(2); data.u32(1); data.u32(2623556); data.u8(0); data.u32(2623556)
  data.u16(0); data.u8(0x31); data.bytes(new Uint8Array(9))
  data.shortString('HQ0000FUZZ0'); data.u16(0)
  data.u32(0); data.u32(0); data.u32(1_790_000_000); data.u32(0)
  data.u16(n * 2)
  for (let i = 0; i < n; i++) data.u16(i * 3)
  const mem = new Uint8Array(4096).fill(0xff)
  mem.set([1, 2, 3, 4, 5, 6, 7, 8], 0)
  data.bytes(RLE.encode(mem, undefined))
  return new SettingFile([
    { name: 'Mk2vscInfo', body: mk.data },
    { name: 'BareSettingInfo', body: info.data },
    { name: 'BareSettingData', body: data.data },
  ]).encoded()
}

const bases = [syntheticFile(), ...(existsSync(samplePath('s5')) ? [bytes(samplePath('s5'))] : [])]

/** Parses like the editor does; anything but a FormatError is a bug. */
function parseOrFormatError(b: Uint8Array): DeviceConfiguration | undefined {
  try {
    return DeviceConfiguration.parse(b)
  } catch (e) {
    if (!(e instanceof FormatError)) throw e
    return undefined
  }
}

/** Byte-level mutations of a valid file: flips, overwrites, truncation, insertion. */
const mutated = (base: Uint8Array) =>
  fc.array(
    fc.oneof(
      fc.record({ k: fc.constant('flip' as const), at: fc.nat(base.length - 1), bit: fc.integer({ min: 0, max: 7 }) }),
      fc.record({ k: fc.constant('set' as const), at: fc.nat(base.length - 1), v: fc.integer({ min: 0, max: 255 }) }),
      fc.record({ k: fc.constant('cut' as const), at: fc.nat(base.length) }),
      fc.record({ k: fc.constant('insert' as const), at: fc.nat(base.length), b: fc.uint8Array({ maxLength: 64 }) }),
    ),
    { minLength: 1, maxLength: 6 },
  ).map((ops) => {
    let b = Array.from(base)
    for (const op of ops) {
      if (op.k === 'flip' && op.at < b.length) b[op.at]! ^= 1 << op.bit
      else if (op.k === 'set' && op.at < b.length) b[op.at] = op.v
      else if (op.k === 'cut') b = b.slice(0, op.at)
      else if (op.k === 'insert') b.splice(op.at, 0, ...op.b)
    }
    return Uint8Array.from(b)
  })

describe('fuzz: configuration files', () => {
  it('the synthetic base file is valid and round-trips', () => {
    const c = DeviceConfiguration.parse(bases[0]!)
    expect(c.encoded()).toEqual(bases[0])
  })

  it('random bytes: parsed or refused with a FormatError', () => {
    fc.assert(fc.property(fc.uint8Array({ maxLength: 8192 }), (b) => { parseOrFormatError(b) }), fcOpts)
  })

  for (const [i, base] of bases.entries()) {
    it(`mutations of base ${i}: parsed or refused, and what parses re-encodes stably`, () => {
      fc.assert(fc.property(mutated(base), (b) => {
        const c = parseOrFormatError(b)
        if (!c) return
        const once = c.encoded()
        const again = DeviceConfiguration.parse(once)
        expect(again.encoded()).toEqual(once)
        expect(c.data.assistantMemory.length).toBe(4096)
      }), fcOpts)
    })

    it(`mutations of base ${i} with fixed checksums reach the section parsers`, () => {
      // Re-encode each section's checksum so the mutation is judged by the section parsers, not the checksum.
      fc.assert(fc.property(fc.integer({ min: 0, max: 2 }), fc.uint8Array({ minLength: 1, maxLength: 32 }), fc.nat(), (s, junk, at) => {
        const file = SettingFile.parse(base)
        const sec = file.sections[s]!
        const body = Array.from(sec.body)
        body.splice(at % (body.length + 1), Math.min(junk.length, 8), ...junk)
        file.sections[s] = { name: sec.name, body: Uint8Array.from(body) }
        parseOrFormatError(file.encoded())
      }), fcOpts)
    })
  }

  it('RLE: never more than 4096 bytes, refused cleanly', () => {
    fc.assert(fc.property(fc.uint8Array({ maxLength: 2048 }), (b) => {
      try { expect(RLE.decode(b).memory.length).toBeLessThanOrEqual(4096) } catch (e) { expect(e).toBeInstanceOf(FormatError) }
    }), fcOpts)
  })

  it('RLE: any memory image encodes and decodes back', () => {
    fc.assert(fc.property(fc.uint8Array({ minLength: 4096, maxLength: 4096 }), (m) => {
      expect(RLE.decode(RLE.encode(m, undefined)).memory).toEqual(m)
    }), { numRuns: Math.min(runs, 100) })
  })
})

describe('fuzz: assistant library', () => {
  it('zlib: random streams are refused with a FormatError', () => {
    fc.assert(fc.property(fc.uint8Array({ maxLength: 4096 }), (b) => {
      try { inflate(b, 'fuzz') } catch (e) { expect(e).toBeInstanceOf(FormatError) }
    }), fcOpts)
  })

  it('packages and libraries: random bytes are parsed or refused with a FormatError', () => {
    fc.assert(fc.property(fc.uint8Array({ maxLength: 4096 }), (b) => {
      for (const parse of [() => AssistantPackage.parse(b, 'x_0001.vap'), () => AssistantLibrary.parse(b)]) {
        try { parse() } catch (e) { expect(e).toBeInstanceOf(FormatError) }
      }
    }), fcOpts)
  })
})

describe('fuzz: assembler and calculator', () => {
  class Env implements CalculatorHost {
    lookup(_: string): Label | undefined { return undefined }
    readBack() { return { ok: true as const, value: -1 } }
    assistantText() { return undefined }
    assistantLabelValue() { return undefined }
    noteReadBackUsed() {}
  }
  const exprChars = fc.constantFrom(...'0123456789+-*/%()[]{},.<>=!&|^~ "\'$#@abcxyzSTRLEN'.split(''))

  it('calculator: any expression evaluates or reports an error, without throwing', () => {
    fc.assert(fc.property(fc.array(exprChars, { maxLength: 80 }).map((a) => a.join('')), (s) => {
      new Calculator(new Env()).evaluate(s)
    }), { numRuns: runs * 3 })
  })

  const tokens = fc.constantFrom(
    ' .SET', ' .EQU', ' .IF', ' .ELSE', ' .ENDIF', ' .MACRO', ' .ENDM', ' .REPEAT', ' .ENDR', ' .SOURCE', ' .INSERT',
    ' .DB', ' .DW', ' .STRING', ' .ERROR', ' .MESSAGE', ' .AID', ' .AUE', ' .ALS', ' .RESTART', 'L1', 'L2:', ' 1', ' 2',
    ',', ' "x"', " 'main'", ' L1+1', ' (', ')', '\n', '\n', '\n',
  )

  it('assembler: random sources assemble or report errors, and always stop', () => {
    fc.assert(fc.property(fc.array(tokens, { maxLength: 120 }).map((a) => a.join('')), (source) => {
      const a = new Assembler()
      a.lineBudget = 20_000
      a.sourceProvider = (name) => (name === 'main' ? latin1Encode(source) : undefined)
      a.assemble(LineList.fromLines('root', [SourceLine.parse(latin1Encode(" .SOURCE 'main'"))]))
    }), fcOpts)
  })
})

describe('fuzz: serial frames and password field', () => {
  it('frame reader: random byte streams only ever yield checksummed frames', () => {
    fc.assert(fc.property(fc.array(fc.uint8Array({ maxLength: 64 }), { maxLength: 20 }), (chunks) => {
      const r = new FrameReader()
      for (const c of chunks) {
        for (const f of r.push(c)) expect(f.data).toBeInstanceOf(Uint8Array)
        expect(r.pending).toBeLessThan(200)
      }
    }), fcOpts)
    expect(checksum([1, 2, 3])).toBe((256 - 6) & 0xff)
  })

  it('grid password: random entries are refused without throwing', () => {
    fc.assert(fc.property(fc.string({ maxLength: 40 }), (s) => {
      // 12-character entries in the alphabet pay the key derivation; keep them rare so the test stays quick.
      expect(GridPassword.verify(s)).toBeUndefined()
    }), fcOpts)
  })
})
