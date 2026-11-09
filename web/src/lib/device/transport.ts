// Byte transport to an MK3-USB or MK2 interface over Web Serial (read-only beta).
// The MK3-USB enumerates as an FTDI USB-serial adapter (VID 0x0403, PID 0x6015, product "MK3-USB Interface");
// an MK2-USB is an FTDI adapter too, and an MK2.2 (RS232) sits behind any USB-serial adapter (FTDI, Prolific,
// CP210x, CH340). The OS driver exposes them as serial ports, which Web Serial opens in Chromium desktop browsers.
// Communication parameters: 2400 baud, 8 data bits, no parity, 1 stop bit (MK2 Protocol 3.14, §3.1).

export interface SerialTransport {
  /** Sends bytes as one write. */
  write(bytes: Uint8Array): Promise<void>
  /** Next chunk of received bytes, or `undefined` when nothing arrives within `timeoutMs`. */
  read(timeoutMs: number): Promise<Uint8Array | undefined>
  close(): Promise<void>
}

export const MK3_USB_FILTER: SerialPortFilter = { usbVendorId: 0x0403, usbProductId: 0x6015 }
export const MK2_BAUD_RATE = 2400

/** Whether this browser can talk to a serial port at all (Chromium desktop: yes; Safari, Firefox: no). */
export const webSerialAvailable = () => typeof navigator !== 'undefined' && navigator.serial !== undefined

/** The port was unplugged or the OS closed it while reading. */
export class DeviceLostError extends Error {
  constructor() {
    super('The interface was disconnected.')
    this.name = 'DeviceLostError'
  }
}

const usbVendors: Record<number, string> = { 0x0403: 'FTDI', 0x067b: 'Prolific', 0x10c4: 'Silicon Labs CP210x', 0x1a86: 'CH340' }

/** A short name for the port: "MK3-USB" for Victron's interface, else the USB-serial chip when known. */
export function portLabel(port: SerialPort): string {
  let info: SerialPortInfo = {}
  try { info = port.getInfo() } catch { /* some fakes have no info */ }
  if (info.usbVendorId === MK3_USB_FILTER.usbVendorId && info.usbProductId === MK3_USB_FILTER.usbProductId) return 'MK3-USB'
  const vendor = info.usbVendorId !== undefined ? usbVendors[info.usbVendorId] : undefined
  if (vendor) return `${vendor} USB serial`
  if (info.usbVendorId !== undefined) {
    const h = (n: number | undefined) => (n ?? 0).toString(16).padStart(4, '0')
    return `USB serial ${h(info.usbVendorId)}:${h(info.usbProductId)}`
  }
  return 'serial port'
}

/**
 * Opens the browser's port picker. No vendor filter: MK2 interfaces sit behind many USB-serial chips, and a filter
 * would hide them. Must run from a user gesture (a click).
 */
export async function requestPort(): Promise<SerialPort> {
  if (!navigator.serial) throw new Error('This browser has no Web Serial support.')
  return navigator.serial.requestPort({})
}

/** Web Serial implementation. */
export class WebSerialTransport implements SerialTransport {
  private reader: ReadableStreamDefaultReader<Uint8Array> | undefined
  private pendingRead: Promise<ReadableStreamReadResult<Uint8Array>> | undefined
  private closed = false

  private constructor(private readonly port: SerialPort) {}

  static async open(port: SerialPort, baudRate = MK2_BAUD_RATE): Promise<WebSerialTransport> {
    await port.open({ baudRate, dataBits: 8, stopBits: 1, parity: 'none', flowControl: 'none' })
    // MK2.2 (RS232) takes its power from DTR/RTS (§3.1). Harmless on the MK3-USB and MK2-USB.
    try { await port.setSignals({ dataTerminalReady: true, requestToSend: true }) } catch { /* not supported by every driver */ }
    return new WebSerialTransport(port)
  }

  async write(bytes: Uint8Array): Promise<void> {
    if (this.closed) throw new DeviceLostError()
    const w = this.port.writable?.getWriter()
    if (!w) throw new DeviceLostError()
    try { await w.write(bytes) } catch { throw new DeviceLostError() } finally { w.releaseLock() }
  }

  async read(timeoutMs: number): Promise<Uint8Array | undefined> {
    if (this.closed) throw new DeviceLostError()
    if (!this.reader) {
      const r = this.port.readable?.getReader()
      if (!r) throw new DeviceLostError()
      this.reader = r
    }
    // Keep one read in flight across timeouts: cancelling a Web Serial read would drop its bytes.
    this.pendingRead ??= this.reader.read()
    let timer: ReturnType<typeof setTimeout> | undefined
    const timeout = new Promise<'timeout'>((resolve) => { timer = setTimeout(() => resolve('timeout'), timeoutMs) })
    let result: ReadableStreamReadResult<Uint8Array> | 'timeout'
    try {
      result = await Promise.race([this.pendingRead, timeout])
    } catch {
      this.pendingRead = undefined
      throw new DeviceLostError()
    } finally {
      clearTimeout(timer)
    }
    if (result === 'timeout') return undefined
    this.pendingRead = undefined
    if (result.done) throw new DeviceLostError()
    return result.value
  }

  /** Releases the port. Never throws and never hangs for more than a second. */
  async close(): Promise<void> {
    if (this.closed) return
    this.closed = true
    const settle = (p: Promise<unknown>) => Promise.race([p.catch(() => undefined), new Promise((r) => setTimeout(r, 1000))])
    if (this.reader) {
      await settle(this.reader.cancel())
      try { this.reader.releaseLock() } catch { /* still locked by a read */ }
    }
    this.reader = undefined
    this.pendingRead = undefined
    try { await this.port.setSignals({ dataTerminalReady: false, requestToSend: false }) } catch { /* already gone */ }
    await settle(this.port.close())
  }
}

/**
 * Test double: each written frame is handed to `respond`, whose bytes are then delivered to readers.
 * `unsolicited` bytes are delivered first (e.g. the version frame the MK2 sends every second when idle, §3.4).
 */
export class MockTransport implements SerialTransport {
  readonly written: Uint8Array[] = []
  private inbox: Uint8Array[] = []

  constructor(private readonly respond: (frame: Uint8Array) => Uint8Array[] | Uint8Array | undefined, unsolicited: Uint8Array[] = []) {
    this.inbox.push(...unsolicited)
  }

  async write(bytes: Uint8Array): Promise<void> {
    this.written.push(bytes)
    const r = this.respond(bytes)
    if (r) this.inbox.push(...(Array.isArray(r) ? r : [r]))
  }

  async read(): Promise<Uint8Array | undefined> {
    return this.inbox.shift()
  }

  async close(): Promise<void> {}
}
