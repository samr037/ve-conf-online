// Phones and tablets: no sideways page scroll, 44 × 44 px touch targets, every section reachable, Save within
// reach, dialogs on screen. Screenshots go to web/e2e/screenshots/responsive/ (not in Git).
//
// The editor tests need a configuration file without private data: VE_DEMO_FILE=/path/to/demo.rvsc.
// Without it only the open screen and the landing page are checked.
import { devices, expect, test, type Page } from '@playwright/test'
import { existsSync } from 'node:fs'
import { join } from 'node:path'

const demo = process.env.VE_DEMO_FILE
const hasDemo = !!demo && existsSync(demo)
const shot = (name: string) => join(import.meta.dirname, 'screenshots', 'responsive', `${name}.png`)

/** Device descriptors without their browser choice: the suite runs in the project's Chromium. */
function device(name: string, viewport?: { width: number; height: number }) {
  const { defaultBrowserType: _, ...d } = devices[name]!
  return viewport ? { ...d, viewport } : d
}

const targets = [
  { id: 'iphone13', use: device('iPhone 13'), phone: true },
  { id: 'iphone-se', use: device('iPhone SE (3rd gen)'), phone: true },
  { id: 'pixel7', use: device('Pixel 7'), phone: true },
  { id: 'phone-landscape', use: device('iPhone 13 landscape', { width: 844, height: 390 }), phone: false },
  { id: 'ipad', use: device('iPad (gen 7)'), phone: false },
  { id: 'ipad-landscape', use: device('iPad (gen 7) landscape'), phone: false },
]

const sectionTitles = ['General', 'Grid', 'Inverter', 'Charger', 'Virtual Switch', 'Assistants', 'Advanced']

/** The page is never wider than the screen (mobile browsers widen the layout viewport to fit overflowing content). */
async function expectNoSidewaysScroll(page: Page, where: string) {
  const width = page.viewportSize()!.width
  const m = await page.evaluate(() => ({ scroll: document.documentElement.scrollWidth, inner: window.innerWidth }))
  expect(m.inner, `${where}: layout viewport`).toBeLessThanOrEqual(width)
  expect(m.scroll, `${where}: page width`).toBeLessThanOrEqual(m.inner)
}

/**
 * Visible controls smaller than 44 × 44 px. Exceptions, as in WCAG 2.5.8: links inside running text, and
 * radio buttons or checkboxes whose label is the target (the label is measured instead).
 */
async function smallTargets(page: Page, scope = 'body'): Promise<string[]> {
  return page.evaluate((scope) => {
    const root = document.querySelector(scope) ?? document.body
    const out: string[] = []
    for (const el of root.querySelectorAll<HTMLElement>('button, a[href], select, input:not([type=hidden]), textarea, [role=button], [role=option], [role=menuitem]')) {
      if (el.closest('[aria-hidden="true"], .visually-hidden, [inert]')) continue
      const cs = getComputedStyle(el)
      if (cs.visibility === 'hidden') continue
      let r = el.getBoundingClientRect()
      if (r.width === 0 || r.height === 0) continue
      if (el.tagName === 'A' && cs.display === 'inline') continue
      if (el.matches('input[type=radio], input[type=checkbox]')) {
        const label = el.closest('label')
        if (label) r = label.getBoundingClientRect()
      }
      if (r.width < 43.5 || r.height < 43.5) {
        const name = el.getAttribute('aria-label') ?? el.textContent?.trim().slice(0, 30) ?? ''
        out.push(`${el.tagName.toLowerCase()}.${[...el.classList].join('.')} "${name}" ${Math.round(r.width)}×${Math.round(r.height)}`)
      }
    }
    return out
  }, scope)
}

/** The box is entirely on screen. */
async function expectOnScreen(page: Page, selector: string, what: string) {
  const vp = page.viewportSize()!
  await page.locator(selector).evaluate((e) => Promise.all(e.getAnimations({ subtree: true }).filter((a) => a.effect?.getComputedTiming().iterations !== Infinity).map((a) => a.finished)))
  const box = await page.locator(selector).boundingBox()
  expect(box, what).not.toBeNull()
  expect(box!.x, `${what} left`).toBeGreaterThanOrEqual(-0.5)
  expect(box!.y, `${what} top`).toBeGreaterThanOrEqual(-0.5)
  expect(box!.x + box!.width, `${what} right`).toBeLessThanOrEqual(vp.width + 0.5)
  expect(box!.y + box!.height, `${what} bottom`).toBeLessThanOrEqual(vp.height + 0.5)
}

const tab = (page: Page, title: string) => page.locator('nav .nav').filter({ has: page.locator('.nav-title', { hasText: new RegExp(`^${title}$`) }) })

async function openDemo(page: Page) {
  // The download path (Safari, Firefox and mobile browsers): Save asks for the name in a dialog.
  await page.addInitScript(() => { delete (window as { showSaveFilePicker?: unknown }).showSaveFilePicker })
  await page.goto('app.html')
  await page.locator('.welcome input[type=file]').setInputFiles(demo!)
  await expect(page.locator('.file-name')).toBeVisible()
  await page.evaluate(() => document.fonts.ready)
}

for (const target of targets) {
  test.describe(target.id, () => {
    test.use({ ...target.use, reducedMotion: 'reduce' })

    test('open screen: fits, touch targets', async ({ page }) => {
      await page.goto('app.html')
      await expect(page.locator('.welcome h1')).toBeVisible()
      expect(await page.evaluate(() => matchMedia('(pointer: coarse)').matches)).toBe(true)
      await expectNoSidewaysScroll(page, 'open screen')
      expect(await smallTargets(page)).toEqual([])
      await page.screenshot({ path: shot(`${target.id}-welcome`), fullPage: true })
      // The device dialog (Chromium only: Web Serial).
      const connect = page.getByRole('button', { name: /Connect a device/ })
      if (await connect.count()) {
        await connect.click()
        await expectOnScreen(page, 'dialog[open]', 'device dialog')
        await expectOnScreen(page, 'dialog[open] footer', 'device dialog buttons')
        expect(await smallTargets(page, 'dialog[open]')).toEqual([])
        await page.screenshot({ path: shot(`${target.id}-device`) })
      }
    })

    test('landing: fits, the drop block is the button', async ({ page }) => {
      await page.goto('index.html')
      await page.evaluate(() => document.fonts.ready)
      await expectNoSidewaysScroll(page, 'landing')
      expect(await smallTargets(page)).toEqual([])
      // The visible blue block is the drop button itself, not an empty shape above it.
      const drop = page.locator('.hero .drop')
      await expect(drop).toBeVisible()
      const wiring = page.locator('.hero svg.wiring:visible')
      await expect(wiring).toHaveCount(1)
      const [b, w] = [await drop.boundingBox(), await wiring.boundingBox()]
      expect(b!.y).toBeGreaterThan(w!.y)
      expect(b!.y + b!.height).toBeLessThan(w!.y + w!.height)
      expect(b!.height).toBeGreaterThanOrEqual(88)
      await page.screenshot({ path: shot(`${target.id}-landing`) })
    })

    test('editor: every section fits and is reachable', async ({ page }) => {
      test.skip(!hasDemo, 'set VE_DEMO_FILE to a configuration without private data')
      await openDemo(page)
      for (const title of sectionTitles) {
        const t = tab(page, title)
        await t.click()
        await expect(t).toHaveAttribute('aria-current', 'page')
        await expect(page.locator('.page h1')).toHaveText(title)
        // The current tab is shown in the strip, not clipped off its edge.
        await expect.poll(async () => {
          const [tb, nb] = [await t.boundingBox(), await page.locator('nav.sidebar').boundingBox()]
          return tb!.x >= nb!.x - 0.5 && tb!.x + tb!.width <= nb!.x + nb!.width + 0.5
        }, `${title} tab in view`).toBe(true)
        await expectNoSidewaysScroll(page, title)
        expect(await smallTargets(page), title).toEqual([])
      }
    })

    test('editor: overflow menu', async ({ page }) => {
      test.skip(!hasDemo, 'set VE_DEMO_FILE to a configuration without private data')
      test.skip(page.viewportSize()!.width > 860, 'wide enough for every action in the header')
      await openDemo(page)
      const more = page.getByRole('button', { name: 'More actions' })
      await expect(more).toBeVisible()
      await expect(page.locator('header.top').getByRole('button', { name: 'Export as text' })).toBeHidden()
      await more.click()
      await expect(more).toHaveAttribute('aria-expanded', 'true')
      const panel = page.locator('.more .panel')
      for (const name of ['Export as text', 'Print', 'Open another file…']) await expect(panel.getByRole('button', { name })).toBeVisible()
      if (target.phone) {
        await expect(panel.getByRole('button', { name: 'Save as…' })).toBeVisible()
        await expect(panel.getByLabel('Language')).toBeVisible()
      }
      await expectOnScreen(page, '.more .panel', 'menu')
      expect(await smallTargets(page, '.more .panel')).toEqual([])
      await page.screenshot({ path: shot(`${target.id}-menu`) })
      // Keyboard: arrows move, Escape closes and gives focus back.
      await page.keyboard.press('ArrowDown')
      await page.keyboard.press('Escape')
      await expect(panel).toHaveCount(0)
      await expect(more).toBeFocused()
      // A tap outside closes it.
      await more.click()
      await expect(panel).toBeVisible()
      await page.locator('.page h1').click()
      await expect(panel).toHaveCount(0)
      // An action runs from the menu.
      await more.click()
      const [download] = await Promise.all([page.waitForEvent('download'), panel.getByRole('button', { name: 'Export as text' }).click()])
      expect(download.suggestedFilename()).toMatch(/\.txt$/)
    })

    test('editor: edit with the touch stepper, save from the bar', async ({ page }) => {
      test.skip(!hasDemo, 'set VE_DEMO_FILE to a configuration without private data')
      await openDemo(page)
      await expect(page.locator('.savebar')).toHaveCount(0)
      await tab(page, 'Charger').click()
      const row = page.locator('[data-control]:has(input.field.value:not([disabled]))').first()
      const input = row.locator('input.field.value')
      await expect(input).toHaveAttribute('inputmode', 'decimal')
      expect(await input.evaluate((e) => parseFloat(getComputedStyle(e).fontSize))).toBeGreaterThanOrEqual(16)
      const before = await input.inputValue()
      await row.locator('.tstep').last().click()
      await expect(input).not.toHaveValue(before)
      await expect(page.locator('.changes li')).toHaveCount(1)

      const bar = page.locator('.savebar')
      if (page.viewportSize()!.width <= 1100) {
        await page.evaluate(() => window.scrollTo(0, 0))
        await expect(bar).toHaveClass(/shown/)
        await expectOnScreen(page, '.savebar', 'save bar')
        await expect(bar.locator('.savebar-n')).toHaveText('1')
        expect(await smallTargets(page, '.savebar')).toEqual([])
        // The page ends above the bar: the last control can be scrolled clear of it.
        await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight))
        await expect(bar).not.toHaveClass(/shown/)
        await page.evaluate(() => window.scrollTo(0, 0))
        await expect(bar).toHaveClass(/shown/)
        await page.screenshot({ path: shot(`${target.id}-savebar`) })
        await bar.getByRole('button', { name: 'Save as…' }).click()
      } else {
        await page.locator('.changes .save').click()
      }
      const dialog = page.locator('dialog', { has: page.getByLabel('File name') })
      await expect(dialog).toBeVisible()
      await expectOnScreen(page, 'dialog[open]', 'save dialog')
      await expectOnScreen(page, 'dialog[open] footer', 'save dialog buttons')
      expect(await dialog.getByLabel('File name').evaluate((e) => parseFloat(getComputedStyle(e).fontSize))).toBeGreaterThanOrEqual(16)
      await page.screenshot({ path: shot(`${target.id}-save-dialog`) })
      const [download] = await Promise.all([page.waitForEvent('download'), dialog.getByRole('button', { name: 'Save', exact: true }).click()])
      expect(download.suggestedFilename()).toMatch(/\.rvsc$/)
    })

    test('editor: dialogs stay on screen', async ({ page }) => {
      test.skip(!hasDemo, 'set VE_DEMO_FILE to a configuration without private data')
      await openDemo(page)

      // Battery presets.
      await tab(page, 'Charger').click()
      await page.getByRole('button', { name: 'Battery Presets…' }).click()
      await expect(page.locator('dialog[open]')).toBeVisible()
      await expectOnScreen(page, 'dialog[open]', 'presets')
      await expectOnScreen(page, 'dialog[open] footer', 'presets buttons')
      expect(await smallTargets(page, 'dialog[open]')).toEqual([])
      await page.screenshot({ path: shot(`${target.id}-presets`) })
      await page.locator('dialog[open]').getByRole('button', { name: 'Cancel' }).click()

      // Grid code password.
      await tab(page, 'Grid').click()
      const unlock = page.getByRole('button', { name: 'Unlock grid settings…' })
      if (await unlock.isEnabled()) {
        await unlock.click()
        await expectOnScreen(page, 'dialog[open]', 'password')
        await expectOnScreen(page, 'dialog[open] footer', 'password buttons')
        expect(await page.locator('dialog[open] input[type=password]').evaluate((e) => parseFloat(getComputedStyle(e).fontSize))).toBeGreaterThanOrEqual(16)
        await page.screenshot({ path: shot(`${target.id}-password`) })
        await page.locator('dialog[open]').getByRole('button', { name: 'Cancel' }).click()
      }

      // The Assistant wizard.
      await tab(page, 'Assistants').click()
      // An installed assistant opens on a real step; adding one may stop at a firmware message.
      const configure = page.getByRole('button', { name: 'Configure…' }).first()
      if (await configure.count()) await configure.click()
      else {
        await page.getByRole('button', { name: 'Add Assistant…' }).click()
        await page.locator('.menu.wide [role=menuitem]').first().click()
      }
      const wizard = page.locator('dialog[open]')
      await expect(wizard.getByRole('button', { name: 'Next' })).toBeVisible()
      await expectOnScreen(page, 'dialog[open]', 'wizard')
      await expectOnScreen(page, 'dialog[open] footer', 'wizard buttons')
      for (const name of ['Cancel', 'Previous', 'Next']) {
        const b = await wizard.getByRole('button', { name, exact: true }).boundingBox()
        expect(b!.height, name).toBeGreaterThanOrEqual(43.5)
      }
      expect(await smallTargets(page, 'dialog[open]')).toEqual([])
      await page.screenshot({ path: shot(`${target.id}-wizard`) })
      await wizard.getByRole('button', { name: 'Cancel', exact: true }).click()
    })
  })
}

// Light and dark screenshots of the main screens for review.
for (const scheme of ['light', 'dark'] as const) {
  for (const target of targets.filter((t) => ['iphone13', 'ipad', 'phone-landscape'].includes(t.id))) {
    test(`${target.id} screenshots ${scheme}`, async ({ browser }) => {
      test.skip(!hasDemo, 'set VE_DEMO_FILE to a configuration without private data')
      const context = await browser.newContext({ ...target.use, colorScheme: scheme, reducedMotion: 'reduce', baseURL: 'http://127.0.0.1:5179/', locale: 'en-US' })
      const page = await context.newPage()
      const name = (s: string) => shot(`${target.id}-${s}-${scheme}`)
      await page.goto('index.html')
      await page.evaluate(() => document.fonts.ready)
      await page.screenshot({ path: name('landing') })
      await openDemo(page)
      await page.screenshot({ path: name('general') })
      await tab(page, 'Charger').click()
      const row = page.locator('[data-control]:has(input.field.value:not([disabled]))').first()
      await row.locator('.tstep').last().click()
      await page.evaluate(() => window.scrollTo(0, 0))
      await page.screenshot({ path: name('charger') })
      await row.locator('.info button').click()
      await page.screenshot({ path: name('info') })
      await page.keyboard.press('Escape')
      await tab(page, 'Advanced').click()
      await page.screenshot({ path: name('advanced') })
      await context.close()
    })
  }
}
