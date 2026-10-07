# NanoKVM Pro Custom Firmware & Optimization Quest

## Hardware & Architecture Specs
* **Device:** Sipeed NanoKVM Pro (Desk / ATX)
* **SoC:** Axera AX630C (Dual-core ARM Cortex-A53 @ 1.2 GHz)
* **RAM / Storage:** 1GB LPDDR4, 32GB eMMC
* **Base OS:** Ubuntu 22.04 LTS ARM64 (ext4 rootfs inside `.axp` image container)
* **Video Pipeline:** Axera MSP hardware video encoder (H.264/H.265/MJPEG up to 4K30 / 2K60)
* **USB HID:** Linux ConfigFS USB Gadget (`/sys/kernel/config/usb_gadget/g0/UDC`) via `/kvmapp/scripts/usbdev.sh`

---

## Known Stock Inefficiencies & Targets for Improvement

1. **Aggressive USB UDC Resets (`server/service/hid/hid.go`):**
   * The Go backend sets an 8ms deadline on `/dev/hidg0-2` writes.
   * On write errors or buffer overflows, it triggers `usbdev.sh restart`, which unbinds the hardware UDC.
   * **Target:** Implement non-blocking ring buffers with dropped frame coalescing instead of resetting the USB controller.

2. **Composite Gadget Descriptors & Phantom Joystick (`js0`):**
   * Exposing absolute pointer coordinates (`HID2`) without proper usage descriptors causes Linux to identify it as a gamepad.
   * **Target:** Patch the HID report descriptor or provide a streamlined, pure Keyboard + Relative Mouse profile.

3. **Background Daemon Bloat:**
   * Stock backend runs mouse jiggler (`jiggler.GetJiggler().Run()`), OCR hooks, speedtest routines, and storage daemons in the background.
   * **Target:** Make all non-core services opt-in or eliminate them for a high-efficiency KVM core.

4. **Stream & WebUI Latency:**
   * Optimize WebRTC / WebSocket frame delivery pipeline and strip frontend bloat.

---

## Workspace Structure

* `server/`: Go backend (`main.go`, Gin HTTP/WS server, HID, ATX power, streaming).
* `web/`: React + Vite + TypeScript frontend.
* `support/packages/`: Upstream and custom Debian package source trees (`nanokvmpro`, `kvmcomm`) built via `dpkg-deb`.
* `support/blobs/`: Extracted silicon binaries, bootloader stages, bootfs assets, and Axera hardware drivers.
* `support/base_firmware/`: Pristine official stock firmware releases (`20260529_NanoKVMPro_1_0_15.axp`, stock `.deb` packages).
* `support/scripts/toolchain_setup.sh`: Downloads ARM64 GNU GCC toolchain (`aarch64-none-linux-gnu`) and libraries.
* `support/scripts/build_image/`: Scripts to expand rootfs, overlay custom binaries/configs, and pack final `.axp` images.
* `.agents/`: Repository skills and architectural rules for agentic workflows and automated smoke testing.


---

## Action Plan & Completion Status

- [x] **Step 1: Setup Toolchain:** Run `support/scripts/toolchain_setup.sh` to install `aarch64-none-linux-gnu-gcc`.
- [x] **Step 2: Build Verification:** Compile `server` (Go) and `web` (pnpm/vite) locally.
- [x] **Step 3: Fix Spontaneous USB Disconnects & Stalls:**
  * Implemented non-blocking relative mouse delta chunking with zero motion loss and transition duplicate report prevention in [`mouse.go`](file:///home/tung/Git/nanokvm-pro/server/service/hid/mouse.go).
  * Added bounded-timeout queue writes for keyboard events in [`client.go`](file:///home/tung/Git/nanokvm-pro/server/service/ws/client.go) to prevent stuck keys on saturated channels.
  * Hardened [`hid.go`](file:///home/tung/Git/nanokvm-pro/server/service/hid/hid.go) with automatic descriptor recovery on fatal driver errors/UDC rebinds.
  * Added unit tests in [`mouse_test.go`](file:///home/tung/Git/nanokvm-pro/server/service/hid/mouse_test.go).
- [x] **Step 4: Fix Phantom Joystick (`js0`) & Restore Absolute Mouse:**
  * Updated [`usbdev.sh`](file:///home/tung/Git/nanokvm-pro/support/packages/nanokvmpro/kvmapp/scripts/usbdev.sh) to configure `hid.GS2` (absolute mouse/touchpad) with `protocol 0` and `subclass 0` (non-boot generic pointer), resolving Linux host phantom joystick (`js0`) detection without disabling the interface.
  * Ensured `/dev/hidg2` is created and enabled by default (with opt-out via `/boot/usb.no_touchpad`) so that the default Absolute Mouse mode in the WebUI operates out of the box.
  * Added requestAnimationFrame throttling to absolute mouse in [`absolute.tsx`](file:///home/tung/Git/nanokvm-pro/web/src/pages/desktop/mouse/absolute.tsx) and preserved scroll wheel deltas across coalesced events in [`mouse.go`](file:///home/tung/Git/nanokvm-pro/server/service/hid/mouse.go).
- [x] **Step 5: On-Demand Services & Optimization:**
  * Maintained Mouse Jiggler feature with persistence via `/etc/kvm/mouse-jiggler`, executing conditionally with zero idle overhead when toggled off.
  * Configured Computer Use Agent (CUA / OCR) for on-demand activation on first use (spawns via WebUI API `/api/extensions/assistant/start` and auto-terminates on tab close), saving ~200MB RAM at boot.
- [x] **Step 6: Full Image Build (`.axp` and `.img.xz`):**
  * Built complete production images located in [`build_dist/`](file:///home/tung/Git/nanokvm-pro/build_dist/):
    * `NanoKVMPro_Custom_1_2_15.axp` (1.5 GB) - Flashable via Sipeed AXDL tool.
    * `NanoKVMPro_Custom_1_2_15.img.xz` (720 MB) - Raw disk image flashable to eMMC or SD card.
- [x] **Step 7: Fix Wi-Fi Auto-Restore After Power Loss (Issue #144):**
  * Created package scripts in [`support/packages/kvmcomm/kvmcomm/scripts/`](file:///home/tung/Git/nanokvm-pro/support/packages/kvmcomm/kvmcomm/scripts/):
    * [`wifi.sh`](file:///home/tung/Git/nanokvm-pro/support/packages/kvmcomm/kvmcomm/scripts/wifi.sh): Preserves `/etc/kvm/wifi.conf` during normal disconnect/AP transitions, enhances `try_connect` and `check_previous_wifi` with persistent fallback (`/etc/kvm/wifi_save` and `wpa_supplicant`), and fixes `if_previous_wifi` / `try_previous_wifi` so volatile `/dev/shm` loss doesn't trigger unexpected QR-code AP mode on boot.
    * [`kvmcomm.sh`](file:///home/tung/Git/nanokvm-pro/support/packages/kvmcomm/kvmcomm/scripts/kvmcomm.sh): Automatically triggers background Wi-Fi auto-connect on boot if a network configuration is present.
  * Hardened [`wifi.go`](file:///home/tung/Git/nanokvm-pro/server/service/network/wifi.go) `isAPMode()` to ensure active STA connections are never misclassified as AP mode.
- [x] **Step 8: Pristine Base Firmware Archiving:**
  * Stored untouched base firmware releases inside [`support/base_firmware/`](file:///home/tung/Git/nanokvm-pro/support/base_firmware/):
    * `20260529_NanoKVMPro_1_0_15.axp` (1.4 GB base image container).
    * `nanokvm_pro_1.2.15.tar.gz` and extracted stock Debian packages (`nanokvmpro`, `kvmcomm`, `pikvm`).
  * Updated [`Makefile`](file:///home/tung/Git/nanokvm-pro/Makefile) to keep base packages strictly read-only and staged into `build_dist/` on build.
- [x] **Step 9: Upstream Synchronization & Rebase Automation:**
  * Added `make check-upstream` to inspect new commits in `sipeed/NanoKVM-Pro:main` without modifying the workspace.
  * Added `make rebase-upstream` (alias: `make sync-upstream`) to cleanly replay custom commits on top of latest upstream releases with pre-flight working tree validation and conflict guidance.
- [x] **Step 10: Mouse Pipeline Hardening & Host Test Decoupling:**
  * Decoupled CGO hardware video encoder dependencies with build tags (`common/kvm_vision.go` vs `common/kvm_vision_stub.go`) so `go test ./...` passes natively on host dev machines.
  * Hardened mouse WebSocket ingress in [`client.go`](file:///home/tung/Git/nanokvm-pro/server/service/ws/client.go) with bounded timeouts to prevent click/release drop during transient USB write saturation.
  * Added off-canvas window drag release synchronization in [`absolute.tsx`](file:///home/tung/Git/nanokvm-pro/web/src/pages/desktop/mouse/absolute.tsx) to flush pending rAF moves and emit `mouseup` at exact coordinates.
  * Expanded [`mouse_test.go`](file:///home/tung/Git/nanokvm-pro/server/service/hid/mouse_test.go) with tests for consecutive wheel events, burst coordinate convergence, and invalid event handling.
- [x] **Step 11: Multi-Distribution Tooling Installation & Robust Build Pipeline:**
  * Created [`support/scripts/setup_tooling.sh`](file:///home/tung/Git/NanoKVM-Pro/support/scripts/setup_tooling.sh) with automatic Linux distribution detection (Arch/CachyOS `pacman`, Ubuntu/Debian `apt`, Fedora `dnf`) and elevated package installation (`dpkg-deb`, `pnpm`, `qemu-user-static`, `android-tools`, etc.) via `pkexec`.
  * Added Python virtual environment provisioning (`support/scripts/build_image/.venv`) for `axp-tools` (`axp2img`) and `tqdm`, respecting PEP 668 on modern Linux distributions (Arch/CachyOS Python 3.14).
  * Refactored [`support/scripts/toolchain_setup.sh`](file:///home/tung/Git/NanoKVM-Pro/support/scripts/toolchain_setup.sh) to be completely path-agnostic (executable from any directory), support non-interactive execution (`--non-interactive`, `--check`, `--reinstall`), cache existing ARM64 sysroot libraries, and clarify target sysroot libraries vs host tools.
  * Hardened [`support/scripts/build_image/build_image.py`](file:///home/tung/Git/NanoKVM-Pro/support/scripts/build_image/build_image.py) with dynamic QEMU static emulator discovery (`find_qemu_static`), dereferencing and loopback filtering in chroot `/etc/resolv.conf`, and safe fallback for `tqdm`.
  * Enhanced [`Makefile`](file:///home/tung/Git/NanoKVM-Pro/Makefile) with `make check-tools` pre-flight diagnostic validator, `make setup-tooling` single-command environment bootstrapping, and automatic cross-toolchain triggers.
- [x] **Step 12: Standalone Kernel Build, Axera Signing & kexec Live Pipeline:**
  * Engineered standalone kernel build pipeline in [`support/scripts/build_kernel.sh`](file:///home/tung/Git/NanoKVM-Pro/support/scripts/build_kernel.sh) without requiring cumbersome full-SDK rebuilds.
  * Configured official Axera Linux `4.19.125` tree with `axera_AX630C_emmc_arm64_k419_sipeed_nanokvm_defconfig` and board device tree `AX630C_emmc_arm64_k419_sipeed_nanokvm.dts`.
  * Extracted stock recovery/initialization CPIO archive (`initramfs_rootfs.cpio`) to preserve early USB gadget MSC recovery, MAC address generation, and e2fsck repair.
  * Integrated statically linked `ax_gzip` compression utility and RSA-2048 header signing (`sec_boot_AX620E_sign.py`) to generate authentic Axera boot containers ([`boot_signed.bin`](file:///home/tung/Git/NanoKVM-Pro/build_dist/boot_signed.bin) with magic `0x55543322` and cap `0x0054fafe`).
  * Added Makefile targets: `make kernel` (build + sign), `make kernel-menuconfig` (interactive configuration), `make kernel-test IP=<device-ip>` (or `make test-kernel`, `make kernel-kexec` for zero-flash volatile testing in RAM with SSH reboot polling), `make kernel-setup`, and `make kernel-clean`.
  * Integrated custom kernel artifacts into [`make image-axp`](file:///home/tung/Git/NanoKVM-Pro/Makefile), automatically embedding custom `boot_signed.bin` and DTB into `.axp` and `.img.xz` releases when present.
- [x] **Step 13: Kernel Verification, Watchdog Disarm & Dual-Slot A/B Testing:**
  * **Factory Kernel Byte Comparison:** Decompressed and compared official stock `.axp` kernel vs custom build: verified 100% identical `.config` (IKCONFIG), byte-for-byte matching `initramfs_rootfs.cpio` (MD5 `7c49edc835843afe5a20102ca22c009f`), and 100% byte-for-byte identical compiled device tree binary ([`AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb`](file:///home/tung/Git/NanoKVM-Pro/support/kernel/AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb)).
  * **Watchdog Shutdown Hook:** Added `ax_wdt_drv_shutdown()` in [`drivers/watchdog/ax_wdt.c`](file:///home/tung/Git/NanoKVM-Pro/support/kernel/linux/linux-4.19.125/drivers/watchdog/ax_wdt.c) to cleanly disarm hardware watchdog timer `wdt0` and gate clocks during `device_shutdown()`, preventing watchdog expirations during warm jumps/reboots.
  * **Discovered Hardware A/B Switching Mechanism:** Identified that ROM/BL1 (SPL) checks persistent SoC hardware register `TOP_CHIPMODE_GLB_BACKUP0` (`0x2390024`):
    * `SLOTA = BIT(2) (0x04)`, `SLOTA_BOOTABLE = BIT(4) (0x10)` -> `0x14`
    * `SLOTB = BIT(3) (0x08)`, `SLOTB_BOOTABLE = BIT(5) (0x20)` -> `0x28`
    * If `SLOTB_BOOTABLE` is not asserted, BL1 automatically clears `SLOTB`, warns `"try slot A"`, and falls back to Slot A (`0x14`), providing a hardware-level safety net.
  * **Automated Tooling:** Added `flash-slot-b <IP>` and `boot-slot <A|B> <IP>` commands to [`build_kernel.sh`](file:///home/tung/Git/NanoKVM-Pro/support/scripts/build_kernel.sh) and Makefile targets `make kernel-flash-b` and `make kernel-boot-a` / `make kernel-boot-b`.
- [x] **Step 14: Linux 4.19.325 Rebase, BL1 Token Architecture & Stable 1440p Capture:**
  * **Linux 4.19.325 Rebase:** Successfully ported Axera AX630C MSP, NPU, VIN/VO, and peripheral drivers onto stable LTS `4.19.325` (`rebase-4.19.325-v2`), compiling and packaging into signed container `boot_signed.bin` (#15).
  * **BL1 One-Shot Token & Fallback Demystified:** Traced Axera SPL (`meta/boot/bl1/core/boot/boot.c`) arbitration logic: BL1 consumes the `SLOTB_BOOTABLE` bit (0x20) immediately upon booting Slot B. If userspace does not re-assert it (`0x2390028=0x20`), subsequent boots automatically fall back to Golden Slot A (`0x14`). Hardened [`build_kernel.sh`](file:///home/tung/Git/NanoKVM-Pro/support/scripts/build_kernel.sh) to explicitly clear `BOOT_KERNEL_FAIL` (`0x80`) and stale slot bits before arming.
  * **Hardware Register Reference Table:**
    | Register | Address | Function |
    | :--- | :--- | :--- |
    | `TOP_CHIPMODE_GLB_BACKUP0` | `0x2390024` | Status Readback |
    | `TOP_CHIPMODE_GLB_BACKUP0_SET` | `0x2390028` | Write-1-to-set |
    | `TOP_CHIPMODE_GLB_BACKUP0_CLR` | `0x239002C` | Write-1-to-clear |
    * Bits: `SLOTA=BIT(2) (0x04)`, `SLOTB=BIT(3) (0x08)`, `SLOTA_BOOTABLE=BIT(4) (0x10)`, `SLOTB_BOOTABLE=BIT(5) (0x20)`, `BOOT_KERNEL_FAIL=BIT(7) (0x80)`.
    * Arm Slot B: `devmem 0x239002C 32 0x80 && devmem 0x239002C 32 0x14 && devmem 0x2390028 32 0x28 && fw_setenv bootsystem B`
    * Arm Slot A: `devmem 0x239002C 32 0x80 && devmem 0x239002C 32 0x28 && devmem 0x2390028 32 0x14 && fw_setenv bootsystem A`
  * **LT6911D Driver Stabilization:**
    - Eliminated recursive 1,400 calls/sec I2C bus storms by removing recursive worker scheduling from `proc_hdmi_status_read()`.
    - Protected internal SPI flash by returning static Desk-G identity (`NebE20020`) and serving cached EDID from RAM, preventing bus lockups during warm resets.
    - Extended HPD power-cycle timing in driver init to cleanly signal connected host GPUs.
  * **Live Verification in Slot B:**
    - Active Kernel: `Linux kvm-b9c7 4.19.325 #15` (`0x2390024=0x28`, `bootsystem=B`).
    - Video Capture: `2560x1440 @ 59 FPS`, status `stable`.
    - Hardware Interrupts: `ax_proton_intt` firing actively at 60 FPS (`+122` int/s).
    - WebUI API & Stream: `/api/vm/info` reports `pn: "NebE20020\n"`, and `/api/stream/mjpeg` streams full 157 KB JPEG frames.
    - Slot A Failsafe: Golden kernel on `/dev/mmcblk0p14` and DTB on `/dev/mmcblk0p12` remain 100% untouched.
  * **Fast Module Reload Pipeline (Zero Reflashing):**
    ```bash
    # 1. Compile module (~3s)
    make -C support/kernel/linux/linux-4.19.125 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M=drivers/misc modules
    # 2. Deploy & reload live (~3s)
    scp support/kernel/linux/linux-4.19.125/drivers/misc/lt6911_manage.ko root@<IP>:/kvmcomm/ko_4.19.325/
    ssh root@<IP> "systemctl stop kvmcomm && rmmod lt6911_manage && insmod /kvmcomm/ko_4.19.325/lt6911_manage.ko && systemctl start kvmcomm"
    ```
- [x] **Step 15: End-to-End In-System Firmware Update Packaging (`make firmware-pkg` & `make firmware-flash`):**
  * **Unified Recompile & Packaging Recipe:** Added [`support/scripts/package_firmware.sh`](file:///home/tung/Git/NanoKVM-Pro/support/scripts/package_firmware.sh) and Makefile targets `make firmware-pkg` (alias: `make update-pkg`) and `make firmware-flash IP=<ip>` (alias: `make update-flash`).
  * **End-to-End Build Automation:** Runs full recompile of server, web frontend (Vite), Debian packages (`nanokvmpro` & `kvmcomm`), and Linux kernel & modules, then stages signed boot binaries (`boot_signed.bin`, DTB, `u-boot_signed.bin`), rootfs overlay, and version metadata.
  * **Native Updater Compatibility:** Generates deterministic `b2sum.txt` manifest and parallel XZ compressed `build_dist/axera_firmware_v<VERSION>.tar.xz`, 100% compatible with NanoKVM WebUI manual update and `/kvmcomm/scripts/firmware_update.sh`.
  * **Safe Live Flashing:** `make firmware-flash IP=<ip>` runs pre-flight diagnostics, verifies Slot A failsafe integrity, uploads the package, triggers native partition flashing (`axkernel.sh`, `axdtb.sh`, `axuboot.sh`), and reboots.
- [x] **Step 16: Rootfs Lifecycle Verification & Boot Service Startup Fixes:**
  * **OpenSSH On-Demand Startup Fix:** Resolved `sshd -t` exit code 255 (`Missing privilege separation directory: /run/sshd`) caused by `/run` being mounted as an in-RAM `tmpfs` upon system boot. Added `/etc/tmpfiles.d/sshd.conf` (`d /run/sshd 0755 root root -`) to `support/blobs/rootfs` and `support/packages/kvmcomm/kvmcomm/overlay/` and systemd drop-in override `/etc/systemd/system/ssh.service.d/override.conf` (`RuntimeDirectory=sshd` and `ExecStartPre=/bin/mkdir -p -m 0755 /run/sshd`), ensuring on-demand SSH activation succeeds without error while preserving intentional out-of-the-box disabled state in `build_image.py`.
  * **NanoKVM HTTP/HTTPS Service Auto-Enablement:** Fixed empty `support/packages/nanokvmpro/DEBIAN/postinst` by executing `systemctl daemon-reload` and `systemctl enable nanokvm.service`, ensuring `nanokvm.service` is actively linked into `/etc/systemd/system/multi-user.target.wants/`.
  * **Pre-bundled Default SSL Certificates:** Bundled default 10-year self-signed certificates in `/etc/kvm/server.crt` and `server.key` (with permissions `0600`/`0644`) to eliminate 10-15s RSA key generation CPU delays and startup races during initial boot.
  * **Axera Shared Library Resolution:** Added `/etc/ld.so.conf.d/00-axera.conf` registering `/opt/lib` and `/kvmapp/server/dl_lib` for system-wide dynamic linking.
  * **Automated Rootfs Verification Runner (`make verify-rootfs`):** Created [`.agents/skills/nanokvm-rootfs-verification/scripts/verify_rootfs.py`](file:///home/tung/Git/nanokvm-pro/.agents/skills/nanokvm-rootfs-verification/scripts/verify_rootfs.py) using loop+overlayfs to smoke-test OpenSSH, systemd boot links, and daemon execution inside QEMU ARM64 prior to flashing hardware.
  * **Skill Codification:** Codified all repository operational knowledge under `.agents/skills/` (`nanokvm-rootfs-verification`, `nanokvm-firmware-builder`, `nanokvm-kernel-workflow`, `nanokvm-service-integration`) and `.agents/rules/nanokvm-rules.md`.
