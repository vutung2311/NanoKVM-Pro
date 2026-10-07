---
name: nanokvm-kernel-workflow
description: >-
  Use this skill when building the Linux 4.19 kernel for AX630C, compiling out-of-tree
  drivers (AIC8800 WiFi, Axera multimedia modules), managing A/B boot slots, or deploying
  kernel updates over SSH. Triggers on "build kernel", "compile kernel", "flash kernel",
  "A/B slot", "bootsystem", "AIC8800", "WiFi driver", or "DTB".
---

# NanoKVM-Pro Kernel & Driver Workflow

This skill documents kernel compilation, driver integration, and safe deployment procedures for the Axera AX630C SoC running Linux 4.19.125.

## Quick Command Reference

```bash
# 1. Compile kernel, signed boot image, and DTB
bash support/scripts/build_kernel.sh build

# 2. Compile kernel and out-of-tree AIC8800 WiFi drivers
bash support/scripts/build_kernel.sh build-modules

# 3. Test kernel in RAM over SSH (non-destructive test boot)
bash support/scripts/build_kernel.sh test-ram <device-ip>

# 4. Flash kernel to alternate A/B partition over SSH
bash support/scripts/build_kernel.sh flash-slot <device-ip> B

# 5. Verify live device hardware and kernel status
bash support/scripts/build_kernel.sh verify <device-ip>
```

---

## Architecture & Boot Partitions

The AX630C eMMC layout uses dual A/B slots for fail-safe booting:

| Partition | Slot | Role |
| :--- | :--- | :--- |
| `/dev/mmcblk0p12` | Slot A | DTB A |
| `/dev/mmcblk0p13` | Slot B | DTB B (Safe staging slot) |
| `/dev/mmcblk0p14` | Slot A | Boot Kernel A |
| `/dev/mmcblk0p15` | Slot B | Boot Kernel B (Safe staging slot) |
| `/dev/mmcblk0p16` | Common | `ubuntu_rootfs.ext4` |

### Slot Switching Mechanism
To switch boot slots, U-Boot environment and hardware mailbox registers must both be set:
```bash
# Switch to Slot B:
devmem 0x239002C 32 0x80
devmem 0x239002C 32 0x14
devmem 0x2390028 32 0x28
fw_setenv bootsystem B

# Switch back to Slot A:
devmem 0x239002C 32 0x80
devmem 0x239002C 32 0x28
devmem 0x2390028 32 0x14
fw_setenv bootsystem A
```

---

## Out-of-Tree Drivers

1. **AIC8800 WiFi Drivers:**
   - Modules: `aic8800_bsp.ko`, `aic8800_fdrv.ko`, `aic8800_btlpm.ko`.
   - Firmware: `/opt/firmware/aic8800/` or `/lib/firmware/aic8800/`.
   - Modprobe config: `/etc/modprobe.d/aic8800.conf`.
2. **Axera Multimedia Acceleration Modules:**
   - Located in `/soc/ko/`: `ax_sys.ko`, `ax_venc.ko`, `ax_vo.ko`, `ax_cmm.ko`, `ax_ivps.ko`, `ax_pool.ko`.
   - Auto-loaded via `/soc/scripts/auto_load_all_drv.sh` during early system boot.

---

## Safe Kernel Testing Checklist
1. **Never overwrite Slot A directly:** Always stage and test in Slot B first.
2. **Verify MD5 checksums after dd:**
   ```bash
   dev_md5=$(head -c <kernel_size> /dev/mmcblk0p15 | md5sum | awk '{print $1}')
   ```
3. **Run `depmod -a <kver>`** whenever updating kernel modules to update module symbol maps.
