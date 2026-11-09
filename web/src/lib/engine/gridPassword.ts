// Authorization for the grid-code access class in VE Configure 9004248 (port of Sources/VEKit/GridPassword.swift).
// A file token never creates a live authorization: the user must enter the password.
//
// The password is Victron's and is given to installers only. The entry is checked against a salted PBKDF2-SHA-256
// hash, and the 8-byte token written to the file is computed from what the user typed, the way VE Configure encodes
// an entered password.
import type { DeviceConfiguration } from './deviceConfiguration'
import { pbkdf2Sha256 } from './sha256'

const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'
const salt = hexBytes('251dea09d5b5e4a5ab86b51aafb1e6e8')
const iterations = 120_000
const expected = hexBytes('598ce0dcc8a2215541602d3723b0a82a14135b0406ade1cc7248ac28ad5c0f7f')

function hexBytes(h: string): Uint8Array {
  return Uint8Array.from(h.match(/../g)!, (x) => parseInt(x, 16))
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  let d = a.length ^ b.length
  for (let i = 0; i < Math.min(a.length, b.length); i++) d |= a[i]! ^ b[i]!
  return d === 0
}

/** The entry last accepted in this page, so a second unlock does not pay the key derivation again. */
let lastAccepted: string | undefined

export class GridPassword {
  private constructor(private readonly token: Uint8Array) {}

  /** `undefined` unless `input` is the grid-code password. */
  static verify(input: string): GridPassword | undefined {
    const text = input.trim().toUpperCase()
    if (text.length !== 12) return undefined
    let value = 0n
    for (const ch of text) {
      const digit = alphabet.indexOf(ch)
      if (digit < 0) return undefined
      value = ((value << 5n) | BigInt(digit)) & 0xffffffffffffffffn
    }
    if (text !== lastAccepted) {
      if (!sameBytes(pbkdf2Sha256(new TextEncoder().encode(text), salt, iterations), expected)) return undefined
      lastAccepted = text
    }
    return new GridPassword(Uint8Array.from({ length: 8 }, (_, i) => Number((value >> BigInt(i * 8)) & 0xffn)))
  }

  /** Record only the authorization verified in this session. Version 1 has no token fields. */
  authorizeSave(config: DeviceConfiguration, now: bigint): void {
    if (config.data.version < 2) throw new Error('Grid authorization needs a version 2 file')
    config.data.tokens = [this.token.slice()]
    config.data.tokenTime = now
  }
}
