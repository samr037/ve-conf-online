// VE.Bus device configuration: setting info, setting data, assistant memory RLE
// (port of Sources/VEKit/DeviceConfiguration.swift). Swift structs are values; here `clone()` gives a copy.
import { ByteReader, ByteWriter, FormatError, type Bytes } from './binary'
import { SettingFile } from './settingFile'
import { flagWords } from './settingNames'

/** Swift `.rounded(.toNearestOrEven)` (Delphi `Round`). */
export function roundHalfEven(x: number): number {
  const f = Math.floor(x)
  const d = x - f
  if (d < 0.5) return f
  if (d > 0.5) return f + 1
  return f % 2 === 0 ? f : f + 1
}

const i16 = (u: number) => (u << 16) >> 16

/**
 * MK2 "setting info" record: how a raw 16-bit setting maps to a physical value.
 * `display = scale * (raw + offset)`; `scaleRaw` 0 means the device does not support the setting.
 */
export class SettingInfo {
  constructor(
    public scaleRaw: number,
    public offset: number,
    public defaultRaw: number,
    public minRaw: number,
    /** For flag words this is the mask of supported bits. */
    public maxRaw: number,
  ) {}

  get isSupported(): boolean { return this.scaleRaw !== 0 }
  get scale(): number { return this.scaleRaw > 0 ? this.scaleRaw : this.scaleRaw < 0 ? 1 / -this.scaleRaw : 0 }
  /** Smallest step between two displayable values. */
  get step(): number { return this.scale }
  display(raw: number): number { return this.scale * (raw + this.offset) }

  /**
   * Nearest raw value for a physical value, clamped to the device range. Ties round to even.
   * `undefined` for an unsupported setting or a non-finite value, which must never reach the device.
   */
  rawValue(value: number): number | undefined {
    if (!this.isSupported || !Number.isFinite(value)) return undefined
    const r = roundHalfEven(value / this.scale - this.offset)
    if (!Number.isFinite(r)) return undefined
    return Math.min(Math.max(Math.min(Math.max(r, this.minRaw), this.maxRaw), 0), 0xffff)
  }

  /** `rawValue`, falling back to the current default when the value cannot be encoded. */
  raw(value: number): number { return this.rawValue(value) ?? this.defaultRaw }
}

/** Settings that are grid-code protected on every firmware: the grid code (81) and the grid words (128…191). */
export const isGridProtectedSetting = (id: number) => id === 81 || (id >= 128 && id <= 191)
/** `@_ShortCircuitIsFatal`, the only protected flag bit seen. */
export const isGridProtectedFlag = (n: number) => n === 64

/** `BareSettingInfo`: what the device reports about each of its settings, plus the firmware grid-code table. */
export class DeviceSettingInfo {
  version = 0
  firmware = 0
  configResponseChar = 0
  records: SettingInfo[] = []
  flagAttributes: Bytes = new Uint8Array()
  settingAttributes: Bytes = new Uint8Array()
  /** Raw firmware grid-code table (version >= 3). Kept verbatim. */
  gridTable: Bytes | undefined
  trailing: Bytes = new Uint8Array()

  static parse(body: Bytes): DeviceSettingInfo {
    const s = new DeviceSettingInfo()
    const r = new ByteReader(body)
    s.version = r.u32()
    if (s.version >= 5) throw new FormatError({ kind: 'unsupportedVersion', section: 'BareSettingInfo', version: s.version })
    s.firmware = r.u32()
    s.configResponseChar = r.u8()
    const n = r.u16()
    if (n % 10 !== 0)
      throw new FormatError({ kind: 'malformed', why: `BareSettingInfo: setting records are ${n} bytes, not a multiple of 10.` })
    if (n / 10 > DeviceSettingData.maxValues)
      throw new FormatError({ kind: 'malformed', why: `BareSettingInfo: ${n / 10} setting records, at most ${DeviceSettingData.maxValues} exist.` })
    const rr = new ByteReader(r.bytes(n))
    for (let i = 0; i < n / 10; i++) {
      s.records.push(new SettingInfo(i16(rr.u16()), i16(rr.u16()), rr.u16(), rr.u16(), rr.u16()))
    }
    if (s.version >= 2) {
      s.flagAttributes = r.bytes(r.u16())
      s.settingAttributes = r.bytes(r.u16())
    }
    s.gridTable = s.version > 2 ? r.bytes(r.u16()) : undefined
    s.trailing = r.bytes(r.remaining)
    return s
  }

  encoded(): Bytes {
    const w = new ByteWriter()
    w.u32(this.version); w.u32(this.firmware); w.u8(this.configResponseChar)
    w.u16(this.records.length * 10)
    for (const s of this.records) {
      w.u16(s.scaleRaw & 0xffff); w.u16(s.offset & 0xffff)
      w.u16(s.defaultRaw); w.u16(s.minRaw); w.u16(s.maxRaw)
    }
    if (this.version >= 2) {
      w.u16(this.flagAttributes.length); w.bytes(this.flagAttributes)
      w.u16(this.settingAttributes.length); w.bytes(this.settingAttributes)
    }
    if (this.gridTable) { w.u16(this.gridTable.length); w.bytes(this.gridTable) }
    w.bytes(this.trailing)
    return w.data
  }

  clone(): DeviceSettingInfo {
    const c = Object.assign(new DeviceSettingInfo(), this)
    c.records = this.records.map((r) => new SettingInfo(r.scaleRaw, r.offset, r.defaultRaw, r.minRaw, r.maxRaw))
    return c
  }

  info(id: number): SettingInfo | undefined { return id >= 0 ? this.records[id] : undefined }

  /** Bit 7: hidden/locked in the UI for this firmware. */
  isHiddenSetting(id: number): boolean {
    return id >= 0 && id < this.settingAttributes.length && (this.settingAttributes[id]! & 0x80) !== 0
  }
  /** Bit 0: protected. Fails closed: without an attribute byte the grid items stay protected. */
  isProtectedSetting(id: number): boolean {
    return id >= 0 && id < this.settingAttributes.length ? (this.settingAttributes[id]! & 0x01) !== 0 : isGridProtectedSetting(id)
  }
  isHiddenFlag(n: number): boolean {
    return n >= 0 && n < this.flagAttributes.length && (this.flagAttributes[n]! & 0x80) !== 0
  }
  isProtectedFlag(n: number): boolean {
    return n >= 0 && n < this.flagAttributes.length ? (this.flagAttributes[n]! & 0x01) !== 0 : isGridProtectedFlag(n)
  }
}

export interface RLEToken { literal: number; fill: number; count: number }

/** Run-length coding of the assistant memory (VEConfig `FUN_004bd71c` / `FUN_004bd51c`). */
export const RLE = {
  /** Throws as soon as the output would exceed `limit` bytes. */
  decode(bytes: Bytes, limit = DeviceSettingData.assistantMemorySize): { memory: Bytes; tokens: RLEToken[] } {
    const r = new ByteReader(bytes)
    const mem: number[] = []
    const tokens: RLEToken[] = []
    while (!r.isAtEnd) {
      const lit = r.bytes(r.u16())
      const fill = r.u8()
      const count = r.u16()
      if (mem.length + lit.length + count > limit) throw new FormatError({ kind: 'tooLarge', what: 'Assistant memory', limit })
      tokens.push({ literal: lit.length, fill, count })
      for (const b of lit) mem.push(b)
      for (let i = 0; i < count; i++) mem.push(fill)
    }
    return { memory: Uint8Array.from(mem), tokens }
  },

  encode(mem: Bytes, tokens: RLEToken[] | undefined): Bytes {
    // Reuse the original boundaries only if they still describe this exact image.
    if (tokens && tokens.reduce((a, t) => a + t.literal + t.count, 0) === mem.length) {
      let p = 0
      let ok = true
      for (const t of tokens) {
        for (let i = p + t.literal; i < p + t.literal + t.count; i++) if (mem[i] !== t.fill) { ok = false; break }
        if (!ok) break
        p += t.literal + t.count
      }
      if (ok) return RLE.emit(mem, tokens)
    }
    return RLE.emit(mem, RLE.canonicalTokens(mem))
  },

  emit(mem: Bytes, tokens: RLEToken[]): Bytes {
    const w = new ByteWriter()
    let p = 0
    for (const t of tokens) {
      w.u16(t.literal); w.bytes(mem.subarray(p, p + t.literal))
      w.u8(t.fill); w.u16(t.count)
      p += t.literal + t.count
    }
    return w.data
  },

  /** Literal runs, then fill runs of at least 6 equal bytes. */
  canonicalTokens(mem: Bytes): RLEToken[] {
    const tokens: RLEToken[] = []
    const n = mem.length
    let i = 0
    while (i < n) {
      let j = i
      while (j < n) {
        let k = j
        while (k < n && mem[k] === mem[j]) k++
        if (k - j >= 6) break
        j = k
      }
      let k = j
      while (k < n && k < j + 0xffff && mem[k] === mem[j]) k++
      tokens.push({ literal: j - i, fill: j < n ? mem[j]! : 0, count: k - j })
      i = k
    }
    return tokens
  },
}

const u64 = (lo: number, hi: number) => BigInt.asIntN(64, (BigInt(hi >>> 0) << 32n) | BigInt(lo >>> 0))

/** `BareSettingData`: the device's actual setting values and its assistant program memory. */
export class DeviceSettingData {
  /** VE Configure reads at most 0x180 bytes of values (settings 0…191) and skips the rest. */
  static readonly maxValues = 192
  /** Size of the assistant program memory of every VE.Bus device. */
  static readonly assistantMemorySize = 4096

  version = 0
  deviceID = 0
  firmwareAlt = 0
  obj20 = 0xff
  obj21 = 0
  byte8 = 0
  firmware = 0
  firmwareExtra: Bytes = new Uint8Array()
  configResponseChar = 0
  deviceRecord: Bytes = new Uint8Array()
  serial: string | undefined
  tokens: Bytes[] = []
  tokenTime = 0n
  readTime = 0n
  values: number[] = []
  /** 4096-byte assistant program image (0xFF = unprogrammed). */
  assistantMemory: Bytes = new Uint8Array()
  /** Original RLE token boundaries, so an untouched memory image re-encodes byte for byte. */
  rleTokens: RLEToken[] | undefined

  static parse(body: Bytes): DeviceSettingData {
    const d = new DeviceSettingData()
    const r = new ByteReader(body)
    d.version = r.u32()
    if (d.version >= 4) throw new FormatError({ kind: 'unsupportedVersion', section: 'BareSettingData', version: d.version })
    d.deviceID = r.u32()
    d.firmwareAlt = r.u32()
    if (d.version >= 3) { d.obj20 = r.u8(); d.obj21 = r.u8() }
    d.byte8 = r.u8()
    d.firmware = r.u32()
    d.firmwareExtra = r.bytes(r.u16())
    d.configResponseChar = r.u8()
    d.deviceRecord = r.bytes(9)
    if (d.version > 1) {
      d.serial = r.shortString()
      const count = r.u16()
      for (let i = 0; i < count; i++) d.tokens.push(r.bytes(r.u16()))
      d.tokenTime = u64(r.u32(), r.u32())
      d.readTime = u64(r.u32(), r.u32())
    }
    const n = r.u16()
    if (n % 2 !== 0) throw new FormatError({ kind: 'malformed', why: `BareSettingData: values are ${n} bytes, not a whole number of words.` })
    const vr = new ByteReader(r.bytes(n))
    for (let i = 0; i < Math.min(n / 2, DeviceSettingData.maxValues); i++) d.values.push(vr.u16())
    const decoded = RLE.decode(r.bytes(r.remaining), DeviceSettingData.assistantMemorySize)
    if (decoded.memory.length !== DeviceSettingData.assistantMemorySize)
      throw new FormatError({
        kind: 'malformed',
        why: `BareSettingData: assistant memory is ${decoded.memory.length} bytes, expected ${DeviceSettingData.assistantMemorySize}.`,
      })
    d.assistantMemory = decoded.memory
    d.rleTokens = decoded.tokens
    return d
  }

  encoded(): Bytes {
    const w = new ByteWriter()
    w.u32(this.version); w.u32(this.deviceID); w.u32(this.firmwareAlt)
    if (this.version >= 3) { w.u8(this.obj20); w.u8(this.obj21) }
    w.u8(this.byte8); w.u32(this.firmware)
    w.u16(this.firmwareExtra.length); w.bytes(this.firmwareExtra)
    w.u8(this.configResponseChar); w.bytes(this.deviceRecord)
    if (this.version > 1) {
      w.shortString(this.serial ?? '')
      w.u16(this.tokens.length)
      for (const t of this.tokens) { w.u16(t.length); w.bytes(t) }
      for (const t of [this.tokenTime, this.readTime]) {
        const u = BigInt.asUintN(64, t)
        w.u32(Number(u & 0xffffffffn)); w.u32(Number(u >> 32n))
      }
    }
    w.u16(this.values.length * 2)
    for (const v of this.values) w.u16(v)
    w.bytes(RLE.encode(this.assistantMemory, this.rleTokens))
    return w.data
  }

  clone(): DeviceSettingData {
    const c = Object.assign(new DeviceSettingData(), this)
    c.values = [...this.values]
    c.tokens = this.tokens.map((t) => t.slice())
    c.assistantMemory = this.assistantMemory.slice()
    c.rleTokens = this.rleTokens?.map((t) => ({ ...t }))
    return c
  }
}

export class Firmware {
  constructor(readonly number: number) {}
  get family(): number { return Math.floor(this.number / 100_000) }
  get type(): number { return Math.floor((this.number % 100_000) / 1000) }
  get version(): number { return this.number % 1000 }
  toString(): string { return `${this.number}` }
}

const hex2 = (n: number) => n.toString(16).toUpperCase().padStart(2, '0')

/** A complete VE.Bus device configuration as stored in a `.rvsc` file. */
export class DeviceConfiguration {
  private constructor(
    public formatVersion: string,
    public info: DeviceSettingInfo,
    public data: DeviceSettingData,
    public mk2Version: number,
    public file: SettingFile,
  ) {}

  static parse(bytes: Bytes): DeviceConfiguration { return DeviceConfiguration.fromFile(SettingFile.parse(bytes)) }

  static fromFile(file: SettingFile): DeviceConfiguration {
    const mk = file.get('Mk2vscInfo'), infoBody = file.get('BareSettingInfo'), dataBody = file.get('BareSettingData')
    if (!mk || !infoBody || !dataBody) throw new FormatError({ kind: 'badMagic', what: 'VE.Bus configuration (missing sections)' })
    const r = new ByteReader(mk)
    const mk2Version = r.u32()
    const formatVersion = r.shortString()
    const info = DeviceSettingInfo.parse(infoBody)
    const data = DeviceSettingData.parse(dataBody)
    // VE Configure asserts these match (docs/re/02-settings.md §2, §3). Info v<4 stores 3 firmware bytes.
    if ((info.firmware & 0xffffff) !== (data.firmware & 0xffffff))
      throw new FormatError({
        kind: 'malformed',
        why: `Setting info is for firmware ${info.firmware & 0xffffff} but the values are from firmware ${data.firmware & 0xffffff}.`,
      })
    if (info.configResponseChar !== data.configResponseChar)
      throw new FormatError({
        kind: 'malformed',
        why: `Setting info and values disagree on the device type (ConfigResponseChar 0x${hex2(info.configResponseChar)} vs 0x${hex2(data.configResponseChar)}).`,
      })
    if (data.values.length < info.records.length)
      throw new FormatError({
        kind: 'malformed',
        why: `The file has ${info.records.length} setting records but only ${data.values.length} values.`,
      })
    return new DeviceConfiguration(formatVersion, info, data, mk2Version, file)
  }

  clone(): DeviceConfiguration {
    return new DeviceConfiguration(this.formatVersion, this.info.clone(), this.data.clone(), this.mk2Version, this.file.clone())
  }

  settingFile(): SettingFile {
    const f = this.file.clone()
    const w = new ByteWriter()
    w.u32(this.mk2Version); w.shortString(this.formatVersion)
    f.set('Mk2vscInfo', w.data)
    f.set('BareSettingInfo', this.info.encoded())
    f.set('BareSettingData', this.data.encoded())
    return f
  }

  encoded(): Bytes { return this.settingFile().encoded() }

  get firmware(): Firmware { return new Firmware(this.data.firmware & 0xffffff) }

  raw(id: number): number { return id >= 0 && id < this.data.values.length ? this.data.values[id]! : 0 }

  setRaw(id: number, value: number): void {
    if (id < 0 || id >= this.data.values.length) return
    this.data.values[id] = value & 0xffff
  }

  value(id: number): number | undefined {
    const i = this.info.info(id)
    if (!i || !i.isSupported) return undefined
    return i.display(this.raw(id))
  }

  /** Returns false (and changes nothing) for an unsupported setting or a non-finite value. */
  setValue(id: number, value: number): boolean {
    const r = this.info.info(id)?.rawValue(value)
    if (r === undefined || id < 0 || id >= this.data.values.length) return false
    this.setRaw(id, r)
    return true
  }

  static isFlagIndex(n: number): boolean { return n >= 0 && n < flagWords.length * 16 }

  flag(n: number): boolean {
    if (!DeviceConfiguration.isFlagIndex(n)) return false
    return ((this.raw(flagWords[Math.floor(n / 16)]!) >> (n % 16)) & 1) === 1
  }

  setFlag(n: number, on: boolean): void {
    if (!DeviceConfiguration.isFlagIndex(n)) return
    const word = flagWords[Math.floor(n / 16)]!
    const mask = 1 << (n % 16)
    this.setRaw(word, on ? this.raw(word) | mask : this.raw(word) & ~mask)
  }

  /** Whether the firmware supports flag bit `n` (the info record's max holds the supported-bits mask). */
  supportsFlag(n: number): boolean {
    if (!DeviceConfiguration.isFlagIndex(n)) return false
    const i = this.info.info(flagWords[Math.floor(n / 16)]!)
    return !!i && i.isSupported && ((i.maxRaw >> (n % 16)) & 1) === 1
  }

  get serial(): string | undefined { return this.data.serial }
  get readDate(): Date | undefined { return this.data.readTime > 0n ? new Date(Number(this.data.readTime) * 1000) : undefined }
}
