// The "Connect a device" flow (read-only beta): pick a serial port, find the VE.Bus devices, read one.
// Every frame goes through the device layer's read-only guard; nothing here can write to a device.
import type { DeviceConfiguration } from '../lib/engine/deviceConfiguration'
import {
  DeviceLostError, ForbiddenFrameError, Mk3TimeoutError, WebSerialTransport, discoverDevices, draftConfiguration, portLabel,
  readConfiguration, requestPort,
} from '../lib/device'
import type { AppKey } from '../lib/i18n/app'

export type DeviceErrorKey = Extract<AppKey, 'errPortBusy' | 'errNoAnswer' | 'errNoDevice' | 'errLost' | 'errDevice'>

export class DeviceFlowError extends Error {
  constructor(readonly key: DeviceErrorKey, why = '') {
    super(why)
    this.name = 'DeviceFlowError'
  }
}

/** The user closed the browser's port picker without choosing. */
export class PickerDismissed extends Error {}

function classify(e: unknown): DeviceFlowError {
  if (e instanceof DeviceFlowError) return e
  if (e instanceof DeviceLostError) return new DeviceFlowError('errLost')
  if (e instanceof Mk3TimeoutError) return new DeviceFlowError('errNoAnswer')
  if (e instanceof ForbiddenFrameError) return new DeviceFlowError('errDevice', e.message)
  return new DeviceFlowError('errDevice', e instanceof Error ? e.message : String(e))
}

/** One connection: from the port picker to the read configuration. `close()` always releases the port. */
export class DeviceSession {
  private port: SerialPort | undefined
  private transport: WebSerialTransport | undefined
  private readonly abort = new AbortController()
  private lost = false
  label = ''

  private readonly onDisconnect = (e: Event) => {
    if (e.target === this.port) { this.lost = true; this.abort.abort() }
  }

  /** Opens the browser's picker (must run from a click), then the port at 2400 baud. */
  async choose(): Promise<void> {
    try {
      this.port = await requestPort()
    } catch (e) {
      if (e instanceof DOMException && e.name === 'NotFoundError') throw new PickerDismissed()
      throw classify(e)
    }
    this.label = portLabel(this.port)
    navigator.serial?.addEventListener('disconnect', this.onDisconnect)
    try {
      this.transport = await WebSerialTransport.open(this.port)
    } catch (e) {
      if (e instanceof DOMException && (e.name === 'InvalidStateError' || e.name === 'NetworkError')) throw new DeviceFlowError('errPortBusy')
      throw classify(e)
    }
  }

  /** The VE.Bus addresses that answer. Throws `errNoDevice` when none does. */
  async discover(): Promise<number[]> {
    try {
      const { addresses } = await discoverDevices(this.transport!, this.abort.signal)
      if (addresses.length === 0) throw new DeviceFlowError('errNoDevice')
      return addresses
    } catch (e) {
      throw this.lost ? new DeviceFlowError('errLost') : classify(e)
    }
  }

  /** Reads the device at `address` and builds a display-only configuration. */
  async read(address: number, onProgress: (done: number, total: number) => void): Promise<DeviceConfiguration> {
    try {
      const reading = await readConfiguration(this.transport!, { address, onProgress, signal: this.abort.signal })
      return draftConfiguration(reading).config
    } catch (e) {
      if (this.lost) throw new DeviceFlowError('errLost')
      throw e instanceof DOMException && e.name === 'AbortError' ? e : classify(e)
    }
  }

  cancel(): void { this.abort.abort() }

  async close(): Promise<void> {
    this.abort.abort()
    navigator.serial?.removeEventListener('disconnect', this.onDisconnect)
    await this.transport?.close()
    this.transport = undefined
    if (this.port && !this.transport) { try { await this.port.close() } catch { /* already closed */ } }
    this.port = undefined
  }
}
