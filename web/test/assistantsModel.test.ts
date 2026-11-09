// The editor's assistants model: a library swap while a wizard is open must not drop the wizard's answers.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { AssistantsModel } from '../src/app/assistants'
import { MetaGenerator } from '../src/lib/engine/assembler'
import { AssistantLibrary } from '../src/lib/engine/assistantPackage'
import { ConfigDocument, buildCatalog, configureL10n, useCatalog } from '../src/lib/rules'
import { bytes, hasLibrary, libraryPath, samplePath } from './fixtures'
import { existsSync } from 'node:fs'

const hasS2 = existsSync(samplePath('s2'))

describe.runIf(hasLibrary && hasS2)('AssistantsModel', () => {
  useCatalog(buildCatalog(JSON.parse(readFileSync(join(import.meta.dirname, '..', 'src', 'data', 'catalog.json'), 'utf8'))))
  configureL10n({ language: 'en', locale: 'en-US' })
  const lib = AssistantLibrary.parse(bytes(libraryPath))

  function walk(swapMidway: boolean) {
    const doc = ConfigDocument.open(bytes(samplePath('s2')), 's2.rvsc', { ratings: MetaGenerator.ratings })
    const model = new AssistantsModel(doc, lib, ['en'])
    const ess = model.installed.findIndex((i) => i.package.baseName === 'ESS')
    const session = model.wizard(ess)!
    let steps = 0
    while (!session.finished && session.canGoForward && steps < 300) {
      if (session.step?.step.id === 'aidCapacity') session.texts[0] = '200'
      if (steps === 1 && swapMidway) model.setLibrary(AssistantLibrary.parse(bytes(libraryPath)))
      expect(session.next()).toBe(true)
      steps++
    }
    expect(session.finished).toBe(true)
    return { doc, model }
  }

  it('keeps the answers when the library is replaced during the wizard', () => {
    const plain = walk(false)
    const swapped = walk(true)
    expect(plain.doc.changes.length).toBeGreaterThan(0)
    expect(swapped.model.message).toBe(plain.model.message)
    expect(swapped.doc.changes.map((c) => c.label)).toEqual(plain.doc.changes.map((c) => c.label))
    expect(swapped.doc.config.encoded()).toEqual(plain.doc.config.encoded())
    expect(swapped.model.status.k).toBe('ready')
  })
})
