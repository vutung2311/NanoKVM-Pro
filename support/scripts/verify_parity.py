#!/usr/bin/env python3
"""
NanoKVM-Pro Rootfs & Hardware Parity Verification Engine.
Performs exhaustive structural, hardware driver vermagic, service link,
and bootloader configuration auditing on rootfs directories, raw .ext4 images, or .axp archives.
"""

import os
import sys
import stat
import re
import argparse
import subprocess
import tempfile
import atexit

REQUIRED_SOC_KO = [
    "aic8800_bsp.ko", "aic8800_btlpm.ko", "aic8800_fdrv.ko", "ax_audio.ko",
    "ax_avs.ko", "ax_base.ko", "ax_cmm.ko", "ax_ddr_dfs.ko", "ax_fb.ko",
    "ax_gdc.ko", "ax_ive.ko", "ax_ivps.ko", "ax_jenc.ko", "ax_mipi_rx.ko",
    "ax_mipi_switch.ko", "ax_npu.ko", "ax_perf_monitor.ko", "ax_pool.ko",
    "ax_proton.ko", "ax_sys.ko", "ax_tdp.ko", "ax_vdec.ko", "ax_venc.ko",
    "ax_vo.ko", "ax_vpp.ko", "hynitron_touch.ko"
]

REQUIRED_KVMCOMM_KO = [
    "rotary_encoder.ko", "gpio_keys.ko", "fbtft.ko", "fb_jd9853.ko",
    "f_udisp_drv.ko", "lt6911_manage.ko", "wireguard.ko"
]

EXPECTED_VERMAGIC = "4.19.125"

def get_vermagic(file_path):
    """Extract vermagic string from an ELF kernel module."""
    try:
        res = subprocess.run(["strings", file_path], capture_output=True, text=True, check=True)
        for line in res.stdout.splitlines():
            if line.startswith("vermagic="):
                return line.split("=")[1].strip()
    except Exception:
        pass
    return None

class ParityAuditor:
    def __init__(self, rootfs_dir):
        self.root = os.path.abspath(rootfs_dir)
        self.passes = 0
        self.failures = 0
        self.warnings = 0

    def check(self, title, condition, error_msg="", is_warning=False):
        if condition:
            print(f"  [✓] {title}")
            self.passes += 1
            return True
        else:
            if is_warning:
                print(f"  [!] {title}: {error_msg}")
                self.warnings += 1
            else:
                print(f"  [✗] {title}: {error_msg}")
                self.failures += 1
            return False

    def path(self, rel_path):
        return os.path.join(self.root, rel_path.lstrip("/"))

    def exists_in_root(self, rel_path):
        """Check if a path exists within rootfs, following symlinks relative to self.root."""
        curr = self.path(rel_path)
        visited = set()
        while os.path.islink(curr):
            if curr in visited:
                return False  # cyclic symlink
            visited.add(curr)
            target = os.readlink(curr)
            if target.startswith("/"):
                curr = self.path(target)
            else:
                curr = os.path.normpath(os.path.join(os.path.dirname(curr), target))
        return os.path.exists(curr)

    def run_all_audits(self):
        print("==================================================================")
        print(f"[*] Running NanoKVM-Pro Hardware Parity Audit on: {self.root}")
        print("==================================================================")

        self.audit_usrmerge()
        self.audit_soc_drivers()
        self.audit_kvmcomm_drivers()
        self.audit_rotary_and_touch_pinmux()
        self.audit_wifi_subsystem()
        self.audit_daemons_and_ui()
        self.audit_systemd_boot_links()
        self.audit_storage_and_ssh()

        print("\n==================================================================")
        print(f"Audit Results: {self.passes} Passed, {self.failures} Failed, {self.warnings} Warnings")
        print("==================================================================")
        return self.failures == 0

    def audit_usrmerge(self):
        print("\n--- 1. Usrmerge & Init Integrity ---")
        for sym in ["bin", "sbin", "lib"]:
            p = self.path(sym)
            self.check(f"/{sym} is a symlink", os.path.islink(p), f"Corrupted directory structure at {p}")
        
        init_path = self.path("sbin/init")
        init_valid = os.path.islink(init_path) and ("systemd" in os.readlink(init_path))
        self.check("/sbin/init points to systemd", init_valid, "System will kernel panic on boot!")

    def audit_soc_drivers(self):
        print("\n--- 2. Axera SoC Kernel Modules & Vermagic ---")
        soc_dir = self.path("soc/ko")
        self.check("/soc/ko directory exists", os.path.isdir(soc_dir))
        
        missing_ko = []
        bad_vermagic = []
        for ko in REQUIRED_SOC_KO:
            p = os.path.join(soc_dir, ko)
            if not os.path.isfile(p):
                missing_ko.append(ko)
            else:
                v = get_vermagic(p)
                if not v or not v.startswith(EXPECTED_VERMAGIC):
                    bad_vermagic.append((ko, v))

        self.check("All 27 required /soc/ko drivers present", len(missing_ko) == 0, f"Missing: {missing_ko}")
        self.check(
            f"All /soc/ko drivers match kernel vermagic ({EXPECTED_VERMAGIC})",
            len(bad_vermagic) == 0,
            f"Mismatched vermagic: {bad_vermagic}"
        )

    def audit_kvmcomm_drivers(self):
        print("\n--- 3. KVMComm Kernel Modules & Rotary Encoder ---")
        kvmcomm_dir = self.path("kvmcomm/ko")
        self.check("/kvmcomm/ko directory exists", os.path.isdir(kvmcomm_dir))
        
        missing_ko = []
        bad_vermagic = []
        for ko in REQUIRED_KVMCOMM_KO:
            p = os.path.join(kvmcomm_dir, ko)
            if not os.path.isfile(p):
                missing_ko.append(ko)
            else:
                v = get_vermagic(p)
                if not v or not v.startswith(EXPECTED_VERMAGIC):
                    bad_vermagic.append((ko, v))

        self.check("All 7 required /kvmcomm/ko drivers present", len(missing_ko) == 0, f"Missing: {missing_ko}")
        self.check(
            f"All /kvmcomm/ko drivers match kernel vermagic ({EXPECTED_VERMAGIC})",
            len(bad_vermagic) == 0,
            f"Mismatched vermagic: {bad_vermagic}"
        )

    def audit_rotary_and_touch_pinmux(self):
        print("\n--- 4. Rotary Knob, Button & CST816 Touch Initialization ---")
        rc_local = self.path("etc/rc.local")
        self.check("/etc/rc.local exists", os.path.isfile(rc_local))
        if os.path.isfile(rc_local):
            mode = stat.S_IMODE(os.stat(rc_local).st_mode)
            self.check("/etc/rc.local is executable (0755)", (mode & 0o111) != 0, f"Current mode: {oct(mode)}")
            content = open(rc_local, "r", errors="ignore").read()
            self.check(
                "Rotary encoder devmem pinmux (0x10030028) present in /etc/rc.local",
                "0x10030028" in content,
                "Rotary knob will not function without pinmux!"
            )
            self.check(
                "auto_load_all_drv.sh invoked in /etc/rc.local",
                "auto_load_all_drv.sh" in content,
                "CST816 touch driver and Axera modules will not load!"
            )
            self.check(
                "Stale 192.168.100.200 IP removed from /etc/rc.local",
                "192.168.100.200" not in content
            )

        rc_service = "etc/systemd/system/multi-user.target.wants/rc-local.service"
        self.check("rc-local.service linked in multi-user.target.wants", self.exists_in_root(rc_service))

    def audit_wifi_subsystem(self):
        print("\n--- 5. Wi-Fi (AIC8800) Firmware & Automation ---")
        fw_dir = self.path("opt/firmware/aic8800")
        fw_count = len(os.listdir(fw_dir)) if os.path.isdir(fw_dir) else 0
        self.check("AIC8800 Wi-Fi/BT firmware present (>= 28 files)", fw_count >= 28, f"Found {fw_count} files")

        wifi_sh = self.path("opt/scripts/wifi.sh")
        self.check("/opt/scripts/wifi.sh exists", os.path.isfile(wifi_sh))
        if os.path.isfile(wifi_sh):
            content = open(wifi_sh, "r", errors="ignore").read()
            # Check for bad exit 1 when aic8800_fdrv already loaded
            bad_exit = re.search(r'aic8800_fdrv already loaded["\s\n]+exit 1', content)
            self.check("wifi.sh exits cleanly when aic8800_fdrv already loaded", not bad_exit, "Systemd restart loop hazard!")

        # Verify networking binaries
        for b in ["iptables", "wpa_supplicant", "wpa_cli", "udhcpc"]:
            has_b = any(self.exists_in_root(f"{p}/{b}") for p in ["sbin", "bin", "usr/sbin", "usr/bin"])
            self.check(f"Network tool '{b}' installed", has_b)

    def audit_daemons_and_ui(self):
        print("\n--- 6. NanoKVM-Server & Touchscreen UI ---")
        srv = self.path("kvmapp/server/NanoKVM-Server")
        self.check("NanoKVM-Server binary exists and is executable", os.path.isfile(srv) and os.access(srv, os.X_OK))

        web_assets = self.path("kvmapp/server/web/assets")
        has_assets = os.path.isdir(web_assets) and len(os.listdir(web_assets)) > 0
        self.check("NanoKVM Web UI assets built and populated", has_assets)

        kvm_ui = self.path("kvmcomm/ui/kvm_ui")
        self.check("kvm_ui touchscreen application binary exists", os.path.isfile(kvm_ui) and os.access(kvm_ui, os.X_OK))

        frameforge = self.path("kvmcomm/ui/frameforge")
        self.check("frameforge asset compiler binary exists", os.path.isfile(frameforge) and os.access(frameforge, os.X_OK))

        for hid in ["hid_keyboard.bin", "hid_mouse_abs.bin", "hid_mouse_rel.bin"]:
            self.check(f"Pre-generated HID descriptor '{hid}' present", os.path.isfile(self.path(f"kvmapp/scripts/{hid}")))

    def audit_systemd_boot_links(self):
        print("\n--- 7. Systemd Service Enablements & Collisions ---")
        wants = "etc/systemd/system/multi-user.target.wants"
        self.check("nanokvm.service enabled in boot targets", self.exists_in_root(f"{wants}/nanokvm.service"))
        self.check("kvmcomm.service enabled in boot targets", self.exists_in_root(f"{wants}/kvmcomm.service"))
        self.check("wifi.service enabled in boot targets", self.exists_in_root(f"{wants}/wifi.service"))
        
        # Prevent collisions
        nginx_wants = self.exists_in_root(f"{wants}/nginx.service")
        self.check("nginx.service disabled (prevents HTTP 80/443 collision)", not nginx_wants)

    def audit_storage_and_ssh(self):
        print("\n--- 8. Storage, U-Boot & OpenSSH Safeguards ---")
        fstab = self.path("etc/fstab")
        self.check("/etc/fstab exists", os.path.isfile(fstab))
        if os.path.isfile(fstab):
            content = open(fstab).read()
            self.check("/etc/fstab mounts /boot (mmcblk0p16)", "/boot" in content and "mmcblk0p16" in content)
        
        sshd_conf = self.exists_in_root("etc/tmpfiles.d/sshd.conf")
        self.check("OpenSSH tmpfiles.d rule configured (/run/sshd)", sshd_conf)

        journald_conf = self.exists_in_root("etc/systemd/journald.conf.d/00-volatile.conf")
        self.check("Volatile journald configured (eMMC flash write wear protection)", journald_conf)

        fw_printenv = any(self.exists_in_root(f"{p}/fw_printenv") for p in ["usr/bin", "sbin", "bin", "opt/swupdate/bin"])
        self.check("U-Boot env tool fw_printenv available", fw_printenv)


def audit_from_image(image_path):
    """Mount ext4 or AXP image and run audit."""
    mount_dir = tempfile.mkdtemp(prefix="nanokvm_parity_")
    cleanup_cmds = []

    def cleanup():
        for cmd in reversed(cleanup_cmds):
            subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if os.path.exists(mount_dir):
            try:
                os.rmdir(mount_dir)
            except Exception:
                pass

    atexit.register(cleanup)

    target_ext4 = image_path
    temp_extract = None

    if image_path.endswith(".axp"):
        print(f"[*] Extracting ubuntu_rootfs_sparse.ext4 from AXP: {image_path}")
        temp_extract = tempfile.mktemp(prefix="axp_sparse_", suffix=".ext4")
        temp_raw = tempfile.mktemp(prefix="axp_raw_", suffix=".ext4")
        unzip_cmd = f"unzip -p {image_path} ubuntu_rootfs_sparse.ext4 > {temp_extract}"
        subprocess.run(unzip_cmd, shell=True, check=True)
        subprocess.run(["simg2img", temp_extract, temp_raw], check=True)
        os.remove(temp_extract)
        target_ext4 = temp_raw
        cleanup_cmds.append(["rm", "-f", temp_raw])
    elif image_path.endswith(".ext4"):
        # Check if sparse
        test = subprocess.run(["file", image_path], capture_output=True, text=True)
        if "Android sparse image" in test.stdout:
            temp_raw = tempfile.mktemp(prefix="sparse_raw_", suffix=".ext4")
            subprocess.run(["simg2img", image_path, temp_raw], check=True)
            target_ext4 = temp_raw
            cleanup_cmds.append(["rm", "-f", temp_raw])

    # Mount read-only via loop
    subprocess.run(["mount", "-o", "loop,ro", target_ext4, mount_dir], check=True)
    cleanup_cmds.append(["umount", "-l", mount_dir])

    auditor = ParityAuditor(mount_dir)
    success = auditor.run_all_audits()
    cleanup()
    return success


def main():
    parser = argparse.ArgumentParser(description="NanoKVM-Pro Hardware & Rootfs Parity Verifier")
    parser.add_argument("target", help="Path to rootfs directory, .ext4 raw/sparse image, or .axp package")
    args = parser.parse_args()

    if not os.path.exists(args.target):
        print(f"[✗] Target not found: {args.target}")
        sys.exit(1)

    if os.path.isdir(args.target):
        auditor = ParityAuditor(args.target)
        success = auditor.run_all_audits()
    else:
        success = audit_from_image(args.target)

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
