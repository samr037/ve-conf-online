// "Connect a device" (read-only beta) against a fake navigator.serial backed by the device simulator
// (src/lib/device/simulator.ts, loaded from the Vite dev server inside the page).
import { expect, test, type Page } from '@playwright/test'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { assertReadOnlyFrame } from '../src/lib/device/guard'
import { deviceFromConfiguration, syntheticDevice, type SimulatedDevice } from '../src/lib/device/simulator'
import { DeviceConfiguration } from '../src/lib/engine/deviceConfiguration'

const repo = join(import.meta.dirname, '..', '..')
const samplePath = (n: string) => join(repo, 'samples', `${n}.rvsc`)
const shots = (name: string) => join(import.meta.dirname, 'screenshots', `${name}.png`)

/** Installs a fake Web Serial API whose only port is an MK3-USB in front of `device`. Replies come after `delayMs`. */
async function fakeSerial(page: Page, device: SimulatedDevice, delayMs = 4) {
  await page.addInitScript(({ device, delayMs }) => {
    const written: number[][] = []
    ;(window as unknown as { __written: number[][] }).__written = written
    class FakePort extends EventTarget {
      readable: ReadableStream<Uint8Array> | null = null
      writable: WritableStream<Uint8Array> | null = null
      getInfo() { return { usbVendorId: 0x0403, usbProductId: 0x6015 } }
      async setSignals() {}
      async open() {
        const sim = await import('/src/lib/device/simulator.ts' as string)
        const respond = sim.deviceResponder(device)
        let push: (b: Uint8Array) => void = () => {}
        this.readable = new ReadableStream<Uint8Array>({ start(c) { push = (b) => c.enqueue(b) } })
        this.writable = new WritableStream<Uint8Array>({
          write(chunk) {
            written.push(Array.from(chunk))
            const replies = respond(chunk) as Uint8Array[] | undefined
            if (replies) setTimeout(() => replies.forEach((r) => push(r)), delayMs)
          },
        })
      }
      async close() {}
    }
    const port = new FakePort()
    class FakeSerial extends EventTarget {
      async requestPort() { return port }
      async getPorts() { return [port] }
    }
    Object.defineProperty(Navigator.prototype, 'serial', { configurable: true, get: () => serial })
    const serial = new FakeSerial()
  }, { device: JSON.parse(JSON.stringify(device)) as SimulatedDevice, delayMs })
}

async function section(page: Page, title: string) {
  await page.locator('nav .nav').filter({ has: page.locator('.nav-title', { hasText: new RegExp(`^${title}$`) }) }).click()
  await page.mouse.move(0, 0)
}

async function connect(page: Page, screenshot?: string) {
  await page.goto('app.html')
  await page.getByRole('button', { name: /Connect a device/ }).click()
  const dialog = page.locator('dialog')
  await expect(dialog.getByRole('heading', { name: 'Connect a device' })).toBeVisible()
  if (screenshot) await page.screenshot({ path: shots(`${screenshot}-intro`) })
  await dialog.getByRole('button', { name: 'Choose the port…' }).click()
  const bar = dialog.getByRole('progressbar')
  await expect(bar).toBeVisible({ timeout: 15_000 })
  await expect.poll(async () => Number(await bar.getAttribute('aria-valuenow')), { timeout: 15_000 }).toBeGreaterThan(20)
  if (screenshot) await page.screenshot({ path: shots(`${screenshot}-reading`) })
  await expect(page.locator('.device-banner')).toBeVisible({ timeout: 60_000 })
}

test('the action is hidden without Web Serial', async ({ page }) => {
  await page.addInitScript(() => Object.defineProperty(Navigator.prototype, 'serial', { configurable: true, get: () => undefined }))
  await page.goto('app.html')
  await expect(page.locator('.welcome h1')).toBeVisible()
  await expect(page.getByRole('button', { name: /Connect a device/ })).toHaveCount(0)
  await expect(page.getByText(/Connect a device|Beta/)).toHaveCount(0)
})

test('read a synthetic device: read-only editor, values from the device, only read commands sent', async ({ page }) => {
  const device = syntheticDevice()
  await fakeSerial(page, device)
  await connect(page)

  await expect(page.locator('.device-banner')).toContainText('MK3-USB')
  await expect(page.locator('.device-banner')).toContainText('Read-only beta')
  await expect(page.locator('.file-name')).toHaveText('MK3-USB')
  await expect(page.locator('header.top').getByRole('button', { name: 'Save as…' })).toBeDisabled()
  await expect(page.locator('.changes .save')).toBeDisabled()

  await section(page, 'Charger')
  const absorption = page.locator('[data-control] input.field.value').filter({ hasText: '' })
  const values = await absorption.evaluateAll((els) => els.map((e) => (e as HTMLInputElement).value))
  expect(values).toContain('56.40')
  expect(values).toContain('54.00')
  // Every input of the page is disabled.
  expect(await page.locator('.page-col input:not([type=hidden]):not([disabled]), .page-col select:not([disabled])').count()).toBe(0)

  await section(page, 'Assistants')
  await expect(page.getByText('The assistant program cannot be read over the interface yet.')).toBeVisible()

  const written = await page.evaluate(() => (window as unknown as { __written: number[][] }).__written)
  expect(written.length).toBeGreaterThan(192)
  for (const f of written) assertReadOnlyFrame(Uint8Array.from(f))

  // A reload goes back to the open screen: device documents are not kept.
  await page.reload()
  await expect(page.locator('.welcome h1')).toBeVisible()
  await expect(page.locator('.device-banner')).toHaveCount(0)
})

test('reading the private sample device shows the same values as the file', async ({ page }) => {
  test.skip(!existsSync(samplePath('s5')), 'needs the private sample files')
  const c = DeviceConfiguration.parse(new Uint8Array(readFileSync(samplePath('s5'))))
  await fakeSerial(page, deviceFromConfiguration(c), 1)
  await connect(page)
  await section(page, 'Charger')
  const values = await page.locator('[data-control] input.field.value').evaluateAll((els) => els.map((e) => (e as HTMLInputElement).value))
  expect(values).toContain(c.value(2)!.toFixed(2))
  expect(values).toContain(c.value(3)!.toFixed(2))
})

for (const scheme of ['light', 'dark'] as const) {
  test(`device screenshots ${scheme}`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: scheme })
    await fakeSerial(page, syntheticDevice(), 12)
    await connect(page, `device-${scheme}`)
    await page.screenshot({ path: shots(`device-general-${scheme}`) })
    await section(page, 'Charger')
    await page.screenshot({ path: shots(`device-charger-${scheme}`) })
  })
}

test('landing page: the device link opens the editor with the connect dialog', async ({ page }) => {
  await fakeSerial(page, syntheticDevice())
  await page.goto('index.html')
  const link = page.getByRole('link', { name: /connect a device/i })
  await expect(link).toBeVisible()
  await link.click()
  await expect(page.locator('dialog').getByRole('heading', { name: 'Connect a device' })).toBeVisible()
  await expect(page).toHaveURL(/app\.html$/)
})

test('landing page: no device link without Web Serial', async ({ page }) => {
  await page.addInitScript(() => Object.defineProperty(Navigator.prototype, 'serial', { configurable: true, get: () => undefined }))
  await page.goto('index.html')
  await expect(page.locator('h1')).toBeVisible()
  await expect(page.getByRole('link', { name: /connect a device/i })).toHaveCount(0)
})
