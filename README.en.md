# Elegoo Neptune 3 Pro · Lossless Klipper Conversion · Stock Serial Screen Bridge · One-Click Deploy

**English** | [中文](README.md)

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Klipper](https://img.shields.io/badge/Klipper-v0.13.x-green)
![MCU](https://img.shields.io/badge/MCU-STM32F401RCT6-orange)
![Host](https://img.shields.io/badge/Host-MKS%20Pi%20%2F%20Armbian-lightgrey)

> **No screen rewiring, no soldering, no panel removal.** After flashing Klipper onto the stock
> Elegoo Neptune 3 Pro mainboard (ZNP Robin Nano_DW V2.2 / STM32F401RCT6), the stock 4P4C telephone-cable
> TJC display keeps working — via a **UART bridge implemented inside the MCU firmware**:
> panel data flows `J33 → USART6 PA12/PA11 → Klipper byte pipe → host PTY /tmp/ttyTJC → KlipperLCD`.
> The printer board also stops using USB: it talks to the MKS Pi over a 3-wire link on
> **J17 (former WiFi socket) = `USART2 PA3/PA2`** → Pi `UART0 /dev/ttyS0`.

- Status: **verified end-to-end** (2026-11-11; Klipper `state: ready`, zero retransmits/drops, screen hot-plug auto-reconnect)
- Firmware layout: **Katapult `@0x08000000` (16 KiB boot region) + Klipper `@0x08004000` (16 KiB offset)**
- Includes: on-screen **WiFi scan/connect panel**, **one-click deploy script**, full troubleshooting notes

---

## 1. Architecture

```text
                 J17 (USART2 PA3/PA2, 250000 8N1, 3.3V TTL)
   ┌──────────────────────┐   GND / TXD2 / RXD2   ┌──────────────────────────┐
   │  Elegoo Neptune 3 Pro│◄──── 3-wire link ────►│  MKS Pi V1.1 (Armbian)   │
   │  ZNP Robin Nano_DW   │                       │  /dev/ttyS0 (UART0)      │
   │  V2.2 / STM32F401RCT6│                       │  Klipper + Moonraker     │
   │                      │                       │  screen_bridge.py        │
   │   ┌───────────────┐  │  J33 (USART6 PA12/PA11, 115200 8N1)  │  /tmp/ttyTJC (PTY)   │
   │   │ Stock TJC LCD │  │◄── original phone cable ────────────►│  KlipperLCD          │
   │   │ TJC4827X243_011│ │                       └──────────────────────────┘
   │   └───────────────┘  │
   └──────────────────────┘
```

| Link | Interface | Pins | Baud |
|---|---|---|---|
| Host ↔ mainboard | `J17` ↔ Pi `UART0` `/dev/ttyS0` | `PA2(TXD2)` / `PA3(RXD2)` / `GND` | **250000** |
| Mainboard ↔ stock LCD | `J33` (4P4C phone jack) | `PA11(TXD6)` / `PA12(RXD6)` | **115200** |
| Host ↔ screen service | Klipper `[screen_bridge]` → PTY | `/tmp/ttyTJC` | 115200 |

---

## 2. Three addresses, two baud rates (memorize before you start)

| Item | Value | Note |
|---|---|---|
| Katapult start | `0x08000000` | occupies 16 KiB boot region (~2.3 KB binary) |
| Klipper start | **`0x08004000`** | **16 KiB offset — not 32 KiB** |
| Host link | `USART2 PA3(RX)/PA2(TX)`, J17, **250000** | to Pi `/dev/ttyS0` |
| Screen link | `USART6 PA12(RX)/PA11(TX)`, J33, **115200** | original cable, MCU bridge |

> ⚠️ **Three fatal traps**
> 1. **Never flash Klipper at `0x08000000`** — it overwrites the bootloader; recovery requires SWD.
> 2. **The screen port is NOT `USART6 PC7/PC6`** — those are `Z_STEP` / `E0_EN` on this board. The panel is on `PA12/PA11`.
> 3. **Don't mix old artifacts** — the old build is 32 KiB offset / 500000 baud; the final one is **16 KiB / 250000**
>    (`out/klipper.bin` 35,864 B, reset vector `0x08004271`).

---

## 3. Repository layout

```text
neptune3pro-klipper-screen-bridge/
├── README.md / README.en.md           # Chinese / English (this file)
├── LICENSE                            # GPL-3.0
├── deploy/
│   ├── install.sh                     # ★ one-click: patch + config + screen service + optional flash
│   ├── flash.sh                       # firmware upgrade only (Katapult)
│   ├── verify.sh                      # post-deploy health check (read-only)
│   └── uninstall.sh                   # remove deployment (does not touch board firmware)
├── src/
│   ├── klipper_bridge/
│   │   ├── screen_bridge.c            # MCU side: USART6(PA12/PA11) ↔ Klipper byte pipe
│   │   ├── screen_bridge.py           # host side: PTY /tmp/ttyTJC (hot-plug keep-alive)
│   │   └── .config                    # Klipper build config (F401xc / 16 KiB / USART2 / WANT_SCREEN_BRIDGE)
│   ├── KlipperLCD/                    # main.py / lcd.py / printer.py / lib_col_pic.py / service
│   └── config/printer.cfg             # final Neptune 3 Pro config
├── artifacts/
│   ├── katapult_F401_USART2_J17.bin           # bootloader @0x08000000 (2,286 B)
│   ├── klipper_F401_USART2_J17_bridge.bin     # application @0x08004000 (35,864 B)
│   └── 20240129.tft                           # TJC4827X243_011 panel firmware (6.6 MB)
└── docs/
    ├── RUNBOOK.zh.md                  # full procedure (build → flash → configure → debug)
    ├── 改造方案与踩坑总结.md           # design notes + six pitfalls (Chinese)
    ├── 烧录说明.txt                    # dual-segment flashing cheat-sheet (Chinese)
    └── ZNP_Robin_Nano_DW_V2.2_SCH.pdf # official mainboard schematic
```

---

## 4. One-click deploy (recommended)

Prerequisites: **Klipper + Moonraker + Mainsail** already installed on the MKS Pi (KIAUH), and **Katapult already flashed** on the board (see §5.3).

```bash
# 1) fetch and run the installer (patches Klipper, installs config + screen service, optionally flashes)
curl -fsSL https://raw.githubusercontent.com/zhangbo010/neptune3pro-klipper-screen-bridge/main/deploy/install.sh -o /tmp/install.sh
sudo bash /tmp/install.sh --flash --yes

# 2) health check
curl -fsSL https://raw.githubusercontent.com/zhangbo010/neptune3pro-klipper-screen-bridge/main/deploy/verify.sh -o /tmp/verify.sh
sudo bash /tmp/verify.sh
```

Or clone and run locally:

```bash
git clone https://github.com/zhangbo010/neptune3pro-klipper-screen-bridge.git
cd neptune3pro-klipper-screen-bridge
sudo bash deploy/install.sh --dry-run          # preview only
sudo bash deploy/install.sh --flash --yes      # do it
sudo bash deploy/verify.sh                     # verify
```

**What the installer does (8 stages, idempotent)**

| Stage | Action |
|---|---|
| 0 | Preflight: Klipper dir, python3, serial device, getty/kernel-console conflicts, dialout group |
| 1 | Copy `screen_bridge.c/.py` into the Klipper tree and patch `src/stm32/Makefile` + `src/stm32/Kconfig` (skipped if already patched) |
| 2 | Back up and install `printer.cfg`, set serial device/baud, comment out missing `[include]` files |
| 3 | Install KlipperLCD (clone + overlay enhanced files), `pyserial`, systemd unit, `nmcli` sudoers rule |
| 4 | With `--build`: apply `.config`, compile, verify offset/baud/`bridge_*` symbols |
| 5 | With `--flash`: stop Klipper → Katapult `-r` → `-f` firmware → restart |
| 6 | Restart Klipper / Moonraker / KlipperLCD |
| 7 | Verify: services, `/tmp/ttyTJC`, minimal-config MCU handshake (`mcu_version`) |
| 8 | Print summary and next steps |

**Options**

| Option | Meaning |
|---|---|
| `--flash` | flash firmware over Katapult after deploying (off by default) |
| `--build` | build firmware from source (default: use prebuilt bins in `artifacts/`) |
| `--yes` / `-y` | non-interactive |
| `--dry-run` | print commands only |
| `--port /dev/ttyS0` | host serial device |
| `--baud 250000` | host baud rate |
| `--klipper-dir` / `--katapult-dir` / `--lcd-dir` | custom install paths |
| `--no-patch` / `--no-config` / `--skip-lcd` | skip individual stages |

---

## 5. Detailed procedure

### 5.1 Prerequisites

| Item | Requirement |
|---|---|
| Printer | Elegoo Neptune 3 Pro (**not** Neptune 3 / Neptune 4 — different boards) |
| Mainboard | `ZNP Robin Nano_DW V2.2`, `STM32F401RCT6`, 8 MHz crystal |
| Display | Stock TJC `TJC4827X243_011`, 4P4C phone cable |
| Host | MKS Pi V1.1 (RK3328 / 1 GB) or any Debian ARM host with a 3.3 V UART |
| OS | Armbian / Debian 12 bookworm with Klipper + Moonraker + Mainsail |
| Tools | ST-Link (first flash / recovery), 3 dupont wires, multimeter |

```bash
ls -l /dev/ttyS0                                  # UART0 must exist
cat /proc/cmdline | tr ' ' '\n' | grep console    # console must not be ttyS0
systemctl status serial-getty@ttyS0               # must be inactive
stty -F /dev/ttyS0 -a | head -1                   # sanity check
sudo usermod -aG dialout klipper
```

Klipper stack (skip if already installed):

```bash
cd ~ && git clone https://github.com/dw-0/kiauh.git && ./kiauh/kiauh.sh
# install: Klipper, Moonraker, Mainsail
```

### 5.2 Wiring

**① Mainboard J17 (former WiFi socket) ↔ MKS Pi UART0** — 3 wires, TX/RX crossed

| J17 | Signal | Connect to MKS Pi |
|---|---|---|
| 1 | `+5V` (module supply output) | **leave open — never connect** (otherwise 5 V back-feeds the Pi) |
| 2 | `GND` | `GND` (physical pin 6) |
| 3 | `TXD2` (`PA2`, MCU TX) | `UART0_RX` (GPIO15 / physical pin 10) |
| 4 | `RXD2` (`PA3`, MCU RX) | `UART0_TX` (GPIO14 / physical pin 8) |

> - 3.3 V TTL direct, **connect/disconnect with power off**.
> - Remove the onboard WiFi module (`ROBIN-WIFI`, M1) — otherwise it shares USART2 and fights for the bus; alternatively pull its `EN` low.

**② Mainboard J33 (4P4C phone jack) ↔ stock display** — zero modification

- Plug the original cable straight into `J33`; no cutting, no adapter.
- `J33.3 = TXD6 → PA11`, `J33.4 = RXD6 → PA12`, `115200 8N1`.
- Panel 5 V comes from J33 pin 1 (wire order: black=5V, red=GND, green=RX, yellow=TX — **verify by pin position, not colour**).

**③ Power-up order**: printer 24 V → Pi boots (~40 s) → Klipper → Moonraker → KlipperLCD.

### 5.3 First flash: Katapult bootloader (once)

Pick one method. **Back up the official firmware first** (Elegoo SD-card update package) — the stock bootloader will be overwritten.

**A. ST-Link SWD (recommended)**

| Signal | Mainboard J1 |
|---|---|
| 3.3V | 3.3V (reference only; do not tie to board rails) |
| GND | GND |
| SWDIO | SWDIO |
| SWCLK | SWCLK |
| NRST | **not wired on J1**; use `Connect under reset` |

In STM32CubeProgrammer use **Connect under reset**: write `artifacts/katapult_F401_USART2_J17.bin` at **`0x08000000`**, then `artifacts/klipper_F401_USART2_J17_bridge.bin` at **`0x08004000`**; power-cycle afterwards.

**B. BOOT0 + chip ROM bootloader (no ST-Link)**

1. Short **J10 jumper 1-2** (pin 1 = BOOT0/pin 60, pin 2 = +3V3); measure J10-1 to GND = **3.3 V**;
2. Keep the jumper, **power-cycle** (BOOT0 is sampled only at reset);
3. Connect the mainboard USB (CH340) to the Pi → `/dev/ttyUSB0`;
4. Write in two passes — **do not use `-e` (full erase)**:

```bash
stm32flash -b 115200 -m 8e1 -w artifacts/katapult_F401_USART2_J17.bin       -S 0x08000000 -v /dev/ttyUSB0
stm32flash -b 115200 -m 8e1 -w artifacts/klipper_F401_USART2_J17_bridge.bin -S 0x08004000 -v /dev/ttyUSB0
```

5. Remove J10 → power-cycle.

> The CH340's DTR# is capacitively coupled to RESET via C33, so opening the port pulses reset — that is expected and helpful when BOOT0 is high.

### 5.4 Routine OTA upgrade (Katapult present, no disassembly)

```bash
sudo bash deploy/flash.sh            # prebuilt artifact
sudo bash deploy/flash.sh --built    # ~/klipper/out/klipper.bin
```

Equivalent manual commands:

```bash
sudo systemctl stop klipper
python3 ~/katapult/scripts/flashtool.py -d /dev/ttyS0 -b 250000 -r
sleep 0.5
python3 ~/katapult/scripts/flashtool.py -d /dev/ttyS0 -b 250000 -f ~/klipper/out/klipper.bin
sudo systemctl start klipper && sudo systemctl restart KlipperLCD
```

- If `-r` fails: **double-tap J1 5(RESET)-6(GND)**, or power-cycle and retry.
- Always compare the SHA reported by flashtool with your local `sha256sum`.

### 5.5 printer.cfg

`src/config/printer.cfg` is the final version (pins, fans, `[screen_bridge]`). Key lines:

```ini
[mcu]
serial: /dev/ttyS0
baud: 250000
restart_method: command

[screen_bridge]
pty: /tmp/ttyTJC
baud: 115200
```

> Machine-specific values (re-tune for another unit): `extruder rotation_distance: 7.53`,
> `nozzle_diameter: 0.600`, `Z endstop: PB4`, `safe_z_home: 146.0, 95.5`.
> Probe and `bed_mesh` are commented out; with a CR-Touch, uncomment them and switch Z to `probe:z_virtual_endstop`.

### 5.6 KlipperLCD service + WiFi panel

Already handled by the installer; manual steps:

```bash
cd ~ && git clone https://github.com/joakimtoe/KlipperLCD.git
cd KlipperLCD
cp <repo>/src/KlipperLCD/{main.py,lcd.py,printer.py,lib_col_pic.py} .
pip3 install pyserial --break-system-packages
python3 -m py_compile main.py lcd.py printer.py
sudo cp <repo>/src/KlipperLCD/KlipperLCD.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now KlipperLCD
# WiFi panel needs passwordless nmcli
echo 'klipper ALL=(ALL) NOPASSWD: /usr/bin/nmcli' | sudo tee /etc/sudoers.d/klipper-nmcli
sudo chmod 440 /etc/sudoers.d/klipper-nmcli
```

Panel operation:

- **Macro page**: dropdown lists `[RESCAN_WIFI]` + strongest APs → select → Send → jumps back to Console;
- **Console page**: tap the input box, type the password, Send → `nmcli` connects; wrong password falls back to the previous network;
- Non-ASCII SSIDs are filtered out (panel font has no CJK glyphs); ASCII SSIDs work.

### 5.7 (Optional) Build firmware from source

Only needed if you change pins / baud rates / bridge logic.

**Katapult** (16 KiB bootloader):

```bash
cd ~ && git clone https://github.com/Arksine/katapult.git && cd katapult
make menuconfig
#   STM32 / STM32F401 / 16KiB bootloader (0x8004000) / 8 MHz crystal
#   Serial (on USART2 PA3/PA2) / 250000 / entry on double reset = y
make
# out/katapult.bin (final: 2,286 B)
grep -E 'FLASH_APPLICATION_ADDRESS|SERIAL_BAUD|STM32_SERIAL_USART2 |ENABLE_DOUBLE_RESET' out/autoconf.h
```

**Klipper** (16 KiB + screen bridge):

```bash
cd ~/klipper
cp <repo>/src/klipper_bridge/screen_bridge.c  src/stm32/
cp <repo>/src/klipper_bridge/screen_bridge.py klippy/extras/
# Makefile: after the src-$(CONFIG_SERIAL) line, add
#   src-$(CONFIG_WANT_SCREEN_BRIDGE) += stm32/screen_bridge.c
# Kconfig: before the last endif of src/stm32/Kconfig, add WANT_SCREEN_BRIDGE / STM32_SCREEN_BRIDGE_BAUD
cp <repo>/src/klipper_bridge/.config .config
make olddefconfig && make
# verify
grep -E 'FLASH_APPLICATION_ADDRESS|SERIAL_BAUD=|SCREEN_BRIDGE' out/autoconf.h
grep -E 'bridge_(tx|rx|config|reset|get_stats)' out/compile_time_request.txt
xxd -l 8 out/klipper.bin     # reset vector must be 0x08004xxx
sha256sum out/klipper.bin    # expect 54c573d1…df957e86, 35,864 B
```

`menuconfig` highlights: `STM32F401` / **16 KiB bootloader** / 8 MHz crystal / **Serial (USART2 PA3/PA2)** / 250000 / enable low-level options / **Serial screen UART bridge (USART6 PA12/PA11) = y** / bridge baud 115200.

### 5.8 Verification checklist

1. `cat /proc/tty/driver/serial`: `ttyS0` tx/rx counters increase, no sustained `brk/oe`;
2. Klipper `state: ready`; `mcu_version` matches the `~/klipper` commit;
3. `ls -l /tmp/ttyTJC` exists (points to `/dev/pts/N`);
4. Panel shows the main screen; temperatures/IP match Mainsail;
5. **Hot-plug**: unplug the phone cable for 2 s and replug — main screen returns within 1–2 s;
6. WiFi panel: scan, connect, wrong-password fallback;
7. `STEPPER_BUZZ STEPPER=stepper_x` (x/y/z/extruder); invert `dir_pin` with `!` if needed;
8. `QUERY_ENDSTOPS` with manual triggering of X/Y/Z; first `G28` with hand on the e-stop;
9. `PID_CALIBRATE HEATER=extruder TARGET=200`, `HEATER=heater_bed TARGET=60` → `SAVE_CONFIG`;
10. Dry-run a 20×20 square → first layer → Benchy.

---

## 6. Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| Panel dead, Klipper says `Pin PC7 is reserved` | bridge built on `PC6/PC7` (Z_STEP/E0_EN) | rebuild with `PA12/PA11` (USART6 AF8) |
| `Timeout on connect` after flashing | old 32 KiB / 500000 build | use 16 KiB / 250000; `xxd` reset vector must be `0x08004xxx` |
| Katapult not responding | already jumped to app / missed 500 ms window | `flashtool -r`; double-tap J1 5-6; power-cycle |
| ST-Link `TransferError 0x06` | old firmware runs away, J1 has no NRST | `Connect under reset` + halt on reset vector (see docs) |
| Panel stuck on boot logo | idle with no data, panel's `0x1A` dropped | use enhanced `lcd.py`/`main.py` (`0x1A`/`0x88` re-init + 4 s heartbeat) |
| KlipperLCD disconnects after replug | PTY destroyed when Klipper restarts | use `screen_bridge.py` (disconnect/shutdown keep-alive + inode tracking) |
| Host serial retransmits | baud not 250000 | unify Katapult, firmware and `[mcu] baud` |
| Pi won't boot with J17 connected | J17 +5V wired to Pi | connect only GND/TX/RX |
| WiFi module fights for UART | `ROBIN-WIFI` still on J17 | remove module or pull `EN` low |
| White/garbled panel | panel firmware / wire order / 5 V | reflash `20240129.tft`; check 5V/GND/RX/TX by pin position |

---

## 7. Upgrade & rollback

**Upgrade**: `sudo bash deploy/flash.sh --built`

**Roll back Klipper**: flash the previous `klipper.bin` (also 16 KiB / 250000) via `flashtool`.

**Back to stock Marlin**: ⚠️ the stock bootloader has been replaced by Katapult and **this repo does not ship official firmware**.
You need to rebuild Katapult with a **32 KiB offset**, then write the official firmware at **`0x08008000`** via SWD.
Therefore: **back up the official firmware binary before you touch the board.**

---

## 8. Artifact checksums (SHA256)

| File | Size | SHA256 |
|---|---:|---|
| `artifacts/katapult_F401_USART2_J17.bin` | 2,286 | `bc235d64f6dcd6844d08f5077fda5b5e5bce05558070387d99318ef3b0d93465` |
| `artifacts/klipper_F401_USART2_J17_bridge.bin` | 35,864 | `54c573d11df2c7a47be8247d2541a9bf7152d121596efecd1e910c57df957e86` |
| `artifacts/20240129.tft` | 6,638,240 | `cb2bda95dbfd4cb8caad1e0cf3ef3e708177a9f3c66dcf2e64b9d28a646b9567` |

---

## 9. License & credits

- This repository: **GNU GPL v3.0** ([LICENSE](LICENSE)). It contains Klipper-derived code, so GPL applies.
- Built on / thanks to:
  - [Klipper](https://github.com/Klipper3d/klipper) (Kevin O'Connor, GPL-3.0)
  - [Katapult](https://github.com/Arksine/katapult) (Arksine, GPL-3.0)
  - [KlipperLCD](https://github.com/joakimtoe/KlipperLCD) (joakimtoe, GPL-3.0) and its panel firmware `20240129.tft`
  - Elegoo official schematic `ZNP_Robin_Nano_DW_V2.2_SCH.pdf`
- Disclaimer: modifying a printer is risky (overwriting the stock bootloader, damaging board or panel). Back up the stock firmware and proceed at your own risk.
