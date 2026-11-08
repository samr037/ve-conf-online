// Screenshots of the main screens in light and dark, for visual review (web/e2e/screenshots/, not in Git).
import { expect, test, type Page } from '@playwright/test'
import { existsSync } from 'node:fs'
import { join } from 'node:path'

const repo = join(import.meta.dirname, '..', '..')
const sample = (n: string) => join(repo, 'samples', `${n}.rvsc`)
const libraryPath = join(repo, 'vendor', 'extracted', 'VE Configure tools', 'Assistants', 'all112.vfp')
const out = (name: string) => join(import.meta.dirname, 'screenshots', `${name}.png`)

async function open(page: Page, n: string) {
  await page.goto('app.html')
  await page.locator('.welcome input[type=file]').setInputFiles(sample(n))
  await expect(page.locator('.file-name')).toBeVisible()
}

async function section(page: Page, title: string) {
  await page.locator('nav .nav').filter({ has: page.locator('.nav-title', { hasText: new RegExp(`^${title}$`) }) }).click()
  await page.mouse.move(0, 0)
}

for (const scheme of ['light', 'dark'] as const) {
  test.describe(scheme, () => {
    test.use({ colorScheme: scheme })

    test(`welcome ${scheme}`, async ({ page }) => {
      await page.goto('app.html')
      await expect(page.locator('.welcome h1')).toBeVisible()
      await page.screenshot({ path: out(`welcome-${scheme}`) })
    })

    test(`editor ${scheme}`, async ({ page }) => {
      test.skip(!existsSync(sample('s5')), 'needs samples/s5.rvsc')
      await open(page, 's5')
      await page.screenshot({ path: out(`general-${scheme}`) })
      await section(page, 'Charger')
      const row = page.locator('[data-control]:has(input.field.value:not([disabled]))').first()
      await row.locator('input.field.value').focus()
      await row.locator('input.field.value').press('ArrowUp')
      await row.locator('input.field.value').press('ArrowUp')
      await page.locator('h1').first().click()
      await page.mouse.move(0, 0)
      await page.screenshot({ path: out(`charger-${scheme}`) })
      await page.screenshot({ path: out(`charger-full-${scheme}`), fullPage: true })
      await section(page, 'Grid')
      await page.screenshot({ path: out(`grid-${scheme}`) })
      await section(page, 'Virtual Switch')
      await page.screenshot({ path: out(`virtualSwitch-${scheme}`) })
      await section(page, 'Inverter')
      await page.screenshot({ path: out(`inverter-${scheme}`) })
      await section(page, 'Assistants')
      await page.screenshot({ path: out(`assistants-nolib-${scheme}`) })
      if (existsSync(libraryPath)) {
        await page.locator('.page input[type=file]').setInputFiles(libraryPath)
        await expect(page.locator('.assistant').first()).toBeVisible()
        await page.screenshot({ path: out(`assistants-${scheme}`) })
        await page.getByRole('button', { name: 'Configure…' }).first().click()
        await expect(page.locator('dialog')).toBeVisible()
        await page.locator('dialog').getByRole('button', { name: 'Next' }).click()
        await page.screenshot({ path: out(`wizard-${scheme}`) })
        await page.locator('dialog').getByRole('button', { name: 'Cancel' }).click()
      }
      await section(page, 'Charger')
      await page.getByRole('button', { name: 'Battery Presets…' }).click()
      await page.screenshot({ path: out(`presets-${scheme}`) })
      await page.keyboard.press('Escape')
      await section(page, 'Grid')
      const unlock = page.getByRole('button', { name: 'Unlock grid settings…' })
      if (await unlock.count()) {
        await unlock.click()
        await page.screenshot({ path: out(`password-${scheme}`) })
        await page.keyboard.press('Escape')
      }
    })
  })
}

test('french', async ({ page }) => {
  test.skip(!existsSync(sample('s5')), 'needs samples/s5.rvsc')
  await open(page, 's5')
  await page.getByLabel('Language').selectOption('fr')
  await page.locator('nav .nav').nth(3).click()
  await page.mouse.move(0, 0)
  await page.screenshot({ path: out('charger-fr-light') })
  await page.getByLabel('Langue').selectOption('en')
})

test('tablet and phone widths', async ({ page }) => {
  test.skip(!existsSync(sample('s5')), 'needs samples/s5.rvsc')
  await page.setViewportSize({ width: 900, height: 1100 })
  await open(page, 's5')
  await section(page, 'Charger')
  await page.screenshot({ path: out('tablet-light') })
  await page.setViewportSize({ width: 390, height: 844 })
  await page.screenshot({ path: out('phone-light') })
})
