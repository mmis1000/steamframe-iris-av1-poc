#!/usr/bin/env bash
# Run on the headset. --check is read-only; --load swaps only the live module.
set -euo pipefail
RELEASE=6.18.0-g83913f38113c
SERVICE=iris-driver-rebind.service
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
if [[ $# != 2 || ( $1 != --check && $1 != --load ) ]]; then
    echo 'Usage: bash load-temporary.sh --check /path/to/artifacts/iris-av1-poc.ko'
    echo '       sudo bash load-temporary.sh --load /path/to/artifacts/iris-av1-poc.ko'
    exit 1
fi
MODE=$1
[[ $(uname -m) == aarch64 && $(uname -r) == "$RELEASE" ]] || die "Requires aarch64 kernel $RELEASE."
for tool in modinfo sha256sum realpath gzip v4l2-ctl systemctl; do
    command -v "$tool" >/dev/null || die "Missing command: $tool"
done
if [[ $MODE == --load ]]; then
    [[ $EUID == 0 ]] || die 'Run --load with sudo.'
    for tool in insmod rmmod modprobe flock awk dmesg mktemp; do
        command -v "$tool" >/dev/null || die "Missing command: $tool"
    done
    exec 9>/run/iris-av1-poc.lock
    flock -n 9 || die 'Another temporary-load operation is running.'
fi
MODULE=$(realpath -- "$2")
ARTIFACTS=$(dirname -- "$MODULE")
[[ $(basename -- "$MODULE") == iris-av1-poc.ko ]] || die 'Use the original artifact filename.'
[[ -r $ARTIFACTS/SHA256SUMS && -r $ARTIFACTS/kernel-config.sha256 ]] || die 'Copy the entire artifacts directory.'
(cd "$ARTIFACTS" && sha256sum -c SHA256SUMS)
[[ $(modinfo -F name "$MODULE") == iris ]] || die 'Unexpected module name.'
STOCK=$(modinfo -n iris)
[[ -f $STOCK ]] || die 'Installed Iris module was not found.'
[[ $(modinfo -F vermagic "$MODULE") == "$(modinfo -F vermagic "$STOCK")" ]] || die 'Module vermagic differs from the installed driver.'
[[ -r /proc/config.gz ]] || die 'Cannot verify the running kernel configuration.'
CONFIG_SHA=$(gzip -dc /proc/config.gz | sha256sum | cut -d' ' -f1)
[[ $CONFIG_SHA == "$(cat "$ARTIFACTS/kernel-config.sha256")" ]] || die 'Running kernel configuration differs from the build configuration.'
[[ -r /sys/module/iris/initstate && $(cat /sys/module/iris/initstate) == live ]] || die 'Expected the original Iris module to be live.'
[[ $(cat /sys/module/iris/refcnt) == 0 ]] || die 'Iris is in use. Close video playback and retry.'
[[ -e /dev/video-dec0 ]] || die '/dev/video-dec0 is missing.'
FORMATS=$(v4l2-ctl -d /dev/video-dec0 --list-formats-out)
[[ $FORMATS != *AV01* ]] || die 'The live driver already exposes AV1. Restore the original session before using this script.'
[[ $(cat /sys/module/iris/refcnt) == 0 ]] || die 'Iris became busy during checks.'
echo "Checks passed: $RELEASE; matching configuration/vermagic; Iris is idle."
if [[ $MODE == --check ]]; then
    echo 'Check only: no service or module was changed.'
    exit 0
fi

STATE=$(mktemp -d /run/iris-av1-poc.XXXXXX)
chmod 700 "$STATE"
# Stage and recheck the module so the load uses the bytes that were verified.
cp -- "$MODULE" "$STATE/iris-av1-poc.ko"
cp "$ARTIFACTS/SHA256SUMS" "$STATE/manifest.txt"
EXPECTED_MODULE_SHA=$(awk '$2 == "iris-av1-poc.ko" {print $1}' "$STATE/manifest.txt")
[[ $EXPECTED_MODULE_SHA =~ ^[[:xdigit:]]{64}$ ]] || die 'Missing or ambiguous module checksum.'
printf '%s  %s\n' "$EXPECTED_MODULE_SHA" "$STATE/iris-av1-poc.ko" | sha256sum -c -
sha256sum "$STOCK" > "$STATE/original.sha256"
modinfo "$STOCK" > "$STATE/original-modinfo.txt"
cp "$ARTIFACTS/build-info.txt" "$STATE/" 2>/dev/null || true
was_active=0
if systemctl is-active --quiet "$SERVICE"; then was_active=1; fi
printf '%s\n' "$was_active" > "$STATE/rebind-was-active"
unloaded=0
loaded=0
recover_on_error() {
    local status=$?
    trap - EXIT
    if (( status != 0 )); then
        echo "Temporary load failed. Diagnostics: $STATE" >&2
        dmesg > "$STATE/dmesg-failure.txt" 2>/dev/null || true
        if (( unloaded && !loaded )) && [[ ! -d /sys/module/iris ]]; then
            modprobe iris || echo 'Original driver could not be reloaded; manual recovery is required.' >&2
        fi
        if (( was_active && !loaded )) && [[ -r /sys/module/iris/initstate ]] &&
           [[ $(cat /sys/module/iris/initstate) == live ]]; then
            systemctl start "$SERVICE" || true
        fi
        sha256sum -c "$STATE/original.sha256" || true
        echo 'The script will not reboot. A user-initiated reboot restores the installed driver.' >&2
    fi
    exit "$status"
}
trap recover_on_error EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if (( was_active )); then systemctl stop "$SERVICE"; fi
[[ $(cat /sys/module/iris/refcnt) == 0 ]] || die 'Iris became busy; leaving it loaded.'
dmesg > "$STATE/dmesg-before.txt"
rmmod iris
unloaded=1
insmod "$STATE/iris-av1-poc.ko"
loaded=1
[[ $(cat /sys/module/iris/initstate) == live ]] || die 'Experimental module did not reach live state.'
for _ in {1..20}; do
    [[ -e /dev/video-dec0 ]] && break
    sleep 0.1
done
v4l2-ctl -d /dev/video-dec0 --list-formats-out | tee "$STATE/formats.txt"
grep -q AV01 "$STATE/formats.txt" || die 'Experimental driver did not advertise AV1.'
sha256sum -c "$STATE/original.sha256"
dmesg > "$STATE/dmesg-after.txt"
trap - EXIT INT TERM
printf '\nTemporary AV1 module is loaded. Session records: %s\n' "$STATE"
echo 'The rebind service stays stopped for this session if it was previously active.'
echo 'Installed module files and boot settings are unchanged.'
echo 'When finished, reboot the headset yourself to restore the original driver.'
