# Attribution and modifications

## Upstream

This repository is a derivative of **[fwz233-RE/C1ancher](https://github.com/fwz233-RE/C1ancher)**,
licensed under GPL-3.0. All original source under `src/`, `scripts/device-*.sh`, `config/`,
`tests/`, `third_party/` and the `Makefile` is the work of the upstream author.
The upstream project README is preserved verbatim at [`README.upstream.md`](README.upstream.md).

Bundled third-party components and their licenses are listed in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) — notably libtsm and Neofetch 7.1.0.

## Modifications made in this repository

As required by GPL-3.0 §5(a), the changes relative to upstream are:

**Added — macOS host tooling (`macos/`), all new files:**

| File | Replaces upstream | Notes |
|---|---|---|
| `c1-adb-admit-macos.py` | `adb_admit_local.py` | WinDivert packet capture/injection → pf `rdr` redirect in anchor `com.apple/c1slim-adb`; PowerShell host discovery → `ifconfig` / `arp` / `/var/db/dhcpd_leases` |
| `install-open-adb.sh` | `scripts/install-open-adb.ps1` | Also removes the dependency on an out-of-tree firmware dump: stock `S90usb` is pulled from the device and hash-checked instead of read from `firmware-analysis/` |
| `install-default-app.sh` | `scripts/install-default-app.ps1` | Emits a byte-identical `app_daemon` shim (SHA-256 `676a57aa…`) so devices provisioned from either platform match |
| `build.sh` | `scripts/build.ps1` + `validate-keyboard.ps1` | WSL → Docker/Podman container; ABI and keyboard-profile checks ported |
| `lib-adb.sh` | — | Shared ADB orchestration helpers |
| `doctor.sh` | — | New: read-only preflight check; lists hotspot clients to help locate the device MAC |
| `backup.sh` | — | New: read-only full-device backup (partition table, boot scripts, partition images, SHA256SUMS) |

**Added — documentation:** `MACOS.md`, `MACOS.zh-CN.md`, `docs/index.html`, this file.

**Added — `prebuilt/`:** MIPS binaries cross-compiled from the unmodified upstream sources
in this tree, with ABI reports and checksums. Reproducible via `macos/build.sh`.

**Removed:** `scripts/*.ps1` (Windows-only; superseded by `macos/*.sh`).

No upstream source file has been modified.

## Scope

Use only on hardware you own. Once open ADB is installed, any computer that plugs in
obtains a root shell without an authorization prompt — a deliberate choice inherited from
upstream, documented rather than introduced here.
