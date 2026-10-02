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
* `support/base_firmware/`: Pristine official stock firmware releases (`20260529_NanoKVMPro_1_0_15.axp`, stock `.deb` packages).
* `support/scripts/toolchain_setup.sh`: Downloads ARM64 GNU GCC toolchain (`aarch64-none-linux-gnu`) and libraries.
* `support/scripts/build_image/`: Scripts to expand rootfs, overlay custom binaries/configs, and pack final `.axp` images.

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
  * Updated [`usbdev.sh`](file:///home/tung/Git/nanokvm-pro/support/scripts/build_image/overlay/kvmapp/scripts/usbdev.sh) to configure `hid.GS2` (absolute mouse/touchpad) with `protocol 0` and `subclass 0` (non-boot generic pointer), resolving Linux host phantom joystick (`js0`) detection without disabling the interface.
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
  * Created overlay scripts in [`support/scripts/build_image/overlay/kvmcomm/scripts/`](file:///home/tung/Git/nanokvm-pro/support/scripts/build_image/overlay/kvmcomm/scripts/):
    * [`wifi.sh`](file:///home/tung/Git/nanokvm-pro/support/scripts/build_image/overlay/kvmcomm/scripts/wifi.sh): Preserves `/etc/kvm/wifi.conf` during normal disconnect/AP transitions, enhances `try_connect` and `check_previous_wifi` with persistent fallback (`/etc/kvm/wifi_save` and `wpa_supplicant`), and fixes `if_previous_wifi` / `try_previous_wifi` so volatile `/dev/shm` loss doesn't trigger unexpected QR-code AP mode on boot.
    * [`kvmcomm.sh`](file:///home/tung/Git/nanokvm-pro/support/scripts/build_image/overlay/kvmcomm/scripts/kvmcomm.sh): Automatically triggers background Wi-Fi auto-connect on boot if a network configuration is present.
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


