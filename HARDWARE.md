# C1-Slim — device reference

**[English](HARDWARE.md) · [简体中文](HARDWARE.zh-CN.md)**

快易典 C1-Slim / MP-D261. Everything here was established on real hardware; none of it
appears in any datasheet we could find. Unverified items are marked as such.

---

## 1. Overview

A 296 × 152 monochrome e-ink device with a full QWERTY keyboard, running a **Buildroot
Linux userland** — not Android — on an Ingenic X1600. Root over ADB out of the box.

| | |
|---|---|
| SoC | Ingenic X1600 · XBurst1 MIPS32r2 LE · 1 core · `cpufreq-dt` |
| RAM | 64 MB (`mem=64M@0x0`) |
| Storage | 64 GB eMMC — 122 142 720 × 512 B sectors |
| Kernel | Linux 5.10.186 · Buildroot userland · SysV init · BusyBox |
| Panel | SEEKINK E0266A128 · 296 × 152 · 1 bpp · ~125 DPI · 60 × 31 mm |
| Keyboard | 40 keys — 30 matrix (`event0`) + 10 GPIO (`event1`) |
| LEDs | 4 · led2/3 green, led4/5 red · on/off only |
| Wi-Fi | AltoBeam ATBM603x · SDIO `007A:6011` · 2.4 GHz b/g/n HT40 |
| Bluetooth | **none** |
| Audio | ALSA card `halley6`, codec ES8326 — mic, speaker, 3.5 mm jack |
| Other | battery + AC/USB detect · RTC `/dev/rtc0` · 2 × I²C · 1 × UART |
| Absent | camera, vibration motor, SPI, touch |

`halley6` is Ingenic's own X1600 reference board name, so the vendor stayed close to the
reference design — Ingenic Halley6 material is likely to apply.

### 1.1 What "not Android" means in practice

SysV init scripts, BusyBox, ALSA used directly, vendor character devices instead of HALs.
No property service, no `pm`, no ART, no APKs.

The one Android component is **adbd**, lifted from AOSP and still reporting the LG Nexus 4
identity (`product:occam model:Nexus_4 device:mako`, Android 4.2, 2012). Consequence:
**adb features added after ~2012 are missing** — notably `adb exec-out`, which fails with
`error: closed`. Use `adb pull` / `adb push`.

---

## 2. Boot and recovery

### 2.1 Boot chain

```
BootROM  (mask ROM inside the SoC — cannot be erased or corrupted)
└─ eMMC user area, sector 0 — "INGE" magic
   └─ U-Boot SPL 2013.07
      └─ U-Boot        console ttyS2 @ 1500000 8N1, bootdelay=1
         └─ kernel → /dev/mmcblk0p7 (ext4, read-only) → C1ancher
```

Shipped `bootargs`:

```
console=ttyS2,1500000n8  rootfstype=ext4 root=/dev/mmcblk0p7 rootdelay=1 ro mem=64M@0x0
```

The U-Boot binary carries a second set using `root=/dev/ram0 rdinit=/linuxrc` — an
initramfs rescue path exists but is not selected by default.

### 2.2 Partition map

| Region | Start sector | Size | Mount |
|---|---|---|---|
| SPL + U-Boot | 0 | 3 MB | raw, **not a partition** |
| p1 | 6 144 | 9 MB | not mounted, role unknown |
| p2 | 24 576 | 16 MB | not mounted, role unknown |
| p3 | 57 344 | 16 MB | not mounted, role unknown |
| p4 | 90 112 | 68 MB | not mounted, role unknown |
| p5 | 229 376 | 200 MB | `/usr/resource` rw |
| p6 | 638 976 | 100 MB | `/usr/data` rw |
| p7 | 843 776 | 400 MB | `/` ext4 **read-only** |
| p8 | 1 662 976 | 60 GB | `/storage` rw |

`mmcblk0boot0` / `boot1` exist (4 MB each) but are **entirely zero** — the hardware eMMC
boot partitions are unused. All boot code lives in the 3 MB gap ahead of p1, which
per-partition backups do not cover.

### 2.3 Whole-system image

Sectors 0 – 1 662 975 (**812 MiB**) contain everything that makes this device itself.
p8 is user data and is not part of it.

```sh
adb shell 'dd if=/dev/mmcblk0 of=/storage/c1-system.img bs=1M count=812'
adb shell 'sha256sum /storage/c1-system.img'
adb pull /storage/c1-system.img .
shasum -a 256 c1-system.img            # must match
head -c 4 c1-system.img | xxd          # must read INGE
adb shell 'rm /storage/c1-system.img'
```

### 2.4 BootROM USB recovery — confirmed

The X1600 selects its boot source from two straps sampled at power-on. On this board
**both are wired to keys**, which is why trying single keys never works:

| Strap | GPIO | Key |
|---|---|---|
| BOOT_SEL0 | PC27 — gpio-91, kernel label `KEY_ENTER` | **Enter** |
| BOOT_SEL1 | PC28 — gpio-92, claimed by no driver | **Back** |

| boot_sel[1:0] | Source | Result here |
|---|---|---|
| `00` nothing held | MSC0 (eMMC) | normal boot |
| `01` Enter | SFC0 (SPI flash) | none fitted — does not boot |
| `10` Back | NOR | none fitted — does not boot |
| `11` **Back + Enter** | **USB** | **BootROM USB recovery** |

Hold **Back + Enter**, then plug in USB. The device enumerates as:

```
idVendor  0xa108     Ingenic
idProduct 0xEAEF
product   "Ingenic USB BOOT DEVICE"
```

This sits below U-Boot, below the SPL, below everything on eMMC, and software cannot
damage it. **Entering it writes nothing** — the BootROM only waits for a host.

**Host side is unproven.** No cloner tool has yet been built on macOS and talked to this
device, so reading and writing over this channel is not yet demonstrated.

### 2.5 Getting back out — read before going in

Once in BootROM USB mode:

- **Unplugging USB does not exit.** An internal battery keeps the SoC powered.
- **Long-pressing power does not exit.** Power-off here is implemented in software and
  no kernel is running.
- **The screen tells you nothing.** E-ink holds its last image with no power.

The way out is the **reset pinhole beside the power key** — press it and the device
cold-boots normally. Without it, the only exit is draining the battery (hours).

### 2.6 U-Boot `softburn`

The U-Boot image carries a `softburn` command ("Ingenic usb soft burn") reaching the same
USB burn mode from a U-Boot prompt. That needs UART on `ttyS2` at **1 500 000 baud** —
most cheap adapters top out below it; CH343P and FT232RL work, older CP2102 does not.
Since Back + Enter reaches the BootROM directly, `softburn` is redundant here and remains
**untested**. Whether UART is even brought out to pads is **unverified** (case never
opened).

### 2.7 Write risk

| Target | Risk | Recovery |
|---|---|---|
| panel, LEDs, `/tmp`, `/dev/shm` | none | power cycle |
| p5, p6, p8 | none | not part of boot |
| files on p7, incl. `/etc/app_daemon` | low | re-push over ADB |
| `/etc/init.d/S90usb`, `/etc/init.d/usb/adb` | **high** | BootROM |
| p1–p4 | unknown | BootROM |
| sectors 0–6143, U-Boot environment | high | BootROM + image |

`app_daemon` is safe to break: `S80app` starts it with `&` and returns immediately, while
adbd is started separately by `S90usb` → `/etc/init.d/usb/adb`. Those two files are
correspondingly the ones not to touch — **they are the only channel into the device**.
There is no second channel: sshd is installed but cannot start, because `ssh-keygen -A`
writes into the read-only `/etc/ssh`, and root's password field is `*`.

Editing p7: `mount -o remount,rw /` → edit → `sync` → `mount -o remount,ro /`. The device
**cannot power itself off** (no `pm_power_off`), so every shutdown is a hard cut; leaving
`/` mounted rw is the most realistic way to actually lose data here.

---

## 3. Display

### 3.1 Framebuffer layout — strip-major

```
byte = buf[(y >> 3) * 296 + x]
bit  = 7 - (y & 7)
1    = black
```

19 horizontal strips of 8 pixels. Each strip is 296 consecutive bytes, one per column;
each byte holds 8 vertically-stacked pixels, MSB topmost. Total **5 624 bytes**.

Authoritative source — `c1_display_frame_set_pixel()` in `src/display/frame.c`:

```c
offset = (y / C1_DISPLAY_STRIP_HEIGHT) * C1_DISPLAY_WIDTH + x;
mask   = (uint8_t)(0x80U >> (y % C1_DISPLAY_STRIP_HEIGHT));
```

**The trap:** column-major (296 × 19) and strip-major (19 × 296) both total 5 624 bytes.
A size check cannot tell them apart, and a pack/unpack round-trip passes either way
because it is self-consistent. Verify against the source or the panel, never against your
own round-trip.

### 3.2 One `write()` per frame

The driver treats **every `write()` as the start of a new frame**. A chunked write renders
only the last chunk at the top-left — with a horizontal offset too, if the chunk boundary
is not strip-aligned.

```sh
cat frame.bin > /dev/epaper_lcd                      # WRONG — may split
dd if=frame.bin of=/dev/epaper_lcd bs=5624 count=1   # RIGHT — one syscall
```

### 3.3 Refresh timing — measured

| Operation | Panel time | Notes |
|---|---|---|
| Write frame only | **~150 ms** | the write alone updates the panel; no sysfs poke needed |
| Write + `echo 1 > refresh` | **~700 ms** | full refresh, visible black inversion flash |

Two independent methods agree. **30 fps video frame-counting**: write-only settles in 4–5
frames (133–167 ms, three observations); `echo 1 > refresh` produced white → **black** →
white over 21 frames (~700 ms), the black phase being the ghost-clearing waveform.
**Polling `refresh_cnt`**: 670, 670, 680, 680, 670 ms (σ ≈ 5 ms). Cross-check: C1ancher's
README quotes "about 150 ms" for terminal fast refreshes — the constant came from the
hardware.

**Writes to `refresh` are non-blocking.** They return in 10–20 ms; the panel updates
afterwards. Timing the syscall measures nothing.

`echo 0 > refresh` is **unconfirmed** — one observation looked like a fast update rather
than a full refresh, but that is a single sample. Use `1`.

### 3.4 `refresh_cnt` is not a completion counter

Readable and changing, but **not monotonic** — observed `30 → 31 → 1 → 3`, and `6 → 31`
after writing `1`. With `refresh_max = 30` it behaves like a partial-refresh cycle
counter: count up, force a full refresh at the limit, reset. Usable only as a coarse
completion signal for a full refresh, never as a frame counter.

### 3.5 The framebuffer cannot be read back

`/dev/epaper_lcd` is write-only (char major 10, minor 61); `read()` returns 0 bytes. There
is no `/dev/fb*`.

For screenshots, patch the renderer to tee each frame —
[`patches/display-shadow.patch`](patches/display-shadow.patch) writes every frame to
`/dev/shm/c1-screen.bin` (tmpfs, no eMMC wear) after a successful panel write; `adb pull`
it for a pixel-exact capture. Costs 4 bytes of binary size.

### 3.6 sysfs

`/sys/devices/platform/e0266a128/epaper/`

| Attribute | Mode | Notes |
|---|---|---|
| `refresh` | `--w-------` | write `1` for a full refresh; non-blocking |
| `refresh_cnt` | `-r--r--r--` | cycle counter, not monotonic |
| `refresh_max` | `-rw-r--r--` | `30` — partial refreshes before a forced full one |
| `fast_refresh_only` | `-rw-r--r--` | `1` suppressed the full-refresh path in our tests |

### 3.7 Design consequences

The binding constraint is **refresh time, not resolution or colour depth**. Static content
is free and permanent; changing pixels is what costs.

- Approval cards, status pages, reference sheets → full refresh. 700 ms buys a clean,
  ghost-free image, and a decision prompt does not need faster.
- Terminals and continuous output → write the frame, don't poke `refresh`. ~150 ms, and
  the call returns in 10–20 ms so it never blocks the loop.
- Expect a periodic ~700 ms hitch: after roughly `refresh_max` partial updates the driver
  forces a full refresh.
- **Use the LEDs for anything that must feel instant.** A GPIO write is immediate; the
  panel is not. Screen answers "what", LED answers "whether".
- 152 = 19 × 8 exactly, so any element whose vertical extent starts on a multiple of 8
  blits as plain byte stores. Off-grid placement needs shift + mask.
- A 1 px horizontal line touches 296 bytes; a 1 px vertical line touches 19 bytes in one
  strip. Vertical elements are far cheaper.
- Use **ordered (Bayer) dithering, not error diffusion**, for UI. Ordered patterns are
  spatially fixed, so a small content change flips only the pixels that changed;
  Floyd–Steinberg re-randomises whole regions and ghosts badly. Error diffusion is still
  right for photographs.
- At ~125 DPI a 1 px rule is ~0.2 mm — a hairline. The panel supports finer detail than
  the 72 DPI classic-Mac aesthetic suggests.

### 3.8 Writing to the panel directly

C1ancher owns the display and redraws periodically, so it paints over anything you write:

```sh
adb shell '/etc/init.d/S80app stop'
# ... your writes ...
adb reboot
```

---

## 4. Input

Full 26-letter QWERTY plus Shift, Space, Enter, Delete, arrows, Back, OK, Home, Wakeup and
volume keys — 30 matrix keys on `/dev/input/event0`, 10 GPIO keys on `event1`. Scan codes
in [`config/c1-slim/keyboard.csv`](config/c1-slim/keyboard.csv).

C1ancher maps OK-hold + letter to Ctrl+A–Z, OK click to Tab, Back to Esc — enough to drive
`vi`, `top`, `less` and an interactive `ssh` session in its built-in terminal.

### 4.1 GPIO key map (Port C)

Live levels are readable at pin register `0x10010200`, which is how the boot straps were
found:

```sh
adb shell 'while true; do busybox devmem 0x10010200; sleep 0.1; done' | awk '!seen[$0]++'
```

| Bit | GPIO | Key | Note |
|---|---|---|---|
| 0 | PC0 | Emoji (Home) | |
| 1 | PC1 | Shift | |
| 2 | PC2 | Volume down | |
| 26 | PC26 | — | `sdio_power`, toggles with Wi-Fi |
| **27** | **PC27** | **Enter** | **BOOT_SEL0** |
| **28** | **PC28** | **Back** | **BOOT_SEL1** |
| 31 | PC31 | Power | active low |

Other GPIO labels from `/sys/kernel/debug/gpio` (mount debugfs first): `matrix_kbd_row/col`,
`lcd-reset/dc/busy/cs/sdi/sck`, `up/down/left/right/ok`, `DELETE`, `key_p`, `wifi_reset`,
`led2`–`led5`, `ingenic,audio-select`, `charge_stat`, `vbus_detect`, `ingenic,spken`.

---

## 5. LEDs

Four, via the standard Linux LED class under `/sys/class/leds/`, from the vendor's
`mpen,gpio-leds` node.

| Node | Colour |
|---|---|
| `led2`, `led3` | green |
| `led4`, `led5` | red |

`max_brightness` reads `255` but **there is no PWM** — 8, 32, 96 and 255 look identical.
Treat as binary.

Expressiveness comes from kernel triggers instead, at no CPU cost:

```
none  timer  oneshot  heartbeat  mtd  nand-disk  mmc0  mmc1
battery-charging  battery-full  battery-charging-or-full
battery-charging-blink-full-solid  ac-online  usb-online
rfkill-any  rfkill-none  kbd-*lock
```

`timer` gives arbitrary blink rates via `delay_on` / `delay_off` (ms); `oneshot` blinks
once; `heartbeat` follows CPU load. **A `timer` trigger overrides manual `brightness`
writes** — set `trigger` to `none` first:

```sh
echo none > /sys/class/leds/led4/trigger
echo 255  > /sys/class/leds/led4/brightness
```

At least one LED is on a charging trigger by default (red while charging with the device
powered off), so note the original `trigger` before taking one over.

---

## 6. Wireless

**AltoBeam ATBM603x**, SDIO, module `atbm603x_wifi_sdio.ko` (818 KB, vendor blob).

```
SDIO_ID=007A:6011   DRIVER=atbm_wlan   MODALIAS=sdio:c00v007Ad6011
```

Loaded **on demand** — by default there is no `wlan0` and `/proc/modules` is empty, so the
radio is fully unpowered at rest. The vendor provides `/bin/wifi_up.sh` and
`/bin/wifi_down.sh`; `wifi_up.sh` does `insmod`, waits for `wlan0`, then starts
`wpa_supplicant` with the **stock** config at `/usr/resource/wpa_supplicant.conf` —
C1ancher uses its own at `/usr/data/c1/wifi/wpa_supplicant.conf`, so don't mix the two
(reboot after running `wifi_up.sh` by hand).

The module path is `.../atbm_wifi_40M/hal_apollo/`. "Apollo" is the ST-Ericsson **CW1200**
codename, so this driver is a CW1200 derivative — mainline
`drivers/net/wireless/st/cw1200/` is a distant relative.

### 6.1 No Bluetooth

Four independent negative checks: no `/sys/class/bluetooth`, no `/proc/net/bluetooth` (no
BT stack compiled in), nothing in `/proc/devices`, no `hci*` nodes. The only kernel modules
on the whole system are the Wi-Fi driver and one netfilter module.

The ATBM6031 datasheet lists no Bluetooth. Newer parts in the family (ATBM6012B-X, 6132,
6162) are BLE 5.0 combos, but the SDIO ID here is `6011`, the base tier. Even with the
silicon, the kernel would need a BT stack, an HCI transport and firmware — none present.

---

## 7. Audio

```
card 0: halley6
  capture  device 0: i2s-ecodec es8326.1-0018-0    (I²C bus 1, address 0x18)
  capture  device 1: i2s-tloop dump_pcm_codec-1
  playback device 0: i2s-ecodec es8326.1-0018-0
```

Microphone, speaker and the 3.5 mm jack all work. Mixer controls include `Analog
Headphone`, `Speaker Enable`, `ADC PGA Gain`, `ALC …`, `DRC …`. Headset detection is
exposed Android-style at `/sys/class/switch/h2w/state` (0 = none, 1 = headset with mic,
2 = headphone).

```sh
arecord -D hw:0,0 -f S16_LE -r 16000 -c 1 -d 3 /tmp/t.wav
```

16 kHz mono S16LE is the standard ASR input format, so the mic feeds a speech pipeline
with no resampling.

Measured on one sample of ordinary speech: peak −0.83 dBFS, RMS −23.7 dBFS, crest factor
22.8 dB. Crest factor is normal for speech, but the peak is under 1 dB from clipping —
**capture gain is set very hot**. Trim with `amixer -c 0` if ASR accuracy matters.
`scripts/device-control.sh` snapshots and restores mixer state with `alsactl … 0`.

---

## 8. Power

`/sys/class/power_supply/` exposes `battery`, `ac` and `usb`. Battery reports `status`,
`capacity` and `voltage_now` (4.192 V full); no `current_now`, no `temp`. Hardware RTC at
`/dev/rtc0`; `cpufreq-dt` present, so frequency scaling is available.

**The device cannot power itself off.** `poweroff`, `halt` and `poweroff -f` all run to
completion and leave the power on — there is no `pm_power_off` for this board. Long-press
power-off is handled in software, so it does not work when no kernel is running either.
The only hardware-level power cut is the **reset pinhole beside the power key**.

Plugging USB while off charges the device without booting it (red LED via the
`battery-charging` trigger).

---

## Appendix A — what we tried, including what failed

Negative results, in the order they were established. They are recorded because each cost
a debugging round and each closes off a plausible-looking path.

| Attempt | Outcome |
|---|---|
| Assumed Android from VID `18D1` + ADB + MTP | **Wrong** — Buildroot; only adbd is AOSP. `pm`, Launcher advice all inapplicable |
| Column-major framebuffer packing | **Wrong** — both layouts are 5 624 B so size checks and self-consistent round-trips passed; rendered as vertical stripes |
| `cat frame.bin > /dev/epaper_lcd` | **Wrong** — each `write()` starts a new frame; only the last chunk appears |
| Timed the `refresh` syscall | **Wrong by 50×** — writes to `refresh` are non-blocking |
| `adb exec-out` | Unsupported by 2012-era adbd (`error: closed`) |
| Wrote test frames to `/tmp` | `/tmp` is tmpfs — wiped by `adb reboot` |
| Wrote to the panel with C1ancher running | It redraws over you |
| `make -j4` on the C1ancher Makefile | Race — host-test links before libtsm objects. Use `-j1` |
| Hand-written 5 × 7 bitmap font | g/p/q glyphs wrong. Replaced with Ark Pixel Font (OFL-1.1), baked from PNG glyph sources |
| `poweroff`, `halt`, `poweroff -f` | All no-ops — no `pm_power_off` |
| Single keys held at power-on (Home, Power, Home+Power, stick+Power) | No recovery mode. Both straps are keys; only the **pair** works |
| Held Back alone at power-on | Device does not boot — `boot_sel = 10` = NOR, none fitted. Looks like a fault, is not |
| `cat /sys/kernel/debug/gpio` | Empty until debugfs is mounted: `mount -t debugfs none /sys/kernel/debug` |
| `cat /proc/iomem \| grep -i gpio` | Empty — GPIO is not labelled there. Use debugfs |
| Assumed sshd was a usable second channel | It is not — no host keys (`/etc/ssh` read-only), root password `*` |
| Planned an early `S15adbd` insurance script | Rejected — `S90usb` is one configfs gadget sequence; duplicating it conflicts, and editing it means editing the only channel in |
| Unplugged USB / long-pressed power to exit BootROM | Neither works — internal battery, software power-off. **Reset pinhole** is the exit |

### Host-side gotchas

- In shell scripts write `${VAR}`, not `$VAR`, when a non-ASCII character follows. Bash
  absorbs the leading UTF-8 bytes into the identifier and under `set -u` dies with
  `VAR?: unbound variable`. This bit us twice.
- `local a="$1" b=$((...))` expands all arguments before assigning — split into two
  statements or it dies under `set -u`.
- zsh does **not** treat `#` as an interactive comment unless `setopt
  interactive_comments`; pasting commented blocks gives `command not found: #`.
- E-ink holds its last image with no power, so **the panel is never evidence of device
  state**. Check USB enumeration instead.

### Still unverified

- Roles of p1–p4
- `echo 0 > refresh` semantics
- Whether UART is brought out to accessible pads
- `softburn` — the command exists in the U-Boot image but has never been run
- The BootROM host side: no cloner tool has been built and talked to this device
- The fifth physical light one of us counted, versus four LEDs in sysfs
- I²C bus contents

---

## Appendix B — quick reference

```sh
# screen
adb shell '/etc/init.d/S80app stop'
adb push frame.bin /tmp/f.bin
adb shell 'dd if=/tmp/f.bin of=/dev/epaper_lcd bs=5624 count=1'
adb shell 'echo 1 > /sys/devices/platform/e0266a128/epaper/refresh'

# screenshot (patched firmware)
adb pull /dev/shm/c1-screen.bin

# LEDs
adb shell 'echo none > /sys/class/leds/led4/trigger; echo 255 > /sys/class/leds/led4/brightness'

# GPIO / key probing
adb shell 'mount -t debugfs none /sys/kernel/debug; cat /sys/kernel/debug/gpio'
adb shell 'while true; do busybox devmem 0x10010200; sleep 0.1; done' | awk '!seen[$0]++'

# audio
adb shell 'arecord -D hw:0,0 -f S16_LE -r 16000 -c 1 -d 3 /tmp/t.wav'

# whole-system backup — see 2.3
# BootROM recovery — hold Back + Enter, plug USB; exit via reset pinhole
```

---

## Appendix C — related work

The device-specific ecosystem is essentially just C1ancher, but **Ingenic X1600 +
AltoBeam ATBM603x is the standard Chinese IP-camera bill of materials**, and that
community's tooling applies:

- [gtxaspec/atbm-wifi](https://github.com/gtxaspec/atbm-wifi) — open driver for this Wi-Fi family
- [Ingenic-community/linux](https://github.com/Ingenic-community/linux) — kernel tree; X1600 partially supported
- [gtxaspec/ingenic-u-boot-xburst1](https://github.com/gtxaspec/ingenic-u-boot-xburst1) — U-Boot for XBurst1
- [ballaswag/ingenic-usbboot](https://github.com/ballaswag/ingenic-usbboot) — usbboot for X2000E; closest modern sibling to X1600
- [gcwnow/ingenic-boot](https://github.com/gcwnow/ingenic-boot) — USB boot tools for older XBurst
- [wltechblog/thingino-dfu](https://github.com/wltechblog/thingino-dfu) — USB DFU / Ingenic Cloner flashing tools
- [gtxaspec/ingenic-cloner-profiles](https://github.com/gtxaspec/ingenic-cloner-profiles) — per-SoC cloner trigger profiles
- [themactep/thingino-firmware](https://github.com/themactep/thingino-firmware) · [OpenIPC](https://github.com/openipc) — large Ingenic firmware communities

The same maintainer publishes both the XBurst1 U-Boot and the AltoBeam Wi-Fi driver —
not a coincidence, it is the same hardware platform.
