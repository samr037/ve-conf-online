// Paths to the private reference material. Tests that need it skip on a clean clone.
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

export const repo = join(import.meta.dirname, '..', '..')
export const goldenDir = join(repo, 'web', 'fixtures', 'golden')
export const libraryPath = join(repo, 'vendor', 'extracted', 'VE Configure tools', 'Assistants', 'all112.vfp')
export const samplePath = (name: string) => join(repo, 'samples', `${name}.rvsc`)
export const samples = ['s1', 's2', 's3', 's4', 's5']

export const hasGolden = existsSync(join(goldenDir, 'library.json'))
export const hasLibrary = existsSync(libraryPath)

export const bytes = (path: string) => new Uint8Array(readFileSync(path))
export const golden = <T = any>(rel: string): T => JSON.parse(readFileSync(join(goldenDir, rel), 'utf8'))
export const hex = (b: ArrayLike<number>) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')

// Editing-rules reference (Tests/VEConfigureTests/RulesGoldenExport.swift) and the app catalog it was made with.
export const rulesGoldenDir = join(goldenDir, 'rules')
export const hasRulesGolden = existsSync(join(rulesGoldenDir, 'catalog.json'))
export const catalogJSONPath = join(repo, 'Sources', 'VEConfigure', 'Resources', 'catalog.json')
export const rulesGolden = <T = any>(rel: string): T => JSON.parse(readFileSync(join(rulesGoldenDir, rel), 'utf8'))
