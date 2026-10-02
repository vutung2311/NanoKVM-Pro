#!/usr/bin/env python3

import os
import sys
import time
import signal
import pwd
import zipfile
import shutil
import argparse
import subprocess
from tqdm import tqdm

_active_mount_point = None

def _cleanup_signal_handler(signum, frame):
    global _active_mount_point
    if _active_mount_point and os.path.exists(_active_mount_point):
        print(f"\n[!] Signal {signum} received. Cleaning up active mounts at {_active_mount_point}...")
        umount_chroot(_active_mount_point)
    sys.exit(128 + signum)

signal.signal(signal.SIGINT, _cleanup_signal_handler)
signal.signal(signal.SIGTERM, _cleanup_signal_handler)

def get_privilege_cmd():
    if os.geteuid() == 0:
        return []
    if shutil.which("pkexec"):
        return ["pkexec"]
    if shutil.which("sudo"):
        return ["sudo"]
    if shutil.which("doas"):
        return ["doas"]
    return []

SUDO = get_privilege_cmd()

def ensure_root_privileges():
    if os.geteuid() == 0:
        return
    priv_cmd = get_privilege_cmd()
    if not priv_cmd:
        print("[!] Error: Root privileges are required for image loop mount and chroot, but no privilege escalation tool (pkexec/sudo/doas) was found.")
        sys.exit(1)

    print("[*] NanoKVM Pro image builder requires elevated privileges (loop mount, chroot).")
    print(f"[*] Waiting for authorization ({priv_cmd[0]})...")
    sys.stdout.flush()

    cmd = priv_cmd + [sys.executable, os.path.abspath(__file__)] + sys.argv[1:]
    res = subprocess.run(cmd)
    sys.exit(res.returncode)

def replace_axp(axp_file, replacements, output=None, work_dir=None):
    global _active_mount_point
    if output is None:
        output = os.path.splitext(axp_file)[0] + "_modified.axp"

    temp_dir = os.path.abspath(work_dir) if work_dir else os.path.join(os.path.dirname(axp_file), "axp_temp")
    mount_point = os.path.join(temp_dir, "mount_point")
    _active_mount_point = mount_point

    if os.path.exists(mount_point):
        print(f"[+] Checking and cleaning any stale mounts in {mount_point}...")
        umount_chroot(mount_point)

    if os.path.exists(temp_dir):
        shutil.rmtree(temp_dir, ignore_errors=True)
    os.makedirs(temp_dir, exist_ok=True)
    os.makedirs(mount_point, exist_ok=True)

    print(f"[+] Extracting {axp_file}")
    with zipfile.ZipFile(axp_file, 'r') as zip_ref:
        file_list = zip_ref.namelist()
        with tqdm(total=len(file_list), desc="Extracting", unit="files") as pbar:
            for file in file_list:
                zip_ref.extract(file, temp_dir)
                pbar.update(1)

    for fname, new_path in replacements.items():
        target_path = os.path.join(temp_dir, fname)
        if not os.path.exists(target_path):
            print(f"[!] Warning: {fname} not found in axp, skipping")
            continue
        print(f"[+] Replacing {fname} -> {new_path}")
        shutil.copy2(new_path, target_path)

    sparse_to_raw(os.path.join(temp_dir, "ubuntu_rootfs_sparse.ext4"),
                  os.path.join(temp_dir, "ubuntu_rootfs.ext4"))
    os.remove(os.path.join(temp_dir, "ubuntu_rootfs_sparse.ext4"))

    raw_img = os.path.join(temp_dir, "ubuntu_rootfs.ext4")
    print("[+] Expanding image size by 512MB...")
    subprocess.run(["dd", "if=/dev/zero", f"of={raw_img}", "bs=1M", "count=512", "conv=notrunc", "oflag=append"], check=True)
    print("[+] Resizing filesystem to use new space...")
    subprocess.run(["e2fsck", "-fy", raw_img], check=False)
    subprocess.run(["resize2fs", raw_img], check=True)

    try:
        mount_and_chroot(os.path.join(temp_dir, "ubuntu_rootfs.ext4"), mount_point)

        run_chroot_commands(mount_point=mount_point, commands=[
            '''if [ ! -e /usr/sbin/ether-wake ]; then
                ln -sf /usr/sbin/etherwake /usr/sbin/ether-wake
                echo "Created symlink: /usr/sbin/ether-wake -> /usr/sbin/etherwake"
            else
                echo "/usr/sbin/ether-wake already exists, skipping"
            fi'''
        ])

        run_chroot_commands(mount_point=mount_point, commands=["mkdir -p /data"])

        if args.remove_file:
            remove_files(mount_point=mount_point, remove_file_list=args.remove_file)

        if args.app:
            subprocess.run(SUDO + ["rsync", "-av", f"{args.app}/", f"{mount_point}/root"], check=True)
            run_chroot_commands(mount_point=mount_point, commands=["dpkg -i /root/*.deb"])
            run_chroot_commands(mount_point=mount_point, commands=["rm -f /root/*.deb"])
            run_chroot_commands(mount_point=mount_point, commands=["mkdir -p /root/.kvmcache"])
            subprocess.run(SUDO + ["rsync", "-av", f"{args.app}/", f"{mount_point}/root/.kvmcache"], check=True)

        if args.overlay:
            subprocess.run(SUDO + ["rsync", "-av",
                "--exclude=boot/",
                f"{args.overlay}/",
                f"{mount_point}/"
            ], check=True)

        run_chroot_commands(mount_point=mount_point, commands=["apt update && apt install --reinstall -y ca-certificates && update-ca-certificates || true"])
        run_chroot_commands(mount_point=mount_point, commands=["rm -f /etc/systemd/system/multi-user.target.wants/ssh.service"])
        run_chroot_commands(mount_point=mount_point, commands=["rm -f /etc/systemd/system/multi-user.target.wants/usb-gadget.service"])
        run_chroot_commands(mount_point=mount_point, commands=["rm -f /etc/systemd/system/sockets.target.wants/ssh.socket"])
        run_chroot_commands(mount_point=mount_point, commands=["rm -f /etc/systemd/system/multi-user.target.wants/cua.service"])

        # Disable redundant background timers & unused services
        run_chroot_commands(mount_point=mount_point, commands=[
            "rm -f /etc/systemd/system/timers.target.wants/apt-daily.timer "
            "/etc/systemd/system/timers.target.wants/apt-daily-upgrade.timer "
            "/etc/systemd/system/timers.target.wants/motd-news.timer "
            "/etc/systemd/system/bluetooth.target.wants/bluetooth.service || true"
        ])

        # Configure journald to volatile RAM storage (16MB max) to eliminate eMMC flash churn
        run_chroot_commands(mount_point=mount_point, commands=[
            "mkdir -p /etc/systemd/journald.conf.d && printf '[Journal]\\nStorage=volatile\\nRuntimeMaxUse=16M\\n' > /etc/systemd/journald.conf.d/00-volatile.conf"
        ])

        # Purge stale APT cache and package lists (saves ~374MB)
        run_chroot_commands(mount_point=mount_point, commands=[
            "rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/cache/apt/archives/* /tmp/*"
        ])

        # Purge unused Mesa 3D desktop GPU DRI drivers (saves ~1.1GB on headless AX630C)
        run_chroot_commands(mount_point=mount_point, commands=[
            "rm -rf /usr/lib/aarch64-linux-gnu/dri/*"
        ])

        # Purge unused camera sensor tuning files from IP camera BSP (saves ~150MB)
        run_chroot_commands(mount_point=mount_point, commands=[
            "find /opt/etc/ -maxdepth 1 -type f \\( -name '*.ini' -o -name '*.bin' \\) ! -name '*lt6911*' -delete 2>/dev/null || true"
        ])

        run_chroot_commands(mount_point=mount_point, commands=["mkdir -p /var/lib/misc"])
        run_chroot_commands(mount_point=mount_point, commands=["touch /var/lib/misc/udhcpd.usb0.leases"])
        run_chroot_commands(mount_point=mount_point, commands=["chmod 644 /var/lib/misc/udhcpd.usb0.leases"])

        # Zero unallocated blocks before unmount so img2simg skips empty space
        run_chroot_commands(mount_point=mount_point, commands=[
            "dd if=/dev/zero of=/zero.fill bs=1M status=none 2>/dev/null || true",
            "rm -f /zero.fill",
            "sync"
        ])
    finally:
        print("[+] Cleaning up mounts...")
        umount_chroot(mount_point)
        _active_mount_point = None

    raw_img = os.path.join(temp_dir, "ubuntu_rootfs.ext4")
    subprocess.run(["e2fsck", "-fy", raw_img], check=False)
    subprocess.run(["resize2fs", "-f", raw_img], check=True)

    raw_to_sparse(os.path.join(temp_dir, "ubuntu_rootfs.ext4"),
                  os.path.join(temp_dir, "ubuntu_rootfs_sparse.ext4"))
    os.remove(os.path.join(temp_dir, "ubuntu_rootfs.ext4"))

    if args.overlay:
        print("Overlaying boot files...")
        try:
            subprocess.run(SUDO + ["mount", "-t", "vfat",
                            os.path.join(temp_dir, "bootfs.fat32"),
                            mount_point], check=True)
            subprocess.run(SUDO + ["rsync", "-av", "--no-owner", "--no-group",
                            f"{args.overlay}/boot/",  f"{mount_point}/"], check=True)
        finally:
            subprocess.run(SUDO + ["umount", "-l", mount_point], check=False)

    subprocess.run(["sync"], check=True)

    print(f"[+] Repackaging to {output}")

    total_files = 0
    for root, _, files in os.walk(temp_dir):
        total_files += len(files)

    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as zip_out:
        with tqdm(total=total_files, desc="Repackaging", unit="files") as pbar:
            for root, _, files in os.walk(temp_dir):
                for file in files:
                    full_path = os.path.join(root, file)
                    rel_path = os.path.relpath(full_path, temp_dir)
                    zip_out.write(full_path, rel_path)
                    pbar.update(1)

    print(f"[+] Cleaning up temporary build directory: {temp_dir}...")
    shutil.rmtree(temp_dir, ignore_errors=True)

    real_uid_str = os.environ.get("PKEXEC_UID") or os.environ.get("SUDO_UID")
    if real_uid_str and os.path.exists(output):
        try:
            uid = int(real_uid_str)
            gid = pwd.getpwuid(uid).pw_gid
            os.chown(output, uid, gid)
        except Exception:
            pass

    print(f"[+] Done! New axp file: {output}")

def sparse_to_raw(sparse_img, raw_img):
    subprocess.run(["simg2img", sparse_img, raw_img], check=True)

def raw_to_sparse(raw_img, sparse_img):
    subprocess.run(["img2simg", raw_img, sparse_img], check=True)

def mount_and_chroot(raw_img, mount_point="/mnt"):
    os.makedirs(mount_point, exist_ok=True)

    subprocess.run(SUDO + ["mount", "-o", "loop", raw_img, mount_point], check=True)
    subprocess.run(SUDO + ["mount", "-t", "proc", "/proc", os.path.join(mount_point, "proc")], check=True)
    subprocess.run(SUDO + ["mount", "-t", "sysfs", "/sys", os.path.join(mount_point, "sys")], check=True)
    subprocess.run(SUDO + ["mount", "--bind", "/dev", os.path.join(mount_point, "dev")], check=True)
    subprocess.run(SUDO + ["mount", "--bind", "/dev/pts", os.path.join(mount_point, "dev/pts")], check=True)

    subprocess.run(SUDO + ["cp", "/usr/bin/qemu-aarch64-static", os.path.join(mount_point, "usr/bin/qemu-aarch64-static")], check=True)
    subprocess.run(SUDO + ["cp", "/etc/resolv.conf", os.path.join(mount_point, "etc/resolv.conf")], check=True)

def run_chroot_commands(mount_point="/mnt", commands=None):
    if commands:
        for cmd in commands:
            full_cmd = f"export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export DEBIAN_FRONTEND=noninteractive; {cmd}"
            subprocess.run(SUDO + ["chroot", mount_point, "bash", "-c", full_cmd], check=True)
    else:
        subprocess.run(SUDO + ["chroot", mount_point, "/bin/bash"], check=True)

def is_mounted(path):
    path = os.path.realpath(path)
    try:
        with open("/proc/mounts", "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2 and os.path.realpath(parts[1]) == path:
                    return True
    except Exception:
        pass
    return False

def umount_chroot(mount_point="/mnt"):
    mount_point = os.path.realpath(mount_point)
    qemu_path = os.path.join(mount_point, "usr/bin/qemu-aarch64-static")
    if os.path.exists(qemu_path):
        subprocess.run(SUDO + ["rm", "-rf", qemu_path], check=False)
    for mp in ["dev/pts", "dev", "sys", "proc"]:
        target = os.path.join(mount_point, mp)
        if is_mounted(target):
            subprocess.run(SUDO + ["umount", "-l", target], check=False)
    if is_mounted(mount_point):
        subprocess.run(SUDO + ["umount", "-l", mount_point], check=False)

def remove_files(mount_point="/mnt", remove_file_list="remove_file.txt"):
    if not os.path.exists(remove_file_list):
        print(f"[!] Warning: Remove file list not found: {remove_file_list}")
        return

    print(f"[+] Removing unwanted files from list: {remove_file_list}")

    target_list = os.path.join(mount_point, "root", "remove_file.txt")
    subprocess.run(SUDO + ["cp", remove_file_list, target_list], check=True)

    removal_script = f'''
remove_file_list="/root/remove_file.txt"

if [ ! -f "$remove_file_list" ]; then
    echo "[!] Warning: Remove file list not found: $remove_file_list"
    exit 0
fi

echo "[+] Removing unwanted files..."
removed_count=0
total_count=0

while IFS= read -r file_path; do
    [[ -z "$file_path" || "$file_path" =~ ^[[:space:]]*# ]] && continue

    total_count=$((total_count + 1))

    if [ -e "$file_path" ]; then
        if rm -rf "$file_path" 2>/dev/null; then
            echo "[+] Removed: $file_path"
            removed_count=$((removed_count + 1))
        else
            echo "[!] Warning: Failed to remove: $file_path"
        fi
    else
        echo "[+] File not found (skipping): $file_path"
    fi
done < "$remove_file_list"

echo "[+] Cleanup completed: $removed_count/$total_count files removed"

# Clean up the temporary remove list
rm -f "$remove_file_list"
'''

    subprocess.run(SUDO + ["chroot", mount_point, "bash", "-c", removal_script], check=True)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Replace dtb/boot/u-boot files in AXP file")
    parser.add_argument("axp", help="Input axp file path")
    parser.add_argument("-o", "--output", help="Output axp file path")
    parser.add_argument("--dtb", help="New dtb file path")
    parser.add_argument("--boot", help="New boot_signed.bin file path")
    parser.add_argument("--uboot", help="New u-boot_signed.bin file path")
    parser.add_argument("--remove_file", help="File to remove from the chroot environment")
    parser.add_argument("--overlay", help="Overlay file to add to the chroot environment")
    parser.add_argument("--app", help="App file to add to the chroot environment")
    parser.add_argument("--work-dir", default="/var/tmp/nanokvm_build_axp", help="Working directory for firmware modification (default: /var/tmp/nanokvm_build_axp)")
    args = parser.parse_args()
    ensure_root_privileges()

    replacements = {}
    if args.dtb:
        replacements["AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb"] = args.dtb
        replacements["AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb.1"] = args.dtb
    if args.boot:
        replacements["boot_signed.bin"] = args.boot
        replacements["boot_signed.bin.1"] = args.boot
    if args.uboot:
        replacements["u-boot_signed.bin"] = args.uboot
        replacements["u-boot_b_signed.bin"] = args.uboot

    replace_axp(args.axp, replacements, args.output, work_dir=args.work_dir)
