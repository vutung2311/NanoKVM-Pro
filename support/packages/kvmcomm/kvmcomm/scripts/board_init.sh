#!/bin/bash
# NanoKVM-Pro board init: Axera media/touch drivers, rotary pinmux, NPU
# bandwidth limit, Ethernet tuning and the OTA result check. Run once per boot
# by kvm-board-init.service, which kvmcomm.service pulls in, because kvm_ui
# needs the touch driver and kvm_vin the ax_* drivers.
# Ported from the vendor 1.0.15 image's /etc/rc.local.
#
# Every step must be safe to run twice: a vendor-base device may still run the
# vendor /etc/rc.local, with the same steps, before this unit. Our images and
# device_repairs.sh make that file non-executable, so it normally does not run.
# No `set -e`: one failed step must not stop the rest.
#
# Left out on purpose:
#   S99checkboot start - kvmcomm.sh's mark_booted_slot_good re-arms the slot
#     from the hardware register; this script trusts the U-Boot env, which can
#     be stale after a BL1 fallback, and would arm the wrong slot.
#   axsyslogd / axklogd - BusyBox applets not present on this rootfs, and they
#     would log to the eMMC that volatile journald exists to protect.
#   sysdev.service - no such unit ships; sysdev.sh is now an idle loop.

# Jammy ships no `devmem`; fall back to busybox, then python3 on /dev/mem.
devmem() {
    local bin
    if bin=$(type -P devmem); then
        "$bin" "$@"
    elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx devmem; then
        busybox devmem "$@"
    elif [ "${2:-32}" = 32 ]; then
        python3 -I - "$1" ${3:+"$3"} <<'PY'
import mmap, os, sys
addr = int(sys.argv[1], 0)
page, off = addr & ~0xFFF, addr & 0xFFF
write = len(sys.argv) > 2
fd = os.open("/dev/mem", (os.O_RDWR if write else os.O_RDONLY) | os.O_SYNC)
m = mmap.mmap(fd, 4096, mmap.MAP_SHARED,
              mmap.PROT_READ | (mmap.PROT_WRITE if write else 0), offset=page)
words = memoryview(m).cast("I")
if write:
    words[off // 4] = int(sys.argv[2], 0) & 0xFFFFFFFF
else:
    print("0x%08X" % words[off // 4])
PY
    else
        echo "devmem: only 32-bit access is supported without a devmem binary" >&2
        return 1
    fi
}

# Skip a module that is already loaded, so a second run neither fails nor
# reloads it. Per module, so a half-loaded set is completed, not skipped.
insmod() {
    local name=${1##*/}
    name=${name%.ko}
    name=${name//-/_}
    if [ -d "/sys/module/$name" ]; then
        echo "insmod: $name already loaded, skipping"
        return 0
    fi
    "$(type -P insmod)" "$@"
}

# The vendor fw_printenv/fw_setenv need the bundled libubootenv in
# /opt/swupdate/lib, which is not on the Jammy loader path. Call them with it
# here instead of relying on /usr/bin: older images ship bare symlinks there,
# which device_repairs.sh only replaces later in boot (from kvmcomm.sh, after
# this unit), so S99checkota would fail on the first boot after an update.
uboot_tool() {
    local tool=$1 bin=/opt/swupdate/bin/$1
    shift
    [ -x "$bin" ] || bin=$(type -P "$tool") || return 127
    LD_LIBRARY_PATH="/opt/swupdate/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$bin" "$@"
}
fw_printenv() { uboot_tool fw_printenv "$@"; }
fw_setenv() { uboot_tool fw_setenv "$@"; }

# Exported so the vendor scripts below, run through bash, use them too.
export -f devmem insmod uboot_tool fw_printenv fw_setenv

# The vendor scripts use bash syntax behind #!/bin/sh, and /bin/sh is dash
# on Jammy, so every one of them is run through bash explicitly.
bash /etc/init.d/axemac.sh

bash /soc/scripts/auto_load_all_drv.sh

bash /soc/scripts/npu_set_bw_limiter.sh start

# Rotary encoder pinmux.
devmem 0x10030028 32 0x000006A0

bash /etc/init.d/S99checkota start

exit 0
