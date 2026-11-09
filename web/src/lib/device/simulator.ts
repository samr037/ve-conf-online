// A simulated MK2/MK3 interface with VE.Bus devices behind it, answering the read commands of the beta the way the
// MK2 Protocol 3.14 describes (Winmon mode 1, short frames, at most three 3-byte replies per frame). Used by the
// unit tests and by the browser tests (through a fake navigator.serial); never by the app itself.
import type { DeviceConfiguration } from '../engine/deviceConfiguration'
import { ascii, encodeFrame } from './frame'
import type { RawSettingInfo } from './mk3'

export interface SimulatedDevice {
  /** VE.Bus firmware number. */
  firmware: number
  /** Setting info per id; `undefined` = not supported. */
  records: (RawSettingInfo | undefined)[]
  /** Raw value per id. */
  values: number[]
  /** VE.Bus addresses that answer (0 for a single unit). */
  addresses?: number[]
  /** The interface's own firmware version, answered to 'V'. */
  interfaceVersion?: number
}

/** The device behind a configuration file: same firmware, records and values. */
export function deviceFromConfiguration(c: DeviceConfiguration): SimulatedDevice {
  const records = c.info.records.map((r) => (r.isSupported ? { scaleRaw: r.scaleRaw, offset: r.offset, defaultRaw: r.defaultRaw, minRaw: r.minRaw, maxRaw: r.maxRaw } : undefined))
  return { firmware: c.info.firmware & 0xffffff, records, values: records.map((_, id) => c.raw(id)) }
}

/**
 * A small synthetic 48 V inverter/charger with invented values (firmware 1912560: family 19, type 12, version 560),
 * for tests that must run without private files.
 * Flag words 0, 1, 60, 61, 82; absorption, float, charge current, inverter voltage, AC input current limit.
 */
export function syntheticDevice(): SimulatedDevice {
  const records: (RawSettingInfo | undefined)[] = []
  const values: number[] = []
  const set = (id: number, r: RawSettingInfo, v: number) => { records[id] = r; values[id] = v }
  for (const id of [0, 1, 60, 61, 82]) set(id, { scaleRaw: 1, offset: 0, defaultRaw: 0, minRaw: 0, maxRaw: 0x7fff }, 0)
  values[0] = 0x0024 // 60 Hz off, PowerAssist on, weak AC off…
  set(2, { scaleRaw: -100, offset: 0, defaultRaw: 5760, minRaw: 4800, maxRaw: 6400 }, 5640) // absorption 56.40 V
  set(3, { scaleRaw: -100, offset: 0, defaultRaw: 5520, minRaw: 4800, maxRaw: 6400 }, 5400) // float 54.00 V
  set(4, { scaleRaw: 1, offset: 0, defaultRaw: 70, minRaw: 0, maxRaw: 70 }, 50) // charge current 50 A
  set(5, { scaleRaw: 1, offset: 0, defaultRaw: 230, minRaw: 210, maxRaw: 245 }, 230) // inverter output 230 V
  set(6, { scaleRaw: -10, offset: 0, defaultRaw: 500, minRaw: 30, maxRaw: 500 }, 250) // AC input limit 25.0 A
  for (let id = 0; id < 192; id++) if (values[id] === undefined) values[id] = 0
  return { firmware: 1912560, records: Array.from({ length: 192 }, (_, i) => records[i]), values, addresses: [0], interfaceVersion: 1130131 }
}

/** Answers one frame. Commands outside the beta's read set get the Winmon "unknown command" reply. */
export function deviceResponder(device: SimulatedDevice): (frame: Uint8Array) => Uint8Array[] | undefined {
  const addresses = device.addresses ?? [0]
  let address = 0xff
  const reply = (cmd: string, data: number[]) => encodeFrame(ascii(cmd), data)
  const w = (code: number, v: number) => [code, v & 0xff, (v >> 8) & 0xff]
  return (frame) => {
    const cmd = String.fromCharCode(frame[2]!)
    const d = Array.from(frame.slice(3, -1))
    switch (cmd) {
      case 'V': {
        const v = device.interfaceVersion ?? 1130131
        return [reply('V', [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >>> 24) & 0xff, address === 0xff ? ascii('B') : address])]
      }
      case 'A':
        if (d[0]! & 1) address = d[1]! <= 0x1f ? d[1]! : 0xff
        return [reply('A', [d[0]!, address])]
      case 'W': {
        if (!addresses.includes(address)) return undefined
        const id = d[1]! | (d[2]! << 8)
        const fw = device.firmware
        switch (d[0]) {
          case 0x05: return [reply('W', w(0x82, fw & 0xffff))]
          case 0x06: return [reply('W', w(0x83, (fw >>> 16) & 0xffff))]
          case 0x35: {
            const s = device.records[id]
            if (!s) return [reply('W', w(0x89, 0))]
            return [
              reply('W', [...w(0x89, s.scaleRaw), ...w(0x8a, s.offset), ...w(0x8b, s.defaultRaw)]),
              reply('W', [...w(0x8c, s.minRaw), ...w(0x8d, s.maxRaw)]),
            ]
          }
          case 0x31: {
            const s = device.records[id]
            return [s ? reply('W', w(0x86, device.values[id] ?? 0)) : reply('W', w(0x91, 0))]
          }
          default: return [reply('W', w(0x80, 0))]
        }
      }
    }
    return undefined
  }
}
