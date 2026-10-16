# VE Configure for Mac

A native macOS replacement for Victron Energy's Windows-only **VE Configure 3**, for VE.Bus inverter/chargers (MultiPlus, MultiPlus-II, Quattro). It opens the configuration file you download from VRM (**Remote VE Configure**, `.rvsc`), lets you change every setting VE Configure exposes, and runs the **Assistants** (ESS, generator start/stop, programmable relay…). It then writes a new file for you to upload through VRM.

> Independent project, not made or endorsed by Victron Energy. Victron Energy, VE.Bus, VE Configure and VRM are trademarks of Victron Energy B.V.

## What it does

- **Settings.** All seven VE Configure tabs: General, Grid, Inverter, Charger, Virtual switch, Assistants and Advanced. Pages are generated from VE Configure's own form layout, and the dependency rules and battery presets are reproduced. The help text appears on every setting.
- **Grid codes.** Changing them needs your grid-code password, exactly as in VE Configure. The app never bypasses it.
- **Assistants.** The app re-assembles Victron's own Assistant sources with a port of VE Configure's macro assembler. It reads the Assistants already in a file back, with your answers, and you can add, remove, reorder or re-configure them step by step. Programs are byte-identical to VE Configure's: tested on a real ESS setup and on every Assistant in the library.
- **Review before you save.** A change list shows every difference from the loaded file (old → new) and supports undo. A file is never overwritten, and the app never talks to a device.
- **Other features:** export and print the settings report; interface in English, French, German and Spanish.

## Use

1. On VRM, open the installation, then go to **Device list › Remote VE Configure** and download the `.rvsc`.
2. Open it in VE Configure for Mac.
3. Change settings or run Assistants. Review the change list and save a new file.
4. Upload it on the same VRM page. The GX sends it to the inverter and resets it if needed.

**Assistant library.** The Assistants are Victron's programs and are not included. Import the library once from a VE Configure installation: the file is `VE Configure tools/Assistants/allNNN.vfp`. The app keeps a copy in `~/Library/Application Support/VE Configure/`.

## Build

You need the Command Line Tools (Swift 6) and macOS 14 or later. Xcode is not required.

```sh
scripts/test.sh          # unit and end-to-end tests (VEKit)
scripts/build-app.sh     # builds and installs ~/Applications/VE Configure.app
```

`vecfg` is a command-line companion:

```sh
swift build --scratch-path /tmp/vec-build --product vecfg
vecfg show file.rvsc                  # settings, flags, assistant memory
vecfg diff a.rvsc b.rvsc              # what changed
vecfg set file.rvsc UBatAbsorption=56.4 AssistEnabled=on -o out.rvsc
vecfg reconstruct allNNN.vfp file.rvsc   # read assistants and answers back, prove byte-identical rebuild
vecfg wizard allNNN.vfp file.rvsc ESS    # walk an assistant headlessly
```

## Layout

| Path | What |
|---|---|
| `Sources/VEKit` | File formats (`.rvsc` sections and checksum, settings, RLE assistant memory), assistant library (`.vfp`/`.vap`), the VLL macro assembler, the assistant engine (`.AID/.AUE/.ALD`), META generator, wizard text rendering |
| `Sources/VEConfigure` | The SwiftUI app |
| `Sources/vecfg` | CLI |
| `docs/re/` | Reverse-engineering notes: 01 feature inventory · 02 settings layout · 03 assembler spec · 04 UI rules · 05 META environment |
| `tools/` | Python tools used during the reverse engineering |

`vendor/` holds Victron's installer and the extracted files. It is git-ignored and never distributed.
