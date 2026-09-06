# C1-Slim

**Hardware and firmware reference for the 快易典 (Kuaiyidian) C1-Slim / MP-D261** — a
296 × 152 e-paper device with a full keyboard, running Buildroot Linux on an Ingenic X1600.

Everything here was established on real hardware. None of it is in any datasheet we could
find, and the wrong turns are documented alongside the findings.

### 📘 Device reference · 硬件手册

**[English](HARDWARE.md)**  ·  **[简体中文](HARDWARE.zh-CN.md)**  ·  **[Web version](https://theBillLee.github.io/c1-slim/)**

| | |
|---|---|
| SoC | Ingenic X1600 · XBurst1 MIPS32r2 LE · 64 MB RAM |
| Storage | 64 GB eMMC · root on p7, ext4, read-only |
| Kernel | Linux 5.10.186 · Buildroot userland — **not Android** |
| Panel | SEEKINK E0266A128 · 296 × 152 · 1 bpp · ~125 DPI · 5 624 B/frame |
| Wi-Fi | AltoBeam ATBM603x · SDIO `007A:6011` · no Bluetooth |
| Audio | ALSA `halley6`, ES8326 — mic, speaker, 3.5 mm jack |

## Highlights

- **BootROM USB recovery, confirmed.** Hold **Back + Enter** and plug in USB: the device
  enumerates as `a108:EAEF` "Ingenic USB BOOT DEVICE". Both boot straps are wired to keys
  (BOOT_SEL0 = PC27 = Enter, BOOT_SEL1 = PC28 = Back), so no disassembly and no UART are
  needed. **Exit is the reset pinhole beside the power key** — unplugging USB and
  long-pressing power both fail.
- **Boot chain and partition map**, including the 3 MB raw region ahead of p1 that holds
  SPL and U-Boot and that per-partition backups miss, plus the 812 MiB whole-system image
  procedure.
- **Panel internals**: strip-major framebuffer layout, the single-`write()` requirement,
  and refresh timing measured two independent ways (~150 ms write-only, ~700 ms full).
- **Per-target write risk table** — what is safe to break, what is the only channel in.
- **Appendix A: what we tried, including what failed** — eighteen negative results, so the
  next person does not spend the debugging rounds they cost us.

## Going further — flashing C1ancher

The reference above describes the device as shipped. To turn it into a small MIPS computer
with Wi-Fi, SSH and a root terminal, use **C1ancher**:

- **Upstream: [fwz233-RE/C1ancher](https://github.com/fwz233-RE/C1ancher)** (GPL-3.0) —
  the application, the device-side installers and all the reverse engineering.
- **On a Mac:** [flashing guide](MACOS.md) · [简体中文](MACOS.zh-CN.md) ·
  [web](https://theBillLee.github.io/c1-slim/flashing.html). Upstream's flow needs
  Windows and WinDivert; this is the macOS port — no Windows, no WSL, no Docker, no
  disassembly. Tested on Apple Silicon.

```bash
brew install --cask android-platform-tools && pip3 install cryptography
chmod +x macos/*.sh

./macos/doctor.sh                                    # preflight; finds your device MAC
sudo python3 macos/c1-adb-admit-macos.py --device-mac <MAC>   # open ADB (temporary)
./macos/backup.sh                                    # ⚠️ back up before changing anything
./macos/install-open-adb.sh     install --reboot     # make ADB persistent
./macos/install-default-app.sh  install --reboot     # install C1ancher
```

Flashing touches no firmware, writes no partition and unlocks no bootloader; the root
filesystem stays read-only throughout.

## What's here

| Path | |
|---|---|
| `HARDWARE.md` · `HARDWARE.zh-CN.md` | The device reference |
| `docs/` | Web versions (GitHub Pages) — reference and flashing guide |
| `macos/` | macOS host scripts for flashing C1ancher |
| `prebuilt/` | MIPS binaries, already cross-compiled and ABI-verified |
| `tools/` | Frame packing, pixel-font rendering, screenshots |
| `patches/` | `display-shadow.patch` — adds screenshot support to C1ancher |
| `config/c1-slim/` | Keyboard scan codes and other device tables |
| `src/`, `scripts/`, `third_party/` | Upstream C1ancher sources, unmodified |

## Safety

- **Back up first.** `macos/backup.sh` is read-only and exports partition images with
  checksums. See §2.3 of the reference for the whole-system image.
- **Open ADB means open.** After installing C1ancher's ADB hook, any computer that plugs
  in gets a root shell with no authorization prompt. Inherited from upstream by design.
- **Only use this on hardware you own.**

## Credits

**[fwz233-RE/C1ancher](https://github.com/fwz233-RE/C1ancher)** (GPL-3.0) — the device
application and the original reverse engineering. This repository adds the hardware
reference, macOS host tooling and bilingual documentation.

See [NOTICE.md](NOTICE.md) for the full list of modifications and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled components.

## License

GPL-3.0, inherited from upstream. See [LICENSE](LICENSE).
