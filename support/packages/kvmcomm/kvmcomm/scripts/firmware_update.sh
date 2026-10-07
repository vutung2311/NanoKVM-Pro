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
        find firmware overlay -type f 2>/dev/null | sort | xargs b2sum > "$out_file"
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

        # Arm active boot slot in AX630C persistent backup registers and U-Boot environment
        local bootsystem
        bootsystem=$(fw_printenv bootsystem 2>/dev/null | awk -F= '{print $2}')
        [ -z "$bootsystem" ] && bootsystem="A"

        echo "Arming boot slot ($bootsystem) in hardware registers..."
        # Always clear BOOT_KERNEL_FAIL flag (0x80)
        devmem 0x239002C 32 0x80 2>/dev/null || true

        if [ "$bootsystem" = "B" ]; then
            devmem 0x239002C 32 0x14 2>/dev/null || true
            devmem 0x2390028 32 0x28 2>/dev/null || true
            fw_setenv bootsystem B 2>/dev/null || true
        else
            devmem 0x239002C 32 0x28 2>/dev/null || true
            devmem 0x2390028 32 0x14 2>/dev/null || true
            fw_setenv bootsystem A 2>/dev/null || true
        fi
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
    rsync -a --exclude='/boot' overlay/ /

    touch /var/run/reboot-required

    sync
    sync
    sync

    echo "Firmware update completed"
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
                if curl -fsSL -k --connect-timeout 5 --max-time 30 "$json_url" -o "$WORKDIR/$json_file" >/dev/null 2>&1; then
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
                if curl -fsSL -k --connect-timeout 15 --max-time 300 "$url" -o "$WORKDIR/$ext" >/dev/null 2>&1; then
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
