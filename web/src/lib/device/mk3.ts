// MK2/MK3 command client, read-only (beta). Every frame passes the read-only guard (guard.ts) before it is sent.
// Source: Victron, "Interfacing with VE.Bus products – MK2 Protocol" 3.14 (§3.4 'V', §7.1 'A', §7.2 discovery,
// §7.3 Winmon 'W' commands). Every request waits for its reply before the next one is sent (§7.1).
import { FrameReader, ascii, encodeFrame, i16, le16, u16, type Frame } from './frame'
import { ReadOnlyTransport } from './guard'
import type { SerialTransport } from './transport'

/** Reply timeout advised by the document (§3.3); 'F' 5 needs more than 750 ms. */
export const DEFAULT_TIMEOUT_MS = 500

/** Winmon reply codes used here (§7.3). */
export const Winmon = {
  sendSoftwareVersionPart0: 0x05,
  sendSoftwareVersionPart1: 0x06,
  readRAMVar: 0x30,
  readSetting: 0x31,
  getSettingInfo: 0x35,
  getRAMVarInfo: 0x36,
  // replies
  unknownCommand: 0x80,
  softwareVersionPart0: 0x82,
  softwareVersionPart1: 0x83,
  ramReadOK: 0x85,
  settingReadOK: 0x86,
  settingInfoScale: 0x89,
  settingInfoOffset: 0x8a,
  settingInfoDefault: 0x8b,
  settingInfoMinimum: 0x8c,
  settingInfoMaximum: 0x8d,
  ramInfoScale: 0x8e,
  ramInfoOffset: 0x8f,
  variableNotSupported: 0x90,
  settingNotSupported: 0x91,
} as const

/** A 3-byte Winmon reply `<W command> <Info0> <Info1>` (short frames, Winmon mode 1, the MK2 default). */
export interface WFrame { code: number; lo: number; hi: number }

export class Mk3TimeoutError extends Error {
  constructor(what: string) {
    super(`No reply from the interface (${what}).`)
    this.name = 'Mk3TimeoutError'
  }
}

/** The raw 10-byte setting info record, exactly what BareSettingInfo stores per setting (docs/re/02-settings.md §2.1). */
export interface RawSettingInfo { scaleRaw: number; offset: number; defaultRaw: number; minRaw: number; maxRaw: number }

export class Mk3Client {
  private readonly reader = new FrameReader()
  private queue: Frame[] = []

  private readonly transport: SerialTransport

  constructor(transport: SerialTransport, private readonly timeoutMs = DEFAULT_TIMEOUT_MS) {
    this.transport = new ReadOnlyTransport(transport)
  }

  /** Sends one frame and returns the frames received until `done` says the reply is complete. */
  private async exchange(command: number, data: number[], accept: (f: Frame) => boolean, done: (got: Frame[]) => boolean, what: string, timeoutMs = this.timeoutMs): Promise<Frame[]> {
    this.queue = []
    await this.transport.write(encodeFrame(command, data))
    const got: Frame[] = []
    const deadline = Date.now() + timeoutMs
    while (!done(got)) {
      const f = this.queue.shift()
      if (f) {
        // Unsolicited version frames (sent about once per second when idle, §3.4) and stray frames are skipped.
        if (accept(f)) got.push(f)
        continue
      }
      const left = deadline - Date.now()
      if (left <= 0) throw new Mk3TimeoutError(what)
      const chunk = await this.transport.read(left)
      if (!chunk) {
        if (Date.now() >= deadline) throw new Mk3TimeoutError(what)
        continue
      }
      this.queue.push(...this.reader.push(chunk))
    }
    return got
  }

  /** 'V': the interface's own firmware version, and the address it currently uses ('B' when none, 'W' = VE 9-bit). */
  async interfaceVersion(timeoutMs = this.timeoutMs * 4): Promise<{ version: number; mode: number }> {
    const V = ascii('V')
    const [f] = await this.exchange(V, [], (f) => f.kind === 'mk2' && f.command === V && f.data.length >= 4, (g) => g.length > 0, "'V'", timeoutMs)
    const d = f!.data
    return { version: (d[0]! | (d[1]! << 8) | (d[2]! << 16) | (d[3]! << 24)) >>> 0, mode: d[4] ?? 0 }
  }

  /** 'A' 01 <address>: selects the VE.Bus device the Winmon commands go to (0x00…0x1F, §7.1). */
  async setAddress(address: number): Promise<number> {
    if (address < 0 || address > 0x1f) throw new Error(`Invalid VE.Bus address ${address}`)
    const A = ascii('A')
    const [f] = await this.exchange(A, [0x01, address], (f) => f.kind === 'mk2' && f.command === A, (g) => g.length > 0, "'A'")
    return f!.data[1] ?? 0xff
  }

  /** One Winmon command; collects the 3-byte replies until `complete` is satisfied. */
  async winmon(code: number, info0: number, info1: number, complete: (frames: WFrame[]) => boolean, what: string): Promise<WFrame[]> {
    const W = ascii('W')
    const frames: WFrame[] = []
    const split = (f: Frame) => {
      if (f.kind !== 'mk2' || f.command !== W) return false
      for (let i = 0; i + 2 < f.data.length; i += 3) frames.push({ code: f.data[i]!, lo: f.data[i + 1]!, hi: f.data[i + 2]! })
      return true
    }
    await this.exchange(W, [code, info0, info1], split, () => complete(frames) || frames.some((w) => w.code === Winmon.unknownCommand), what)
    const unknown = frames.find((w) => w.code === Winmon.unknownCommand)
    if (unknown && !complete(frames)) throw new Error(`Device rejected Winmon command 0x${code.toString(16)} (reason ${unknown.lo}).`)
    return frames
  }

  /** CommandSendSoftwareVersion (§7.3.1), short frames: the VE.Bus firmware number, e.g. 2623552. */
  async softwareVersion(): Promise<number> {
    const p0 = await this.winmon(Winmon.sendSoftwareVersionPart0, 0, 0, (w) => w.some((x) => x.code === Winmon.softwareVersionPart0), 'software version 0')
    const p1 = await this.winmon(Winmon.sendSoftwareVersionPart1, 0, 0, (w) => w.some((x) => x.code === Winmon.softwareVersionPart1), 'software version 1')
    const a = p0.find((x) => x.code === Winmon.softwareVersionPart0)!
    const b = p1.find((x) => x.code === Winmon.softwareVersionPart1)!
    return (u16(a.lo, a.hi) | (u16(b.lo, b.hi) << 16)) >>> 0
  }

  /** CommandGetSettingInfo (§7.3.8), short frames. `undefined` when the device does not support the setting (Sc = 0). */
  async settingInfo(id: number): Promise<RawSettingInfo | undefined> {
    const codes = [Winmon.settingInfoScale, Winmon.settingInfoOffset, Winmon.settingInfoDefault, Winmon.settingInfoMinimum, Winmon.settingInfoMaximum]
    const [lo, hi] = le16(id)
    const frames = await this.winmon(Winmon.getSettingInfo, lo!, hi!, (w) => {
      const sc = w.find((x) => x.code === Winmon.settingInfoScale)
      if (sc && i16(sc.lo, sc.hi) === 0) return true
      return codes.every((c) => w.some((x) => x.code === c))
    }, `setting info ${id}`)
    const get = (c: number) => frames.find((x) => x.code === c)
    const sc = get(Winmon.settingInfoScale)!
    if (i16(sc.lo, sc.hi) === 0) return undefined
    const v = (c: number) => { const f = get(c)!; return u16(f.lo, f.hi) }
    return {
      scaleRaw: i16(sc.lo, sc.hi),
      offset: i16(get(Winmon.settingInfoOffset)!.lo, get(Winmon.settingInfoOffset)!.hi),
      defaultRaw: v(Winmon.settingInfoDefault),
      minRaw: v(Winmon.settingInfoMinimum),
      maxRaw: v(Winmon.settingInfoMaximum),
    }
  }

  /** CommandReadSetting (§7.3.4). `undefined` when the setting is not supported (0x91). */
  async readSetting(id: number): Promise<number | undefined> {
    const [lo, hi] = le16(id)
    const frames = await this.winmon(Winmon.readSetting, lo!, hi!,
      (w) => w.some((x) => x.code === Winmon.settingReadOK || x.code === Winmon.settingNotSupported), `setting ${id}`)
    const ok = frames.find((x) => x.code === Winmon.settingReadOK)
    return ok ? u16(ok.lo, ok.hi) : undefined
  }

  /**
   * Device discovery (§7.2): tries addresses from 0 and stops after 3 consecutive addresses without a reply.
   * Returns the addresses that answered CommandSendSoftwareVersionPart0.
   */
  async discover(): Promise<number[]> {
    const found: number[] = []
    let misses = 0
    for (let address = 0; address <= 0x1f && misses < 3; address++) {
      await this.setAddress(address)
      try {
        await this.winmon(Winmon.sendSoftwareVersionPart0, 0, 0, (w) => w.some((x) => x.code === Winmon.softwareVersionPart0), `probe ${address}`)
        found.push(address)
        misses = 0
      } catch (e) {
        if (!(e instanceof Mk3TimeoutError)) throw e
        misses++
      }
    }
    return found
  }
}

// TODO(write): deliberately not implemented in the beta, and the guard refuses every such frame. What writing needs, per the document and VE Configure:
//  - CommandWriteSetting 0x33 <id> then CommandWriteData 0x34 <value> → 0x88 (§7.3.6–7.3.7), or
//    CommandWriteViaID 0x37 <flags> <id> <data> → 0x88 / 0x9B "access level required" (§7.3.11, Winmon mode 2).
//  - Many settings only take effect after a device reset (§7.3.13.2 note e): 'F' 8 <long address> (§6.3).
//  - Grid-code protected settings need the grid password / access level first (VE Configure: "Some settings could
//    not be written because they require an access password", WinMonbus.pas); the mechanism is undocumented.
//  - Assistant memory: VE Configure warns "Reading the assistant setup will reset the device"; the commands are
//    undocumented (VEConfig WinMonbus.pas / "BareEPROMAcess").
//  Safeguards required before any write: same firmware as the reading, read-back verify of every value, refuse
//  grid-protected changes without the password, explicit confirmation listing the changes, and a reset step.
