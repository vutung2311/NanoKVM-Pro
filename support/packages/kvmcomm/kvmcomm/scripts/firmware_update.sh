#!/bin/bash

# -----------------------------------------------------------------------------
# Firmware directory structure for firmware update script:
#
# firmware/
# ├─ u-boot_signed.bin                                      # U-Boot binary
# ├─ boot_signed.bin                                        # Bootloader binary
# └─ AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb
#
# overlay/
# ├─ boot/ver                                               # Version file
# └─ boot/configs                                           # Configuration file
#
# Usage:
# ./firmware_update.sh gen_b2sum        # Generate b2sum.txt
# ./firmware_update.sh fetch <version>  # Fetch firmware package from CDN
# ./firmware_update.sh update           # Flash firmware
# -----------------------------------------------------------------------------

set -eo pipefail

UBOOT_FILE=firmware/u-boot_signed.bin
DTB_FILE=firmware/AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb
KERNEL_FILE=firmware/boot_signed.bin

CDN_URLS=(
    "https://cdn.sipeed.com/nanokvm/pro"
    "https://cdn.sipeed.com/nanokvm/pro/preview"
)

WORKDIR="/tmp/firmware_update"

gen_b2sum() {
    local out_file="b2sum.txt"
    echo "Generating checksums for firmware and overlay files..."
    : > "$out_file"

    if [ -d "firmware" ] || [ -d "overlay" ]; then
        find firmware overlay -type f -print0 2>/dev/null | sort -z | xargs -0 -r b2sum > "$out_file"
    fi

    echo "b2sum have been saved to $out_file ($(wc -l < "$out_file") files)"
}

check_sum() {
    local sum_file="b2sum.txt"
    if [ ! -f "$sum_file" ]; then
        echo "Checksum file $sum_file not found!"
        exit 1
    fi

    echo "Verifying checksums..."
    if b2sum -c "$sum_file"; then
        echo "All checksums are valid"
    else
        local failed=$(b2sum -c "$sum_file" 2>&1 | grep -c FAILED || true)
        echo "Checksum verification failed! ($failed file(s) mismatched)"
        exit 1
    fi
}

flash_image() {
    local file="$1"
    local script="$2"
    shift 2
    local partitions=("$@")

    if [ -f "$file" ]; then

        echo "Flashing $file ..."

        if [ -f "$script" ]; then
            "$script" "$file" > /dev/null 2>&1
        else
            for part in "${partitions[@]}"; do
                dd if="$file" of="$part" bs=4K conv=notrunc > /dev/null 2>&1
            done
        fi
    fi
}

# 32-bit SoC register access: soc_reg ADDR (read, prints hex) / soc_reg ADDR VALUE (write).
# The Jammy rootfs ships no `devmem`, so fall back to busybox's applet, then to
# python3 on /dev/mem (kernel has CONFIG_DEVMEM=y, STRICT_DEVMEM off).
soc_reg() {
    if command -v devmem >/dev/null 2>&1; then
        devmem "$1" 32 ${2:+"$2"}
    elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx devmem; then
        busybox devmem "$1" 32 ${2:+"$2"}
    elif command -v python3 >/dev/null 2>&1; then
        python3 -I - "$1" ${2:+"$2"} <<'PY'
import mmap, os, sys
addr = int(sys.argv[1], 0)
page, off = addr & ~0xFFF, addr & 0xFFF
write = len(sys.argv) > 2
fd = os.open("/dev/mem", (os.O_RDWR if write else os.O_RDONLY) | os.O_SYNC)
m = mmap.mmap(fd, 4096, mmap.MAP_SHARED,
              mmap.PROT_READ | (mmap.PROT_WRITE if write else 0), offset=page)
words = memoryview(m).cast("I")  # single aligned 32-bit loads/stores
if write:
    words[off // 4] = int(sys.argv[2], 0) & 0xFFFFFFFF
else:
    print("0x%08X" % words[off // 4])
PY
    else
        return 127
    fi
}

# fw_printenv/fw_setenv from /opt/swupdate need its bundled libubootenv, which
# is not on the Jammy loader path.
uboot_env() {
    if [ -d /opt/swupdate/lib ]; then
        LD_LIBRARY_PATH="/opt/swupdate/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$@"
    else
        "$@"
    fi
}

# Mark the slot that actually booted as good (same as vendor S99checkboot start;
# kvmcomm.sh does the same on every boot). BL1 (bl1/core/boot/boot.c
# select_slot_ab) consumes the booted slot's BOOTABLE bit on every warm boot.
# The slot comes from the hardware register, not from the U-Boot env, which can
# be stale after a BL1 fallback. Never touch the other slot's bits.
# TOP_CHIPMODE_GLB_BACKUP0: 0x2390024 readback, 0x2390028 set, 0x239002C clear.
#   BIT2 SLOTA, BIT3 SLOTB, BIT4 SLOTA_BOOTABLE, BIT5 SLOTB_BOOTABLE, BIT7 BOOT_KERNEL_FAIL
# ON-DEVICE CHECK: `soc_reg 0x2390024` showed 0x4 after booting slot A
# (verified 2026-11-14). PENDING: confirm 0x8 (not 0x4) after booting slot B.
mark_booted_slot_good() {
    local raw reg slot token env_slot
    raw=$(soc_reg 0x2390024 2>/dev/null) || raw=""
    raw=$(printf '%s\n' "$raw" | grep -oiE '0x[0-9a-f]+' | tail -n1 || true)
    if [ -z "$raw" ]; then
        echo "Boot slot: cannot read 0x2390024; not arming"
        return 0
    fi
    reg=$((raw))
    case $((reg & 0xC)) in
        4) slot=A; token=0x10 ;;
        8) slot=B; token=0x20 ;;
        *)
            echo "Boot slot: 0x2390024=${raw} selects neither or both slots; not arming"
            return 0
            ;;
    esac

    echo "Marking boot slot ${slot} bootable (0x2390024 was ${raw})..."
    soc_reg 0x239002C 0x80 2>/dev/null || true # clear BOOT_KERNEL_FAIL
    soc_reg 0x2390028 "$token" 2>/dev/null || true # re-arm only the booted slot

    env_slot=$(uboot_env fw_printenv bootsystem 2>/dev/null | sed -n 's/^bootsystem=//p' | tail -n1 || true)
    if [ "$env_slot" != "$slot" ]; then
        echo "Boot slot: bootsystem env '${env_slot}' disagrees with hardware; setting ${slot}"
        uboot_env fw_setenv bootsystem "$slot" 2>/dev/null || true
    fi
}

update() {
    echo "Checking b2sum ..."
    check_sum

    if [ ! -f overlay/boot/ver ]; then
        echo "Version file not found!"
        exit 1
    fi

    local root_dev
    root_dev=$(grep -o 'root=[^ ]*' /proc/cmdline | head -n1 | cut -d= -f2)

    if [ "$root_dev" = "/dev/mmcblk0p17" ]; then
        echo "Updating firmware for EMMC boot ..."
        flash_image "$UBOOT_FILE"  /kvmcomm/scripts/axuboot.sh  /dev/mmcblk0p5  /dev/mmcblk0p6
        flash_image "$DTB_FILE"    /kvmcomm/scripts/axdtb.sh    /dev/mmcblk0p12 /dev/mmcblk0p13
        flash_image "$KERNEL_FILE" /kvmcomm/scripts/axkernel.sh /dev/mmcblk0p14 /dev/mmcblk0p15

        # Both slots now hold the same image (see flash_image calls above), so
        # do not switch slots here: only keep the slot that booted armed.
        mark_booted_slot_good
    elif [ "$root_dev" = "/dev/mmcblk1p2" ]; then
        echo "Updating firmware for SD boot ..."
        cp "$UBOOT_FILE" /boot/uboot.bin
        cp "$DTB_FILE" /boot/dtb.img
        cp "$KERNEL_FILE" /boot/kernel.img
    else
        echo "Unsupported boot root device: ${root_dev:-unknown}"
        echo "Expected root=/dev/mmcblk0p17 (EMMC) or root=/dev/mmcblk1p2 (SD)"
        exit 1
    fi

    if [ -d overlay/boot ]; then
        cp -r overlay/boot/* /boot 2>/dev/null || true
    fi
    # Never leave the web UI without assets: rsync replaces each file via a
    # temp file + rename, so at every point the assets referenced by whichever
    # index.html is on disk still exist. Order:
    #   1. add the new hashed assets next to the old ones (no deletion),
    #   2. install the rest of the overlay (including the new index.html),
    #   3. once that is on disk, prune assets the new build no longer ships.
    # A power cut at any step leaves at worst some stale assets, which the
    # next update prunes.
    local web_assets=kvmapp/server/web/assets
    if [ -d "overlay/$web_assets" ]; then
        mkdir -p "/$web_assets"
        rsync -a "overlay/$web_assets/" "/$web_assets/"
    fi
    rsync -a --exclude='/boot' --exclude="/$web_assets" overlay/ /
    if [ -d "overlay/$web_assets" ]; then
        sync
        rsync -a --delete-after "overlay/$web_assets/" "/$web_assets/"
    fi

    touch /var/run/reboot-required

    sync
    sync
    sync

    echo "Firmware update completed"
}

# Download over verified TLS. Exit codes 58/59/60/77/83/90/91 are TLS or
# certificate failures: retrying or trying another mirror will not help, and
# there is deliberately no insecure fallback.
cdn_download() {
    local url="$1" out="$2" connect_timeout="$3" max_time="$4" rc=0
    curl -fsSL --connect-timeout "$connect_timeout" --max-time "$max_time" "$url" -o "$out" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        58|59|60|77|83|90|91)
            echo "Error: TLS certificate verification failed for $url (curl exit $rc)."
            echo "Check the system clock and that CA certificates are installed (ca-certificates, /etc/ssl/certs)."
            exit 1
            ;;
    esac
    return "$rc"
}

fetch_from_cdn() {
    local version="$1"
    local pkg_xz="axera_firmware_${version}.tar.xz"
    local pkg_gz="axera_firmware_${version}.tar.gz"
    local json_file="firmware_${version#v}.json"

    mkdir -p "$WORKDIR"
    rm -rf "$WORKDIR"/*

    local url pkg json_url json_content sha512_expected sha512_actual

    local max_retries=3
    local retry_delay=1
    local json_downloaded=false

    for base in "${CDN_URLS[@]}"; do
        for json_url in "$base/$json_file"; do
            echo "Trying to download JSON: $json_url"
            for ((i=1; i<=max_retries; i++)); do
                if cdn_download "$json_url" "$WORKDIR/$json_file" 5 30; then
                    echo "Downloaded JSON: $WORKDIR/$json_file (attempt $i)"
                    json_downloaded=true
                    break 3
                else
                    echo "Download attempt $i failed for JSON"
                    if [ $i -lt $max_retries ]; then
                        echo "Retrying in ${retry_delay} seconds..."
                        sleep $retry_delay
                    fi
                fi
            done
        done
    done

    if [ "$json_downloaded" != "true" ]; then
        echo "Error: Failed to fetch JSON metadata for version $version after $max_retries attempts"
        exit 1
    fi

    sha512_expected=$(grep -oP '"sha512"\s*:\s*"\K[^"]+' "$WORKDIR/$json_file")
    pkg_name=$(grep -oP '"name"\s*:\s*"\K[^"]+' "$WORKDIR/$json_file")

    local pkg_downloaded=false

    for base in "${CDN_URLS[@]}"; do
        for ext in "$pkg_xz" "$pkg_gz"; do
            url="${base}/${ext}"
            echo "Trying to download firmware package: $url"
            for ((i=1; i<=max_retries; i++)); do
                if cdn_download "$url" "$WORKDIR/$ext" 15 300; then
                    pkg="$WORKDIR/$ext"
                    echo "Downloaded firmware package: $pkg (attempt $i)"
                    pkg_downloaded=true
                    break 3
                else
                    echo "Download attempt $i failed for firmware package"
                    if [ $i -lt $max_retries ]; then
                        echo "Retrying in ${retry_delay} seconds..."
                        sleep $retry_delay
                    fi
                fi
            done
        done
    done

    if [ "$pkg_downloaded" != "true" ]; then
        echo "Error: Failed to fetch firmware package for version $version after $max_retries attempts"
        exit 1
    fi

    echo "Verifying SHA512 checksum..."
    sha512_actual=$(sha512sum "$pkg" | awk '{print $1}' | xxd -r -p | base64 | tr -d '\n')

    if [ "$sha512_actual" != "$sha512_expected" ]; then
        echo "Error: SHA512 checksum mismatch!"
        echo "Expected: $sha512_expected"
        echo "Actual:   $sha512_actual"
        exit 1
    fi

    echo "Checksum verified successfully"

    echo "Extracting $pkg ..."
    tar --warning=no-timestamp -xf "$pkg" -C "$WORKDIR"

    echo "Firmware package extracted to $WORKDIR"
}

case "${1:-}" in
    gen_b2sum)
        echo "Generating b2sum ..."
        gen_b2sum
        ;;
    fetch)
        if [ -z "$2" ]; then
            echo "Usage: $0 fetch <version>"
            exit 1
        fi
        fetch_from_cdn "$2"
        ;;
    update)
        if [ -n "$2" ]; then
            if [ -f "$2" ]; then
                echo "Detected local firmware package: $2"
                local_pkg_path=$(readlink -f "$2")
                mkdir -p "$WORKDIR"
                rm -rf "$WORKDIR"/*
                echo "Extracting local package to $WORKDIR ..."
                tar --warning=no-timestamp -xf "$local_pkg_path" -C "$WORKDIR"
                cd "$WORKDIR"
            else
                fetch_from_cdn "$2"
                cd "$WORKDIR"
            fi
        fi

        update
        ;;
    *)
        echo "usage:"
        echo "  $0 gen_b2sum"
        echo "  $0 fetch <version>"
        echo "  $0 update [<version>]"
        exit 1
        ;;
esac
