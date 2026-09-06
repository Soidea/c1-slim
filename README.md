# C1ancher-mac

**macOS toolchain for flashing [C1ancher](https://github.com/fwz233-RE/C1ancher) onto the
Kuaiyidian (快易典) C1-Slim / MP-D261 e-paper device.**

No Windows, no WSL, no Docker, no disassembly. Tested on Apple Silicon.

### 📖 Flashing guide · 刷机指南

**[English](MACOS.md)**  ·  **[简体中文](MACOS.zh-CN.md)**  ·  [Web version](https://theBillLee.github.io/C1ancher-mac/)

### 🔬 Hardware notes · 硬件笔记

**[English](HARDWARE.md)**  ·  **[简体中文](HARDWARE.zh-CN.md)**

Framebuffer layout, the single-`write()` requirement, screenshot support, audio and
keyboard — all verified on real hardware. Read this before writing anything that drives
the panel directly.

---

```bash
brew install --cask android-platform-tools && pip3 install cryptography
chmod +x macos/*.sh

./macos/doctor.sh                                    # preflight; finds your device MAC
sudo python3 macos/c1-adb-admit-macos.py --device-mac <MAC>   # open ADB (temporary)
./macos/backup.sh                                    # ⚠️ back up before changing anything
./macos/install-open-adb.sh     install --reboot     # make ADB persistent
./macos/install-default-app.sh  install --reboot     # install C1ancher
```

| | |
|---|---|
| Device | 快易典 C1-Slim / MP-D261 |
| SoC | Ingenic X1600 · XBurst1 MIPS32r2 LE |
| Kernel | Linux 5.10.186 (Buildroot) |
| Panel | SEEKINK E0266A128 · 296 × 152 · 1 bpp · ~125 DPI |
| Host | macOS 13+ · Intel or Apple Silicon |

## What's here

| Path | |
|---|---|
| `macos/` | The macOS host scripts — everything you run |
| `prebuilt/` | MIPS binaries, already cross-compiled and ABI-verified |
| `docs/` | Bilingual web guide (GitHub Pages) |
| `tools/` | Host-side tooling: frame packing, pixel-font rendering, screenshots |
| `patches/` | `display-shadow.patch` — adds screenshot support to C1ancher |
| `src/`, `scripts/`, `third_party/` | Upstream C1ancher sources, unmodified |

Copy `prebuilt/C1ancher` and `prebuilt/C1ancher-launcher` into `build/` to skip
compiling, or run `./macos/build.sh` to reproduce them in a container.

## How it works, briefly

The device's "About device" screen has a hidden entry point that makes it call the vendor
API to ask whether ADB may be enabled. The firmware skips certificate and hostname
verification, so a scoped pf redirect plus a local one-shot TLS listener is enough to
answer that one request ourselves. Nothing is flashed; the root filesystem stays
read-only. Full explanation in the guide.

## Safety

- **Back up first.** `macos/backup.sh` is read-only and exports partition images with
  checksums. `remove-original` has no on-device recovery path.
- **Open ADB means open.** After installation, any computer that plugs in gets a root
  shell with no authorization prompt. Inherited from upstream by design.
- **Only use this on hardware you own.**

## Credits

Upstream: **[fwz233-RE/C1ancher](https://github.com/fwz233-RE/C1ancher)** (GPL-3.0) — the
device application, the device-side installers and all the reverse engineering.
This repository adds macOS host tooling and bilingual documentation.

See [NOTICE.md](NOTICE.md) for the full list of modifications, and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled components.

## License

GPL-3.0, inherited from upstream. See [LICENSE](LICENSE).
