#!/bin/bash

set -euo pipefail
KERNEL_FILE="$1"
TARGET_DEV1="/dev/mmcblk0p14"
TARGET_DEV2="/dev/mmcblk0p15"

function usage() {
    echo "Usage: sudo $0 <new_kernel_file>"
    exit 1
}

function die() {
    echo "Error: $*" >&2
    exit 2
}

[[ $# -lt 1 ]] && usage
[[ ! -r "$KERNEL_FILE" ]] && die "KERNEL file unreadable: $KERNEL_FILE"

dd if="$KERNEL_FILE" of="$TARGET_DEV1" bs=4K conv=notrunc status=progress
dd if="$KERNEL_FILE" of="$TARGET_DEV2" bs=4K conv=notrunc status=progress

sync
sync
sync
