// The editor ships copies of the Mac app's catalog and translations (web/src/data): they must not drift.
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { repo } from './fixtures'

const pairs: [string, string][] = [
  ['Sources/VEConfigure/Resources/catalog.json', 'web/src/data/catalog.json'],
  ['Sources/VEConfigure/Resources/catalog-strings.json', 'web/src/data/catalog-strings.json'],
  ['Resources/fr.lproj/Localizable.strings', 'web/src/data/l10n/fr.strings'],
  ['Resources/de.lproj/Localizable.strings', 'web/src/data/l10n/de.strings'],
  ['Resources/es.lproj/Localizable.strings', 'web/src/data/l10n/es.strings'],
]

describe.runIf(existsSync(join(repo, 'Sources')))('web data copies match the Mac app', () => {
  for (const [source, copy] of pairs) {
    it(copy, () => expect(readFileSync(join(repo, copy)).equals(readFileSync(join(repo, source)))).toBe(true))
  }
})
