// Reading a VE.Bus device's configuration through an MK3-USB or MK2 interface (read-only beta).
//
// What the public protocol gives (MK2 Protocol 3.14): the firmware number, and for each setting id its info record
// (Sc, Offset, Default, Min, Max — exactly BareSettingInfo's 10-byte record) and its raw value (BareSettingData).
// Flag words are settings 0, 1, 60, 61 and 82; their info Maximum is the mask of supported bits (§7.3.13.3).
//
// What it does not give, and VE Configure reads with undocumented commands (see web/docs/mk3-webserial.md):
// setting/flag attribute bytes (hidden, protected), the firmware grid-code table, the serial number, the unlock
// tokens, ConfigResponseChar, the device record, firmware_extra and the 4096-byte assistant memory.
import { ByteWriter, concat } from '../engine/binary'
import { DeviceConfiguration, DeviceSettingData, RLE } from '../engine/deviceConfiguration'
import { SettingFile } from '../engine/settingFile'
import { Mk3Client, Mk3TimeoutError, type RawSettingInfo } from './mk3'
import type { SerialTransport } from './transport'

export interface DeviceReading {
  interfaceVersion: number
  address: number
  /** VE.Bus firmware number (e.g. 1912345 = family 19, type 12, version 345). */
  firmware: number
  /** One entry per setting id; `undefined` = not supported by this device. */
  records: (RawSettingInfo | undefined)[]
  /** Raw values, 0 for unsupported settings (as in a file). */
  values: number[]
  /** Parts of an .rvsc this reading could not fill in. */
  missing: string[]
}

export interface ReadOptions {
  /** VE.Bus address of the device (0 in a single-unit system, §7.2 / Appendix 2). */
  address?: number
  /** Number of setting ids to read. A file holds at most 192 (settings 0…191). */
  settingCount?: number
  onProgress?: (done: number, total: number) => void
  signal?: AbortSignal
}

const MISSING = [
  'setting attribute bytes (hidden / protected)',
  'flag attribute bytes',
  'grid-code table',
  'serial number',
  'unlock tokens',
  'ConfigResponseChar (device type)',
  'device record and firmware_extra',
  'assistant memory (4096 bytes)',
]

const aborted = (signal?: AbortSignal) => {
  if (signal?.aborted) throw new DOMException('Reading cancelled', 'AbortError')
}

/** One request, tried again once after a timeout (a frame lost on the bus). A rejection reads as "not supported". */
async function attempt<T>(run: () => Promise<T>, signal?: AbortSignal): Promise<T | undefined> {
  for (let i = 0; ; i++) {
    aborted(signal)
    try {
      return await run()
    } catch (e) {
      if (e instanceof Mk3TimeoutError && i === 0) continue
      if (e instanceof Error && /rejected Winmon/.test(e.message)) return undefined
      throw e
    }
  }
}

/** The interface's version and the VE.Bus addresses that answer (§7.2). */
export async function discoverDevices(transport: SerialTransport, signal?: AbortSignal): Promise<{ interfaceVersion: number; addresses: number[] }> {
  const mk = new Mk3Client(transport)
  aborted(signal)
  const iface = await mk.interfaceVersion()
  if (iface.mode === 'W'.charCodeAt(0)) throw new Error('The interface is in VE 9-bit RS485 mode, not VE.Bus.')
  aborted(signal)
  const addresses = await mk.discover()
  return { interfaceVersion: iface.version, addresses }
}

/** Reads what the public MK2 protocol exposes. About 2 × settingCount Winmon exchanges at 2400 baud. */
export async function readConfiguration(transport: SerialTransport, options: ReadOptions = {}): Promise<DeviceReading> {
  const { address = 0, settingCount = DeviceSettingData.maxValues, onProgress, signal } = options
  const mk = new Mk3Client(transport)
  aborted(signal)
  const iface = await mk.interfaceVersion()
  if (iface.mode === 'W'.charCodeAt(0)) throw new Error('The interface is in VE 9-bit RS485 mode, not VE.Bus.')
  await mk.setAddress(address)
  const firmware = await attempt(() => mk.softwareVersion(), signal)
  if (firmware === undefined) throw new Error('The device did not report its firmware version.')

  const records: (RawSettingInfo | undefined)[] = []
  const values: number[] = []
  onProgress?.(0, settingCount)
  for (let id = 0; id < settingCount; id++) {
    const info = await attempt(() => mk.settingInfo(id), signal)
    records.push(info)
    values.push(info ? (await attempt(() => mk.readSetting(id), signal)) ?? 0 : 0)
    onProgress?.(id + 1, settingCount)
  }
  aborted(signal)
  return { interfaceVersion: iface.version, address, firmware, records, values, missing: [...MISSING] }
}

/**
 * Builds an .rvsc-shaped configuration from a reading, for display only. It uses the oldest section versions
 * (BareSettingInfo v1 without attribute bytes, so every grid item stays protected; BareSettingData v1 without
 * serial or tokens). The assistant memory is unknown and filled with 0xFF: such a configuration must never be
 * written back to a device or uploaded through VRM, because it would erase the device's assistants.
 */
export function draftConfiguration(r: DeviceReading): { config: DeviceConfiguration; assistantMemoryKnown: false } {
  const mk = new ByteWriter()
  mk.u32(1)
  mk.shortString('1.27')

  // Records are written up to the highest supported setting, like VE Configure's writer.
  let n = r.records.length
  while (n > 0 && !r.records[n - 1]) n--
  const info = new ByteWriter()
  info.u32(1)
  info.u32(r.firmware)
  info.u8(0) // TODO(protocol): ConfigResponseChar is not in the public document.
  info.u16(n * 10)
  for (let id = 0; id < n; id++) {
    const s = r.records[id]
    info.u16((s?.scaleRaw ?? 0) & 0xffff); info.u16((s?.offset ?? 0) & 0xffff)
    info.u16(s?.defaultRaw ?? 0); info.u16(s?.minRaw ?? 0); info.u16(s?.maxRaw ?? 0)
  }

  const data = new ByteWriter()
  data.u32(1)
  data.u32(0) // TODO(protocol): device id
  data.u32(0) // TODO(protocol): firmware_alt
  data.u8(0)
  data.u32(r.firmware)
  data.u16(0) // firmware_extra: unknown
  data.u8(0) // ConfigResponseChar, must equal the info's
  data.bytes(new Uint8Array(9)) // TODO(protocol): device record
  const values = r.values.slice(0, DeviceSettingData.maxValues)
  data.u16(values.length * 2)
  for (const v of values) data.u16(v)
  const memory = new Uint8Array(DeviceSettingData.assistantMemorySize).fill(0xff)
  const body = concat(data.data, RLE.encode(memory, undefined))

  const file = new SettingFile([
    { name: 'Mk2vscInfo', body: mk.data },
    { name: 'BareSettingInfo', body: info.data },
    { name: 'BareSettingData', body },
  ])
  return { config: DeviceConfiguration.fromFile(file), assistantMemoryKnown: false }
}
