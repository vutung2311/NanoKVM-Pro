---
name: nanokvm-rootfs-verification
description: >-
  Use this skill to audit, smoke-test, and verify the NanoKVM-Pro root filesystem,
  systemd service targets, tmpfs /run boot traps, package integrity, and OpenSSH/HTTP
  startup before flashing images to hardware.
---

# NanoKVM-Pro Rootfs & Service Verification

This runbook codifies critical lessons learned from debugging boot, service, and networking failures on the NanoKVM Pro (AX630C ARM64 SoC).

## The Core Rule: Build != Boot

A successful compiler run (`go build`, `npm run build`), deb build (`dpkg-deb`), or image creation (`build_image.py`) **only proves artifact creation**, not that the system will boot and services will start.

Always run rootfs lifecycle audits before flashing to hardware.

---

## 4 Critical Verification Traps

### 1. The `tmpfs /run` State Trap (OpenSSH & PiKVM)
* **Trap:** When Linux boots, systemd mounts an empty in-memory `tmpfs` over `/run`. Any static directory created in `/run` on disk (e.g. `/run/sshd` or `/run/kvmd`) **disappears on boot**.
* **Failure Mode:** If `/run/sshd` is missing, `sshd -t` fails with exit code `255`. In `/lib/systemd/system/ssh.service`, `RestartPreventExitStatus=255` locks OpenSSH permanently into a `failed` state.
* **Mandatory Safeguards:**
  1. `/etc/tmpfiles.d/sshd.conf`: Contains `d /run/sshd 0755 root root -`.
  2. `/etc/systemd/system/ssh.service.d/override.conf`: Contains `RuntimeDirectory=sshd` and `ExecStartPre=/bin/mkdir -p -m 0755 /run/sshd`.
  3. Early boot scripts (`nanokvm_pre.sh`): Run `mkdir -p -m 0755 /run/sshd`.

### 2. The Packaging Postinst Trap (`nanokvm.service`)
* **Trap:** `dpkg-deb` builds packages without verifying runtime behavior. An empty `DEBIAN/postinst` results in a valid `.deb` where services are never enabled in systemd.
* **Verification:** Always inspect `/etc/systemd/system/multi-user.target.wants/` in the target rootfs:
  ```bash
  ls -la <mount_point>/etc/systemd/system/multi-user.target.wants/ | grep nanokvm.service
  ```
  If `nanokvm.service` is not linked, HTTP/HTTPS connection will be refused on boot.

### 3. Shared Library Path Resolution (`/opt/lib`)
* **Trap:** Proprietary Axera multimedia acceleration libraries (`libax_sys.so`, `libax_venc.so`, etc.) live in `/opt/lib`. Server libraries live in `/kvmapp/server/dl_lib`.
* **Mandatory Safeguard:** Ensure `/etc/ld.so.conf.d/00-axera.conf` contains:
  ```text
  /opt/lib
  /kvmapp/server/dl_lib
  ```
  and `ldconfig` is run during rootfs assembly and `postinst`.

### 4. Deb Archive Truncation Check
* **Trap:** If a build script is cancelled or interrupted mid-write, `.deb` files in `build_dist/` or `/root/.kvmcache/` can become truncated (e.g. 2KB). `build_image.py` running `dpkg -i` will fail during image assembly.
* **Verification:** Run `dpkg-deb -c <pkg.deb> >/dev/null` on all packages before staging.

### 5. The Systemd Reentrant Deadlock Trap (`ExecStartPre`)
* **Trap:** Calling `systemctl` (`disable`, `stop`, `start`) inside an `ExecStartPre` script (e.g. `nanokvm_pre.sh`) deadlocks systemd's D-Bus queue. Systemd waits for `ExecStartPre` to finish, while `systemctl` waits for systemd to handle the job.
* **Failure Mode:** Systemd kills the service after 90 seconds (`start-pre operation timed out. Terminating.`). `NanoKVM-Server` never starts, and the touchscreen UI cannot talk to `https://127.0.0.1/api/`.
* **Safeguard:** `nanokvm_pre.sh` must never call `systemctl`. Disable conflicting services (`nginx`) at build time.

### 6. The `|| true` Blindness & Bogus Static IP Trap
* **Trap:** Blindly appending `|| true` to build scripts swallows fatal certificate generation failures or chroot command errors.
* **Bogus IP Trap:** Injecting `ip addr add 192.168.100.200/24 dev eth0` into `/etc/rc.local` causes `kvm_ui` to display `192.168.100.200` on the touchscreen whenever Ethernet lacks DHCP, isolating the board from local Wi-Fi subnets (`192.168.88.x`).
* **Safeguard:** Never inject static IPs into `rc.local`. Let `/etc/network/interfaces` handle DHCP cleanly.

---

## Automated Smoke-Test Runner

Run the automated verification script on any rootfs image (`ubuntu_rootfs.ext4`):

```bash
pkexec python3 .agents/skills/nanokvm-rootfs-verification/scripts/verify_rootfs.py [path-to-rootfs.ext4]
```

This 14-point audit:
1. Mounts the image via loop + copy-on-write overlayfs (never modifies original image).
2. Simulates boot with `/run` as an empty `tmpfs`.
3. Verifies `nanokvm.service` and `kvmcomm.service` are linked in `multi-user.target.wants`.
4. Verifies `ssh.service` and `usb-gadget.service` units are available for on-demand UI start.
5. Verifies `sshd` tmpfiles rules and systemd override exist, and `sshd -t` passes with exit code 0.
6. Verifies `/etc/ld.so.conf.d/00-axera.conf` exists and contains `/opt/lib`.
7. Verifies `/etc/kvm/server.crt` and `server.key` exist and match.
8. Verifies `nginx.service` is NOT enabled in boot targets (avoids port 80/443 collision).
9. Verifies bogus `192.168.100.200` static fallback IP is absent from `/etc/rc.local`.
10. Executes `NanoKVM-Server` in ARM64 QEMU chroot to confirm port binding without missing library crashes.
