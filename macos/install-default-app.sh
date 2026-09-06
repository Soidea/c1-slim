#!/usr/bin/env bash
# macOS port of scripts/install-default-app.ps1.
#
# Deploys C1ancher, the app_daemon supervisor shim and bundled Neofetch, then
# verifies single-instance state and a read-only root. The device-side script
# does the hash-checked install with rollback; this script orchestrates it.
#
# Usage: macos/install-default-app.sh [install|verify|remove-original] [--reboot] [--timeout N]
#
# remove-original deletes the stock /usr/bin/d261 English-learning software and
# is NOT reversible from the device: recovery then needs a full system image.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-adb.sh
source "$SCRIPT_DIR/lib-adb.sh"

ACTION="install"
REBOOT=0
TIMEOUT=300
while [[ $# -gt 0 ]]; do
    case "$1" in
        install|verify|remove-original) ACTION="$1"; shift ;;
        --reboot) REBOOT=1; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
(( TIMEOUT >= 30 && TIMEOUT <= 600 )) || die "--timeout must be between 30 and 600"

EXPECTED_ORIGINAL_HASH="ceb56ddf2ff3c10f7c4c2cd6216b298da1cea799ca7170322f8229d5e9af6ee7"
EXPECTED_PREVIOUS_SHIM_HASH="feff5a9df87fd350cb9fdc56c4d5245c9ca19755e9706a189002c720c9ef9e60"
OPEN_ADB_HASH="626e4c5d600b543531337eb67220b0a7520d461211cc7ecafd36666d4f8905cb"

APP="$PROJECT_ROOT/build/C1ancher"
LAUNCHER="$PROJECT_ROOT/build/C1ancher-launcher"
NEOFETCH_ROOT="$PROJECT_ROOT/third_party/neofetch"
DEVICE_SCRIPT="$PROJECT_ROOT/scripts/device-default-app.sh"
RUN_ROOT="$PROJECT_ROOT/artifacts/default-app-$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d /tmp/c1-default-app-XXXXXXXX)"
UPLOADED=0

R_SCRIPT="/dev/shm/c1-device-default-app.sh"
R_SHIM="/dev/shm/C1ancher-daemon.shim"
R_APP="/dev/shm/C1ancher.install"
R_LAUNCHER="/dev/shm/C1ancher-launcher.install"
R_HOSTKEY="/dev/shm/c1-ssh-host-key.install"
R_NF_CMD="/dev/shm/c1-neofetch.install"
R_NF_UP="/dev/shm/c1-neofetch-upstream.install"
R_NF_CFG="/dev/shm/c1-neofetch-config.install"
R_NF_LOGO="/dev/shm/c1-neofetch-logo.install"
R_NF_LIC="/dev/shm/c1-neofetch-license.install"
ALL_REMOTE="$R_SCRIPT $R_SHIM $R_APP $R_LAUNCHER $R_HOSTKEY $R_NF_CMD $R_NF_UP $R_NF_CFG $R_NF_LOGO $R_NF_LIC"

cleanup() {
    if [[ $UPLOADED -eq 1 && -n "$SERIAL" ]]; then
        adb_dev shell "rm -f $ALL_REMOTE" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

NF_CMD="$NEOFETCH_ROOT/neofetch"
NF_UP="$NEOFETCH_ROOT/neofetch.upstream"
NF_CFG="$NEOFETCH_ROOT/c1-config.conf"
NF_LOGO="$NEOFETCH_ROOT/c1-logo.txt"
NF_LIC="$NEOFETCH_ROOT/LICENSE.md"
for required in "$APP" "$LAUNCHER" "$DEVICE_SCRIPT" "$NF_CMD" "$NF_UP" "$NF_CFG" "$NF_LOGO" "$NF_LIC"; do
    [[ -f "$required" ]] || die "Required project file is missing: $required (run macos/build.sh first)"
done

mkdir -p "$RUN_ROOT"

UPLOAD_SCRIPT="$WORK/device-default-app.sh"
tr -d '\r' < "$DEVICE_SCRIPT" > "$UPLOAD_SCRIPT"

SHIM="$WORK/app_daemon"
# Byte-identical to the PowerShell installer's here-string: LF endings, no BOM,
# and no trailing newline. The hash is checked on-device, so this must match.
printf '%s' '#!/bin/sh
while [ ! -x /usr/data/c1/bin/app_daemon ]; do
    sleep 1
done
exec /usr/data/c1/bin/app_daemon' > "$SHIM"

SHIM_HASH="$(local_sha256 "$SHIM")"
APP_HASH="$(local_sha256 "$APP")"
LAUNCHER_HASH="$(local_sha256 "$LAUNCHER")"
NF_CMD_HASH="$(local_sha256 "$NF_CMD")"
NF_UP_HASH="$(local_sha256 "$NF_UP")"
NF_CFG_HASH="$(local_sha256 "$NF_CFG")"
NF_LOGO_HASH="$(local_sha256 "$NF_LOGO")"
NF_LIC_HASH="$(local_sha256 "$NF_LIC")"

resolve_adb
get_only_device
assert_system_state
ADB_STARTUP_HASH="$(remote_sha256 /etc/init.d/S90usb)"
[[ "$ADB_STARTUP_HASH" == "$OPEN_ADB_HASH" ]] || die \
    "Open root ADB startup hash changed: $ADB_STARTUP_HASH
Run macos/install-open-adb.sh install --reboot first."

# --- persistent SSH host key ------------------------------------------------
HOSTKEY="$WORK/ssh_host_ed25519_key"
HOSTKEY_UPLOAD=0
HOSTKEY_PROBE="$(remote 'if [ -f /usr/data/c1/ssh/ssh_host_ed25519_key ]; then sha256sum /usr/data/c1/ssh/ssh_host_ed25519_key; fi')"
if [[ "$HOSTKEY_PROBE" =~ ^([0-9a-fA-F]{64})[[:space:]] ]]; then
    HOSTKEY_HASH="$(tr '[:upper:]' '[:lower:]' <<<"${BASH_REMATCH[1]}")"
elif [[ "$ACTION" == "install" ]]; then
    note "Generating a unique Ed25519 SSH host key for this device..."
    ssh-keygen -q -t ed25519 -N "" -f "$HOSTKEY" </dev/null
    [[ -f "$HOSTKEY" ]] || die "Failed to generate a unique SSH host key."
    HOSTKEY_HASH="$(local_sha256 "$HOSTKEY")"
    HOSTKEY_UPLOAD=1
else
    die "Persistent SSH host key is missing. Run the install action first."
fi

CURRENT_HASH="$(remote_sha256 /etc/app_daemon)"
case "$CURRENT_HASH" in
    "$EXPECTED_ORIGINAL_HASH") EXPECTED_BEFORE="Original" ;;
    "$EXPECTED_PREVIOUS_SHIM_HASH"|"$SHIM_HASH") EXPECTED_BEFORE="C1OrLegacy" ;;
    *) die "Unexpected device app_daemon hash: $CURRENT_HASH" ;;
esac
assert_application_state "$EXPECTED_BEFORE"

evidence baseline.txt "action=$ACTION
identity=$STATE_IDENTITY
root_mount=$STATE_ROOT_MOUNT
storage_mount=$STATE_STORAGE_MOUNT
device_before_sha256=$CURRENT_HASH
original_sha256=$EXPECTED_ORIGINAL_HASH
shim_sha256=$SHIM_HASH
app_sha256=$APP_HASH
launcher_sha256=$LAUNCHER_HASH
ssh_host_key_sha256=$HOSTKEY_HASH
neofetch_command_sha256=$NF_CMD_HASH
neofetch_upstream_sha256=$NF_UP_HASH
neofetch_config_sha256=$NF_CFG_HASH
neofetch_logo_sha256=$NF_LOGO_HASH
neofetch_license_sha256=$NF_LIC_HASH
app_daemon_count=$APP_DAEMON_COUNT
mpenMain_count=$MPENMAIN_COUNT
c1ancher_count=$C1ANCHER_COUNT
legacy_c1_app_count=$LEGACY_COUNT"

note "Uploading payload..."
adb_dev push "$UPLOAD_SCRIPT" "$R_SCRIPT"  >/dev/null
adb_dev push "$SHIM"          "$R_SHIM"    >/dev/null
adb_dev push "$APP"           "$R_APP"     >/dev/null
adb_dev push "$LAUNCHER"      "$R_LAUNCHER">/dev/null
adb_dev push "$NF_CMD"        "$R_NF_CMD"  >/dev/null
adb_dev push "$NF_UP"         "$R_NF_UP"   >/dev/null
adb_dev push "$NF_CFG"        "$R_NF_CFG"  >/dev/null
adb_dev push "$NF_LOGO"       "$R_NF_LOGO" >/dev/null
adb_dev push "$NF_LIC"        "$R_NF_LIC"  >/dev/null
if [[ $HOSTKEY_UPLOAD -eq 1 ]]; then
    adb_dev push "$HOSTKEY" "$R_HOSTKEY" >/dev/null
fi
adb_dev shell "chmod 700 $R_SCRIPT; chmod 600 $R_SHIM $R_APP $R_LAUNCHER $R_HOSTKEY $R_NF_CMD $R_NF_UP $R_NF_CFG $R_NF_LOGO $R_NF_LIC 2>/dev/null || true" >/dev/null
UPLOADED=1

[[ "$(remote_sha256 "$R_APP")" == "$APP_HASH" ]] || die "Uploaded C1ancher hash mismatch."
[[ "$(remote_sha256 "$R_LAUNCHER")" == "$LAUNCHER_HASH" ]] || die "Uploaded launcher hash mismatch."

remote_checked "sh -n $R_SCRIPT" >/dev/null
remote_checked "sh -n $R_SHIM" >/dev/null

DEVICE_ARGS="$EXPECTED_ORIGINAL_HASH $SHIM_HASH $APP_HASH $LAUNCHER_HASH $HOSTKEY_HASH $NF_CMD_HASH $NF_UP_HASH $NF_CFG_HASH $NF_LIC_HASH $NF_LOGO_HASH $EXPECTED_PREVIOUS_SHIM_HASH"

note "Running device action: $ACTION"
OPERATION="$(remote_checked "$R_SCRIPT $ACTION $DEVICE_ARGS")"
evidence operation.log "$OPERATION"
assert_system_state

VERIFICATION="$(remote_checked "$R_SCRIPT verify $DEVICE_ARGS")"
evidence verification-before-reboot.log "$VERIFICATION"
assert_application_state C1

if [[ $REBOOT -eq 1 ]]; then
    UPTIME_BEFORE="$(remote "cut -d' ' -f1 /proc/uptime" | tr -d ' \n')"
    note "Rebooting to verify cold-start selection..."
    adb_dev reboot >/dev/null 2>&1 || true
    wait_for_reconnect "$TIMEOUT"
    UPTIME_AFTER="$(remote "cut -d' ' -f1 /proc/uptime" | tr -d ' \n')"
    assert_system_state
    assert_application_state C1
    POST="$(remote_checked "/storage/c1/recovery/default-app/device-default-app.sh verify $DEVICE_ARGS")"
    evidence verification-after-reboot.log "$POST"
    evidence reboot.log "uptime_before=$UPTIME_BEFORE
uptime_after=$UPTIME_AFTER
identity=$STATE_IDENTITY
root_mount=$STATE_ROOT_MOUNT
expected_application=C1
app_daemon_count=$APP_DAEMON_COUNT
mpenMain_count=$MPENMAIN_COUNT
c1ancher_count=$C1ANCHER_COUNT
legacy_c1_app_count=$LEGACY_COUNT"
fi

echo
echo "$ACTION completed."
echo "Original app_daemon SHA-256: $EXPECTED_ORIGINAL_HASH"
echo "Installed shim SHA-256:      $SHIM_HASH"
echo "C1ancher SHA-256:            $APP_HASH"
echo "C1ancher launcher SHA-256:   $LAUNCHER_HASH"
echo "Neofetch launcher SHA-256:   $NF_CMD_HASH"
echo "Evidence: $RUN_ROOT"
if [[ $REBOOT -eq 0 ]]; then
    echo "WARNING: cold-start application selection has not been verified." >&2
    echo "         Re-run with: macos/install-default-app.sh verify --reboot" >&2
fi
