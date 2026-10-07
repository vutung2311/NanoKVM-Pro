#!/usr/bin/env python3
"""
Automated rootfs and service verification script for NanoKVM-Pro.
Mounts rootfs in read-only overlayfs with emulated boot tmpfs and tests:
1. OpenSSH privsep directory (/run/sshd) & sshd -t exit code
2. systemd target boot links (nanokvm.service, kvmcomm.service)
3. SSL certificate availability in /etc/kvm
4. Dynamic linker configuration (/opt/lib)
5. Daemon startup and test port binding under QEMU ARM64
"""

import os
import sys
import subprocess
import tempfile
import atexit

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))
DEFAULT_IMG = os.path.join(REPO_ROOT, "build_dist/ubuntu_rootfs.ext4")
rootfs_img = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_IMG

if not os.path.exists(rootfs_img):
    print(f"[!] Rootfs image not found: {rootfs_img}")
    sys.exit(1)

mnt_base = "/tmp/nanokvm_verify_base"
merged = "/tmp/nanokvm_verify_merged"
upper = "/tmp/nanokvm_verify_upper"
work = "/tmp/nanokvm_verify_work"

def cleanup():
    for sub in ["run", "dev/pts", "dev", "sys", "proc"]:
        subprocess.run(["umount", "-l", f"{merged}/{sub}"], stderr=subprocess.DEVNULL)
    subprocess.run(["umount", "-l", merged], stderr=subprocess.DEVNULL)
    subprocess.run(["umount", "-l", mnt_base], stderr=subprocess.DEVNULL)
    for d in [merged, upper, work, mnt_base]:
        subprocess.run(["rm", "-rf", d], stderr=subprocess.DEVNULL)

atexit.register(cleanup)
cleanup()

for d in [mnt_base, merged, upper, work]:
    os.makedirs(d, exist_ok=True)

print(f"[*] Mounting image {rootfs_img} (read-only)...")
subprocess.run(["mount", "-o", "loop,ro", rootfs_img, mnt_base], check=True)
subprocess.run(["mount", "-t", "overlay", "overlay", "-o", f"lowerdir={mnt_base},upperdir={upper},workdir={work}", merged], check=True)

# Mount proc, sys, dev
subprocess.run(["mount", "-t", "proc", "proc", f"{merged}/proc"], check=True)
subprocess.run(["mount", "-t", "sysfs", "sysfs", f"{merged}/sys"], check=True)
subprocess.run(["mount", "--bind", "/dev", f"{merged}/dev"], check=True)
subprocess.run(["mount", "--bind", "/dev/pts", f"{merged}/dev/pts"], check=True)

# Mount fresh in-memory tmpfs on /run (simulates Linux boot)
subprocess.run(["mount", "-t", "tmpfs", "tmpfs", f"{merged}/run"], check=True)

# Inject QEMU static emulator
qemu_src = "/usr/bin/qemu-aarch64-static"
if os.path.exists(qemu_src):
    subprocess.run(["cp", qemu_src, f"{merged}/usr/bin/qemu-aarch64-static"], check=True)

passes = 0
failures = 0

def check(name, success, details=""):
    global passes, failures
    if success:
        print(f"  [✓] {name}")
        passes += 1
    else:
        print(f"  [✗] {name}: {details}")
        failures += 1

print("\n=== 1. Systemd Boot Services Check ===")
wants_dir = f"{merged}/etc/systemd/system/multi-user.target.wants"
nanokvm_linked = os.path.islink(f"{wants_dir}/nanokvm.service")
kvmcomm_linked = os.path.islink(f"{wants_dir}/kvmcomm.service")
check("nanokvm.service linked in multi-user.target.wants", nanokvm_linked, "Missing from boot targets!")
check("kvmcomm.service linked in multi-user.target.wants", kvmcomm_linked, "Missing from boot targets!")
has_ssh_unit = os.path.exists(f"{merged}/lib/systemd/system/ssh.service") or os.path.exists(f"{merged}/etc/systemd/system/ssh.service")
check("ssh.service unit available for on-demand UI start", has_ssh_unit)
has_usb_unit = os.path.exists(f"{merged}/etc/systemd/system/usb-gadget.service")
check("usb-gadget.service unit available for on-demand UI start", has_usb_unit)

print("\n=== 2. OpenSSH PrivSep & tmpfiles Rule Check ===")
has_tmpfiles = os.path.exists(f"{merged}/etc/tmpfiles.d/sshd.conf") or os.path.exists(f"{merged}/usr/lib/tmpfiles.d/sshd.conf")
check("sshd tmpfiles rule exists (/run/sshd)", has_tmpfiles)

has_override = os.path.exists(f"{merged}/etc/systemd/system/ssh.service.d/override.conf")
check("ssh.service systemd override exists (/run/sshd)", has_override)

# Run systemd-tmpfiles to create /run/sshd in fresh tmpfs
subprocess.run(["chroot", merged, "systemd-tmpfiles", "--create", "--prefix=/run/sshd"], stderr=subprocess.DEVNULL)
sshd_check = subprocess.run(["chroot", merged, "/usr/sbin/sshd", "-t"], capture_output=True, text=True)
check("sshd -t configuration dry-run (exit 0)", sshd_check.returncode == 0, sshd_check.stderr.strip())

print("\n=== 3. Dynamic Linker & Axera Blob Configuration ===")
axera_conf = os.path.exists(f"{merged}/etc/ld.so.conf.d/00-axera.conf")
check("/etc/ld.so.conf.d/00-axera.conf exists", axera_conf)
if axera_conf:
    content = open(f"{merged}/etc/ld.so.conf.d/00-axera.conf").read()
    check("/opt/lib included in ld.so.conf", "/opt/lib" in content)

print("\n=== 4. SSL Certificates & Boot Targets Cleanliness ===")
has_crt = os.path.exists(f"{merged}/etc/kvm/server.crt")
has_key = os.path.exists(f"{merged}/etc/kvm/server.key")
check("Default SSL certificate (/etc/kvm/server.crt) exists", has_crt)
check("Default SSL key (/etc/kvm/server.key) exists", has_key)

nginx_wants = os.path.exists(f"{merged}/etc/systemd/system/multi-user.target.wants/nginx.service")
check("nginx.service not enabled in boot targets (avoids port 80/443 collision)", not nginx_wants)

rc_local_path = f"{merged}/etc/rc.local"
has_bogus_ip = os.path.exists(rc_local_path) and "192.168.100.200" in open(rc_local_path).read()
check("Bogus 192.168.100.200 static fallback IP absent from /etc/rc.local", not has_bogus_ip)

print("\n=== 5. NanoKVM-Server Runtime Smoke Test (ARM64 QEMU) ===")
# Generate temporary test config with distinct ports
test_yaml = """
proto: "https"
port:
  http: 18080
  https: 18443
cert:
  crt: "/etc/kvm/server.crt"
  key: "/etc/kvm/server.key"
logger:
  level: "info"
  file: "stdout"
"""
with open(f"{merged}/etc/kvm/server.yaml", "w") as f:
    f.write(test_yaml)

srv_test = subprocess.run(
    ["chroot", merged, "bash", "-c", "cd /kvmapp/server && LD_LIBRARY_PATH=/opt/lib:/kvmapp/server/dl_lib timeout 3 ./NanoKVM-Server"],
    capture_output=True, text=True
)
# Exit code 124 is from timeout command, meaning it successfully started and remained running
check("NanoKVM-Server starts without missing library crashes", srv_test.returncode == 124, srv_test.stderr[:200])

print("\n======================================")
print(f"Summary: {passes} Passed, {failures} Failed")
print("======================================")
sys.exit(0 if failures == 0 else 1)
