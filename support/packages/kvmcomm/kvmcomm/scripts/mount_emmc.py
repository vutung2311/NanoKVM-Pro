#!/usr/bin/env python3

import subprocess
import sys
import argparse
import os
import glob
import dbus

debug = False
DATA_DIR = "/data"
DEFAULT_IMAGE = "/exfat.img"
# Same options as data.mount, but read-only.
DATA_RO_OPTIONS = "ro,relatime,fmask=0022,dmask=0022,iocharset=utf8"

def log(*args, **kwargs):
    if debug:
        print(*args, **kwargs)

def run(cmd, check=True, timeout=None):
    log(f"[RUN] {cmd}")
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout
        )

        if debug:
            if result.stdout:
                log("[STDOUT]", result.stdout.strip())
            if result.stderr:
                log("[STDERR]", result.stderr.strip())

        if check and result.returncode != 0:
            log(f"[ERROR] Command failed: {cmd}")
            log(f"Exit code: {result.returncode}")
            if result.stderr:
                log(f"Error message: {result.stderr.strip()}")
            return result.returncode

        return result.returncode

    except subprocess.TimeoutExpired as e:
        log(f"[TIMEOUT] {cmd} exceeded {timeout}s")
        return -1

def check_exfatprogs():
    try:
        subprocess.run(["mkfs.exfat", "-v"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except FileNotFoundError:
        log("exfatprogs not found.")
        return False

def install_exfatprogs():
    log("Downloading exfatprogs package...")
    deb_url = "https://ports.ubuntu.com/ubuntu-ports/pool/universe/e/exfatprogs/exfatprogs_1.1.3-1ubuntu0.1_arm64.deb"
    deb_file = "/tmp/exfatprogs.deb"

    download_result = run(f"wget --retry-connrefused --tries=10 --timeout=3 -4 -O {deb_file} {deb_url}", check=False, timeout=60)
    if download_result != 0:
        log("ERROR: Failed to download exfatprogs package.")
        log("Please download manually from:")
        log(f"  {deb_url}")
        log("Then install with: dpkg -i /tmp/exfatprogs.deb")
        log("And re-run this script.")
        sys.exit(1)

    log("Installing exfatprogs package...")
    install_result = run(f"dpkg -i {deb_file}", check=False, timeout=30)
    if install_result != 0:
        log("ERROR: Failed to install exfatprogs package.")
        sys.exit(1)

    run(f"rm -f {deb_file}", check=False)

    if not check_exfatprogs():
        log("ERROR: exfatprogs installation verification failed.")
        sys.exit(1)
    log("exfatprogs installed successfully.")

def exported_to_host(path):
    """True if a USB mass-storage LUN currently serves `path` to the host."""
    target = os.path.realpath(path)
    for lun_file in glob.glob("/sys/kernel/config/usb_gadget/*/functions/mass_storage.*/lun.*/file"):
        try:
            with open(lun_file) as f:
                backing = f.read().strip()
        except OSError:
            continue
        if backing and os.path.realpath(backing) == target:
            return True
    return False


def mount_data_read_only(img_file=DEFAULT_IMAGE):
    """Mount the image on /data without ever opening it read-write.

    The host owns the image while it is exported; even a brief rw mount
    writes the exFAT volume-dirty flag into a filesystem the host has open.
    """
    if os.path.ismount(DATA_DIR):
        return run(f"mount -o remount,ro {DATA_DIR}", check=False) == 0
    os.makedirs(DATA_DIR, exist_ok=True)
    return run(f"mount -t exfat -o {DATA_RO_OPTIONS} {img_file} {DATA_DIR}", check=False) == 0


def manage_data_mount(action):
    bus = dbus.SystemBus()
    systemd = bus.get_object('org.freedesktop.systemd1', '/org/freedesktop/systemd1')
    mgr = dbus.Interface(systemd, 'org.freedesktop.systemd1.Manager')

    if action == 'enable':
        mgr.EnableUnitFiles(['data.mount'], False, False)
        if exported_to_host(DEFAULT_IMAGE):
            if mount_data_read_only():
                log("Image is exported to the host; mounted /data read-only")
            else:
                log("Image is exported to the host; failed to mount /data read-only")
            return
        mgr.StartUnit('data.mount', 'replace')
        log("Enabled and started data.mount")
    elif action == 'disable':
        mgr.StopUnit('data.mount', 'replace')
        mgr.DisableUnitFiles(['data.mount'], False)
        log("Disabled and stopped data.mount")
    else:
        log("Invalid action. Use 'enable' or 'disable'.")

def clear_data_directory():
    data_dir = "/data"
    if os.path.exists(data_dir):
        import shutil
        for item in os.listdir(data_dir):
            item_path = os.path.join(data_dir, item)
            try:
                if os.path.isfile(item_path) or os.path.islink(item_path):
                    os.unlink(item_path)
                elif os.path.isdir(item_path):
                    shutil.rmtree(item_path)
            except Exception as e:
                log(f"Failed to remove {item_path}: {e}")
        log("Cleared /data directory.")
    else:
        log("/data directory does not exist.")

def create_exfat_image(img_file="exfat.img", size_mb=500):
    size_bytes = size_mb * 1024 * 1024
    log(f"Creating {size_mb}MB exFAT image: {img_file}")
    try:
        with open(img_file, 'wb') as f:
            os.ftruncate(f.fileno(), size_bytes)
    except Exception as e:
        log(f"Failed to create file: {e}")
        sys.exit(1)
    run(f"mkfs.exfat {img_file}")
    log(f"exFAT image {img_file} created successfully.")

def default_image_size_mb():
    """Image size for `start`: free space minus a 5 GiB reserve; exits if too small."""
    result = None
    try:
        result = subprocess.run(
            "df -BM /dev/mmcblk0p17 | tail -1 | awk '{print $4}'",
            shell=True, capture_output=True, text=True, check=True
        )
        available_mb = int(result.stdout.strip().replace('M', ''))
    except subprocess.CalledProcessError as e:
        log(f"[ERROR] Failed to check disk space: {e}")
        sys.exit(1)
    except ValueError:
        log(f"[ERROR] Failed to parse disk space output: '{result.stdout.strip() if result else ''}'")
        sys.exit(1)

    min_required_mb = 5120
    default_size = available_mb - 5120
    if default_size < min_required_mb:
        log(f"[ERROR] Not enough free space on /dev/mmcblk0p17: available {available_mb}MB")
        sys.exit(1)
    return default_size


def main():
    # The free-space check belongs to `start` only (it sizes a new image).
    # Run up front, a full disk made `stop` and `remove` fail as well.
    parser = argparse.ArgumentParser(description="Manage exFAT image creation.")
    subparsers = parser.add_subparsers(dest='command', required=True, help='Available commands')

    start_parser = subparsers.add_parser('start', help='Create exFAT image and clear data directory')
    start_parser.add_argument('--size', type=int, default=None, help='Size of the image in MB (default: free space minus 5 GiB)')
    start_parser.add_argument('--file', default='/exfat.img', help='Output image file name (default: /exfat.img)')
    start_parser.add_argument('--debug', action='store_true', help='Enable debug output')
    stop_parser = subparsers.add_parser('stop', help='Clear data directory')
    stop_parser.add_argument('--debug', action='store_true', help='Enable debug output')
    restart_parser = subparsers.add_parser('restart', help='Restart data mount')
    restart_parser.add_argument('--debug', action='store_true', help='Enable debug output')
    remove_parser = subparsers.add_parser('remove', help='Remove exFAT image and disable mount')
    remove_parser.add_argument('--file', default='/exfat.img', help='Image file name to remove (default: /exfat.img)')
    remove_parser.add_argument('--debug', action='store_true', help='Enable debug output')

    args = parser.parse_args()
    global debug
    debug = args.debug

    if args.command == 'start':
        if not os.path.exists(args.file):
            size = args.size if args.size is not None else default_image_size_mb()
            if not check_exfatprogs():
                install_exfatprogs()
            create_exfat_image(img_file=args.file, size_mb=size)
            clear_data_directory()
        manage_data_mount('enable')

    elif args.command == 'stop':
        manage_data_mount('disable')

    elif args.command == 'restart':
        manage_data_mount('disable')
        manage_data_mount('enable')

    elif args.command == 'remove':
        if exported_to_host(args.file):
            # Deleting it now would leave the host writing to an unlinked file.
            print(f"{args.file} is exported to the host; detach the USB disk first", file=sys.stderr)
            sys.exit(1)
        manage_data_mount('disable')
        if os.path.exists(args.file):
            os.remove(args.file)

if __name__ == "__main__":
    main()
