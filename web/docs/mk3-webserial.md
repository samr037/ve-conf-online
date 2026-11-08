# MK3-USB over Web Serial — research note (draft)

Status: **draft**. Code in `web/src/lib/device/` reads a device through the public protocol; nothing is wired into
the app and nothing writes to a device. Tests: `web/test/mk3.test.ts`.

## Verdict

**Reading the settings is feasible** from a Chromium desktop browser with the public protocol: firmware number, and
for every setting its info record (scale, offset, default, min, max) and raw value. That is exactly the
`BareSettingInfo` records and the `BareSettingData` values of an `.rvsc`, so the editor's model can show a live
device.

**A complete `.rvsc`-equivalent read is not feasible with public information alone.** The attribute bytes
(hidden/protected), the grid-code table, the serial number, the unlock tokens, `ConfigResponseChar`, the device
record and the **assistant memory** come from undocumented commands that VE Configure uses. Getting them means
reverse engineering `VEConfig.exe` further (WinMon components) and testing on hardware.

**Writing is feasible for ordinary settings** (documented commands), but must wait for the safeguards below.
Grid-code protected settings and assistants depend on the undocumented parts.

## Sources

| Source | Used for |
|---|---|
| Victron, *Interfacing with VE.Bus products – MK2 Protocol* 3.14 (June 2017), <https://www.victronenergy.com/upload/documents/Technical-Information-Interfacing-with-VE-Bus-products-MK2-Protocol-3-14.pdf> | Everything marked §. Read in full for this note. |
| Same document 3.12, <https://communityarchive.victronenergy.com/storage/attachments/interfacing-with-ve-bus-products-mk2-protocol-312.pdf> | Older edition (no long Winmon frames, no X/Y/Z). |
| Victron Community, "VE.Bus interfacing", <https://communityarchive.victronenergy.com/questions/229686/ve-bus-interfacing.html> | The document describes the MK2/MK3 serial side, not the VE.Bus wire protocol. |
| Victron Community, "Lost connection to MultiPlus from RPi 3B", <https://communityarchive.victronenergy.com/questions/80746/lost-connection-to-multiplus-from-rpi-3b.html> | MK3-USB enumerates as FTDI `0403:6015`, product "MK3-USB Interface"; the FTDI EEPROM identifies it as an MK3. |
| Victron Community, "What type of FTDI chip is used in MK3-USB", <https://communityarchive.victronenergy.com/questions/98004/what-type-of-ftdi-chip-is-used-in-mk3-usb-interfac.html> | FTDI chip, standard VCP driver. |
| VE Configure manual, troubleshooting, <https://www.victronenergy.com/media/pg/VEConfigure_Manual/en/troubleshooting.html> | FTDI USB driver; MK3 test procedure with the Multi disconnected from the GX's VE.Bus port. |
| Victron Community, "Using VE.Bus without Venus OS", <https://communityarchive.victronenergy.com/questions/158093/using-ve-bus-without-venus-os.html> | Victron's `mk2-dbus` (Venus OS) drives an MK3; its source is not public (`github.com/victronenergy/mk2-dbus` returns 404). |
| j9brown/victron-mk3, <https://github.com/j9brown/victron-mk3> (MIT) | Working Python MK3 client (remote panel, status, RAM/settings). Behaviour reference only; no code copied. |
| izak/ib.victron, <https://github.com/izak/ib.victron> (no licence) | Older Python MK2 client; reported broken on firmware 4xx. Not used. |
| Web Serial API, <https://wicg.github.io/serial/>; MDN, <https://developer.mozilla.org/en-US/docs/Web/API/Web_Serial_API> | Browser API and support. |
| This repo: `docs/re/02-settings.md`, `ghidra/out/strings.tsv` (VEConfig.exe) | Mapping of file fields to protocol data; VE Configure behaviour (strings cited with their addresses). |

## Hardware and browser

- **MK3-USB**: FTDI USB-serial adapter, VID `0x0403`, PID `0x6015`. It is powered from the VE.Bus side.
- **Drivers**: macOS includes an FTDI driver (port `/dev/cu.usbserial-*`); Windows installs FTDI's VCP driver through
  Windows Update or VE Configure's driver package; Linux uses the in-kernel `ftdi_sio` (the user needs access to the
  tty, e.g. group `dialout`). Web Serial opens whatever serial port the OS exposes, so no extra driver is needed in
  the browser.
- **Browsers**: Web Serial exists in Chromium desktop browsers (Chrome, Edge, Opera, Brave). Not in Safari or
  Firefox. Android and iOS: not usable for this (unverified on Android). The page must be served over HTTPS (or
  `localhost`), and `navigator.serial.requestPort({ filters: [{ usbVendorId: 0x0403, usbProductId: 0x6015 }] })`
  must run from a click.
- **CSP**: Web Serial needs no `connect-src`; the current nginx CSP is fine.

## Protocol summary (public, §)

**Link** (§3.1): 2400 baud, 8N1. MK2.2 (RS232) needs DTR high to power its isolated side.

**Frame** (§3.2): `<Length> 0xFF <Command> <Data…> <Checksum>`.
- `Length` counts the bytes between itself and the checksum.
- MSB of `Length` set: the frame ends with 2 LED status bytes.
- The checksum makes all bytes of the frame sum to 0 mod 256.
- Little endian.
- Replies may grow in later firmware: ignore extra bytes.
- Replies to `'F'` are VE.Bus frames: same layout without the `0xFF` (types `0x20` info, `0x41` MasterMultiLED, `0x3C` BOL).
- Timeout 500 ms, more than 750 ms for `'F' 5` (§3.3).

Example (Appendix 1): `04 FF 'A' 01 00 BB` selects device 0.

**Commands used for reading**:

| Command | Bytes | Reply | § |
|---|---|---|---|
| Interface version | `'V'` | `'V' <u32 version> <mode>` (`mode` = current address, `'B'` none, `'W'` = VE 9-bit) | 3.4 |
| Select device | `'A' 01 <addr>` (0x00–0x1F; 0xFF at power-up = none) | `'A' 01 <addr>` | 7.1 |
| Winmon | `'W' <cmd> <info0> <info1>` | `'W'` + up to three 3-byte replies per frame (short mode 1, default) | 7.3 |
| Software version | Winmon `0x05`, `0x06` | `0x82 lo hi`, `0x83 lo hi` → u32 firmware | 7.3.1 |
| Setting info | Winmon `0x35 <id lo> <id hi>` | `0x89` Sc, `0x8A` Offset, `0x8B` Default, `0x8C` Min, `0x8D` Max; Sc = 0 → unsupported, nothing more | 7.3.8 |
| Read setting | Winmon `0x31 <id lo> <id hi>` | `0x86 lo hi` (OK) or `0x91` (unsupported) | 7.3.4 |
| Unknown command | — | `0x80 <reason> xx` | 7.3 |

- Long Winmon frames (mode 2, §7.3, §7.3.8) return the whole info record in one reply plus an **access level** byte.
  They are selected through the `'S'` command's `FlagsExt0`. `'S'` also sends the panel state (switch,
  input current limit) unless `Flags[4]` is set. The draft therefore stays in mode 1.
- `'X'/'Y'/'Z'` (rotating) and `'x'/'y'/'z'` (with address) let replies be matched to requests. They need recent MK
  firmware; the draft uses `'W'` and strictly one request at a time (§7.1).
- Discovery (§7.2): set address n, send any Winmon command, and stop after 3 silent addresses.
- The MK2 sends a version frame about once per second when idle (§3.4): ignore it while waiting for a reply.

**Setting ids** (§7.3.13): the document lists 0–65. The file stores 192 records (`DeviceSettingData.maxValues`); the
draft assumes the same commands work for 66–191 (TODO hardware). Flags are bits of settings 0, 1, 60, 61, 82; the
info Maximum of a flag word is its mask of supported bits (§7.3.13.3).

## Mapping an `.rvsc` to the protocol

| File field (`docs/re/02-settings.md`) | Protocol | Status |
|---|---|---|
| `Mk2vscInfo` (u32 1, `"1.27"`) | none (file format constants) | known |
| Info/Data `firmware` | Winmon 0x05/0x06 | **public** |
| Info `records[id]` (Sc, Offset, Default, Min, Max) | Winmon 0x35 per id | **public** (ids > 65 unconfirmed) |
| Data `values[id]` | Winmon 0x31 per id | **public** (ids > 65 unconfirmed) |
| Info `setting_attr` low bits (0x01 = grid/installer protected) | probably the long-mode 0x35 `<Access level>` byte | unconfirmed |
| Info `setting_attr` bit 7 (hidden) | computed by VE Configure per firmware (`FUN_0049efdc`) | port that logic |
| Info `flag_attr` (80 bytes) | undocumented (VEConfig string `BareEBITAcess`, 0x004cd0e0) | unknown |
| Info `grid_table` | undocumented (`BareGridInfo`, 0x004cd174; `GridCodeTools.pas`) | unknown |
| Data `serial` | undocumented; VE Configure can ask the user for it ("Enter the 11-characters serial number", 0x004a7e74) | unknown |
| Data `tokens`, `token_list_time` | unlock tokens written by VE Configure | not read from the device |
| Data `ConfigResponseChar`, `device_record`, `device_id`, `firmware_alt`, `firmware_extra` | undocumented (`VEBusTools.pas`) | unknown |
| Data assistant memory (4096 bytes) | undocumented (`BareEPROMAcess`, 0x004cd0f8). VE Configure warns: "Reading the assistant setup will reset the device" (0x0055b49c) | unknown, **resets the device** |
| Data `read_time` | local clock | trivial |

`draftConfiguration()` builds a display-only configuration from what is public:
- `BareSettingInfo` v1 has no attribute bytes, so every grid item stays protected.
- `BareSettingData` v1 has no serial and no tokens.
- The assistant memory is filled with `0xFF`, flagged `assistantMemoryKnown: false`.

Such a configuration must never be uploaded or written back: it would erase the device's assistants.

## Read sequence (draft, `readConfiguration`)

1. `'V'`: check the interface answers and is in VE.Bus mode.
2. `'A' 01 00`: select device 0 (single unit). For multi-unit systems, run discovery first and read each address.
3. Winmon 0x05, 0x06: firmware.
4. For id = 0…191: Winmon 0x35 (info); if supported, Winmon 0x31 (value).
5. Assemble the records and values.

**Time**: about 45 bytes per supported setting, or 0.2 s at 2400 baud, plus the VE.Bus round trips. So expect about
a minute for 192 ids. VE Configure has a "High speed (MK3 required)" option (`UseHighSpeedCommunication`); how it
switches speed is undocumented.

## Unknowns that need hardware or more reverse engineering

1. Whether ids 66–191 answer 0x35/0x31 like 0–65, and whether VE Configure reads all 192.
2. The long-mode access level byte and its relation to the file's attribute bytes; how to enter long mode without
   changing the panel state.
3. The undocumented reads: flag attributes, grid table, serial, `ConfigResponseChar`, device record, and the assistant
   memory (and its device reset). Next step: trace `WinMonbus.pas` and `ExtendedBusDrv.pas` in `ghidra/out/all.c`
   from the strings above.
4. Behaviour with a GX on the same VE.Bus: whether the MK3 and the GX (`mk2-dbus`) can both talk safely during reads.
5. The VE.Bus address of the unit in the owner's system, and whether X/Y/Z works with his MK3 firmware.

## Writing: risks and required safeguards (not implemented)

Documented write paths:
- CommandWriteSetting `0x33` then CommandWriteData `0x34` → `0x88` (§7.3.6–7.3.7).
- CommandWriteViaID `0x37` (long mode, §7.3.11), which can answer `0x9B` "access level required".
- Many settings take effect only after a reset (§7.3.13.2 note e). Reset is `'F' 8 <long address>` (§6.3).
- The document warns against changing unused flags or "not promoted options": this can damage the device (§7.3.13.3).

Before any write is enabled:
- **Same device**: the firmware (and serial, once readable) must match the reading the edits started from.
  Otherwise refuse.
- **Only what changed**: write only the settings in the change list, never unsupported flag bits, never "not
  promoted" flags.
- **Grid code**: refuse grid-protected settings unless the grid password was entered. The device-side password
  mechanism is undocumented.
- **Explicit confirmation**: list every change (old → new) and say the device will reset.
- **Verify**: after each write, read the value back. After the reset, read everything again and compare with the
  intended configuration.
- **Assistants**: no assistant writes until the memory protocol is understood.
- **Recovery**: keep the pre-write reading as an `.rvsc` the user can upload through VRM.

## Test plan with the owner's system (MultiPlus-II 48/5000 with GX)

1. **Before touching hardware**: the GX holds the VE.Bus. Find a free VE.Bus RJ45 on the MultiPlus (or a splitter).
   The MK3 shares the bus with the GX. Victron's troubleshooting page tests the MK3 with the Multi disconnected from
   the GX; for a first test, do the same if possible.
2. **Interface only**: plug the MK3 into the Mac, open a test page in Chrome, pick the port. Check that `'V'` answers
   and the periodic version frames arrive.
3. **Read only**: run `readConfiguration` with the MultiPlus on. Compare records and values with a fresh `.rvsc`
   downloaded from VRM at the same moment. Every supported setting should match. This also answers unknown 1.
4. **Long mode and access level**: on a test bench if possible. Check what `'S'` with `Flags[4]` set does to the
   panel state.
5. **No writes** until 1–4 pass and the safeguards above exist. The first write test should be one harmless setting
   (for example the repeated absorption interval), then read back, reset, and read back again.
