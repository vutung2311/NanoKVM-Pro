#!/bin/bash

set -eo pipefail

readonly LOG_DIR="/var/log/kvmcomm"
readonly LOG_FILE="${LOG_DIR}/kvm_reset_to_default.log"
readonly TMP_LOG_FILE="/tmp/kvm_reset.log"
readonly LOCK_FILE="/dev/shm/reset_in_progress.lock"

exec 1>>"$TMP_LOG_FILE"
exec 2>&1


create_reset_lock() {
    if [ -f "$LOCK_FILE" ]; then
        echo "$(date) - Reset lock file already exists: $LOCK_FILE" >>"$LOG_FILE"
        echo "Error: Reset operation is already in progress or previous reset did not complete properly"
        exit 1
    fi

    echo "$(date) - Creating reset lock file: $LOCK_FILE" >>"$LOG_FILE"
    mkdir -p /kvmcomm
    touch "$LOCK_FILE"
    if [ $? -eq 0 ]; then
        echo "$(date) - Reset lock file created successfully" >>"$LOG_FILE"
        echo "Reset lock created"
    else
        echo "$(date) - Failed to create reset lock file" >>"$LOG_FILE"
        echo "Error: Failed to create reset lock file"
        exit 1
    fi
}

# Remove lock file when reset is completed
remove_reset_lock() {
    echo "$(date) - Removing reset lock file: $LOCK_FILE" >>"$LOG_FILE"
    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
        if [ $? -eq 0 ]; then
            echo "$(date) - Reset lock file removed successfully" >>"$LOG_FILE"
            echo "Reset lock removed"
        else
            echo "$(date) - Failed to remove reset lock file" >>"$LOG_FILE"
            echo "Warning: Failed to remove reset lock file"
        fi
    else
        echo "$(date) - Reset lock file does not exist" >>"$LOG_FILE"
    fi
}

# Set once the reset starts deleting application state. From then on there
# is no going back, so every exit path reboots into whatever was restored
# rather than leaving a half-reset device running.
RESET_COMMITTED=0

reboot_device() {
    sync
    echo "$(date) - Rebooting" >>"$LOG_FILE"
    systemctl reboot
}

cleanup_on_exit() {
    local exit_code=$?
    trap - ERR SIGINT SIGTERM
    if [ $exit_code -ne 0 ]; then
        echo "$(date) - Script exiting with error (exit code: $exit_code)" >>"$LOG_FILE"
    fi
    remove_reset_lock
    if [ "$RESET_COMMITTED" = 1 ]; then
        reboot_device
    fi
    exit $exit_code
}

trap 'echo "$(date) - Script interrupted by signal" >>"$LOG_FILE"; cleanup_on_exit' SIGINT SIGTERM
trap 'cleanup_on_exit' ERR

echo "$(date) - Starting reset to default..." >>"$LOG_FILE"

create_reset_lock

#==================== pick replacement packages ====================#
# Everything below is decided before anything is deleted: a reset that cannot
# reinstall the applications must leave the device as it was.
#
# Packages come only from the local cache that the image build fills
# (/root/.kvmcache/*.deb). The upstream (Sipeed) CDN bundle is never used:
# its packages carry the same version numbers as this fork's and would
# silently replace it. Subdirectories of the cache (where earlier versions of
# this script unpacked those CDN bundles) are ignored for the same reason.

readonly CACHE_BASE_DIR="/root/.kvmcache"
readonly ARCH="arm64"

installed_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

deb_field() {
    dpkg-deb -f "$1" "$2" 2>/dev/null || true
}

# Print the cached .deb for package $1 (file prefix $2): the one matching the
# installed version if present, else the newest cached one.
find_reset_deb() {
    local pkg="$1" prefix="$2" want best="" best_ver="" f ver
    want=$(installed_version "$pkg")
    [ -d "$CACHE_BASE_DIR" ] || return 1
    for f in "$CACHE_BASE_DIR/${prefix}_"*"_${ARCH}.deb"; do
        [ -f "$f" ] || continue
        [ "$(deb_field "$f" Package)" = "$pkg" ] || continue
        [ "$(deb_field "$f" Architecture)" = "$ARCH" ] || continue
        ver=$(deb_field "$f" Version)
        [ -n "$ver" ] || continue
        # Reject a truncated or corrupt archive now, not halfway through.
        dpkg-deb --fsys-tarfile "$f" >/dev/null 2>&1 || {
            echo "$(date) - Ignoring unreadable package: $f" >>"$LOG_FILE"
            continue
        }
        if [ -n "$want" ] && [ "$ver" = "$want" ]; then
            echo "$f"
            return 0
        fi
        if [ -z "$best" ] || dpkg --compare-versions "$ver" gt "$best_ver"; then
            best="$f"
            best_ver="$ver"
        fi
    done
    [ -n "$best" ] || return 1
    echo "$(date) - $pkg: installed version '${want:-none}' not cached, using $best_ver" >>"$LOG_FILE"
    echo "$best"
}

declare -A RESET_DEBS=()
missing=""
for spec in nanokvm:nanokvmpro kvmcomm:kvmcomm pikvm:pikvm; do
    pkg="${spec%%:*}"
    prefix="${spec#*:}"
    if [ "$pkg" = pikvm ] && [ -z "$(installed_version pikvm)" ]; then
        continue  # optional, only reinstalled when present
    fi
    if deb=$(find_reset_deb "$pkg" "$prefix"); then
        RESET_DEBS[$pkg]="$deb"
        echo "$(date) - $pkg will be reinstalled from $deb ($(deb_field "$deb" Version))" >>"$LOG_FILE"
    else
        missing="$missing $pkg"
    fi
done

if [ -n "$missing" ]; then
    echo "$(date) - Aborting reset, no usable cached package for:$missing (looked in $CACHE_BASE_DIR). Nothing was changed." >>"$LOG_FILE"
    echo "Error: no cached package for:$missing; reset aborted, nothing was changed"
    remove_reset_lock
    exit 1
fi

#==================== point of no return ====================#
RESET_COMMITTED=1
# Keep going past individual failures: the device reboots at the end either
# way, and the more is restored the better it comes back.
set +e
trap - ERR

echo "Restoring default configuration files..."

rm -rf /etc/kvm/ || true
rm -rf /etc/kvmd/ || true
rm -rf /userapp || true
rm -rf /kvmcomm || true
rm -rf /kvmapp || true
rm -f /boot/usb* /boot/rndis* /boot/ncm* || true
rm -f /boot/force* || true
touch /boot/usb.ncm || true
touch /boot/first_time_boot || true

systemctl stop tailscaled || true
systemctl disable tailscaled || true
rm -rf /root/.tailscale || true
rm -rf /var/lib/tailscale || true
rm -rf /var/cache/tailscale || true
rm -f /usr/bin/tailscale || true
rm -f /usr/sbin/tailscaled || true
rm -f /etc/systemd/system/tailscaled.service || true
rm -f /etc/default/tailscaled || true

systemctl stop kvmadmin.service || true
systemctl disable kvmadmin.service || true
rm -rf /etc/kvmadmin || true
rm -rf /kvmadmin || true
rm -f /etc/systemd/system/kvmadmin.service || true

rm -f /boot/eth.nodhcp || true

systemctl daemon-reload

echo "Resetting system user passwords..."

# Reset root password
echo "$(date) - Resetting root password" >>"$LOG_FILE"
echo "root:sipeed" | chpasswd
if [ $? -eq 0 ]; then
    echo "$(date) - Successfully reset root password" >>"$LOG_FILE"
    echo "Root password reset to: sipeed"
else
    echo "$(date) - Failed to reset root password" >>"$LOG_FILE"
    echo "Error: Failed to reset root password"
fi

echo "Reinstalling deb packages..."

reinstall_packages() {
    echo "$(date) - Starting package reinstallation" >>"$LOG_FILE"
    local failed=0 pkg deb attempt ok

    for pkg in nanokvm pikvm kvmcomm; do
        deb="${RESET_DEBS[$pkg]:-}"
        [ -n "$deb" ] || continue
        echo "$(date) - Reinstalling $pkg from: $(basename "$deb")" >>"$LOG_FILE"
        echo "Reinstalling $pkg package: $(basename "$deb")"
        ok=0
        for attempt in 1 2; do
            if DEBIAN_FRONTEND=noninteractive dpkg -i --force-confmiss "$deb" 2>>"$TMP_LOG_FILE"; then
                ok=1
                break
            fi
            echo "$(date) - dpkg -i $pkg failed (attempt $attempt)" >>"$LOG_FILE"
        done
        if [ "$ok" = 1 ]; then
            echo "$(date) - Successfully reinstalled $pkg" >>"$LOG_FILE"
        else
            echo "$(date) - Failed to reinstall $pkg" >>"$LOG_FILE"
            echo "Error: Failed to reinstall $pkg"
            failed=1
        fi
    done

    echo "$(date) - Running dpkg --configure -a" >>"$LOG_FILE"
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a >>"$LOG_FILE" 2>&1 || failed=1
    return $failed
}

if ! reinstall_packages; then
    echo "$(date) - Package reinstallation had errors; rebooting anyway" >>"$LOG_FILE"
fi

if [ -f "/etc/kvmd/scripts/pikvm_init.sh" ]; then
    echo "$(date) - Executing PiKVM initialization script" >>"$LOG_FILE"
    if bash /etc/kvmd/scripts/pikvm_init.sh >>"$LOG_FILE" 2>&1; then
        echo "$(date) - Successfully executed pikvm_init.sh" >>"$LOG_FILE"
        echo "PiKVM initialization completed successfully"
    else
        echo "$(date) - Failed to execute pikvm_init.sh" >>"$LOG_FILE"
        echo "Warning: Failed to execute PiKVM initialization script"
    fi
else
    echo "$(date) - pikvm_init.sh not found, skipping initialization" >>"$LOG_FILE"
fi

if [ -f "/usr/share/zoneinfo/Asia/Shanghai" ]; then
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    echo "Asia/Shanghai" > /etc/timezone
    if [ $? -eq 0 ]; then
        echo "$(date) - Successfully reset timezone to Asia/Shanghai" >>"$LOG_FILE"
    else
        echo "$(date) - Failed to reset timezone" >>"$LOG_FILE"
    fi
else
    echo "$(date) - Timezone file not found: /usr/share/zoneinfo/Asia/Shanghai" >>"$LOG_FILE"
fi

cat /kvmcomm/edid/E56-2K60FPS.bin > /proc/lt6911_info/edid 2>/dev/null || \
    echo "$(date) - Could not restore the default EDID" >>"$LOG_FILE"

echo "$(date) - Reset to default completed" >>"$LOG_FILE"
echo "Reset to default process completed successfully"

remove_reset_lock
reboot_device
