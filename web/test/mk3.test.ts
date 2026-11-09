// MK3 draft: framing checked against the byte examples of Victron's "Interfacing with VE.Bus products – MK2
// Protocol" 3.14 (Appendix 1, page 29; Appendix 2, pages 30–32; §3.6, page 6), and a full read against a simulated
// device backed by a configuration file.
import { existsSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { DeviceConfiguration } from '../src/lib/engine/deviceConfiguration'
import { FrameReader, checksum, encodeFrame, ascii } from '../src/lib/device/frame'
import { Mk3Client, Mk3TimeoutError } from '../src/lib/device/mk3'
import { draftConfiguration, readConfiguration } from '../src/lib/device/readConfiguration'
import { MockTransport } from '../src/lib/device/transport'
import { bytes, samplePath } from './fixtures'

const h = (s: string) => Uint8Array.from(s.trim().split(/\s+/).map((t) => (t.length === 3 && t.startsWith("'") ? t.charCodeAt(1) : parseInt(t, 16))))
const withChecksum = (s: string) => { const b = Array.from(h(s)); return Uint8Array.from([...b, checksum(b)]) }

describe('MK2 framing (Appendix 1, page 29)', () => {
  const examples: [string, number, number[]][] = [
    ["04 FF 'A' 01 00 BB", ascii('A'), [0x01, 0x00]],           // address 0
    ["05 FF 'W' 05 00 00 A0", ascii('W'), [0x05, 0x00, 0x00]],  // software version part 0
    ["05 FF 'W' 06 00 00 9F", ascii('W'), [0x06, 0x00, 0x00]],  // software version part 1
    ["05 FF 'W' 36 04 00 6B", ascii('W'), [0x36, 0x04, 0x00]],  // RAM info of UBat
    ["05 FF 'W' 30 0D 00 68", ascii('W'), [0x30, 0x0d, 0x00]],  // state of charge
    ["03 FF 'F' 00 B8", ascii('F'), [0x00]],                    // DC info frame
    ["02 FF 'L' B3", ascii('L'), []],                           // LED status
    ["07 FF 'S' 03 C0 10 01 01 D2", ascii('S'), [0x03, 0xc0, 0x10, 0x01, 0x01]],
    ["07 FF 'S' 03 3B 01 01 80 E7", ascii('S'), [0x03, 0x3b, 0x01, 0x01, 0x80]],
    ["02 FF 'S' AC", ascii('S'), []],
  ]
  for (const [text, cmd, data] of examples) {
    it(text, () => {
      expect(Array.from(encodeFrame(cmd, data))).toEqual(Array.from(h(text)))
      const sum = Array.from(h(text)).reduce((a, b) => a + b, 0)
      expect(sum % 256).toBe(0)
    })
  }

  it('reset frame (§3.6, page 6)', () => {
    const f = encodeFrame(ascii('R'))
    expect(Array.from(f.slice(0, 3))).toEqual([0x02, 0xff, ascii('R')])
    expect(f.reduce((a, b) => a + b, 0) % 256).toBe(0)
  })
})

describe('FrameReader', () => {
  it('parses the Appendix 2 replies (checksums are not in the dump, page 30)', () => {
    const r = new FrameReader()
    const frames = r.push(concat(
      withChecksum("07 FF 'V' 93 3E 11 00 00"),   // MK2 version 1130131
      withChecksum("08 FF 'W' 8E 9C 7F 8F 00 00"), // RAM info: Sc 32668, offset 0
    ))
    expect(frames).toHaveLength(2)
    const [v, w] = frames
    expect(v).toMatchObject({ kind: 'mk2', command: ascii('V') })
    const d = v!.data
    expect((d[0]! | (d[1]! << 8) | (d[2]! << 16) | (d[3]! << 24)) >>> 0).toBe(1130131)
    expect(w).toMatchObject({ kind: 'mk2', command: ascii('W') })
    expect(Array.from(w!.data)).toEqual([0x8e, 0x9c, 0x7f, 0x8f, 0x00, 0x00])
  })

  it('parses VE.Bus frames without the 0xFF marker (DC info, page 31)', () => {
    const r = new FrameReader()
    const [f] = r.push(withChecksum('0F 20 7F 9A 81 79 0C 51 0A 00 00 00 00 00 00 88'))
    expect(f).toMatchObject({ kind: 'vebus', type: 0x20 })
    expect(f!.data[4]).toBe(0x0c) // <Phase info> 0x0C = DC info frame (§6.1)
  })

  it('handles split chunks, LED status and line noise', () => {
    const r = new FrameReader()
    const led = withChecksum("84 FF 'S' 09 02") // Appendix 1: LED status appended, length MSB set
    const noisy = concat(Uint8Array.of(0x13, 0x37), withChecksum("02 FF 'L'").slice(0, 2))
    expect(r.push(noisy)).toEqual([])
    expect(r.push(withChecksum("02 FF 'L'").slice(2))).toHaveLength(1)
    const [s] = r.push(led)
    expect(s).toMatchObject({ kind: 'mk2', command: ascii('S'), led: { on: 0x09, blink: 0x02 } })
    expect(s!.data).toHaveLength(0)
    expect(r.pending).toBe(0)
  })
})

function concat(...p: Uint8Array[]) {
  const out = new Uint8Array(p.reduce((a, b) => a + b.length, 0))
  let o = 0
  for (const b of p) { out.set(b, o); o += b.length }
  return out
}

/** A simulated MK3 + VE.Bus device answering from a configuration file, Winmon mode 1 (short frames). */
function simulatedDevice(c: DeviceConfiguration, addresses = [0]) {
  let address = 0xff
  const reply = (cmd: string, data: number[]) => encodeFrame(ascii(cmd), data)
  return (frame: Uint8Array) => {
    const cmd = String.fromCharCode(frame[2]!)
    const d = Array.from(frame.slice(3, -1))
    switch (cmd) {
      case 'V': return reply('V', [0x93, 0x3e, 0x11, 0x00, address === 0xff ? ascii('B') : address])
      case 'A': if (d[0]! & 1) address = d[1]! <= 0x1f ? d[1]! : 0xff; return reply('A', [d[0]!, address])
      case 'W': {
        if (!addresses.includes(address)) return undefined
        const id = d[1]! | (d[2]! << 8)
        const fw = c.info.firmware
        switch (d[0]) {
          case 0x05: return reply('W', [0x82, fw & 0xff, (fw >> 8) & 0xff])
          case 0x06: return reply('W', [0x83, (fw >> 16) & 0xff, (fw >>> 24) & 0xff])
          case 0x35: {
            const s = c.info.info(id)
            if (!s || !s.isSupported) return reply('W', [0x89, 0, 0])
            const w = (code: number, v: number) => [code, v & 0xff, (v >> 8) & 0xff]
            // Five replies, at most three per MK2 frame (§7.3 'W' command).
            return [
              reply('W', [...w(0x89, s.scaleRaw), ...w(0x8a, s.offset), ...w(0x8b, s.defaultRaw)]),
              reply('W', [...w(0x8c, s.minRaw), ...w(0x8d, s.maxRaw)]),
            ]
          }
          case 0x31: {
            const s = c.info.info(id)
            return s?.isSupported ? reply('W', [0x86, c.raw(id) & 0xff, c.raw(id) >> 8]) : reply('W', [0x91, 0, 0])
          }
          default: return reply('W', [0x80, 0, 0])
        }
      }
    }
    return undefined
  }
}

const sample = ['s5', 's1', 's2'].find((n) => existsSync(samplePath(n)))

describe.runIf(sample)('read a full configuration from a simulated device', () => {
  it('rebuilds every setting record and value of the sample', async () => {
    const c = DeviceConfiguration.parse(bytes(samplePath(sample!)))
    const unsolicited = [encodeFrame(ascii('V'), [0x93, 0x3e, 0x11, 0x00, ascii('B')])]
    const t = new MockTransport(simulatedDevice(c), unsolicited)
    let progress = 0
    const r = await readConfiguration(t, { settingCount: c.info.records.length, onProgress: (n) => (progress = n) })
    expect(progress).toBe(c.info.records.length)
    expect(r.firmware).toBe(c.info.firmware)
    expect(r.interfaceVersion).toBe(1130131)
    for (let id = 0; id < c.info.records.length; id++) {
      const s = c.info.records[id]!
      const got = r.records[id]
      if (!s.isSupported) { expect(got, `setting ${id}`).toBeUndefined(); continue }
      expect(got, `setting ${id}`).toEqual({ scaleRaw: s.scaleRaw, offset: s.offset, defaultRaw: s.defaultRaw, minRaw: s.minRaw, maxRaw: s.maxRaw })
      expect(r.values[id], `value ${id}`).toBe(c.raw(id))
    }
    expect(r.missing).toContain('assistant memory (4096 bytes)')

    const { config: draft, assistantMemoryKnown } = draftConfiguration(r)
    expect(assistantMemoryKnown).toBe(false)
    for (let id = 0; id < c.info.records.length; id++) expect(draft.value(id), `setting ${id}`).toBe(c.value(id))
    for (let n = 0; n < 80; n++) {
      expect(draft.supportsFlag(n), `flag ${n}`).toBe(c.supportsFlag(n))
      if (c.supportsFlag(n)) expect(draft.flag(n), `flag ${n}`).toBe(c.flag(n))
    }
    // No attribute bytes: grid items fail closed (protected).
    expect(draft.info.isProtectedSetting(81)).toBe(true)
    expect(Array.from(draft.data.assistantMemory).every((b) => b === 0xff)).toBe(true)
    // Only read commands went out: 'V', 'A' and Winmon 0x05/0x06/0x31/0x35.
    const winmon = t.written.filter((f) => f[2] === ascii('W')).map((f) => f[3])
    expect(new Set(winmon)).toEqual(new Set([0x05, 0x06, 0x31, 0x35]))
    expect(t.written.every((f) => ['V', 'A', 'W'].includes(String.fromCharCode(f[2]!)))).toBe(true)
  })
})

describe('Mk3Client', () => {
  const synthetic = () => {
    // A minimal device with invented values: firmware 1912345, setting 2 = absorption 56.40 V (a 10-byte info record).
    const s = { scaleRaw: -100, offset: 0, defaultRaw: 0x1680, minRaw: 0x12c0, maxRaw: 0x1900, isSupported: true }
    return {
      info: { firmware: 1912345, info: (id: number) => (id === 2 ? s : undefined) },
      raw: (id: number) => (id === 2 ? 5640 : 0),
    } as unknown as DeviceConfiguration
  }

  it('reads one setting', async () => {
    const mk = new Mk3Client(new MockTransport(simulatedDevice(synthetic())))
    await mk.setAddress(0)
    expect(await mk.softwareVersion()).toBe(1912345)
    expect(await mk.settingInfo(2)).toEqual({ scaleRaw: -100, offset: 0, defaultRaw: 5760, minRaw: 4800, maxRaw: 6400 })
    expect(await mk.readSetting(2)).toBe(5640)
    expect(await mk.settingInfo(3)).toBeUndefined()
    expect(await mk.readSetting(3)).toBeUndefined()
  })

  it('discovers devices and stops after three silent addresses (§7.2)', async () => {
    const t = new MockTransport(simulatedDevice(synthetic(), [0, 1]))
    const mk = new Mk3Client(t, 20)
    expect(await mk.discover()).toEqual([0, 1])
    const addressed = t.written.filter((f) => f[2] === ascii('A')).map((f) => f[4])
    expect(addressed).toEqual([0, 1, 2, 3, 4])
  })

  it('times out when nothing answers', async () => {
    const mk = new Mk3Client(new MockTransport(() => undefined), 20)
    await expect(mk.interfaceVersion()).rejects.toBeInstanceOf(Mk3TimeoutError)
  })

  it('refuses an invalid address', async () => {
    const mk = new Mk3Client(new MockTransport(() => undefined), 20)
    await expect(mk.setAddress(0x20)).rejects.toThrow(/Invalid VE.Bus address/)
  })
})

// MARK: Read-only beta

import { ForbiddenFrameError, READ_ONLY_WINMON, ReadOnlyTransport, assertReadOnlyFrame } from '../src/lib/device/guard'
import { discoverDevices } from '../src/lib/device/readConfiguration'
import { deviceFromConfiguration, deviceResponder, syntheticDevice } from '../src/lib/device/simulator'
import { ConfigDocument } from '../src/lib/rules/document'
import { buildCatalog, useCatalog } from '../src/lib/rules/catalog'
import { readFileSync } from 'node:fs'
import { catalogJSONPath } from './fixtures'

useCatalog(buildCatalog(JSON.parse(readFileSync(catalogJSONPath, 'utf8'))))

describe('read-only guard', () => {
  it('lets through only V, A 01 <address> and Winmon reads', () => {
    expect(() => assertReadOnlyFrame(encodeFrame(ascii('V')))).not.toThrow()
    expect(() => assertReadOnlyFrame(encodeFrame(ascii('A'), [0x01, 0x00]))).not.toThrow()
    expect(() => assertReadOnlyFrame(encodeFrame(ascii('A'), [0x01, 0x1f]))).not.toThrow()
    for (const code of READ_ONLY_WINMON) {
      const id = code === 0x05 || code === 0x06 ? 0 : 0xbf
      expect(() => assertReadOnlyFrame(encodeFrame(ascii('W'), [code, id, 0]))).not.toThrow()
    }
  })

  const forbidden: [string, number[]][] = [
    ['W', [0x32, 0x02, 0x00]], // write RAM var
    ['W', [0x33, 0x02, 0x00]], // write setting
    ['W', [0x34, 0x00, 0x00]], // write data
    ['W', [0x37, 0x00, 0x02]], // write via id
    ['W', [0x30, 0x0d, 0x00]], // RAM read: not needed by the beta
    ['W', [0x36, 0x04, 0x00]], // RAM info: not needed either
    ['W', [0x0e, 0x00, 0x00]], // anything else
    ['W', [0x31, 0xc0, 0x00]], // setting id out of range
    ['W', [0x05, 0x01, 0x00]], // version with a stray argument
    ['A', [0x00, 0x00]],       // address read mode
    ['A', [0x01, 0x20]],       // invalid address
    ['S', []], ['S', [0x03, 0xc0, 0x10, 0x01, 0x01]], // panel state / switch
    ['F', [0x00]], ['F', [0x08]],                     // VE.Bus frames, reset
    ['R', []], ['X', []], ['Y', []], ['Z', []], ['L', []], ['M', [0x00]], ['N', [0x00]],
  ]
  for (const [cmd, data] of forbidden) {
    it(`refuses '${cmd}' ${data.map((b) => b.toString(16)).join(' ')}`, () => {
      expect(() => assertReadOnlyFrame(encodeFrame(ascii(cmd), data))).toThrow(ForbiddenFrameError)
    })
  }

  it('refuses malformed frames and bad checksums', () => {
    const f = encodeFrame(ascii('V'))
    const bad = f.slice(); bad[bad.length - 1] ^= 1
    expect(() => assertReadOnlyFrame(bad)).toThrow(ForbiddenFrameError)
    expect(() => assertReadOnlyFrame(Uint8Array.of(0x01, 0x02))).toThrow(ForbiddenFrameError)
    expect(() => assertReadOnlyFrame(Uint8Array.of(0x84, 0xff, 0x56, 0, 0, 0))).toThrow(ForbiddenFrameError)
  })

  it('the client cannot send a write even when asked to', async () => {
    const t = new MockTransport(() => undefined)
    const mk = new Mk3Client(t, 20)
    await expect(mk.winmon(0x33, 2, 0, () => true, 'write')).rejects.toBeInstanceOf(ForbiddenFrameError)
    expect(t.written).toHaveLength(0)
    await expect(new ReadOnlyTransport(t).write(encodeFrame(ascii('S')))).rejects.toBeInstanceOf(ForbiddenFrameError)
    expect(t.written).toHaveLength(0)
  })
})

describe('full read from a synthetic device (no private files)', () => {
  it('reads every record and value, and only read commands go out', async () => {
    const device = syntheticDevice()
    const t = new MockTransport(deviceResponder(device))
    const steps: number[] = []
    const r = await readConfiguration(t, { onProgress: (n) => steps.push(n) })
    expect(steps[0]).toBe(0)
    expect(steps.at(-1)).toBe(192)
    expect(r.firmware).toBe(device.firmware)
    for (let id = 0; id < 192; id++) {
      expect(r.records[id], `record ${id}`).toEqual(device.records[id])
      expect(r.values[id], `value ${id}`).toBe(device.records[id] ? device.values[id] : 0)
    }
    for (const f of t.written) expect(() => assertReadOnlyFrame(f)).not.toThrow()

    const { config } = draftConfiguration(r)
    expect(config.value(2)).toBeCloseTo(56.4)
    expect(config.value(6)).toBeCloseTo(25)
    const doc = ConfigDocument.fromDevice(config)
    expect(doc.readOnly).toBe(true)
    expect(doc.canSave).toBe(false)
    doc.setRaw(2, 5000, 'Test')
    expect(doc.config.raw(2)).toBe(5640)
    expect(doc.unlockGrid('anything at all')).toBe(false)
    expect(() => doc.save()).toThrow()
  })

  it('discovers the addresses that answer', async () => {
    const t = new MockTransport(deviceResponder({ ...syntheticDevice(), addresses: [0, 2] }))
    const d = await discoverDevices(t)
    expect(d.addresses).toEqual([0, 2])
    expect(d.interfaceVersion).toBe(1130131)
  })

  it('stops when cancelled', async () => {
    const ac = new AbortController()
    const t = new MockTransport(deviceResponder(syntheticDevice()))
    await expect(readConfiguration(t, { signal: ac.signal, onProgress: (n) => { if (n === 10) ac.abort() } })).rejects.toThrow(/cancelled/)
  })

  it('reports a lost interface', async () => {
    let n = 0
    const respond = deviceResponder(syntheticDevice())
    const t = new MockTransport((f) => respond(f))
    t.write = async (bytes) => { if (++n > 30) throw new Error('The interface was disconnected.'); t.written.push(bytes); const r = respond(bytes); if (r) (t as any).inbox.push(...r) }
    await expect(readConfiguration(t)).rejects.toThrow(/disconnected/)
  })
})

describe.runIf(sample)('the simulator built from a sample matches the file', () => {
  it('reads the sample device and opens it read-only', async () => {
    const c = DeviceConfiguration.parse(bytes(samplePath(sample!)))
    const r = await readConfiguration(new MockTransport(deviceResponder(deviceFromConfiguration(c))))
    const doc = ConfigDocument.fromDevice(draftConfiguration(r).config)
    for (let id = 0; id < c.info.records.length; id++) expect(doc.config.value(id), `setting ${id}`).toBe(c.value(id))
    expect(doc.changes).toEqual([])
  })
})
