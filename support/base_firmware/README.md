# Base Firmware Assets

This directory stores pristine, unmodified stock firmware artifacts for the Sipeed NanoKVM Pro.
These files serve as the clean base template for local builds, repackaging, and testing without mutating original stock releases.

## Artifacts Stored Here

1. **Base AXP Image (`20260529_NanoKVMPro_1_0_15.axp`):**
   * Official Sipeed eMMC/flashing base image (Axera AX630C Ubuntu 22.04 LTS rootfs).
   * Used by `support/scripts/build_image/build_image.py` to produce custom `.axp` and `.img.xz` disk images.
   * Source: `https://github.com/sipeed/NanoKVM-Pro/releases/download/v1.0.15/20260529_NanoKVMPro_1_0_15.axp`

2. **Base Application Package Archive (`nanokvm_pro_1.2.15.tar.gz`):**
   * Official application release archive containing stock `.deb` packages and manifest checksums.
   * Source: `https://github.com/sipeed/NanoKVM-Pro/releases/download/1.2.15/nanokvm_pro_1.2.15.tar.gz`

3. **Extracted Base Packages (`nanokvm_pro_1.2.15/`):**
   * `nanokvmpro_1.2.15_arm64.deb` (Pristine Go backend + web server package)
   * `kvmcomm_1.2.15_arm64.deb` (Pristine hardware communication and network daemon package)
   * `pikvm_1.2.15_arm64.deb` (PiKVM compatibility package)

## Automated Fetch

If these files are missing on a fresh clone, run:
```bash
make fetch-base
```
The Makefile will automatically download and unpack the official stock releases here.
During custom builds (`make deb`, `make release`), packages are staged into `build_dist/` so the files in this directory remain permanently untouched.
