#!/usr/bin/env bash
# macOS port of scripts/build.ps1.
# Cross-compiles C1ancher for MIPS32r2 inside a Debian container, then applies
# the same ABI and keyboard-profile checks build.ps1 performs.
#
# Usage: macos/build.sh [--cross-compile mipsel-linux-gnu-] [--engine docker|podman]

set -euo pipefail

CROSS_COMPILE="mipsel-linux-gnu-"
ENGINE=""
IMAGE="debian:bookworm"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cross-compile) CROSS_COMPILE="$2"; shift 2 ;;
        --engine) ENGINE="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ ! "$CROSS_COMPILE" =~ ^[A-Za-z0-9_./+-]+$ ]]; then
    echo "CROSS_COMPILE contains unsupported characters." >&2
    exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "$ENGINE" ]]; then
    for candidate in docker podman; do
        if command -v "$candidate" >/dev/null 2>&1; then ENGINE="$candidate"; break; fi
    done
fi
if [[ -z "$ENGINE" ]]; then
    cat >&2 <<'MSG'
No container engine found. Install one of:
  brew install --cask docker      # Docker Desktop
  brew install podman && podman machine init && podman machine start
MSG
    exit 1
fi
echo "Using container engine: $ENGINE"

# Debian ships the mipsel cross toolchain for arm64 hosts, so this runs natively
# on Apple Silicon with no emulation.
"$ENGINE" run --rm -v "$PROJECT_ROOT":/src -w /src "$IMAGE" bash -euo pipefail -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        make gcc gcc-${CROSS_COMPILE%-} binutils-${CROSS_COMPILE%-} >/dev/null
    make -j1 clean host-test all CROSS_COMPILE=${CROSS_COMPILE}
"

echo "Host tests and MIPS cross-build passed."

# --- keyboard profile validation (port of validate-keyboard.ps1) -------------
python3 - "$PROJECT_ROOT/config/c1-slim/keyboard.csv" <<'PY'
import csv, sys
from collections import Counter

rows = list(csv.DictReader(open(sys.argv[1], newline="")))
def fail(message):
    raise SystemExit(f"Keyboard profile validation failed: {message}")

if len(rows) != 40:
    fail(f"expected 40 keyboard entries, found {len(rows)}")
pairs = Counter((r["source_node"], r["key_code"]) for r in rows)
dupes = [k for k, n in pairs.items() if n != 1]
if dupes:
    fail(f"duplicate source/key mappings: {dupes}")

matrix = [r for r in rows if r["source_node"] == "/dev/input/event0"]
gpio = [r for r in rows if r["source_node"] == "/dev/input/event1"]
if len(matrix) != 30 or len(gpio) != 10:
    fail(f"expected matrix/gpio counts 30/10, found {len(matrix)}/{len(gpio)}")
if any(not r["scan_code"].isdigit() for r in matrix):
    fail("every matrix key must have a numeric scan code")
scans = Counter(r["scan_code"] for r in matrix)
if any(n != 1 for n in scans.values()):
    fail("matrix scan codes must be unique")
if any(r["scan_code"].strip() for r in gpio):
    fail("GPIO keys must not invent scan codes")
if any(r["verified_run"] != "20260814-212736" for r in rows):
    fail("every mapping must reference the verified capture run")

actual = {f'{r["source_node"]}|{r["key_code"]}|{r["scan_code"]}' for r in rows}
for required in (
    "/dev/input/event0|16|3",
    "/dev/input/event0|57|40",
    "/dev/input/event1|25|",
    "/dev/input/event1|28|",
    "/dev/input/event1|352|",
):
    if required not in actual:
        fail(f"required mapping is missing: {required}")
print("Keyboard profile validation passed.")
PY

# --- ABI verification (port of build.ps1) -----------------------------------
verify_abi() {
    local name="$1" abi="$2" binary="$3"
    local text; text="$(cat "$abi")"
    local pattern
    for pattern in 'Class:[[:space:]]+ELF32' \
                   "Data:[[:space:]]+2's complement, little endian" \
                   'Flags:.*o32.*mips32r2' \
                   'FP ABI:[[:space:]]+Hard float \(double precision\)'; do
        if ! grep -Eq "$pattern" <<<"$text"; then
            echo "$name ABI verification failed: missing pattern $pattern" >&2
            exit 1
        fi
    done
    if grep -q 'Requesting program interpreter' <<<"$text" \
       || ! grep -q 'There is no dynamic section' <<<"$text"; then
        echo "$name is not fully static." >&2
        exit 1
    fi
    local hash size
    hash="$(shasum -a 256 "$binary" | awk '{print $1}')"
    size="$(stat -f%z "$binary" 2>/dev/null || stat -c%s "$binary")"
    echo "Built $binary"
    echo "SHA-256 $hash"
    echo "Size $size bytes"
    printf '%s_sha256=%s\n%s_size_bytes=%s\n' "$name" "$hash" "$name" "$size" >> "$BUILD_INFO"
}

BUILD_INFO="$PROJECT_ROOT/build/build-info.txt"
{
    echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "cross_compile=$CROSS_COMPILE"
    echo "target=mips32r2-little-o32-hard-float-double-static"
    echo "mode=app"
} > "$BUILD_INFO"

verify_abi C1ancher "$PROJECT_ROOT/build/abi.txt" "$PROJECT_ROOT/build/C1ancher"
verify_abi C1ancher-launcher "$PROJECT_ROOT/build/launcher-abi.txt" "$PROJECT_ROOT/build/C1ancher-launcher"

NEOFETCH_ROOT="$PROJECT_ROOT/third_party/neofetch"
for name in neofetch neofetch.upstream c1-config.conf c1-logo.txt LICENSE.md; do
    path="$NEOFETCH_ROOT/$name"
    if [[ ! -f "$path" ]]; then
        echo "Bundled Neofetch file is missing: $path" >&2
        exit 1
    fi
    key="${name//./_}"; key="${key//-/_}"
    echo "neofetch_${key}_sha256=$(shasum -a 256 "$path" | awk '{print $1}')" >> "$BUILD_INFO"
done
echo "neofetch_version=7.1.0" >> "$BUILD_INFO"

echo
echo "Build info written to $BUILD_INFO"
