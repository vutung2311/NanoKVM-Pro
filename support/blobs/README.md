# Silicon & Hardware Binary Blobs for NanoKVM Pro

This directory houses the proprietary hardware binaries, silicon bootloader components, and vendor libraries extracted from the base Axera/Sipeed stock firmware. Storing these blobs directly in the repository eliminates dependencies on external 1.4 GB firmware archive downloads, enabling fast, autonomous, and self-contained builds.

## Directory Structure

```
support/blobs/
├── bootloader/     # Axera AX630C SoC bootloader, SPL, DDR init, ATF, OP-TEE, U-Boot & partition XML
├── bootfs/         # FAT32 boot partition filesystem assets (config defaults & scripts)
├── packages/       # Upstream base Debian packages (nanokvmpro, kvmcomm, pikvm) for deb staging
└── rootfs/         # Axera BSP kernel modules (/soc), hardware libraries (/opt/lib), and Wi-Fi firmware
```

### 1. `bootloader/`
Low-level silicon and boot stage binaries executed before Linux kernel startup:
- `spl_AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.bin`: Secondary Program Loader (signed for AX630C).
- `ddrinit_AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.bin`: LPDDR4 timing initialization table.
- `eip_ax620e.bin`: Security engine / cryptographic accelerator firmware.
- `fdl_AX630C_...bin` / `fdl2_signed.bin`: Flash Downloader stages for eMMC flashing.
- `atf_bl31_signed.bin` / `atf_b_bl31_signed.bin`: ARM Trusted Firmware (BL31) Slots A & B.
- `optee_signed.bin` / `optee_signed.bin.1`: OP-TEE OS Trusted Execution Environment Slots A & B.
- `u-boot_signed.bin` / `u-boot_b_signed.bin`: Signed Das U-Boot 2020.04 binary Slots A & B.
- `axera_logo.bmp`: Boot splash screen image.
- `AX630C_emmc_arm64_k419_sipeed_nanokvm.xml`: Partition geometry and flash layout definition.
- `boot_signed.bin` / `AX630C_...signed.dtb`: Stock fallback kernel & device tree (used if custom kernel is not built).

### 2. `bootfs/`
Files placed into the `bootfs.fat32` FAT32 filesystem partition:
- `configs`: Hardware initialization options (HDMI, Wi-Fi mode, USB peripheral emulations).
- `ver`: Firmware version string identifier.
- `usb.ncm`: Default virtual USB networking flag.
- `check_resize2fs` / `first_time_boot`: First-boot rootfs expansion markers.

### 3. `packages/`
Upstream pristine base Debian packages and metadata manifests:
- `nanokvmpro_1.2.15_arm64.deb` / `kvmcomm_1.2.15_arm64.deb`: Reference base Debian packages. (Application packages are built directly from `support/packages/` by `make deb`).
- `pikvm_1.2.15_arm64.deb`: Optional PiKVM compatibility layer package.
- `*.json`: Upstream package manifests and hashes.

### 4. `rootfs/`
Proprietary BSP components injected into Ubuntu 22.04 rootfs:
- `soc/ko/`: Proprietary kernel drivers (`aic8800_*.ko`, `ax_sys.ko`, `ax_venc.ko`, `hynitron_touch.ko`).
- `soc/scripts/`: Driver auto-loading scripts (`auto_load_all_drv.sh`, `npu_set_bw_limiter.sh`).
- `opt/lib/`: Hardware video encoding, decoding, and IVPS pipeline shared objects (`libax_venc.so`, `libax_sys.so`, etc.).
- `opt/firmware/aic8800/`: AIC8800 Wi-Fi and Bluetooth firmware binaries.
- `opt/scripts/`: Board maintenance scripts (`update_bl1.sh`, `sysdev.sh`).
- `etc/rc.local` & `etc/init.d/`: Axera boot hardware initialization hooks.
- `etc/ld.so.conf.d/00-axera.conf`: Dynamic linker configuration indexing `/opt/lib` and `/kvmapp/server/dl_lib`.
- `etc/tmpfiles.d/sshd.conf`: In-RAM tmpfs rule (`d /run/sshd 0755 root root -`) ensuring OpenSSH starts cleanly on-demand without exit code 255.
- `etc/systemd/system/ssh.service.d/override.conf`: OpenSSH systemd drop-in override guaranteeing `/run/sshd` privilege separation directory creation.

