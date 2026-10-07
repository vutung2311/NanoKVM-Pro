---
name: nanokvm-service-integration
description: >-
  Use this skill when modifying, debugging, or switching between NanoKVM and PiKVM services,
  configuring USB Gadget HID emulation, managing SSL certificates, or troubleshooting
  kvmcomm.service. Triggers on "switch to pikvm", "nanokvm vs pikvm", "kvmcomm", "usbdev.sh",
  "hid keyboard", "hid mouse", "server.yaml", "ssl certs", or "atx power".
---

# NanoKVM-Pro Service Integration & Runtime Architecture

This skill documents runtime service management, dual KVM daemon architectures, USB gadget emulation, and SSL certificate sharing.

## Runtime Architecture Overview

The system supports two independent KVM server implementations managed by a single supervisor (`kvmcomm.service`):

```text
                  +-----------------------------------+
                  |         kvmcomm.service           |
                  |     (/kvmcomm/scripts/kvmcomm.sh) |
                  +-----------------+-----------------+
                                    |
                    Reads /etc/kvm/server.txt
                   /                         \
         "nanokvm"                             "pikvm"
            |                                     |
+-----------v-----------+             +-----------v-----------+
|    nanokvm.service    |             |     kvmd.service      |
|  - NanoKVM-Server     |             |  - kvmd (Python)      |
|  - HTTP: 80           |             |  - ustreamer          |
|  - HTTPS: 443         |             |  - janus gateway      |
|  - Web UI (Vite)      |             |  - nginx (HTTPS: 443) |
|  - usbdev.sh (HID)    |             |  - kvmd-otg (HID)     |
+-----------------------+             +-----------------------+
```

---

## Switching Between NanoKVM and PiKVM

1. **State File:** `/etc/kvm/server.txt` contains either `nanokvm` (default) or `pikvm`.
2. **Switching Command:**
   ```bash
   # Switch to PiKVM:
   echo "pikvm" > /etc/kvm/server.txt && sync && reboot

   # Switch to NanoKVM:
   echo "nanokvm" > /etc/kvm/server.txt && sync && reboot
   ```
3. **Supervisor Behavior (`kvmcomm.sh`):**
   - If `nanokvm`: Starts `nanokvm.service` via systemctl.
   - If `pikvm`: Executes `/etc/kvmd/scripts/pikvm_init.sh` (if first run), creates `/usr/lib/tmpfiles.d/kvmd.conf`, and starts `kvmd-nginx.service` and `kvmd.service`.

---

## Critical Startup Hazards & Architecture Rules

### 1. The Reentrant Systemd Deadlock Trap (`ExecStartPre`)
* **Hazard:** Never invoke `systemctl` (`disable`, `stop`, `start`) inside an `ExecStartPre` script (such as `nanokvm_pre.sh`).
* **Mechanism:** Systemd synchronously waits for `ExecStartPre` to finish before proceeding. If `ExecStartPre` executes `systemctl disable --now ...`, `systemctl` sends a synchronous D-Bus request back to systemd's job queue. This results in a reentrant deadlock until systemd aborts with:
  ```text
  systemd[1]: nanokvm.service: start-pre operation timed out. Terminating.
  systemd[1]: nanokvm.service: Failed with result 'timeout'.
  ```
* **Rule:** Pre-disable, mask, or un-want services at **image build time** in `build_image.py`. `ExecStartPre` must only perform instant filesystem setup (`mkdir`, symlinks).

### 2. Touchscreen UI (`kvm_ui`) Local REST API Dependency
* **Architecture:** The touchscreen UI binary (`/kvmcomm/ui/kvm_ui`) **does not run system commands directly** to toggle features (e.g. "Enable SSH").
* **Mechanism:** Tapping "Enable SSH" sends an internal HTTP POST to `https://127.0.0.1/api/vm/ssh` serviced by `NanoKVM-Server`.
* **Failure Cascade:** If `NanoKVM-Server` is down or deadlocked, the touchscreen UI gets connection refused on `127.0.0.1`, causing buttons like "Enable SSH" to silently fail without errors shown on screen.

### 3. Nginx vs. NanoKVM Port 80/443 Coordination
* **NanoKVM:** Directly binds to port 80 (HTTP redirect) and port 443 (HTTPS Web UI).
* **PiKVM:** Reverse-proxies through `kvmd-nginx` / `nginx`.
* **Coordination Pattern:** `nginx.service` and `kvmd-nginx.service` must be removed from `multi-user.target.wants` at build time. When the user switches to PiKVM, `kvmcomm.sh` explicitly starts `kvmd-nginx.service`. Never disable nginx dynamically in `nanokvm_pre.sh`.

---

## SSL Certificate Architecture

Both NanoKVM and PiKVM share the same SSL certificates located in `/etc/kvm/`:
* `/etc/kvm/server.crt` (Permissions: `0644`)
* `/etc/kvm/server.key` (Permissions: `0600`)

### Pre-bundling Requirement
* Default self-signed certificates must be pre-packaged in `support/packages/nanokvmpro/etc/kvm/`.
* **Hazard:** Generating RSA 2048-bit keys on AX630C takes 10-15 seconds of 100% CPU. If certs are missing at boot, `NanoKVM-Server` will race and fail with `HTTPS server failed: open /etc/kvm/server.crt: no such file or directory`.
* When PiKVM initializes, `pikvm_init.sh` symlinks `/etc/kvm/server.*` directly into `/etc/kvmd/nginx/ssl/`.

---

## USB Gadget Emulation (`usbdev.sh`)

USB device emulation is handled via Linux ConfigFS (`/sys/kernel/config/usb_gadget/g1`):
* **HID Keyboard:** Standard 8-byte HID reports.
* **HID Mouse:** Dual mode support:
  - Absolute mouse (tablet mode for KVM console pointer sync).
  - Relative mouse (fallback for legacy OSes / BIOS).
* **Mass Storage:** Virtual USB flash drive / ISO mounting.
* **Virtual Network:** RNDIS or CDC-NCM Ethernet over USB.

Control commands:
```bash
/kvmapp/scripts/usbdev.sh start     # Start full gadget stack
/kvmapp/scripts/usbdev.sh stop      # Unbind and clean up gadget
/kvmapp/scripts/usbdev.sh restart   # Restart USB stack
/kvmapp/scripts/usbdev.sh hid-only  # Restrict to keyboard/mouse
```
