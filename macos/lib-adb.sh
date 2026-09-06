# Shared ADB orchestration helpers for the macOS installers.
# shellcheck shell=bash

ADB="${ADB:-adb}"
SERIAL=""

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

resolve_adb() {
    if ! command -v "$ADB" >/dev/null 2>&1; then
        die "ADB was not found. Install it with: brew install --cask android-platform-tools"
    fi
    ADB="$(command -v "$ADB")"
}

adb_raw() { "$ADB" "$@"; }
adb_dev() { "$ADB" -s "$SERIAL" "$@"; }

# Run a remote command and fail loudly on a non-zero remote exit status.
# adb shell does not propagate exit codes on this firmware, so we append a marker.
remote_checked() {
    local command="$1" marker="__C1_REMOTE_EXIT=" output status
    output="$(adb_dev shell "$command; c1_status=\$?; echo ${marker}\$c1_status" 2>&1)" || true
    status="$(printf '%s\n' "$output" | tr -d '\r' | sed -n "s/^${marker}\([0-9]\{1,\}\)$/\1/p" | tail -1)"
    [[ -n "$status" ]] || die "Remote command did not return an exit marker: $command"$'\n'"$output"
    printf '%s\n' "$output" | tr -d '\r' | grep -v "^${marker}[0-9]\{1,\}$" || true
    [[ "$status" -eq 0 ]] || die "Remote command failed ($status): $command"
}

remote() { adb_dev shell "$1" 2>&1 | tr -d '\r'; }

get_only_device() {
    local lines
    lines="$(adb_raw devices | tr -d '\r' | awk '$2=="device" {print $1}')"
    local count; count="$(printf '%s\n' "$lines" | grep -c . || true)"
    [[ "$count" -eq 1 ]] || die "Exactly one connected ADB device is required; found $count."
    SERIAL="$(printf '%s\n' "$lines" | head -1)"
    note "Device: $SERIAL"
}

remote_sha256() { remote "sha256sum $1" | awk '{print tolower($1); exit}'; }
local_sha256() { shasum -a 256 "$1" | awk '{print tolower($1)}'; }

process_count() {
    local pattern
    case "$1" in
        app_daemon) pattern='\{app_daemon\}|/etc/app_daemon|/usr/data/c1/bin/app_daemon' ;;
        mpenMain)   pattern='/usr/bin/d261/mpenMain($|[[:space:]])' ;;
        C1ancher)   pattern='/usr/data/c1/bin/C1ancher($|[[:space:]])' ;;
        c1-app)     pattern='/usr/data/c1/bin/c1-app($|[[:space:]])' ;;
        *) die "unknown process name: $1" ;;
    esac
    remote 'ps -ef' | grep -Ec "$pattern" || true
}

assert_system_state() {
    local identity mounts root_mount storage_mount
    identity="$(remote 'id')"
    grep -q 'uid=0(root)' <<<"$identity" || die "A root ADB shell is required. Got: $identity"
    mounts="$(remote 'mount')"
    root_mount="$(grep -E ' on / type ' <<<"$mounts" | head -1)"
    grep -Eq '\(ro(,|\))' <<<"$root_mount" || die "Root filesystem is not read-only: $root_mount"
    storage_mount="$(grep -E ' on /storage type ' <<<"$mounts" | head -1)"
    grep -Eq '\(rw(,|\))' <<<"$storage_mount" || die "Storage is not writable: $storage_mount"
    STATE_IDENTITY="$identity"
    STATE_ROOT_MOUNT="$root_mount"
    STATE_STORAGE_MOUNT="$storage_mount"
}

# assert_application_state Original|C1|C1OrLegacy
assert_application_state() {
    local expected="$1" deadline=$((SECONDS + 20)) daemon main app legacy matched
    while :; do
        daemon="$(process_count app_daemon)"
        main="$(process_count mpenMain)"
        app="$(process_count C1ancher)"
        legacy="$(process_count c1-app)"
        matched=0
        case "$expected" in
            Original)   [[ $daemon -eq 1 && $main -eq 1 && $app -eq 0 && $legacy -eq 0 ]] && matched=1 ;;
            C1)         [[ $daemon -eq 1 && $main -eq 0 && $app -eq 1 && $legacy -eq 0 ]] && matched=1 ;;
            C1OrLegacy) [[ $daemon -eq 1 && $main -eq 0 && $((app + legacy)) -eq 1 ]] && matched=1 ;;
            *) die "unknown expected state: $expected" ;;
        esac
        if [[ $matched -eq 1 ]]; then
            APP_DAEMON_COUNT=$daemon; MPENMAIN_COUNT=$main
            C1ANCHER_COUNT=$app; LEGACY_COUNT=$legacy
            return 0
        fi
        (( SECONDS < deadline )) || die \
            "Application state did not become ${expected}: app_daemon=$daemon mpenMain=$main C1ancher=$app legacy=$legacy"
        sleep 1
    done
}

wait_for_reconnect() {
    local timeout="$1" deadline=$((SECONDS + timeout))
    note "Waiting up to ${timeout}s for the device to come back..."
    while (( SECONDS < deadline )); do
        sleep 2
        if adb_raw devices | tr -d '\r' | awk '$2=="device"{print $1}' | grep -qx "$SERIAL"; then
            if adb_dev shell id 2>/dev/null | grep -q 'uid=0(root)'; then
                note "Device reconnected with a root shell."
                return 0
            fi
        fi
    done
    die "Device did not reconnect within ${timeout}s. Restore with: adb shell /storage/c1/recovery/default-app/device-default-app.sh uninstall"
}

evidence() { printf '%s\n' "$2" > "$RUN_ROOT/$1"; }
