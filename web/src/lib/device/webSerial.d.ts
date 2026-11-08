// Minimal Web Serial types (https://wicg.github.io/serial/). TypeScript's lib.dom does not ship them.
// Only what web/src/lib/device uses is declared. Chromium desktop browsers implement the API.

interface SerialPortFilter {
  usbVendorId?: number
  usbProductId?: number
}

interface SerialPortRequestOptions {
  filters?: SerialPortFilter[]
}

interface SerialOptions {
  baudRate: number
  dataBits?: 7 | 8
  stopBits?: 1 | 2
  parity?: 'none' | 'even' | 'odd'
  bufferSize?: number
  flowControl?: 'none' | 'hardware'
}

interface SerialPortInfo {
  usbVendorId?: number
  usbProductId?: number
}

interface SerialOutputSignals {
  dataTerminalReady?: boolean
  requestToSend?: boolean
  break?: boolean
}

interface SerialPort {
  readonly readable: ReadableStream<Uint8Array> | null
  readonly writable: WritableStream<Uint8Array> | null
  open(options: SerialOptions): Promise<void>
  close(): Promise<void>
  getInfo(): SerialPortInfo
  setSignals(signals: SerialOutputSignals): Promise<void>
}

interface Serial {
  requestPort(options?: SerialPortRequestOptions): Promise<SerialPort>
  getPorts(): Promise<SerialPort[]>
}

interface Navigator {
  readonly serial?: Serial
}
