<p align="center">
  <b>English</b> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a>
</p>

<h1 align="center">Shunt</h1>

<p align="center">
  Configure Victron Energy VE.Bus inverter/chargers from any computer.<br>
  MultiPlus, MultiPlus-II and Quattro, in the browser.
</p>

<p align="center">
  <a href="https://samr037.github.io/ve-conf-online/"><img alt="Open Shunt" src="https://img.shields.io/badge/open-Shunt-1B5FAA?style=flat"></a>
  <a href="https://github.com/samr037/ve-conf-online/pkgs/container/ve-conf-online"><img alt="Docker image" src="https://img.shields.io/badge/docker-ghcr.io%2Fsamr037%2Fve--conf--online-2496ED?logo=docker&logoColor=white"></a>
  <a href="LICENSE"><img alt="Licence" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <br>
  <a href="https://github.com/samr037/ve-conf-online/actions/workflows/pages.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/samr037/ve-conf-online/pages.yml?branch=main&label=build"></a>
  <a href="https://github.com/samr037/ve-conf-online/actions/workflows/swift.yml"><img alt="Swift engine" src="https://img.shields.io/github/actions/workflow/status/samr037/ve-conf-online/swift.yml?branch=main&label=swift%20engine&logo=swift&logoColor=white"></a>
  <a href="https://github.com/samr037/ve-conf-online/actions/workflows/codeql.yml"><img alt="CodeQL" src="https://img.shields.io/github/actions/workflow/status/samr037/ve-conf-online/codeql.yml?branch=main&label=CodeQL&logo=github"></a>
  <a href="https://github.com/samr037/ve-conf-online/security"><img alt="Dependabot" src="https://img.shields.io/badge/dependabot-enabled-025E8C?logo=dependabot&logoColor=white"></a>
  <br>
  <img alt="Languages" src="https://img.shields.io/badge/languages-EN%20%C2%B7%20FR%20%C2%B7%20DE%20%C2%B7%20ES-6E40C9">
  <img alt="MK3 / MK2" src="https://img.shields.io/badge/MK3%20%2F%20MK2-beta%2C%20read--only-B4531F">
</p>

<p align="center">
  <a href="https://samr037.github.io/ve-conf-online/"><b>Open Shunt</b></a>
</p>

<p align="center">
  <img src="docs/images/web/charger-light.png" width="900" alt="The Charger tab with one changed value in the change list">
</p>

Shunt opens the configuration file you download from VRM (Remote VE Configure, `.rvsc`). You change the settings VE Configure exposes, run the Assistants, review every change, and save a new file that you upload through VRM.

## What it does

- **All seven tabs:** General, Grid, Inverter, Charger, Virtual switch, Assistants, Advanced, with VE Configure's ranges, dependency rules, battery presets and confirmations.
- **Assistants, byte for byte:** ESS, generator start/stop, programmable relay and the others are assembled from Victron's own sources. The program written to your file matches VE Configure's, checksum included. Assistants already in a file are read back with their answers.
- **Grid codes:** protected settings unlock with the grid code password. Range and trip-level checks still apply.
- **Change list:** every difference from the loaded file, old → new, with undo, redo, restore one item or restore all.
- **Four languages:** English, French, German and Spanish, in Victron's vocabulary.
- **Light and dark.**
- **Picks up where you left off:** the open file, its changes and the undo history are still there after a page reload.

<table>
  <tr>
    <td width="50%"><img src="docs/images/web/assistants-wizard-light.png" alt="The ESS wizard with Victron's step text"><br><sub>The ESS wizard, with Victron's step texts.</sub></td>
    <td width="50%"><img src="docs/images/web/general-dark.png" alt="The General tab in dark mode"><br><sub>General tab, dark mode.</sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/web/charger-fr-light.png" alt="The Charger tab in French"><br><sub>The Charger tab in French.</sub></td>
    <td><img src="docs/images/web/landing-light.png" alt="The landing page"><br><sub>Drop a file on the inverter to open it.</sub></td>
  </tr>
</table>

## How it works with VRM

1. On VRM, open the installation, then **Device list › Remote VE Configure**, and download the `.rvsc`.
2. Open it in Shunt. Change settings or run Assistants, then check the change list.
3. Save under a new name and upload it on the same VRM page. The GX sends it to the inverter and resets it if needed.

## Host it yourself

The site is static. One container serves it with nginx, without root, on port 8080.

```sh
docker run -d -p 8080:8080 --read-only --tmpfs /tmp ghcr.io/samr037/ve-conf-online
```

Or with Compose, from `web/`: `docker compose up -d`.

- `GET /healthz` returns `ok`; the image declares a Docker health check on it.
- The container runs read-only with a tmpfs on `/tmp`.
- Images are built for amd64 and arm64.
- Links are relative, so the site also works under a sub-path behind a reverse proxy.

## Development

Web app (`web/`, Vite, Svelte 5, TypeScript):

```sh
cd web
npm ci
npm run dev            # http://localhost:5173
npx vitest run         # unit tests
npx playwright test    # browser tests
npm run build          # static site in dist/
```

Swift (`Sources/`, `Tests/`):

```sh
swift build
swift test
```

The TypeScript engine is a port of the Swift code and is checked against it byte for byte. The reference data comes from `swift run vegolden web/fixtures/golden`, which reads real device files kept out of this repository. Tests that need them are skipped when they are absent.

## Project layout

| Path | What |
|---|---|
| `web/src/lib/engine` | File formats, VLL assembler, Assistant composer and wizard (TypeScript) |
| `web/src/lib/rules` | Settings catalog, rule engine, value codecs, document model (TypeScript) |
| `web/src/app`, `web/src/landing` | The editor and the landing page (Svelte) |
| `web/src/lib/device` | Direct connection through an MK3-USB or MK2 interface, read-only beta |
| `Sources/VEKit` | File formats, assembler and wizard engine (Swift) |
| `Sources/vecfg`, `Sources/vegolden` | Command-line tool, reference-data generator |

## Direct connection (beta)

Connect a device (beta, read-only): MK3-USB or MK2 in Chrome, Edge or other Chromium browsers on Windows, macOS, Linux and ChromeOS. Details and limits: [web/docs/mk3-webserial.md](web/docs/mk3-webserial.md).

<p align="center"><img src="docs/images/web/device-light.png" width="720" alt="A device read over an MK3-USB interface, read-only."><br><sub>A device read over an MK3-USB interface, read-only.</sub></p>

## Licence

MIT, see [LICENSE](LICENSE), [NOTICE](NOTICE). Victron's catalogue texts and Assistant library are not covered and remain Victron's property.

---

Shunt is an independent project, not made, endorsed or supported by Victron Energy, and not affiliated with Victron's SmartShunt. Victron Energy, VE.Bus, VE Configure, VRM, MultiPlus, Quattro and SmartShunt are trademarks of Victron Energy B.V.
