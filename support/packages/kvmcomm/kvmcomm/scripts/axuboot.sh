#!/bin/bash

set -euo pipefail
UBOOT_FILE="$1"
TARGET_DEV1="/dev/mmcblk0p5"
TARGET_DEV2="/dev/mmcblk0p6"

function usage() {
    echo "Usage: sudo $0 <new_uboot_file>"
    exit 1
}

function die() {
    echo "Error: $*" >&2
    exit 2
}

[[ $# -lt 1 ]] && usage
[[ ! -r "$UBOOT_FILE" ]] && die "UBOOT file unreadable: $UBOOT_FILE"

dd if="$UBOOT_FILE" of="$TARGET_DEV1" bs=4K conv=notrunc status=progress
dd if="$UBOOT_FILE" of="$TARGET_DEV2" bs=4K conv=notrunc status=progress

sync
sync
sync
