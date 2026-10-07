---
name: nanokvm-firmware-builder
description: >-
  Use this skill when building, customizing, or packaging NanoKVM-Pro firmware images,
  AXP archives, Debian packages (nanokvmpro, kvmcomm), and OTA update tarballs.
  Triggers on mentions of "build image", "build firmware", "build axp", "make deb",
  "build_image.py", "package_firmware.sh", or "update tarball".
---

# NanoKVM-Pro Firmware Builder Runbook

This skill outlines the exact workflow, requirements, and guardrails for producing production-ready NanoKVM-Pro firmware images and packages.

## Quick Command Reference

```bash
# 1. Compile backend & frontend
make build

# 2. Build Debian packages into build_dist/
make deb

# 3. Assemble complete AXP disk image from repository blobs
make build-axp

# 4. Convert AXP image to compressed raw image (.img.xz)
make image-img

# 5. Build web-uploadable update archive (.tar.gz)
make web-pkg
```

---

## 4 Critical Rules & Guardrails

### 1. UsrMerge Integrity Protection
* **Rule:** On Ubuntu 22.04+ rootfs, `/bin`, `/sbin`, and `/lib` **must remain symlinks** to `usr/bin`, `usr/sbin`, and `usr/lib`.
* **Hazard:** If an overlay tarball or rsync creates a real directory at `/bin` or `/lib`, `dpkg` and systemd will fail catastrophically.
* **Guardrail:** In `build_image.py`, always enforce the usrmerge link check before and after overlay operations:
  ```python
  for sym in ["lib", "bin", "sbin"]:
      if not os.path.islink(os.path.join(mount_point, sym)):
          raise RuntimeError(f"Usrmerge failure: /{sym} was replaced by a directory!")
  ```

### 2. Debian Package Postinst Requirement
* **Rule:** Daemon packages must manage systemd state cleanly in `DEBIAN/postinst` without blind `|| true` error-swallowing.
* **Required Pattern for `nanokvmpro/DEBIAN/postinst`:**
  ```bash
  ldconfig
  mkdir -p /etc/systemd/system/multi-user.target.wants
  [ -f /etc/systemd/system/nanokvm.service ] && ln -sf /etc/systemd/system/nanokvm.service /etc/systemd/system/multi-user.target.wants/nanokvm.service

  # Standard Debian policy: only invoke systemctl if systemd is active (PID 1)
  if [ -d /run/systemd/system ]; then
      systemctl daemon-reload
      if [ "$(stat -c %d:%i /)" == "$(stat -c %d:%i /proc/1/root/.)" ]; then
          systemctl restart nanokvm.service
      fi
  fi
  ```
* **Guardrail:** Never leave `DEBIAN/postinst` empty, and never run unguarded `systemctl` in chroot/build environments.

### 3. Package Truncation Prevention
* **Rule:** If a package build is interrupted, incomplete `.deb` files can break image assembly (`dpkg-deb: unexpected end of file`).
* **Validation:** Before invoking `build_image.py`, verify all debs:
  ```bash
  dpkg-deb -c build_dist/nanokvm_pro_1.2.15/*.deb >/dev/null
  ```

### 4. Boot-Time Service Un-Wanting (Nginx & Port 80/443 Collision)
* **Rule:** Services that conflict with NanoKVM (such as `nginx.service` and `kvmd-nginx.service`) must be unlinked from `multi-user.target.wants` at **image build time** in `build_image.py`.
* **Guardrail:** Never rely on runtime hooks like `systemctl disable --now nginx` inside `ExecStartPre`—this causes systemd reentrant D-Bus deadlocks.

### 5. Network Interface Cleanliness (No Static IP Fallback Pollution)
* **Rule:** Never inject hardcoded static fallback IPs (e.g. `192.168.100.200/24`) into `/etc/rc.local`.
* **Hazard:** If the board does not receive a DHCP offer on `eth0`, a hardcoded IP causes `kvm_ui` to display that IP on the touchscreen, misleading the user when they are connected via Wi-Fi or a different subnet. Let `/etc/network/interfaces` handle standard DHCP.

### 6. Boot Partition (bootfs.fat32) Composition
The 128MB FAT32 boot partition (`bootfs.fat32`) requires:
* `AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb`
* `boot_signed.bin` (Signed kernel Image)
* `u-boot_signed.bin`
* `configs` (boot config parameters, e.g. memory reservations)

---

## Image Customization Workflow

To replace kernel, DTB, or add system overlays into an existing AXP image:

```bash
pkexec python3 support/scripts/build_image/build_image.py \
    --blobs support/blobs \
    --app build_dist/nanokvm_pro_1.2.15 \
    --dtb <path/to/custom.dtb> \
    --boot <path/to/custom_boot_signed.bin> \
    -o build_dist/NanoKVMPro_Custom.axp
```
