<p align="center">
  <a href="README.md">English</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <b>Español</b>
</p>

<h1 align="center">Shunt</h1>

<p align="center">
  Configura los inversores/cargadores VE.Bus de Victron Energy desde cualquier ordenador.<br>
  MultiPlus, MultiPlus-II y Quattro, en el navegador.
</p>

<p align="center">
  <a href="https://samr037.github.io/ve-conf-online/"><img alt="Open Shunt" src="https://img.shields.io/badge/open-Shunt-1B5FAA?style=flat"></a>
  <a href="https://github.com/samr037/ve-conf-online/pkgs/container/ve-conf-online"><img alt="Docker image" src="https://img.shields.io/badge/docker-ghcr.io%2Fsamr037%2Fve--conf--online-2496ED?logo=docker&logoColor=white"></a>
  <a href="LICENSE"><img alt="Licence" src="https://img.shields.io/github/license/samr037/ve-conf-online"></a>
  <br>
  <a href="https://github.com/samr037/ve-conf-online/actions/workflows/pages.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/samr037/ve-conf-online/pages.yml?branch=main&label=build"></a>
  <a href="https://github.com/samr037/ve-conf-online/actions/workflows/swift.yml"><img alt="Swift engine" src="https://img.shields.io/github/actions/workflow/status/samr037/ve-conf-online/swift.yml?branch=main&label=swift%20engine&logo=swift&logoColor=white"></a>
  <a href="https://github.com/samr037/ve-conf-online/actions/workflows/codeql.yml"><img alt="CodeQL" src="https://img.shields.io/github/actions/workflow/status/samr037/ve-conf-online/codeql.yml?branch=main&label=CodeQL&logo=github"></a>
  <a href="https://scorecard.dev/viewer/?uri=github.com/samr037/ve-conf-online"><img alt="OpenSSF Scorecard" src="https://api.scorecard.dev/projects/github.com/samr037/ve-conf-online/badge"></a>
  <a href="https://github.com/samr037/ve-conf-online/security"><img alt="Dependabot" src="https://img.shields.io/badge/dependabot-enabled-025E8C?logo=dependabot&logoColor=white"></a>
  <br>
  <img alt="Languages" src="https://img.shields.io/badge/languages-EN%20%C2%B7%20FR%20%C2%B7%20DE%20%C2%B7%20ES-6E40C9">
  <img alt="MK3 / MK2" src="https://img.shields.io/badge/MK3%20%2F%20MK2-beta%2C%20read--only-B4531F">
</p>

<p align="center">
  <a href="https://samr037.github.io/ve-conf-online/"><b>Abrir Shunt</b></a>
</p>

<p align="center">
  <img src="docs/images/web/charger-light.png" width="900" alt="La pestaña Cargador con un valor cambiado en la lista de cambios">
</p>

Shunt abre el archivo de configuración que descargas de VRM (Remote VE Configure, `.rvsc`). Cambias los ajustes que ofrece VE Configure, ejecutas los asistentes, revisas cada cambio y guardas un archivo nuevo que subes por VRM.

## Qué hace

- **Las siete pestañas:** General, Red, Inversor, Cargador, Interruptor virtual, Asistentes, Avanzado, con los rangos, las reglas de dependencia, los ajustes predefinidos de batería y las confirmaciones de VE Configure.
- **Asistentes, byte a byte:** ESS, arranque/parada del generador, relé programable y los demás se ensamblan a partir de las fuentes de Victron. El programa que se escribe en tu archivo es idéntico al de VE Configure, suma de comprobación incluida. Los asistentes que ya están en un archivo se leen con sus respuestas.
- **Códigos de red:** los ajustes protegidos se desbloquean con la contraseña del código de red. Las comprobaciones de rango y de orden de los umbrales de disparo se siguen aplicando.
- **Lista de cambios:** cada diferencia con el archivo cargado, antes → después, con deshacer, rehacer, restaurar un elemento o restaurarlo todo.
- **Cuatro idiomas:** inglés, francés, alemán y español, con el vocabulario de Victron.
- **Modo claro y oscuro.**
- **Sigue donde lo dejaste:** el archivo abierto, sus cambios y el historial de deshacer siguen ahí después de recargar la página.

<table>
  <tr>
    <td width="50%"><img src="docs/images/web/assistants-wizard-light.png" alt="El asistente ESS con el texto de paso de Victron"><br><sub>El asistente ESS, con los textos de paso de Victron.</sub></td>
    <td width="50%"><img src="docs/images/web/general-dark.png" alt="La pestaña General en modo oscuro"><br><sub>Pestaña General, modo oscuro.</sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/web/charger-dark.png" alt="La pestaña Cargador en modo oscuro"><br><sub>Pestaña Cargador, modo oscuro.</sub></td>
    <td><img src="docs/images/web/landing-light.png" alt="La página de inicio"><br><sub>Suelta un archivo sobre el inversor para abrirlo.</sub></td>
  </tr>
</table>

## Con VRM

1. En VRM, abre la instalación, luego **Lista de dispositivos › Remote VE Configure**, y descarga el `.rvsc`.
2. Ábrelo en Shunt. Cambia ajustes o ejecuta asistentes y revisa la lista de cambios.
3. Guarda con un nombre nuevo y súbelo en la misma página de VRM. El GX lo envía al inversor y lo reinicia si hace falta.

## Alojarlo tú mismo

El sitio es estático. Un solo contenedor lo sirve con nginx, sin root, en el puerto 8080.

```sh
docker run -d -p 8080:8080 --read-only --tmpfs /tmp ghcr.io/samr037/ve-conf-online
```

O con Compose, desde `web/`: `docker compose up -d`.

- `GET /healthz` responde `ok`; la imagen declara una comprobación de salud de Docker sobre él.
- El contenedor funciona en solo lectura con un tmpfs en `/tmp`.
- Las imágenes se construyen para amd64 y arm64.
- Los enlaces son relativos, así que el sitio también funciona en una subruta detrás de un proxy inverso.

## Desarrollo

App web (`web/`, Vite, Svelte 5, TypeScript):

```sh
cd web
npm ci
npm run dev            # http://localhost:5173
npx vitest run         # pruebas unitarias
npx playwright test    # pruebas en el navegador
npm run build          # sitio estático en dist/
```

Swift (`Sources/`, `Tests/`):

```sh
swift build
swift test
```

El motor TypeScript es un port del código Swift y se comprueba contra él byte a byte. Los datos de referencia salen de `swift run vegolden web/fixtures/golden`, que lee archivos reales de un dispositivo que no están en este repositorio. Las pruebas que los necesitan se omiten cuando faltan.

## Estructura del proyecto

| Ruta | Contenido |
|---|---|
| `web/src/lib/engine` | Formatos de archivo, ensamblador VLL, compositor y asistente (TypeScript) |
| `web/src/lib/rules` | Catálogo de ajustes, motor de reglas, conversión de valores, modelo de documento (TypeScript) |
| `web/src/app`, `web/src/landing` | El editor y la página de inicio (Svelte) |
| `web/src/lib/device` | Conexión directa mediante una interfaz MK3-USB o MK2, beta de solo lectura |
| `Sources/VEKit` | Formatos de archivo, ensamblador y motor de asistentes (Swift) |
| `Sources/vecfg`, `Sources/vegolden` | Herramienta de línea de comandos, generador de datos de referencia |

## Conexión directa (beta)

Conectar un equipo (beta, solo lectura): MK3-USB o MK2 en Chrome, Edge u otros navegadores Chromium en Windows, macOS, Linux y ChromeOS. Detalles y límites: [web/docs/mk3-webserial.md](web/docs/mk3-webserial.md).

<p align="center"><img src="docs/images/web/device-light.png" width="720" alt="Un equipo leído a través de una interfaz MK3-USB, solo lectura."><br><sub>Un equipo leído a través de una interfaz MK3-USB, solo lectura.</sub></p>

## Licencia

MIT, véase [LICENSE](LICENSE), [NOTICE](NOTICE). Los textos del catálogo y la biblioteca de Asistentes de Victron no están incluidos y siguen siendo propiedad de Victron.

---

Shunt es un proyecto independiente, no creado, respaldado ni apoyado por Victron Energy, y sin relación con el SmartShunt de Victron. Victron Energy, VE.Bus, VE Configure, VRM, MultiPlus, Quattro y SmartShunt son marcas de Victron Energy B.V.
