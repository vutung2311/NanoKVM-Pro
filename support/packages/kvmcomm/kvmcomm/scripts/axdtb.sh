#!/bin/bash

set -euo pipefail
DTB_FILE="$1"
TARGET_DEV1="/dev/mmcblk0p12"
TARGET_DEV2="/dev/mmcblk0p13"

function usage() {
    echo "Usage: sudo $0 <new_dtb_file>"
    exit 1
}

function die() {
    echo "Error: $*" >&2
    exit 2
}

[[ $# -lt 1 ]] && usage
[[ ! -r "$DTB_FILE" ]] && die "DTB file unreadable: $DTB_FILE"

dd if="$DTB_FILE" of="$TARGET_DEV1" bs=4K conv=notrunc status=progress
dd if="$DTB_FILE" of="$TARGET_DEV2" bs=4K conv=notrunc status=progress

sync
sync
sync
