<p align="center">
  <a href="README.md">English</a> · <b>Français</b> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a>
</p>

<h1 align="center">Shunt</h1>

<p align="center">
  Configurer les convertisseurs/chargeurs VE.Bus de Victron Energy depuis n'importe quel ordinateur.<br>
  MultiPlus, MultiPlus-II et Quattro, dans le navigateur.
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
  <a href="https://samr037.github.io/ve-conf-online/"><b>Ouvrir Shunt</b></a>
</p>

<p align="center">
  <img src="docs/images/web/charger-fr-light.png" width="900" alt="L'onglet Chargeur avec une valeur modifiée dans la liste des modifications">
</p>

Shunt ouvre le fichier de configuration que tu télécharges depuis VRM (Remote VE Configure, `.rvsc`). Tu modifies les réglages que propose VE Configure, tu lances les assistants, tu relis chaque modification, puis tu enregistres un nouveau fichier que tu renvoies par VRM.

## Ce qu'il fait

- **Les sept onglets :** Général, Réseau, Convertisseur, Chargeur, Commutateur virtuel, Assistants, Avancé, avec les plages, les règles de dépendance, les préréglages de batterie et les confirmations de VE Configure.
- **Les assistants, à l'octet près :** ESS, démarrage/arrêt du générateur, relais programmable et les autres sont assemblés à partir des sources de Victron. Le programme écrit dans ton fichier est identique à celui de VE Configure, somme de contrôle comprise. Les assistants déjà présents dans un fichier sont relus avec leurs réponses.
- **Codes de réseau :** les réglages protégés se déverrouillent avec le mot de passe du code de réseau. Les contrôles de plage et d'ordre des seuils de déclenchement s'appliquent toujours.
- **Liste des modifications :** chaque écart avec le fichier chargé, ancienne → nouvelle valeur, avec annuler, rétablir, restaurer un élément ou tout restaurer.
- **Quatre langues :** anglais, français, allemand et espagnol, avec le vocabulaire de Victron.
- **Mode clair et mode sombre.**
- **Tu reprends là où tu en étais :** le fichier ouvert, ses modifications et l'historique d'annulation sont toujours là après un rechargement de la page.

<table>
  <tr>
    <td width="50%"><img src="docs/images/web/assistants-wizard-light.png" alt="L'assistant ESS avec le texte d'étape de Victron"><br><sub>L'assistant ESS, avec les textes d'étape de Victron.</sub></td>
    <td width="50%"><img src="docs/images/web/general-dark.png" alt="L'onglet Général en mode sombre"><br><sub>Onglet Général, mode sombre.</sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/web/charger-dark.png" alt="L'onglet Chargeur en mode sombre"><br><sub>L'onglet Chargeur, mode sombre.</sub></td>
    <td><img src="docs/images/web/landing-light.png" alt="La page d'accueil"><br><sub>Dépose un fichier sur le convertisseur pour l'ouvrir.</sub></td>
  </tr>
</table>

## Avec VRM

1. Sur VRM, ouvre l'installation, puis **Liste des appareils › Remote VE Configure**, et télécharge le `.rvsc`.
2. Ouvre-le dans Shunt. Modifie les réglages ou lance des assistants, puis relis la liste des modifications.
3. Enregistre sous un nouveau nom et envoie le fichier sur la même page VRM. Le GX le transmet au convertisseur et le redémarre si besoin.

## L'héberger soi-même

Le site est statique. Un seul conteneur le sert avec nginx, sans root, sur le port 8080.

```sh
docker run -d -p 8080:8080 --read-only --tmpfs /tmp ghcr.io/samr037/ve-conf-online
```

Ou avec Compose, depuis `web/` : `docker compose up -d`.

- `GET /healthz` répond `ok` ; l'image déclare un contrôle de santé Docker dessus.
- Le conteneur tourne en lecture seule avec un tmpfs sur `/tmp`.
- Les images sont construites pour amd64 et arm64.
- Les liens sont relatifs : le site fonctionne aussi sous un sous-chemin derrière un reverse proxy.

## Développement

App web (`web/`, Vite, Svelte 5, TypeScript) :

```sh
cd web
npm ci
npm run dev            # http://localhost:5173
npx vitest run         # tests unitaires
npx playwright test    # tests dans le navigateur
npm run build          # site statique dans dist/
```

Swift (`Sources/`, `Tests/`) :

```sh
swift build
swift test
```

Le moteur TypeScript est un portage du code Swift et il est vérifié contre lui à l'octet près. Les données de référence viennent de `swift run vegolden web/fixtures/golden`, qui lit de vrais fichiers d'appareil gardés hors de ce dépôt. Les tests qui en ont besoin sont ignorés quand ils sont absents.

## Organisation du projet

| Chemin | Contenu |
|---|---|
| `web/src/lib/engine` | Formats de fichier, assembleur VLL, compositeur et assistant (TypeScript) |
| `web/src/lib/rules` | Catalogue des réglages, moteur de règles, conversions de valeurs, modèle de document (TypeScript) |
| `web/src/app`, `web/src/landing` | L'éditeur et la page d'accueil (Svelte) |
| `web/src/lib/device` | Connexion directe par une interface MK3-USB ou MK2, bêta en lecture seule |
| `Sources/VEKit` | Formats de fichier, assembleur et moteur d'assistant (Swift) |
| `Sources/vecfg`, `Sources/vegolden` | Outil en ligne de commande, générateur de données de référence |

## Connexion directe (bêta)

Connecter un appareil (bêta, lecture seule) : MK3-USB ou MK2 dans Chrome, Edge ou un autre navigateur Chromium sous Windows, macOS, Linux et ChromeOS. Détails et limites : [web/docs/mk3-webserial.md](web/docs/mk3-webserial.md).

<p align="center"><img src="docs/images/web/device-light.png" width="720" alt="Un appareil lu par une interface MK3-USB, en lecture seule."><br><sub>Un appareil lu par une interface MK3-USB, en lecture seule.</sub></p>

## Licence

MIT, voir [LICENSE](LICENSE), [NOTICE](NOTICE). Les textes du catalogue et la bibliothèque d'Assistants de Victron n'en font pas partie et restent la propriété de Victron.

---

Shunt est un projet indépendant, ni réalisé, ni approuvé, ni soutenu par Victron Energy, et sans lien avec le SmartShunt de Victron. Victron Energy, VE.Bus, VE Configure, VRM, MultiPlus, Quattro et SmartShunt sont des marques de Victron Energy B.V.
