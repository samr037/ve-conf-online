// Read-only guard for the device beta: every frame goes through `assertReadOnlyFrame` before it reaches the port.
// The beta may only identify the interface, select a VE.Bus address and read. Anything else (writes, resets,
// access levels, panel state, RAM writes, VE.Bus 'F' frames…) is refused before a byte is sent.
import { MK2_MARKER, checksum } from './frame'
import type { SerialTransport } from './transport'

/** Winmon codes the beta may send (MK2 Protocol 3.14, §7.3): software version parts and setting info/value reads. */
export const READ_ONLY_WINMON = new Set([0x05, 0x06, 0x31, 0x35])

/** Highest setting id a read may ask for (a file holds settings 0…191). */
const MAX_SETTING_ID = 0xbf

export class ForbiddenFrameError extends Error {
  constructor(why: string) {
    super(`Refused to send a frame to the device: ${why}.`)
    this.name = 'ForbiddenFrameError'
  }
}

const describe = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join(' ')

/** Throws unless `frame` is one of the read commands the beta knows: 'V', 'A' 01 <address>, 'W' <read code> <id>. */
export function assertReadOnlyFrame(frame: Uint8Array): void {
  const len = frame[0] ?? 0
  if (frame.length < 4 || (len & 0x80) !== 0 || frame.length !== len + 2) throw new ForbiddenFrameError(`malformed frame ${describe(frame)}`)
  if (checksum(frame.subarray(0, -1)) !== frame[frame.length - 1]) throw new ForbiddenFrameError(`bad checksum ${describe(frame)}`)
  if (frame[1] !== MK2_MARKER) throw new ForbiddenFrameError(`not an MK2 command ${describe(frame)}`)
  const command = String.fromCharCode(frame[2]!)
  const data = frame.subarray(3, -1)
  switch (command) {
    case 'V':
      if (data.length === 0) return
      break
    case 'A':
      // 'A' 01 <address>: select the device the Winmon commands go to (§7.1). Mode bit 0 only.
      if (data.length === 2 && data[0] === 0x01 && data[1]! <= 0x1f) return
      break
    case 'W': {
      if (data.length !== 3 || !READ_ONLY_WINMON.has(data[0]!)) break
      const id = data[1]! | (data[2]! << 8)
      if ((data[0] === 0x05 || data[0] === 0x06) && id === 0) return
      if ((data[0] === 0x31 || data[0] === 0x35) && id <= MAX_SETTING_ID) return
      break
    }
  }
  throw new ForbiddenFrameError(`'${command}' ${describe(data)} is not a read command`)
}

/** Wraps a transport so that only read commands can be written to it. */
export class ReadOnlyTransport implements SerialTransport {
  constructor(private readonly inner: SerialTransport) {}

  async write(bytes: Uint8Array): Promise<void> {
    assertReadOnlyFrame(bytes)
    await this.inner.write(bytes)
  }

  read(timeoutMs: number): Promise<Uint8Array | undefined> { return this.inner.read(timeoutMs) }
  close(): Promise<void> { return this.inner.close() }
}
