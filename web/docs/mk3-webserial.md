# MK3-USB and MK2 over Web Serial

Status: **read-only beta**, in the editor's open screen as "Connect a device" (shown only when the browser has Web
Serial). Code: `web/src/lib/device/` (protocol, guard, transport, simulator), `web/src/app/deviceConnect.ts` and
`DeviceDialog.svelte` (flow). Tests: `web/test/mk3.test.ts` (protocol, guard, simulated reads) and
`web/e2e/device.spec.ts` (whole flow against a fake `navigator.serial`).

Everything marked § refers to Victron's public document *Interfacing with VE.Bus products – MK2 Protocol* 3.14.

## What the beta does

- **Interfaces**: MK3-USB, MK2-USB, and MK2.2 behind any USB-serial adapter (FTDI, Prolific, CP210x, CH340).
  The port picker shows every serial port (no vendor filter), so MK2 adapters appear too. The port label says
  "MK3-USB" for Victron's `0403:6015`, else the USB-serial chip.
- **Flow**: choose the port → `'V'` and discovery of the VE.Bus addresses that answer (§7.2) → choose one when
  several answer → read 192 setting ids with a progress bar and Cancel → the configuration opens **read-only**.
- **What is read**: the firmware number, and for each setting its info record (scale, offset, default, min, max) and
  its raw value; flags come from the flag words. These are the `BareSettingInfo` records and `BareSettingData`
  values of an `.rvsc`, so the editor can show a live device.
- **Not kept**: a device reading is never saved in the browser; a reload goes back to the open screen.
- **Errors handled**: port busy, no answer, no device on VE.Bus, unplugged during the read (Web Serial `disconnect`
  event and read errors), Cancel at any step. Each request is retried once after a timeout.

## What it does not read

The public document does not cover everything an `.rvsc` holds. Not read, and shown as such:

- the assistant program (the Assistants page says so; the configuration's assistant memory is filled with `0xFF`
  and flagged `assistantMemoryKnown: false`);
- the setting and flag attribute bytes (every grid-code item stays locked);
- the grid-code table, serial number, unlock tokens, `ConfigResponseChar` and device record (the model shows as
  "VE.Bus inverter/charger"; pages that depend on the device type may differ from a file of the same unit).

A configuration read this way is for display only. It must never be uploaded or written back: it would erase the
device's assistants.

## Browser support

- Chrome, Edge, Opera, Brave and other Chromium desktop browsers on Windows, macOS, Linux and ChromeOS. Not Safari or
  Firefox (no Web Serial): there the action is not shown at all. Android: Web Serial exists in recent Chrome but is
  untested here.
- The page must be served over HTTPS (or `localhost`), and `navigator.serial.requestPort({})` must run from a click.
  The beta passes no filter: with filters, Web Serial shows only matching ports, which would hide MK2 adapters.
- Drivers: macOS and Linux (`ftdi_sio`; the user needs access to the tty, e.g. group `dialout`) include the FTDI
  driver; Windows installs FTDI's VCP driver through Windows Update. Web Serial opens whatever port the OS exposes.
- Web Serial needs no `connect-src`; the nginx Content Security Policy is unchanged.

## Protocol summary

**Link** (§3.1): 2400 baud, 8N1. The MK2.2 (RS232) takes its power from DTR/RTS; the beta raises both after opening
the port.

**Frame** (§3.2): `<Length> 0xFF <Command> <Data…> <Checksum>`.
- `Length` counts the bytes between itself and the checksum; with its MSB set, the frame ends with 2 LED status bytes.
- The checksum makes all bytes of the frame sum to 0 mod 256. Little endian.
- Replies may grow in later firmware: extra bytes are ignored.
- Replies to `'F'` are VE.Bus frames: the same layout without the `0xFF`.
- Timeout 500 ms, more than 750 ms for `'F' 5` (§3.3).

Example (Appendix 1): `04 FF 'A' 01 00 BB` selects device 0.

| Command | Bytes | Reply | § |
|---|---|---|---|
| Interface version | `'V'` | `'V' <u32 version> <mode>` | 3.4 |
| Select device | `'A' 01 <addr>` (0x00–0x1F) | `'A' 01 <addr>` | 7.1 |
| Winmon | `'W' <cmd> <info0> <info1>` | `'W'` + up to three 3-byte replies per frame (short mode) | 7.3 |
| Software version | Winmon `0x05`, `0x06` | `0x82 lo hi`, `0x83 lo hi` → u32 firmware | 7.3.1 |
| Setting info | Winmon `0x35 <id lo> <id hi>` | `0x89` Sc, `0x8A` Offset, `0x8B` Default, `0x8C` Min, `0x8D` Max; Sc = 0 → unsupported | 7.3.8 |
| Read setting | Winmon `0x31 <id lo> <id hi>` | `0x86 lo hi` (OK) or `0x91` (unsupported) | 7.3.4 |

- Strictly one request at a time (§7.1). Long Winmon frames (§7.3.8) and `'X'/'Y'/'Z'` are not used: entering long
  mode goes through `'S'`, which also sends the panel state.
- Discovery (§7.2): set address n, send a Winmon command, stop after 3 silent addresses.
- The MK2 sends a version frame about once per second when idle (§3.4); it is ignored while waiting for a reply.
- Setting ids (§7.3.13): the document lists 0–65; the file stores 192 records, and the beta reads them all. Flags are
  bits of settings 0, 1, 60, 61, 82; the info Maximum of a flag word is its mask of supported bits (§7.3.13.3).
- Time: about 45 bytes per supported setting at 2400 baud plus the VE.Bus round trips, so about a minute.

## Safety rules

The beta is **read-only, enforced twice**: `ReadOnlyTransport` (`guard.ts`) refuses any frame other than `'V'`,
`'A' 01 <address 0…31>` and Winmon `0x05`/`0x06` (id 0) and `0x31`/`0x35` (ids 0…191) before a byte is written; and
the document opened from a device (`ConfigDocument.fromDevice`) locks every control and refuses edits, the grid
password and saving. Unit tests check every frame the beta can send; the browser test checks every frame actually
sent.

Writing is not implemented. The document describes write commands (`0x33`/`0x34`, `0x37`, §7.3.6–7.3.11), notes
that many settings take effect only after a reset (§7.3.13.2), and warns that changing unused flags can damage the
device (§7.3.13.3). Before any write could be enabled it would need: the same firmware as the reading, writing only
the changed settings, no grid-protected changes without the grid password, an explicit confirmation listing every
change and the reset, a read-back of every value, no assistant writes, and the pre-write reading kept as an `.rvsc`
for recovery.

## Hardware test checklist

For a MultiPlus-II with a GX device. Nothing in the beta can write, so the risk is limited to bus traffic while the
GX also talks to the unit.

1. **Download a fresh `.rvsc` from VRM first** (Device list › Remote VE Configure) as the reference.
2. **Cable**: MK3-USB into a free VE.Bus RJ45 of the inverter (or a VE.Bus splitter), USB into the computer. The GX
   stays connected. If the GX shows VE.Bus errors during the test, unplug the MK3 and note it.
3. **Browser**: Chrome or Edge, open the editor (or `npm run dev` → http://127.0.0.1:5173/app.html). "Connect a
   device" must appear with a Beta tag.
4. **Port**: Connect a device › Choose the port…, pick the MK3 (macOS `cu.usbserial-…` / "MK3-USB Interface";
   Windows a COM port; Linux `/dev/ttyUSB0`). Expected: "Looking for devices…", then the progress bar within a few
   seconds.
5. **Read**: about one minute. Expected banner: "Read from VE.Bus inverter/charger on MK3-USB, <time>. Read-only
   beta."
6. **Compare** with the `.rvsc` from step 1, opened in another tab: General, Inverter, Charger, Virtual switch. Every
   value should match.
7. **Read-only check**: no field can be edited, Save as… is disabled, the Assistants page says the program cannot be
   read. Export as text works.
8. **Unplug test**: start a second read and pull the USB cable mid-way. Expected: "The interface was disconnected."
   and the page stays usable.
9. **MK2 (if available)**: repeat 4–7 with an MK2-USB or MK2.2 + USB-serial adapter.
10. **Report**: interface, OS and browser, read time, and any mismatch from step 6 with the setting name and both
    values.

## Sources

| Source | Used for |
|---|---|
| Victron, *Interfacing with VE.Bus products – MK2 Protocol* 3.14 (June 2017), <https://www.victronenergy.com/upload/documents/Technical-Information-Interfacing-with-VE-Bus-products-MK2-Protocol-3-14.pdf> | Everything marked §. |
| Same document 3.12, <https://communityarchive.victronenergy.com/storage/attachments/interfacing-with-ve-bus-products-mk2-protocol-312.pdf> | Older edition (no long Winmon frames, no X/Y/Z). |
| Victron Community, "VE.Bus interfacing", <https://communityarchive.victronenergy.com/questions/229686/ve-bus-interfacing.html> | The document describes the MK2/MK3 serial side, not the VE.Bus wire protocol. |
| Victron Community, "Lost connection to MultiPlus from RPi 3B", <https://communityarchive.victronenergy.com/questions/80746/lost-connection-to-multiplus-from-rpi-3b.html> | MK3-USB enumerates as FTDI `0403:6015`, product "MK3-USB Interface". |
| Victron Community, "What type of FTDI chip is used in MK3-USB", <https://communityarchive.victronenergy.com/questions/98004/what-type-of-ftdi-chip-is-used-in-mk3-usb-interfac.html> | FTDI chip, standard VCP driver. |
| VE Configure manual, troubleshooting, <https://www.victronenergy.com/media/pg/VEConfigure_Manual/en/troubleshooting.html> | FTDI USB driver; MK3 test procedure. |
| Victron Community, "Using VE.Bus without Venus OS", <https://communityarchive.victronenergy.com/questions/158093/using-ve-bus-without-venus-os.html> | Venus OS drives an MK3 with its own `mk2-dbus` service. |
| j9brown/victron-mk3, <https://github.com/j9brown/victron-mk3> (MIT) | Working Python MK3 client. Behaviour reference only; no code copied. |
| izak/ib.victron, <https://github.com/izak/ib.victron> (no licence) | Older Python MK2 client. Not used. |
| Web Serial API, <https://wicg.github.io/serial/>; MDN, <https://developer.mozilla.org/en-US/docs/Web/API/Web_Serial_API> | Browser API and support. |
