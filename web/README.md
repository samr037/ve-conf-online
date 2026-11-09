# Shunt web app — developer notes

What Shunt is and how to use or self-host it: see the [project README](../README.md).

This folder is the browser version: a landing page (`index.html`) and the editor (`app.html`), built with Vite, Svelte 5 and TypeScript. The engine in `src/lib/engine/` is a TypeScript port of the Swift engine (`Sources/VEKit`), checked against it byte for byte (`test/`). The editing rules in `src/lib/rules/` are checked against reference data made by private tooling.

## Develop

```sh
npm ci
npm run dev            # http://localhost:5173
npx vitest run         # unit tests
npx playwright test    # browser tests (Chromium)
npm run check          # svelte-check and TypeScript
npm run build          # static site in dist/
```

Tests that need the private device samples or the golden reference data are skipped when they are absent.

## Reference data

The golden files in `fixtures/golden/` (git-ignored) are reference data. The engine's come from the Swift code, from the repository root:

```sh
swift run vegolden web/fixtures/golden
```

The editing-rules reference (`fixtures/golden/rules/`) comes from private tooling. Both need private device files that are never committed; the tests that use them skip without them.

## Layout

| Path | What |
|---|---|
| `src/lib/engine` | `.rvsc` / `.vfp` formats, VLL assembler, composer, wizard |
| `src/lib/rules` | Catalog, rule engine, value codecs, `ConfigDocument` |
| `src/lib/device` | MK3-USB over Web Serial, read-only draft ([notes](docs/mk3-webserial.md)) |
| `src/app` | Editor UI |
| `src/landing` | Landing page |
| `src/data` | Catalog, translations, the Assistant library shipped with the site |
| `src/lib/brand.ts` | Product name, repository and image names |
| `e2e` | Playwright tests and screenshot scripts |

## Container

```sh
docker build -t shunt .
docker run --rm -p 8080:8080 --read-only --tmpfs /tmp shunt
```

nginx without root on port 8080, `GET /healthz`, strict Content Security Policy, self-hosted fonts. `compose.yaml` sets the same options. Images for amd64 and arm64 are built by `.github/workflows/web-image.yml` on GitHub.
