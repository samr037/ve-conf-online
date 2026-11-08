// Byte transport to an MK3-USB (DRAFT, not wired into the app).
// The MK3-USB enumerates as an FTDI USB-serial adapter (VID 0x0403, PID 0x6015, product "MK3-USB Interface");
// the OS driver exposes it as a serial port, which Web Serial can open in Chromium desktop browsers.
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

/** Web Serial implementation. `requestMk3Port()` must run from a user gesture (a click). */
export class WebSerialTransport implements SerialTransport {
  private reader: ReadableStreamDefaultReader<Uint8Array> | undefined
  private pendingRead: Promise<ReadableStreamReadResult<Uint8Array>> | undefined

  private constructor(private readonly port: SerialPort) {}

  static async requestMk3Port(): Promise<SerialPort> {
    if (!navigator.serial) throw new Error('This browser has no Web Serial support.')
    return navigator.serial.requestPort({ filters: [MK3_USB_FILTER] })
  }

  static async open(port: SerialPort, baudRate = MK2_BAUD_RATE): Promise<WebSerialTransport> {
    await port.open({ baudRate, dataBits: 8, stopBits: 1, parity: 'none', flowControl: 'none' })
    // MK2.2 (RS232) needs DTR to power its isolated side (§3.1). Harmless on the MK3-USB.
    try { await port.setSignals({ dataTerminalReady: true }) } catch { /* not supported by every driver */ }
    return new WebSerialTransport(port)
  }

  async write(bytes: Uint8Array): Promise<void> {
    const w = this.port.writable?.getWriter()
    if (!w) throw new Error('Serial port is not writable.')
    try { await w.write(bytes) } finally { w.releaseLock() }
  }

  async read(timeoutMs: number): Promise<Uint8Array | undefined> {
    if (!this.reader) {
      const r = this.port.readable?.getReader()
      if (!r) throw new Error('Serial port is not readable.')
      this.reader = r
    }
    // Keep one read in flight across timeouts: cancelling a Web Serial read would drop its bytes.
    this.pendingRead ??= this.reader.read()
    const timeout = new Promise<'timeout'>((resolve) => setTimeout(() => resolve('timeout'), timeoutMs))
    const result = await Promise.race([this.pendingRead, timeout])
    if (result === 'timeout') return undefined
    this.pendingRead = undefined
    if (result.done) throw new Error('Serial port closed.')
    return result.value
  }

  async close(): Promise<void> {
    try { await this.reader?.cancel() } catch { /* already closed */ }
    this.reader?.releaseLock()
    this.reader = undefined
    this.pendingRead = undefined
    await this.port.close()
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
