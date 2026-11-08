// Screenshots of the landing page at desktop and phone widths, light and dark.
//   npx vite build && npx vite preview --port 4173 &  node e2e/landing-shots.mjs
import { chromium } from '@playwright/test'
import { mkdirSync } from 'node:fs'

const base = process.env.BASE ?? 'http://127.0.0.1:4173/'
const out = new URL('./screenshots/', import.meta.url).pathname
mkdirSync(out, { recursive: true })
const browser = await chromium.launch()
for (const scheme of ['light', 'dark']) {
  for (const [w, h] of [[1440, 900], [390, 844]]) {
    const page = await browser.newPage({ viewport: { width: w, height: h }, colorScheme: scheme, reducedMotion: 'reduce' })
    await page.goto(base, { waitUntil: 'networkidle' })
    await page.evaluate(() => document.fonts.ready)
    await page.screenshot({ path: `${out}landing-${w}-${scheme}.png`, fullPage: true })
    await page.screenshot({ path: `${out}landing-${w}-${scheme}-fold.png` })
    await page.close()
  }
}
// Open Graph image: the hero at 1200×630, light.
{
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1, colorScheme: 'light', reducedMotion: 'reduce' })
  await page.goto(base, { waitUntil: 'networkidle' })
  await page.evaluate(() => document.fonts.ready)
  await page.evaluate(() => { document.querySelector('header')?.remove(); document.querySelector('.actions')?.remove(); document.querySelector('.lead')?.remove() })
  await page.screenshot({ path: `${out}og.png` })
  await page.close()
}
await browser.close()
console.log('screenshots in', out)
