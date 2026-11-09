// MK2/MK3 serial framing (DRAFT, not wired into the app).
// Source: Victron, "Interfacing with VE.Bus products – MK2 Protocol" 3.14, §3.2 (message format).
//
//   <Length> 0xFF <Command> <Data0> … <Datan-1> <Checksum>
//
// <Length> counts the bytes after itself and before the checksum. When its MSB is set, the frame carries the
// LED status (2 bytes: <LED on> <LED blink>) at the end of its data (§5, Flags[1]; Appendix 1 "84 FF 'S' …").
// The checksum makes the sum of every byte of the frame, length and checksum included, equal 0 (mod 256).
// Replies to the 'F' command are VE.Bus frames (§6): the same layout without the 0xFF marker, the first byte after
// the length being the frame type (0x20 info, 0x41 MasterMultiLED, 0x3C BOL).

export const MK2_MARKER = 0xff

/** First body byte of every frame the interface sends: the MK2 marker, or a VE.Bus frame type (§5.1, §6). */
const FRAME_STARTS = new Set([MK2_MARKER, 0x20, 0x3c, 0x40, 0x41])

/** Two's complement of the byte sum, so that the whole frame sums to 0 mod 256. */
export function checksum(bytes: ArrayLike<number>): number {
  let sum = 0
  for (let i = 0; i < bytes.length; i++) sum = (sum + bytes[i]!) & 0xff
  return (0x100 - sum) & 0xff
}

/** An MK2 frame to the interface: `command` is the ASCII command ('V', 'A', 'W', 'X'…) as a byte. */
export function encodeFrame(command: number, data: ArrayLike<number> = []): Uint8Array {
  const body = [MK2_MARKER, command & 0xff, ...Array.from(data, (b) => b & 0xff)]
  if (body.length > 0x7f) throw new Error(`MK2 frame too long (${body.length} bytes)`)
  const frame = [body.length, ...body]
  return Uint8Array.from([...frame, checksum(frame)])
}

export const ascii = (c: string) => c.charCodeAt(0)

export type Frame =
  /** A frame from the MK2/MK3 itself (0xFF marker): `command` is its first byte ('V', 'A', 'X'…). */
  | { kind: 'mk2'; command: number; data: Uint8Array; led?: { on: number; blink: number } }
  /** A VE.Bus frame forwarded by the interface (reply to 'F'): `type` is 0x20, 0x41, 0x3C… */
  | { kind: 'vebus'; type: number; data: Uint8Array; led?: { on: number; blink: number } }

/**
 * Splits a byte stream into frames. Bytes that cannot start a valid frame (bad checksum, impossible length) are
 * dropped one at a time until the stream resynchronises, so line noise or a frame cut at connection time is skipped.
 */
export class FrameReader {
  private buf: number[] = []

  push(chunk: ArrayLike<number>): Frame[] {
    for (let i = 0; i < chunk.length; i++) this.buf.push(chunk[i]! & 0xff)
    const out: Frame[] = []
    for (;;) {
      if (this.buf.length < 2) return out
      const lenByte = this.buf[0]!
      const len = lenByte & 0x7f
      const hasLed = (lenByte & 0x80) !== 0
      if (len < 1) { this.buf.shift(); continue }
      // The byte after the length is the 0xFF marker or a VE.Bus frame type: anything else is noise, dropped now
      // rather than waiting for the bytes a bogus length claims.
      if (!FRAME_STARTS.has(this.buf[1]!)) { this.buf.shift(); continue }
      if (this.buf.length < len + 2) return out
      const frame = this.buf.slice(0, len + 2)
      if (checksum(frame.slice(0, len + 1)) !== frame[len + 1]) { this.buf.shift(); continue }
      this.buf.splice(0, len + 2)
      let body = frame.slice(1, len + 1)
      let led: { on: number; blink: number } | undefined
      if (hasLed && body.length >= 3) {
        led = { on: body[body.length - 2]!, blink: body[body.length - 1]! }
        body = body.slice(0, -2)
      }
      if (body[0] === MK2_MARKER) {
        if (body.length < 2) continue
        out.push({ kind: 'mk2', command: body[1]!, data: Uint8Array.from(body.slice(2)), ...(led ? { led } : {}) })
      } else {
        out.push({ kind: 'vebus', type: body[0]!, data: Uint8Array.from(body.slice(1)), ...(led ? { led } : {}) })
      }
    }
  }

  /** Bytes received but not yet part of a complete frame. */
  get pending(): number { return this.buf.length }
}

export const u16 = (lo: number, hi: number) => (lo & 0xff) | ((hi & 0xff) << 8)
export const i16 = (lo: number, hi: number) => (u16(lo, hi) << 16) >> 16
export const le16 = (v: number) => [v & 0xff, (v >>> 8) & 0xff]
