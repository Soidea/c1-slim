#!/usr/bin/env bash
# macOS port of scripts/install-open-adb.ps1.
#
# Makes the temporary ADB session permanent by enabling the ADB FunctionFS entry
# that already exists (commented out) in the stock /etc/init.d/S90usb.
#
# Unlike the PowerShell original this does NOT need a firmware dump on disk: the
# stock S90usb is pulled from the device itself and checked against the same
# known-good hash before the single-line edit is applied.
#
# Usage: macos/install-open-adb.sh [install|verify|uninstall] [--reboot] [--timeout N]

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
        install|verify|uninstall) ACTION="$1"; shift ;;
        --reboot) REBOOT=1; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
(( TIMEOUT >= 30 && TIMEOUT <= 600 )) || die "--timeout must be between 30 and 600"

EXPECTED_ORIGINAL_HASH="c2b278b283e9bf851461d9e8f6edfd207cec3b120585f0e091777d163562e965"
DEVICE_SCRIPT="$PROJECT_ROOT/scripts/device-open-adb.sh"
REMOTE_SCRIPT="/dev/shm/c1-device-open-adb.sh"
REMOTE_CANDIDATE="/dev/shm/c1-S90usb.open-root-adb"
RUN_ROOT="$PROJECT_ROOT/artifacts/open-adb-$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d /tmp/c1-open-adb-XXXXXXXX)"
UPLOADED=0

cleanup() {
    if [[ $UPLOADED -eq 1 && -n "$SERIAL" ]]; then
        adb_dev shell "rm -f $REMOTE_SCRIPT $REMOTE_CANDIDATE" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

[[ -f "$DEVICE_SCRIPT" ]] || die "Required project file is missing: $DEVICE_SCRIPT"
mkdir -p "$RUN_ROOT"
resolve_adb
get_only_device
assert_system_state
assert_application_state Original

# --- pull the stock S90usb from the device and verify it -------------------
note "Pulling /etc/init.d/S90usb from the device..."
STOCK="$WORK/S90usb.original"
adb_dev pull /etc/init.d/S90usb "$STOCK" >/dev/null
DEVICE_HASH="$(local_sha256 "$STOCK")"

CANDIDATE="$WORK/S90usb.open-root-adb"
if [[ "$DEVICE_HASH" == "$EXPECTED_ORIGINAL_HASH" ]]; then
    note "Device S90usb matches the known stock hash."
    # Enable the single commented-out ADB FunctionFS line. Tabs are significant.
    MATCHES="$(grep -c $'^\t#/etc/init\.d/usb/adb\t\$1$' "$STOCK" || true)"
    [[ "$MATCHES" -eq 1 ]] || die "Expected exactly one disabled ADB startup line; found $MATCHES."
    sed $'s|^\t#/etc/init\.d/usb/adb\t\\$1$|\t/etc/init.d/usb/adb\t$1|' "$STOCK" > "$CANDIDATE"
else
    # Already-installed case: rebuild the candidate from the preserved original.
    note "Device S90usb hash is $DEVICE_HASH (not stock); checking for a preserved original..."
    if remote 'test -f /etc/init.d/S90usb.c1-original && echo yes' | grep -q yes; then
        adb_dev pull /etc/init.d/S90usb.c1-original "$STOCK" >/dev/null
        [[ "$(local_sha256 "$STOCK")" == "$EXPECTED_ORIGINAL_HASH" ]] \
            || die "Preserved original S90usb does not match the known stock hash."
        MATCHES="$(grep -c $'^\t#/etc/init\.d/usb/adb\t\$1$' "$STOCK" || true)"
        [[ "$MATCHES" -eq 1 ]] || die "Expected exactly one disabled ADB startup line; found $MATCHES."
        sed $'s|^\t#/etc/init\.d/usb/adb\t\\$1$|\t/etc/init.d/usb/adb\t$1|' "$STOCK" > "$CANDIDATE"
    else
        die "Device S90usb has an unexpected hash and no preserved original exists: $DEVICE_HASH"
    fi
fi

INSTALLED_HASH="$(local_sha256 "$CANDIDATE")"
[[ "$DEVICE_HASH" == "$EXPECTED_ORIGINAL_HASH" || "$DEVICE_HASH" == "$INSTALLED_HASH" ]] \
    || die "Device S90usb has an unexpected hash: $DEVICE_HASH"

# Normalise CRLF out of the device script exactly as the PowerShell version does.
UPLOAD_SCRIPT="$WORK/device-open-adb.sh"
tr -d '\r' < "$DEVICE_SCRIPT" > "$UPLOAD_SCRIPT"

evidence baseline.txt "action=$ACTION
identity=$STATE_IDENTITY
root_mount=$STATE_ROOT_MOUNT
storage_mount=$STATE_STORAGE_MOUNT
app_daemon_count=$APP_DAEMON_COUNT
mpenMain_count=$MPENMAIN_COUNT
original_sha256=$EXPECTED_ORIGINAL_HASH
installed_sha256=$INSTALLED_HASH
device_before_sha256=$DEVICE_HASH
authentication=none"

note "Uploading..."
adb_dev push "$UPLOAD_SCRIPT" "$REMOTE_SCRIPT" >/dev/null
adb_dev push "$CANDIDATE" "$REMOTE_CANDIDATE" >/dev/null
adb_dev shell "chmod 700 $REMOTE_SCRIPT; chmod 600 $REMOTE_CANDIDATE" >/dev/null
UPLOADED=1

[[ "$(remote_sha256 "$REMOTE_SCRIPT")" == "$(local_sha256 "$UPLOAD_SCRIPT")" ]] \
    || die "Uploaded device script hash mismatch."
[[ "$(remote_sha256 "$REMOTE_CANDIDATE")" == "$INSTALLED_HASH" ]] \
    || die "Uploaded S90usb candidate hash mismatch."
remote_checked "sh -n $REMOTE_SCRIPT" >/dev/null

note "Running device action: $ACTION"
OPERATION="$(remote_checked "$REMOTE_SCRIPT $ACTION $EXPECTED_ORIGINAL_HASH $INSTALLED_HASH")"
evidence operation.log "$OPERATION"
assert_system_state

if [[ "$ACTION" == "install" || "$ACTION" == "verify" ]]; then
    VERIFICATION="$(remote_checked "$REMOTE_SCRIPT verify $EXPECTED_ORIGINAL_HASH $INSTALLED_HASH")"
    evidence verification-before-reboot.log "$VERIFICATION"
fi

if [[ $REBOOT -eq 1 ]]; then
    UPTIME_BEFORE="$(remote "cut -d' ' -f1 /proc/uptime" | tr -d ' \n')"
    note "Rebooting..."
    adb_dev reboot >/dev/null 2>&1 || true
    wait_for_reconnect "$TIMEOUT"
    UPTIME_AFTER="$(remote "cut -d' ' -f1 /proc/uptime" | tr -d ' \n')"
    assert_system_state
    assert_application_state Original
    if [[ "$ACTION" == "install" || "$ACTION" == "verify" ]]; then
        POST="$(remote_checked "/storage/c1/recovery/open-adb/device-open-adb.sh verify $EXPECTED_ORIGINAL_HASH $INSTALLED_HASH")"
        evidence verification-after-reboot.log "$POST"
    fi
    evidence reboot.log "uptime_before=$UPTIME_BEFORE
uptime_after=$UPTIME_AFTER
identity=$STATE_IDENTITY
root_mount=$STATE_ROOT_MOUNT
app_daemon_count=$APP_DAEMON_COUNT
mpenMain_count=$MPENMAIN_COUNT
processes=$(remote 'pidof adbd; pidof app_daemon; pidof mpenMain' | tr '\n' ',')"
fi

echo
echo "$ACTION completed."
echo "Original S90usb SHA-256:  $EXPECTED_ORIGINAL_HASH"
echo "Installed S90usb SHA-256: $INSTALLED_HASH"
echo "Evidence: $RUN_ROOT"
if [[ "$ACTION" == "install" && $REBOOT -eq 0 ]]; then
    echo "WARNING: installation is written but cold-start ADB has not been verified." >&2
    echo "         Re-run with: macos/install-open-adb.sh verify --reboot" >&2
fi
