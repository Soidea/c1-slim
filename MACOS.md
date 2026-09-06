# Flashing C1ancher from an Apple Silicon Mac

**[English](MACOS.md) · [简体中文](MACOS.zh-CN.md)**

A macOS port of the C1ancher toolchain for the Kuaiyidian (快易典) C1-Slim / MP-D261 —
an Ingenic X1600 e-paper device. No Windows, no WSL, no Docker, no disassembly.

| | |
|---|---|
| SoC | Ingenic X1600 · XBurst1 MIPS32r2 LE |
| Kernel | Linux 5.10.186 (Buildroot) |
| Panel | SEEKINK E0266A128 · 296 × 152 · 1 bpp · ~125 DPI |
| Framebuffer | 5,624 bytes (column-major, 19 bytes/column) |

> **Only use this on hardware you own.** Once open ADB is installed, *any* computer that
> plugs in gets a root shell with no authorization prompt. That is a deliberate choice by
> the upstream project, not an oversight.

---

## What this actually does

Nothing here touches the firmware, writes a partition, or unlocks a bootloader.

The device's "About device" screen has a hidden entry point. Triggering it makes the
device issue one HTTPS request to the vendor API:

```
GET /v1/pens/{penId}?action=adbAdmit&random={digits}
Host: api.mpen.com.cn
```

The firmware's network library has certificate-chain and hostname verification disabled,
so a one-shot self-signed certificate is enough to terminate that TLS locally. We
intercept exactly that request on the Mac and answer it ourselves:

```json
{"errorCode":"200","errorMsg":"","data":{"success":true}}
```

`errorCode` must be the **string** `"200"`. The numeric `200`, or `0`, will not be
accepted by this firmware even though the log will show the response was sent.

The device then rebuilds its USB gadget and exposes ADB. Everything after that happens
over a normal root ADB shell; the root filesystem stays read-only throughout.

### How the macOS port differs from the Windows original

| Windows original | macOS port |
|---|---|
| WinDivert packet capture + injection | pf `rdr` redirect in anchor `com.apple/c1slim-adb` |
| Windows Mobile Hotspot | System Settings → Sharing → Internet Sharing |
| `New-NetFirewallRule` | pf rule scoped to one source IP |
| `Get-NetNeighbor` for device discovery | `/var/db/dhcpd_leases` + `arp -an` |
| WSL cross-compile | Docker/Podman container (or use `prebuilt/`) |
| `*.ps1` | `macos/*.sh` |

The pf approach is cleaner than WinDivert: the kernel performs the NAT and reverses the
translation on the return path, so the original's manual response-source-address rewriting
is unnecessary.

---

## Requirements

```bash
brew install --cask android-platform-tools
pip3 install cryptography
chmod +x macos/*.sh
```

macOS needs no ADB driver — the device's `VID_18D1` enumerates directly.

A USB-C cable that carries **data**. A charge-only cable is the single most common
reason `adb devices` comes back empty.

---

## Step 0 — Internet Sharing

The device must join a hotspot **this Mac** creates. The whole method depends on its
traffic passing through the Mac, so a device still attached to your home router will
never trigger.

**System Settings → General → Sharing → Internet Sharing.** Share your connection from
your uplink interface, to **Wi-Fi**. Set a name and WPA2 password under "Wi-Fi Options",
then switch it on.

> **Apple Silicon caveat:** one radio doing "join Wi-Fi uplink" *and* "serve Wi-Fi
> hotspot" at the same time is frequently unstable or refuses to start. The reliable
> combination is **uplink over USB-C Ethernet, shared to Wi-Fi**.

The Mac gains a `bridge100` interface, usually at `192.168.2.1`. Connect the C1-Slim
to that hotspot.

## Step 1 — Preflight

`doctor.sh` is read-only. It checks every prerequisite and — importantly — **lists the
clients on your hotspot**, which is how you find your device's MAC. The default MAC in
the scripts belongs to the original author's unit, not yours.

```bash
./macos/doctor.sh
```

Can't tell which client is the C1-Slim? Turn its Wi-Fi off, run again, and note the row
that disappeared.

## Step 2 — Open ADB temporarily

```bash
sudo python3 macos/c1-adb-admit-macos.py --device-mac 58:C5:87:XX:XX:XX
```

Wait for all three lines. **Do not touch the device before `READY`** — the script
guarantees the HTTPS listener is up before the redirect opens, so the first SYN can never
arrive ahead of it.

```
HTTPS_READY    address=192.168.2.1:8443 ...
PF_RULE_LOADED anchor=com.apple/c1slim-adb ...
READY open About-device and press Enter 10 times within 5 seconds
```

Then, on the device:

1. Open **About device**
2. Put the focus on the item showing **static version information**
3. Within about 5 seconds, press and **fully release** the keyboard `Enter` **10 times**

The firmware counts *release* events, so each press must complete. Don't go slowly.

Do **not** use `C → S → Enter` — that combination opens GCTest, which is unrelated.

On success the log shows `TLS_OK` then `APPROVED`, the device rebuilds its USB gadget,
and macOS registers a USB disconnect/reconnect. Verify:

```bash
adb kill-server && adb start-server
adb devices -l          # expect: MagicPen-xxxxxx  device
adb shell id            # expect: uid=0(root) gid=0(root)
```

This ADB session lasts only for the **current boot**. Step 4 makes it persistent.

Useful overrides:

```bash
--device-ip 192.168.2.5           # skip MAC lookup
--bridge bridge100                # name the interface
--gateway-ip 192.168.2.1          # override the bridge address
--origin-ip 39.98.109.39          # override the resolved API address
--keep-running                    # stay up; stop with Ctrl-C
```

## Step 3 — Back up the device ⚠️

**Do not skip this.** A new unit ships with no system image in your hands, and
`remove-original` (step 6) has no on-device recovery path. This backup is the only way
back.

```bash
./macos/backup.sh              # partitions under 512 MB
./macos/backup.sh --all        # every partition
./macos/backup.sh --max-mb 2048
```

Read-only throughout. It exports the partition table, boot scripts and partition images
to `~/C1Slim-Backup/<timestamp>/` with a `SHA256SUMS` manifest.

**Copy that directory to another disk before continuing.**

```bash
cd ~/C1Slim-Backup/<timestamp> && shasum -a 256 -c SHA256SUMS
```

## Step 4 — Make ADB survive reboot

The stock `/etc/init.d/S90usb` already contains an ADB FunctionFS startup line — it is
merely commented out. This uncomments it.

```bash
./macos/install-open-adb.sh install --reboot
```

Unlike the PowerShell original, **no firmware dump is required**. The stock `S90usb` is
pulled from the device, checked against the known hash `c2b278b2…`, and only then edited.
The installer verifies before and after writing, and on failure restores the original and
remounts `/` read-only. Copies are preserved at `/etc/init.d/S90usb.c1-original`,
`/usr/data/c1/recovery/open-adb/` and `/storage/c1/recovery/open-adb/`.

```bash
./macos/install-open-adb.sh verify    --reboot
./macos/install-open-adb.sh uninstall --reboot
```

## Step 5 — Install C1ancher

```bash
./macos/install-default-app.sh install --reboot
```

Deploys C1ancher, the `app_daemon` supervisor shim, Neofetch 7.1.0, and generates a
unique Ed25519 SSH host key for the device. The device-side script verifies every file by
SHA-256 and rolls back on failure. `--reboot` confirms cold-start selection and
single-instance state.

The installed shim is **byte-identical** to the one the PowerShell installer writes
(LF, no BOM, no trailing newline — SHA-256 `676a57aa…`), so devices provisioned from
either platform end up in the same state.

You now have the C1ancher 3×3 home screen: **WI-FI** up, **SSH** left, **TERMINAL**
right, **DEVICE** down (runs neofetch). Corners show Wi-Fi state, SSH state, battery and
time. The stock software is still on disk.

## Step 6 — Remove the stock software (optional, irreversible)

```bash
./macos/install-default-app.sh remove-original --reboot
```

Deletes `/usr/bin/d261`. There is **no on-device recovery** — restoring requires the
images from step 3. Verify your backup passes `shasum -c` and lives on a second disk
first. Skipping this step costs you nothing functionally.

---

## Building from source

`prebuilt/` contains binaries already cross-compiled and ABI-verified:

| File | SHA-256 |
|---|---|
| `C1ancher` | `a031cceaadf85d2270c478713933ddbe51a9696b838ca5e053b03f260f48d6bf` |
| `C1ancher-launcher` | `d8ee229bbeb0b9cdebc5358ba55066b405e4656e33f444acae6af904fb4b394b` |

ELF32 · little-endian · o32 · mips32r2 · hard-float double · fully static.

Copy them to `build/`, or reproduce them yourself:

```bash
./macos/build.sh                 # Docker or Podman
./macos/build.sh --engine podman
```

Debian ships `gcc-mipsel-linux-gnu` for arm64 hosts, so this compiles natively on Apple
Silicon with no emulation. The script runs the upstream host tests, then applies the same
ABI and keyboard-profile checks as `build.ps1`.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `no active Internet Sharing bridge found` | Sharing is off, or `bridge100` has no `inet`. Check `ifconfig bridge100`; pass `--bridge` / `--gateway-ip`. |
| `MAC ... was not found` | Device isn't on the Mac hotspot. The error lists the clients it *did* see — pass `--device-ip`. DHCP addresses change; don't hard-code. |
| `READY` but no `TCP_ACCEPT` | Confirm the device is on the Mac hotspot; confirm you're on the static version-info row; the 10 presses must complete within ~5 s with full releases. |
| `APPROVED` but the device still refuses | The response body must keep the string error code `{"errorCode":"200",…}`. Don't edit it. |
| `adb devices` empty | Data-capable USB-C cable, different port, then `adb kill-server && adb start-server`. |
| `Open root ADB startup hash changed` | Step 5 requires step 4. Run `install-open-adb.sh install --reboot` first. |
| pf rule not taking effect | `sudo pfctl -s info \| head -1` should read Enabled; `/etc/pf.conf` needs `rdr-anchor "com.apple/*"` (macOS ships with it). |
| Leftover pf rules | `sudo pfctl -a com.apple/c1slim-adb -F all` |

### Log privacy

`macos/adb-admit-plaintext.log` records the full decrypted HTTP request. It can contain
cookies, a phone number, `sessionId`, `penId`, the device serial and LAN addresses.
**Strip those before sharing it anywhere**, and delete the log when you're done debugging.

---

## Rollback

| Goal | Command |
|---|---|
| Disable persistent ADB | `./macos/install-open-adb.sh uninstall --reboot` |
| Clear leftover pf rules | `sudo pfctl -a com.apple/c1slim-adb -F all` |
| Restore stock launcher | Requires the images from step 3 |

Stopping the Mac-side script does not close ADB for the device's current boot. To confirm
the default state returns: unplug USB, reboot the device, replug, and run `adb devices -l`.

---

## Related work

The device-specific ecosystem is small, but the **SoC** ecosystem is not. The X1600 is an
XBurst1 part, so these are the right family:

- [Ingenic-community/linux](https://github.com/Ingenic-community/linux) — kernel tree; X1600 marked partially supported
- [gtxaspec/ingenic-u-boot-xburst1](https://github.com/gtxaspec/ingenic-u-boot-xburst1) — U-Boot for XBurst1
- [wltechblog/thingino-dfu](https://github.com/wltechblog/thingino-dfu) — USB DFU / Ingenic Cloner flashing tools
- [gtxaspec/ingenic-cloner-profiles](https://github.com/gtxaspec/ingenic-cloner-profiles) — per-SoC cloner trigger profiles
- [themactep/thingino-firmware](https://github.com/themactep/thingino-firmware) · [OpenIPC](https://github.com/openipc) — large Ingenic firmware communities (IP cameras)

If the X1600 BootROM exposes the Cloner USB recovery mode, a bricked eMMC is recoverable
and the risk calculus for touching U-Boot changes completely. Worth establishing before
going deeper.
