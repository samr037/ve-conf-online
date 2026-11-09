// Paths to the private reference material. Tests that need it skip on a clean clone.
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

export const repo = join(import.meta.dirname, '..', '..')
export const goldenDir = join(repo, 'web', 'fixtures', 'golden')
// The library ships with the web app (src/data/assistants), so the tests always have it.
export const libraryPath = join(repo, 'web', 'src', 'data', 'assistants', 'all112.vfp')
export const samplePath = (name: string) => join(repo, 'samples', `${name}.rvsc`)
export const samples = ['s1', 's2', 's3', 's4', 's5']

// The reference data describes the private samples: without them it cannot be checked.
export const hasSamples = existsSync(samplePath('s5'))
export const hasGolden = existsSync(join(goldenDir, 'library.json')) && hasSamples

// Values the private samples are expected to hold (samples/expected.json, private like the samples).
export const expectedPath = join(repo, 'samples', 'expected.json')
export const hasExpected = existsSync(expectedPath)
export const expected = <T = any>(sample: string): T => {
  const e = JSON.parse(readFileSync(expectedPath, 'utf8'))[sample]
  if (e === undefined) throw new Error(`no ${sample} in samples/expected.json`)
  return e
}
export const hasLibrary = existsSync(libraryPath)

export const bytes = (path: string) => new Uint8Array(readFileSync(path))
export const golden = <T = any>(rel: string): T => JSON.parse(readFileSync(join(goldenDir, rel), 'utf8'))
export const hex = (b: ArrayLike<number>) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')

// Editing-rules reference data (made by private tooling) and the catalog the web app uses. CATALOG_JSON points the
// tests at another catalog file, RULES_GOLDEN_DIR at another copy of the reference data, e.g. to check that a
// rewritten catalog behaves the same.
export const rulesGoldenDir = process.env.RULES_GOLDEN_DIR || join(goldenDir, 'rules')
export const hasRulesGolden = existsSync(join(rulesGoldenDir, 'catalog.json')) && hasSamples
export const catalogJSONPath = process.env.CATALOG_JSON || join(repo, 'web', 'src', 'data', 'catalog.json')
export const rulesGolden = <T = any>(rel: string): T => JSON.parse(readFileSync(join(rulesGoldenDir, rel), 'utf8'))
