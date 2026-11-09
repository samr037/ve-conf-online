import { createHash, createHmac, pbkdf2Sync, randomBytes } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import { hmacSha256, pbkdf2Sha256, sha256 } from '../src/lib/engine/sha256'

const hex = (b: Uint8Array) => Buffer.from(b).toString('hex')

describe('sha256 / hmac / pbkdf2 match node:crypto', () => {
  it('sha256 on lengths around the block boundaries', () => {
    for (const n of [0, 1, 55, 56, 63, 64, 65, 119, 120, 1000]) {
      const d = randomBytes(n)
      expect(hex(sha256(d))).toBe(createHash('sha256').update(d).digest('hex'))
    }
  })
  it('hmac with short and long keys', () => {
    for (const k of [3, 64, 100]) {
      const key = randomBytes(k), msg = randomBytes(77)
      expect(hex(hmacSha256(key, msg))).toBe(createHmac('sha256', key).update(msg).digest('hex'))
    }
  })
  it('pbkdf2', () => {
    const pw = Buffer.from('not the grid password'), salt = randomBytes(16)
    expect(hex(pbkdf2Sha256(pw, salt, 1000))).toBe(pbkdf2Sync(pw, salt, 1000, 32, 'sha256').toString('hex'))
  })
})
