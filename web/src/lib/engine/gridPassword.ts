// Authorization for the grid-code access class in VE Configure 9004248 (port of Sources/VEKit/GridPassword.swift).
// A file token never creates a live authorization: the user must enter the password.
import type { DeviceConfiguration } from './deviceConfiguration'

const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'

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
    // FUN_004bceac encodes this value; FUN_004bced4 decodes entered passwords.
    if (value !== 0x0000000000000000n) return undefined
    return new GridPassword(Uint8Array.from({ length: 8 }, (_, i) => Number((value >> BigInt(i * 8)) & 0xffn)))
  }

  /** Record only the authorization verified in this session. Version 1 has no token fields. */
  authorizeSave(config: DeviceConfiguration, now: bigint): void {
    if (config.data.version < 2) throw new Error('Grid authorization needs a version 2 file')
    config.data.tokens = [this.token.slice()]
    config.data.tokenTime = now
  }
}
