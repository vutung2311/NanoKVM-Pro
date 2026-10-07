#!/bin/bash

exec >/dev/null 2>&1

readonly RAMFS_ROOT="/dev/shm"
readonly APP_ROOT="/kvmcomm"

# Kernel version specific module selection
KVER=$(uname -r | cut -d"-" -f1)
if [ -d "${APP_ROOT}/ko_${KVER}" ]; then
    cp -af "${APP_ROOT}/ko_${KVER}"/* "${APP_ROOT}/ko/" 2>/dev/null || true
    if [ -f "${APP_ROOT}/ko_${KVER}/aic8800_fdrv.ko" ]; then
        mkdir -p "/lib/modules/$(uname -r)/kernel/drivers/net/wireless/aic8800" 2>/dev/null || true
        cp -af "${APP_ROOT}/ko_${KVER}"/aic8800* "/lib/modules/$(uname -r)/kernel/drivers/net/wireless/aic8800/" 2>/dev/null || true
        depmod -a "$(uname -r)" 2>/dev/null || true
    fi
fi

# Silence verbose AMSDU packet traces from AIC8800 Wi-Fi driver in dmesg
if [ -e /sys/module/aic8800_fdrv/parameters/aicwf_dbg_level ]; then
    echo 7 > /sys/module/aic8800_fdrv/parameters/aicwf_dbg_level 2>/dev/null || true
fi

safe_rm() {
    target="$1"
    if [ -e "$target" ]; then
        if [ -d "$target" ]; then
            rm -rf "$target" || {
                exit 1
            }
        else
            rm -f "$target" || {
                exit 1
            }
        fi
    fi
}

safe_copy() {
    local src=$1
    local dest=$2
    if [ ! -e "$src" ]; then
        exit 1
    fi
    cp -av "$src" "$dest" || exit 1
}

safe_rm "${RAMFS_ROOT}${APP_ROOT}"
safe_copy "${APP_ROOT}" "${RAMFS_ROOT}${APP_ROOT}"
