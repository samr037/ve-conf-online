<p align="center">
  <a href="README.md">English</a> · <a href="README.fr.md">Français</a> · <b>Deutsch</b> · <a href="README.es.md">Español</a>
</p>

<h1 align="center">Shunt</h1>

<p align="center">
  VE.Bus-Wechselrichter/Ladegeräte von Victron Energy von jedem Computer aus konfigurieren.<br>
  MultiPlus, MultiPlus-II und Quattro, im Browser.
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
  <a href="https://samr037.github.io/ve-conf-online/"><b>Shunt öffnen</b></a>
</p>

<p align="center">
  <img src="docs/images/web/charger-light.png" width="900" alt="Der Reiter Ladegerät mit einem geänderten Wert in der Änderungsliste">
</p>

Shunt öffnet die Konfigurationsdatei, die du von VRM herunterlädst (Remote VE Configure, `.rvsc`). Du änderst die Einstellungen, die VE Configure anbietet, führst Assistenten aus, prüfst jede Änderung und speicherst eine neue Datei, die du über VRM hochlädst.

## Was es kann

- **Alle sieben Reiter:** Allgemein, Netz, Wechselrichter, Ladegerät, Virtueller Schalter, Assistenten, Erweitert, mit den Bereichen, Abhängigkeitsregeln, Batterie-Voreinstellungen und Bestätigungen von VE Configure.
- **Assistenten, Byte für Byte:** ESS, Generator Start/Stopp, programmierbares Relais und die anderen werden aus Victrons eigenen Quellen assembliert. Das Programm in deiner Datei ist identisch mit dem von VE Configure, Prüfsumme eingeschlossen. Assistenten, die schon in einer Datei sind, werden mit ihren Antworten zurückgelesen.
- **Netzcodes:** geschützte Einstellungen werden mit dem Netzcode-Passwort entsperrt. Bereichs- und Auslöseschwellen-Prüfungen gelten weiterhin.
- **Änderungsliste:** jede Abweichung von der geladenen Datei, alt → neu, mit Rückgängig, Wiederholen, einzelnes Element oder alles wiederherstellen.
- **Vier Sprachen:** Englisch, Französisch, Deutsch und Spanisch, mit Victrons Begriffen.
- **Hell und dunkel.**
- **Weitermachen, wo du warst:** die geöffnete Datei, ihre Änderungen und der Rückgängig-Verlauf sind nach dem Neuladen der Seite noch da.

<table>
  <tr>
    <td width="50%"><img src="docs/images/web/assistants-wizard-light.png" alt="Der ESS-Assistent mit Victrons Schritttext"><br><sub>Der ESS-Assistent mit Victrons Schritttexten.</sub></td>
    <td width="50%"><img src="docs/images/web/general-dark.png" alt="Der Reiter Allgemein im dunklen Modus"><br><sub>Reiter Allgemein, dunkel.</sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/web/charger-dark.png" alt="Der Reiter Ladegerät im dunklen Modus"><br><sub>Reiter Ladegerät, dunkel.</sub></td>
    <td><img src="docs/images/web/landing-light.png" alt="Die Startseite"><br><sub>Datei auf den Wechselrichter ziehen, um sie zu öffnen.</sub></td>
  </tr>
</table>

## Ablauf mit VRM

1. Öffne in VRM die Anlage, dann **Geräteliste › Remote VE Configure**, und lade die `.rvsc` herunter.
2. Öffne sie in Shunt. Ändere Einstellungen oder führe Assistenten aus und prüfe dann die Änderungsliste.
3. Speichere unter einem neuen Namen und lade die Datei auf derselben VRM-Seite hoch. Das GX überträgt sie an den Wechselrichter und setzt ihn bei Bedarf zurück.

## Selbst hosten

Die Seite ist statisch. Ein Container liefert sie mit nginx aus, ohne root, auf Port 8080.

```sh
docker run -d -p 8080:8080 --read-only --tmpfs /tmp ghcr.io/samr037/ve-conf-online
```

Oder mit Compose, aus `web/`: `docker compose up -d`.

- `GET /healthz` antwortet `ok`; das Image deklariert darauf einen Docker-Healthcheck.
- Der Container läuft schreibgeschützt mit einem tmpfs auf `/tmp`.
- Images werden für amd64 und arm64 gebaut.
- Links sind relativ, die Seite funktioniert also auch unter einem Unterpfad hinter einem Reverse Proxy.

## Entwicklung

Web-App (`web/`, Vite, Svelte 5, TypeScript):

```sh
cd web
npm ci
npm run dev            # http://localhost:5173
npx vitest run         # Unit-Tests
npx playwright test    # Tests im Browser
npm run build          # statische Seite in dist/
```

Swift (`Sources/`, `Tests/`):

```sh
swift build
swift test
```

Die TypeScript-Engine ist eine Portierung des Swift-Codes und wird Byte für Byte gegen ihn geprüft. Die Referenzdaten erzeugt `swift run vegolden web/fixtures/golden` aus echten Gerätedateien, die nicht in diesem Repository liegen. Tests, die sie brauchen, werden ohne sie übersprungen.

## Projektaufbau

| Pfad | Inhalt |
|---|---|
| `web/src/lib/engine` | Dateiformate, VLL-Assembler, Assistenten-Composer und -Wizard (TypeScript) |
| `web/src/lib/rules` | Einstellungskatalog, Regel-Engine, Wertumrechnung, Dokumentmodell (TypeScript) |
| `web/src/app`, `web/src/landing` | Editor und Startseite (Svelte) |
| `web/src/lib/device` | Direktverbindung über eine MK3-USB- oder MK2-Schnittstelle, Beta nur zum Lesen |
| `Sources/VEKit` | Dateiformate, Assembler und Assistenten-Engine (Swift) |
| `Sources/vecfg`, `Sources/vegolden` | Kommandozeilenwerkzeug, Referenzdaten-Generator |

## Direktverbindung (Beta)

Gerät verbinden (Beta, nur lesen): MK3-USB oder MK2 in Chrome, Edge oder anderen Chromium-Browsern unter Windows, macOS, Linux und ChromeOS. Details und Grenzen: [web/docs/mk3-webserial.md](web/docs/mk3-webserial.md).

<p align="center"><img src="docs/images/web/device-light.png" width="720" alt="Ein über eine MK3-USB-Schnittstelle gelesenes Gerät, nur lesend."><br><sub>Ein über eine MK3-USB-Schnittstelle gelesenes Gerät, nur lesend.</sub></p>

## Lizenz

MIT, siehe [LICENSE](LICENSE), [NOTICE](NOTICE). Die Katalogtexte und die Assistenten-Bibliothek von Victron sind nicht abgedeckt und bleiben Eigentum von Victron.

---

Shunt ist ein unabhängiges Projekt, weder von Victron Energy erstellt, unterstützt noch empfohlen, und hat nichts mit Victrons SmartShunt zu tun. Victron Energy, VE.Bus, VE Configure, VRM, MultiPlus, Quattro und SmartShunt sind Marken der Victron Energy B.V.
