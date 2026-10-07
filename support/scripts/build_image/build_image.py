#!/usr/bin/env python3

import os
import sys
import stat
import time
import signal
import pwd
import zipfile
import shutil
import argparse
import subprocess

try:
    from tqdm import tqdm
except ImportError:
    class tqdm:
        def __init__(self, iterable=None, total=None, desc="", unit="", **kwargs):
            self.total = total
            self.desc = desc
            self.count = 0
            if desc:
                print(f"[*] {desc}...")
        def update(self, n=1):
            self.count += n
        def __enter__(self):
            return self
        def __exit__(self, exc_type, exc_val, exc_tb):
            pass

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

_NS_ENV = "NANOKVM_BUILD_NS"

def enter_private_namespace():
    """Re-exec (as root) inside a private mount + PID namespace.

    Every mount made by the build is invisible to the host and is torn down
    by the kernel when the namespace exits, even on crash or SIGKILL.
    """
    if os.environ.get(_NS_ENV) == "1":
        return
    if not shutil.which("unshare"):
        print("[!] Error: 'unshare' (util-linux) is required to isolate build mounts from the host.")
        sys.exit(1)
    os.environ[_NS_ENV] = "1"
    sys.stdout.flush()
    os.execvp("unshare", [
        "unshare", "--mount", "--propagation", "private",
        "--pid", "--fork", "--mount-proc",
        sys.executable, os.path.abspath(__file__),
    ] + sys.argv[1:])

def assert_no_mounts_under(path):
    """Refuse to delete a tree that still has something mounted inside it."""
    root = os.path.realpath(path)
    busy = []
    with open("/proc/self/mounts", "r") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            mp = parts[1].replace("\\040", " ")
            if mp == root or mp.startswith(root + os.sep):
                busy.append(mp)
    if busy:
        raise RuntimeError(f"refusing to delete {root}: still mounted: {', '.join(busy)}")

def stage_bootloader_from_blobs(blobs_dir, temp_dir, replacements=None, overlay_dir=None):
    bootloader_dir = os.path.join(blobs_dir, "bootloader")
    bootfs_dir = os.path.join(blobs_dir, "bootfs")

    if not os.path.isdir(bootloader_dir):
        raise FileNotFoundError(f"Bootloader blobs directory not found: {bootloader_dir}")

    print(f"[+] Staging bootloader blobs from {bootloader_dir}...")
    for item in os.listdir(bootloader_dir):
        src = os.path.join(bootloader_dir, item)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(temp_dir, item))

    if replacements:
        for fname, new_path in replacements.items():
            if new_path and os.path.exists(new_path):
                print(f"[+] Replacing {fname} -> {new_path}")
                shutil.copy2(new_path, os.path.join(temp_dir, fname))

    # Generate bootfs.fat32 (128 MB VFAT image)
    bootfs_path = os.path.join(temp_dir, "bootfs.fat32")
    print("[+] Creating bootfs.fat32 partition image (128MB FAT32)...")
    subprocess.run(["dd", "if=/dev/zero", f"of={bootfs_path}", "bs=1M", "count=128", "status=none"], check=True)
    subprocess.run(["mkfs.vfat", "-F", "32", "-n", "BOOT", bootfs_path], check=True)

    if os.path.isdir(bootfs_dir):
        for item in os.listdir(bootfs_dir):
            item_path = os.path.join(bootfs_dir, item)
            subprocess.run(["mcopy", "-o", "-i", bootfs_path, item_path, "::/"], check=True)

    if overlay_dir and os.path.isdir(os.path.join(overlay_dir, "boot")):
        for item in os.listdir(os.path.join(overlay_dir, "boot")):
            item_path = os.path.join(overlay_dir, "boot", item)
            subprocess.run(["mcopy", "-o", "-i", bootfs_path, item_path, "::/"], check=True)

def locate_base_rootfs(rootfs_path=None, blobs_dir=None):
    candidates = []
    if rootfs_path:
        candidates.append(rootfs_path)

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
    candidates.extend([
        os.path.join(repo_root, "build_dist/ubuntu_rootfs.ext4"),
        os.path.join(repo_root, "build_dist/ubuntu_rootfs_sparse.ext4"),
        "/var/tmp/nanokvm_inspect/ubuntu_rootfs.ext4",
        os.path.join(repo_root, "support/base_firmware/ubuntu_rootfs.ext4"),
    ])
    if blobs_dir:
        candidates.extend([
            os.path.join(blobs_dir, "rootfs/ubuntu_rootfs.ext4"),
            os.path.join(blobs_dir, "rootfs/ubuntu_rootfs_sparse.ext4"),
        ])

    for c in candidates:
        if c and os.path.exists(c):
            return c
    return None

def build_axp(axp_file=None, blobs_dir=None, rootfs_path=None, replacements=None, output=None, work_dir=None):
    global _active_mount_point
    if output is None:
        output = "NanoKVMPro_Custom.axp"

    temp_dir = os.path.abspath(work_dir) if work_dir else "/var/tmp/nanokvm_build_axp"
    mount_point = os.path.join(temp_dir, "mount_point")
    _active_mount_point = mount_point

    if os.path.exists(mount_point):
        print(f"[+] Checking and cleaning any stale mounts in {mount_point}...")
        umount_chroot(mount_point)

    if os.path.exists(temp_dir):
        assert_no_mounts_under(temp_dir)
        try:
            shutil.rmtree(temp_dir)
        except Exception:
            subprocess.run(SUDO + ["rm", "-rf", temp_dir], check=True)
    os.makedirs(temp_dir, exist_ok=True)
    os.makedirs(mount_point, exist_ok=True)

    if blobs_dir and os.path.isdir(blobs_dir):
        print(f"[+] Building AXP directly from repository blobs: {blobs_dir}")
        stage_bootloader_from_blobs(blobs_dir, temp_dir, replacements=replacements, overlay_dir=getattr(args, 'overlay', None))
        base_rootfs = locate_base_rootfs(rootfs_path, blobs_dir)
        if not base_rootfs:
            raise FileNotFoundError(
                "Base rootfs not found! Expected 'build_dist/ubuntu_rootfs.ext4'. "
                "Specify --rootfs or provide the base image."
            )
        target_raw = os.path.join(temp_dir, "ubuntu_rootfs.ext4")
        if base_rootfs.endswith("_sparse.ext4"):
            print(f"[+] Converting sparse rootfs {base_rootfs} -> raw {target_raw}...")
            sparse_to_raw(base_rootfs, target_raw)
        else:
            print(f"[+] Staging raw rootfs {base_rootfs} -> {target_raw}...")
            subprocess.run(["cp", "--sparse=always", base_rootfs, target_raw], check=True)
    elif axp_file and os.path.exists(axp_file):
        print(f"[+] Extracting {axp_file}")
        with zipfile.ZipFile(axp_file, 'r') as zip_ref:
            file_list = zip_ref.namelist()
            with tqdm(total=len(file_list), desc="Extracting", unit="files") as pbar:
                for file in file_list:
                    zip_ref.extract(file, temp_dir)
                    pbar.update(1)

        for fname, new_path in (replacements or {}).items():
            target_path = os.path.join(temp_dir, fname)
            if not os.path.exists(target_path):
                print(f"[!] Warning: {fname} not found in axp, skipping")
                continue
            print(f"[+] Replacing {fname} -> {new_path}")
            shutil.copy2(new_path, target_path)

        sparse_to_raw(os.path.join(temp_dir, "ubuntu_rootfs_sparse.ext4"),
                      os.path.join(temp_dir, "ubuntu_rootfs.ext4"))
        os.remove(os.path.join(temp_dir, "ubuntu_rootfs_sparse.ext4"))
    else:
        raise ValueError("Neither valid --blobs directory nor input AXP archive was provided.")

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

        blobs_rootfs = os.path.join(blobs_dir, "rootfs") if blobs_dir else None
        if blobs_rootfs and os.path.isdir(blobs_rootfs):
            print(f"[+] Applying repository rootfs blobs from {blobs_rootfs}...")
            subprocess.run(SUDO + ["rsync", "-av", "--keep-dirlinks", f"{blobs_rootfs}/", f"{mount_point}/"], check=True)

        if args.app:
            subprocess.run(SUDO + ["rsync", "-av", "--keep-dirlinks", f"{args.app}/", f"{mount_point}/root"], check=True)
            run_chroot_commands(mount_point=mount_point, commands=["dpkg -i /root/*.deb"])
            run_chroot_commands(mount_point=mount_point, commands=["rm -f /root/*.deb"])
            run_chroot_commands(mount_point=mount_point, commands=["mkdir -p /root/.kvmcache"])
            subprocess.run(SUDO + ["rsync", "-av", "--keep-dirlinks", f"{args.app}/", f"{mount_point}/root/.kvmcache"], check=True)

        if args.overlay:
            subprocess.run(SUDO + ["rsync", "-av", "--keep-dirlinks",
                "--exclude=boot/",
                f"{args.overlay}/",
                f"{mount_point}/"
            ], check=True)

        # Usrmerge integrity check: ensure /lib, /bin, /sbin remain symlinks
        for sym in ["lib", "bin", "sbin"]:
            sym_path = os.path.join(mount_point, sym)
            if not os.path.islink(sym_path):
                raise RuntimeError(f"Usrmerge integrity failure: {sym_path} is not a symlink! Overlay corrupted rootfs structure.")

        # Refresh DNS and hosts configuration inside rootfs before network operations
        setup_chroot_dns(mount_point)

        run_chroot_commands(mount_point=mount_point, commands=[
            "(apt-get -o Acquire::ForceIPv4=true -o APT::Sandbox::User=root update && "
            "apt-get -o Acquire::ForceIPv4=true -o APT::Sandbox::User=root install --reinstall -y ca-certificates && "
            "update-ca-certificates) || echo '[!] Warning: CA certificates update skipped (offline build)'",
            "mkdir -p /etc/systemd/system/multi-user.target.wants",
            "ln -sf /etc/systemd/system/nanokvm.service /etc/systemd/system/multi-user.target.wants/nanokvm.service",
            "ln -sf /etc/systemd/system/kvmcomm.service /etc/systemd/system/multi-user.target.wants/kvmcomm.service",
            "rm -f /etc/systemd/system/multi-user.target.wants/ssh.service "
            "/etc/systemd/system/multi-user.target.wants/usb-gadget.service "
            "/etc/systemd/system/sockets.target.wants/ssh.socket",
            "mkdir -p /etc/tmpfiles.d && echo 'd /run/sshd 0755 root root -' > /etc/tmpfiles.d/sshd.conf",
            "mkdir -p /etc/systemd/system/ssh.service.d",
            '''printf '[Unit]\\nDescription=OpenBSD Secure Shell server\\n\\n[Service]\\nRuntimeDirectory=sshd\\nRuntimeDirectoryMode=0755\\nExecStartPre=/bin/mkdir -p -m 0755 /run/sshd\\n' > /etc/systemd/system/ssh.service.d/override.conf''',
            "mkdir -p /etc/kvm",
            '''if [ ! -f /etc/kvm/server.crt ] || [ ! -f /etc/kvm/server.key ]; then
                openssl req -x509 -newkey rsa:2048 -keyout /etc/kvm/server.key -out /etc/kvm/server.crt -days 3650 -nodes -subj "/CN=localhost"
                chmod 600 /etc/kvm/server.key
                chmod 644 /etc/kvm/server.crt
            fi''',
            '''if [ -f /etc/rc.local ]; then
                sed -i '/192\\.168\\.100\\.200/d' /etc/rc.local
            fi''',
            "ldconfig"
        ])
        # Disable redundant background timers & services (including nginx so NanoKVM port 80/443 is free)
        run_chroot_commands(mount_point=mount_point, commands=[
            "rm -f /etc/systemd/system/timers.target.wants/apt-daily.timer "
            "/etc/systemd/system/timers.target.wants/apt-daily-upgrade.timer "
            "/etc/systemd/system/timers.target.wants/motd-news.timer "
            "/etc/systemd/system/bluetooth.target.wants/bluetooth.service "
            "/etc/systemd/system/multi-user.target.wants/isc-dhcp-server.service "
            "/etc/systemd/system/multi-user.target.wants/isc-dhcp-server6.service "
            "/etc/systemd/system/multi-user.target.wants/nginx.service "
            "/etc/systemd/system/multi-user.target.wants/kvmd-nginx.service "
            "/etc/systemd/system/multi-user.target.wants/cua.service"
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
    assert_no_mounts_under(temp_dir)
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

replace_axp = build_axp

def sparse_to_raw(sparse_img, raw_img):
    subprocess.run(["simg2img", sparse_img, raw_img], check=True)

def raw_to_sparse(raw_img, sparse_img):
    subprocess.run(["img2simg", raw_img, sparse_img], check=True)

# Minimal device set for apt/dpkg/bash inside the chroot: (name, major, minor)
_DEV_NODES = [
    ("null", 1, 3), ("zero", 1, 5), ("full", 1, 7),
    ("random", 1, 8), ("urandom", 1, 9), ("tty", 5, 0),
]
_DEV_LINKS = {
    "fd": "/proc/self/fd", "stdin": "/proc/self/fd/0",
    "stdout": "/proc/self/fd/1", "stderr": "/proc/self/fd/2",
    "ptmx": "pts/ptmx",
}

def mount_and_chroot(raw_img, mount_point="/mnt"):
    """Mount the rootfs with its own proc/sys/dev; never bind host /dev, /proc or /sys."""
    os.makedirs(mount_point, exist_ok=True)

    def mount(*a):
        subprocess.run(SUDO + ["mount"] + list(a), check=True)

    mount("-o", "loop", raw_img, mount_point)

    # Fresh procfs; kernel-global knobs are made read-only.
    proc = os.path.join(mount_point, "proc")
    mount("-t", "proc", "-o", "nosuid,nodev,noexec", "proc", proc)
    for sub in ("sys", "sysrq-trigger"):
        p = os.path.join(proc, sub)
        mount("--bind", p, p)
        mount("-o", "remount,bind,ro", p)

    mount("-t", "sysfs", "-o", "ro,nosuid,nodev,noexec", "sysfs", os.path.join(mount_point, "sys"))

    # Private /dev with only harmless nodes.
    dev = os.path.join(mount_point, "dev")
    mount("-t", "tmpfs", "-o", "nosuid,noexec,mode=0755,size=16m", "tmpfs", dev)
    for name, major, minor in _DEV_NODES:
        p = os.path.join(dev, name)
        os.mknod(p, stat.S_IFCHR | 0o666, os.makedev(major, minor))
        os.chmod(p, 0o666)
    os.makedirs(os.path.join(dev, "pts"))
    mount("-t", "devpts", "-o", "newinstance,ptmxmode=0666,mode=0620,gid=5", "devpts", os.path.join(dev, "pts"))
    os.makedirs(os.path.join(dev, "shm"))
    mount("-t", "tmpfs", "-o", "nosuid,nodev,mode=1777", "tmpfs", os.path.join(dev, "shm"))
    for name, target in _DEV_LINKS.items():
        os.symlink(target, os.path.join(dev, name))

    qemu_src = find_qemu_static()
    if not qemu_src:
        print("[!] Error: qemu-aarch64-static emulator binary not found.")
        print("[!] Please run 'make setup-tooling' or install qemu-user-static.")
        sys.exit(1)
    subprocess.run(SUDO + ["cp", qemu_src, os.path.join(mount_point, "usr/bin/qemu-aarch64-static")], check=True)
    setup_chroot_dns(mount_point)

def find_qemu_static():
    for candidate in [
        shutil.which("qemu-aarch64-static"),
        "/usr/bin/qemu-aarch64-static",
        "/usr/local/bin/qemu-aarch64-static",
    ]:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None

def setup_chroot_dns(mount_point):
    resolv_dest = os.path.join(mount_point, "etc/resolv.conf")
    nsswitch_dest = os.path.join(mount_point, "etc/nsswitch.conf")
    hosts_dest = os.path.join(mount_point, "etc/hosts")
    hosts_bak = os.path.join(mount_point, "etc/hosts.bak")

    # 1. Guarantee ports.ubuntu.com resolution via /etc/hosts fallback (avoids DNS/ISP timeout)
    if os.path.isdir(os.path.join(mount_point, "etc")):
        if os.path.exists(hosts_dest) and not os.path.exists(hosts_bak):
            subprocess.run(SUDO + ["cp", "-p", hosts_dest, hosts_bak], check=False)
        subprocess.run(SUDO + [
            "sh", "-c",
            f"grep -q 'ports.ubuntu.com' {hosts_dest} 2>/dev/null || printf '\\n91.189.91.102 ports.ubuntu.com\\n91.189.91.104 ports.ubuntu.com\\n' >> {hosts_dest}"
        ], check=False)

    # 2. Gather DNS nameservers
    nameservers = []
    candidate_files = [
        "/run/systemd/resolve/resolv.conf",
        "/etc/resolv.conf",
    ]
    for resolv_file in candidate_files:
        if os.path.exists(resolv_file):
            try:
                with open(resolv_file, "r") as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith("nameserver"):
                            parts = line.split()
                            if len(parts) >= 2 and not parts[1].startswith("127."):
                                if parts[1] not in nameservers:
                                    nameservers.append(parts[1])
            except Exception:
                pass
        if nameservers:
            break

    # Append reliable public DNS resolvers as fallback
    for fallback in ["1.1.1.1", "8.8.8.8", "9.9.9.9"]:
        if fallback not in nameservers:
            nameservers.append(fallback)

    # glibc MAXNS is 3; use first 3 nameservers with IPv4/single-request options
    content = "".join([f"nameserver {ns}\n" for ns in nameservers[:3]])
    content += "options timeout:2 attempts:2 rotate ndots:1\n"

    import tempfile
    try:
        with tempfile.NamedTemporaryFile("w", delete=False) as tf:
            tf.write(content)
            temp_resolv = tf.name

        # Ensure destination is not a dangling symlink inside rootfs
        if os.path.islink(resolv_dest) or os.path.exists(resolv_dest):
            try:
                os.remove(resolv_dest)
            except OSError:
                subprocess.run(SUDO + ["rm", "-f", resolv_dest], check=False)

        subprocess.run(SUDO + ["cp", temp_resolv, resolv_dest], check=True)
        subprocess.run(SUDO + ["chmod", "644", resolv_dest], check=True)
    finally:
        if 'temp_resolv' in locals() and os.path.exists(temp_resolv):
            try:
                os.remove(temp_resolv)
            except OSError:
                pass

    # 3. Ensure nsswitch uses files dns during chroot (bypasses missing systemd-resolved socket)
    if os.path.exists(nsswitch_dest):
        subprocess.run(SUDO + [
            "sed", "-i.bak",
            "s/^hosts:.*/hosts:          files dns/",
            nsswitch_dest
        ], check=False)

def restore_chroot_dns(mount_point):
    resolv_dest = os.path.join(mount_point, "etc/resolv.conf")
    nsswitch_dest = os.path.join(mount_point, "etc/nsswitch.conf")
    nsswitch_bak = os.path.join(mount_point, "etc/nsswitch.conf.bak")
    hosts_dest = os.path.join(mount_point, "etc/hosts")
    hosts_bak = os.path.join(mount_point, "etc/hosts.bak")

    if os.path.exists(hosts_bak):
        subprocess.run(SUDO + ["mv", "-f", hosts_bak, hosts_dest], check=False)

    if os.path.exists(nsswitch_bak):
        subprocess.run(SUDO + ["mv", "-f", nsswitch_bak, nsswitch_dest], check=False)

    if os.path.isdir(os.path.join(mount_point, "etc")):
        try:
            if os.path.islink(resolv_dest) or os.path.exists(resolv_dest):
                os.remove(resolv_dest)
        except OSError:
            subprocess.run(SUDO + ["rm", "-f", resolv_dest], check=False)
        subprocess.run(SUDO + ["ln", "-sf", "../run/systemd/resolve/stub-resolv.conf", resolv_dest], check=False)

def run_chroot_commands(mount_point="/mnt", commands=None):
    if commands:
        for cmd in commands:
            full_cmd = f"export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export DEBIAN_FRONTEND=noninteractive; {cmd}"
            subprocess.run(SUDO + ["chroot", mount_point, "/bin/bash", "-c", full_cmd], check=True)
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
    restore_chroot_dns(mount_point)
    qemu_path = os.path.join(mount_point, "usr/bin/qemu-aarch64-static")
    if os.path.exists(qemu_path):
        subprocess.run(SUDO + ["rm", "-rf", qemu_path], check=False)
    for mp in ["dev/shm", "dev/pts", "dev", "sys", "proc/sysrq-trigger", "proc/sys", "proc"]:
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
    parser = argparse.ArgumentParser(description="Build or customize NanoKVM-Pro AXP image")
    parser.add_argument("axp", nargs="?", default=None, help="Input axp file path (optional if --blobs is provided)")
    parser.add_argument("-o", "--output", help="Output axp file path")
    parser.add_argument("--blobs", help="Directory containing repository binary blobs (support/blobs)")
    parser.add_argument("--rootfs", help="Path to base rootfs image (.ext4 or sparse .ext4)")
    parser.add_argument("--dtb", help="New dtb file path")
    parser.add_argument("--boot", help="New boot_signed.bin file path")
    parser.add_argument("--uboot", help="New u-boot_signed.bin file path")
    parser.add_argument("--remove_file", help="File to remove from the chroot environment")
    parser.add_argument("--overlay", help="Overlay file to add to the chroot environment")
    parser.add_argument("--app", help="App file to add to the chroot environment")
    parser.add_argument("--work-dir", default="/var/tmp/nanokvm_build_axp", help="Working directory for firmware modification (default: /var/tmp/nanokvm_build_axp)")
    args = parser.parse_args()
    ensure_root_privileges()
    enter_private_namespace()

    # Auto-detect blobs directory if not explicitly provided
    if not args.axp and not args.blobs:
        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
        default_blobs = os.path.join(repo_root, "support/blobs")
        if os.path.isdir(default_blobs):
            args.blobs = default_blobs

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

    build_axp(axp_file=args.axp, blobs_dir=args.blobs, rootfs_path=args.rootfs,
              replacements=replacements, output=args.output, work_dir=args.work_dir)
