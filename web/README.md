# Web app

The browser version: a landing page (`index.html`) and the editor (`app.html`), built with Vite, Svelte 5 and TypeScript. The engine in `src/lib/engine/` and the editing rules in `src/lib/rules/` are a TypeScript port of the Swift code, checked against it byte for byte (`test/`).

## Develop

```sh
npm ci
npm run dev          # http://localhost:5173
npx vitest run       # tests; those needing the private samples or the Assistant library skip without them
npm run check        # svelte-check and TypeScript
npm run build        # static site in dist/
```

Reference data for the tests comes from the Swift code: `swift run vegolden web/fixtures/golden` from the repository root (needs `samples/` and `vendor/`).

## Self-hosting

The site is static: one container, nginx without root, port 8080, no backend.

```sh
docker build -t ve-configure web/
docker run --rm -p 8080:8080 ve-configure
```

Or with Compose, from `web/`:

```sh
docker compose up -d
```

- **Port:** 8080 inside the container. Map it to any host port.
- **Health check:** `GET /healthz` returns `ok`. The image declares a Docker `HEALTHCHECK` on it.
- **Read-only:** the container runs with `--read-only` and a tmpfs on `/tmp` (the Compose file sets both).
- **Headers:** a strict Content Security Policy allows only the site's own origin; fonts are self-hosted.
- **Sub-path:** links are relative, so the site also works behind a reverse proxy under a sub-path.

Images for amd64 and arm64 are built by `.github/workflows/web-image.yml` and pushed to `ghcr.io/<owner>/<repo>-web` on pushes to `main` and on version tags.
