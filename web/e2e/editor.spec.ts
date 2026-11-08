// End-to-end: the editor in a real browser against the TypeScript engine run here in Node.
// Each saved file must be byte for byte what the engine produces for the same edits.
import { expect, test, type Page } from '@playwright/test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { AssistantLibrary } from '../src/lib/engine/assistantPackage'
import { ConfigDocument, buildCatalog, catalog, configureL10n, useCatalog } from '../src/lib/rules'
import { MetaGenerator } from '../src/lib/engine/assembler'
import { AssistantsModel } from '../src/app/assistants'

const repo = join(import.meta.dirname, '..', '..')
const samplePath = (n: string) => join(repo, 'samples', `${n}.rvsc`)
const libraryPath = join(repo, 'vendor', 'extracted', 'VE Configure tools', 'Assistants', 'all112.vfp')
const samples = ['s1', 's2', 's3', 's4', 's5'].filter((n) => existsSync(samplePath(n)))

useCatalog(buildCatalog(JSON.parse(readFileSync(join(import.meta.dirname, '..', 'src', 'data', 'catalog.json'), 'utf8'))))
configureL10n({ language: 'en', locale: 'en-US' })

const hex = (b: Uint8Array) => Buffer.from(b).toString('hex')

async function open(page: Page, name: string) {
  await page.goto('app.html')
  await page.locator('.welcome input[type=file]').setInputFiles(samplePath(name))
  await expect(page.locator('.file-name')).toHaveText(`${name}.rvsc`)
}

async function saveBytes(page: Page): Promise<Uint8Array> {
  const [download] = await Promise.all([page.waitForEvent('download'), page.locator('.changes .save').click()])
  const path = await download.path()
  return new Uint8Array(readFileSync(path))
}

for (const name of samples) {
  test(`${name}: step a setting, undo, redo, save`, async ({ page }) => {
    await open(page, name)
    await page.locator('nav .nav').filter({ has: page.locator('.nav-title', { hasText: /^Charger$/ }) }).click()
    // First editable numeric row on the page.
    const row = page.locator('[data-control]:has(input.field.value:not([disabled]))').first()
    const control = await row.getAttribute('data-control')
    expect(control).toBeTruthy()
    const input = row.locator('input.field.value')
    await input.focus()
    await input.press('ArrowUp')
    await expect(page.locator('.changes li')).toHaveCount(1)

    // The same edit through the engine.
    const doc = ConfigDocument.open(new Uint8Array(readFileSync(samplePath(name))), `${name}.rvsc`, { ratings: MetaGenerator.ratings })
    const ctl = catalog().controls.get(control!)!
    expect(doc.step(ctl, 1, 'x')).toBe(true)
    expect(doc.changes.length).toBe(1)

    await page.locator('h1').first().click()
    await page.keyboard.press('ControlOrMeta+z')
    await expect(page.locator('.changes li')).toHaveCount(0)
    await page.keyboard.press('ControlOrMeta+Shift+z')
    await expect(page.locator('.changes li')).toHaveCount(1)

    const saved = await saveBytes(page)
    expect(hex(saved)).toBe(hex(doc.save()))
    await expect(page.locator('.toast')).toContainText(`${name}-edited.rvsc`)
  })
}

// The wizard as a user drives it: Next only while the step offers it. On a file without a grid code ESS stops at
// its "country/grid code not selected" step (Cancel only), so the test picks a sample where it runs to the end.
function walkInNode(name: string, lib: AssistantLibrary, ess: AssistantLibrary['packages'][number]) {
  const doc = ConfigDocument.open(new Uint8Array(readFileSync(samplePath(name))), `${name}.rvsc`, { ratings: MetaGenerator.ratings })
  const model = new AssistantsModel(doc, lib, ['en', 'en'])
  const installed = model.installed.findIndex((i) => i.package.baseName === 'ESS')
  const session = installed >= 0 ? model.wizard(installed) : model.wizard(undefined, ess)
  if (!session) return undefined
  let steps = 0
  let capacityStep: number | undefined
  while (!session.finished && session.canGoForward && steps < 300) {
    if (session.step?.step.id === 'aidCapacity') { capacityStep = steps; session.texts[0] = '200' }
    if (!session.next()) return undefined
    steps++
  }
  if (!session.finished) return undefined
  return { doc, model, steps, capacityStep, configure: installed >= 0, title: installed >= 0 ? model.installed[installed]!.title : model.available.find((a) => a.package === ess)!.title }
}

test('ESS through the wizard, save', async ({ page }) => {
  test.skip(!existsSync(libraryPath), 'needs the vendor library')
  const lib = AssistantLibrary.parse(new Uint8Array(readFileSync(libraryPath)))
  const ess = lib.latest.find((p) => p.baseName === 'ESS')!
  const name = samples.find((n) => walkInNode(n, lib, ess) !== undefined)
  test.skip(!name, 'no sample where ESS runs to the end')
  const run = walkInNode(name!, lib, ess)!
  console.log(`ESS on ${name}: ${run.configure ? 'configure' : 'add'}, ${run.steps} steps, ${run.doc.changes.length} changes`)

  await open(page, name!)
  await page.locator('nav .nav').filter({ has: page.locator('.nav-title', { hasText: /^Assistants$/ }) }).click()
  // The library ships with the site: no import step.
  await expect(page.getByRole('button', { name: 'Choose the library…' })).toHaveCount(0)
  if (run.configure) {
    await page.locator('.assistant', { hasText: run.title }).getByRole('button', { name: 'Configure…' }).click()
  } else {
    await page.getByRole('button', { name: 'Add Assistant…' }).click()
    await page.getByRole('menuitem', { name: new RegExp(`^${run.title.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`) }).click()
  }
  for (let i = 0; i < run.steps; i++) {
    if (i === run.capacityStep) await page.locator('dialog input.field').first().fill('200')
    await page.locator('dialog').getByRole('button', { name: 'Next' }).click()
  }
  // Messages from the assistant sources (as in the Mac app) come as plain dialogs: acknowledge them.
  while (await page.locator('dialog').getByRole('button', { name: 'OK' }).count()) {
    await page.locator('dialog').getByRole('button', { name: 'OK' }).click()
  }
  await expect(page.locator('dialog')).toHaveCount(0, { timeout: 10_000 })
  await expect(page.locator('.assistant h3')).toContainText([run.title])
  expect(run.doc.changes.length).toBeGreaterThan(0)
  await expect(page.locator('.changes li')).toHaveCount(run.doc.changes.length)
  const saved = await saveBytes(page)
  expect(hex(saved)).toBe(hex(run.doc.save()))
})

test('a reload brings back the file, the edits, the tab and undo', async ({ page }) => {
  const name = samples.at(-1)
  test.skip(!name, 'needs a private sample')
  await open(page, name!)
  await page.locator('nav .nav').filter({ has: page.locator('.nav-title', { hasText: /^Charger$/ }) }).click()
  const input = page.locator('[data-control]:has(input.field.value:not([disabled]))').first().locator('input.field.value')
  await input.focus()
  await input.press('ArrowUp')
  await expect(page.locator('.changes li')).toHaveCount(1)
  const before = (await page.locator('.changes li').first().innerText()).replace(/\s+/g, ' ').trim()

  await page.reload()
  await expect(page.locator('.file-name')).toHaveText(`${name}.rvsc`, { timeout: 15_000 })
  await expect(page.locator('h1').first()).toHaveText('Charger')
  await expect(page.locator('.changes li')).toHaveCount(1)
  expect((await page.locator('.changes li').first().innerText()).replace(/\s+/g, ' ').trim()).toBe(before)

  await page.locator('h1').first().click()
  await page.keyboard.press('ControlOrMeta+z')
  await expect(page.locator('.changes li')).toHaveCount(0)
  await page.keyboard.press('ControlOrMeta+Shift+z')
  await expect(page.locator('.changes li')).toHaveCount(1)
})
