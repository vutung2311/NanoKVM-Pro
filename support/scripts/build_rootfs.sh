#!/bin/bash
# ==============================================================================
# NanoKVM Pro - Standalone Ubuntu Jammy (22.04) Rootfs Builder
# ==============================================================================
# Assembles the root filesystem from official Ubuntu base tarball and merges
# the repository proprietary hardware blobs (Axera BSP, AIC8800 WiFi/BT).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ORIG_PWD="$PWD"
DIST_DIR="${REPO_ROOT}/build_dist"
BLOBS_DIR="${REPO_ROOT}/support/blobs"
SDK_ROOTFS_DIR="${REPO_ROOT}/support/sdk/meta/build/projects/AX630C_emmc_arm64_k419_sipeed_nanokvm/rootfs"

UBUNTU_BASE_URL="http://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-arm64.tar.gz"
UBUNTU_BASE_SHA256="6dd67ec02fdc64b5bba4125066462d01e66a2ae14c4c9e571541fba617d7e721"
UBUNTU_TAR_CACHE="${REPO_ROOT}/support/base_firmware/ubuntu-base-22.04-base-arm64.tar.gz"
CACHED_ROOTFS="${REPO_ROOT}/support/base_firmware/ubuntu_rootfs.ext4"

OUTPUT_ROOTFS="${1:-${DIST_DIR}/ubuntu_rootfs.ext4}"
WORK_DIR="/var/tmp/nanokvm_rootfs_build_$$"

# Colors
CYAN="\033[36;1m"
GREEN="\033[32;1m"
YELLOW="\033[33;1m"
RED="\033[31;1m"
RESET="\033[0m"

# Elevate privileges ONCE at script start so user is only prompted once
if [[ $EUID -ne 0 ]]; then
    REAL_UID="${PKEXEC_UID:-${SUDO_UID:-$(id -u)}}"
    REAL_GID="${PKEXEC_GID:-${SUDO_GID:-$(id -g)}}"
    if command -v pkexec >/dev/null 2>&1; then
        echo -e "${YELLOW}[*] Elevated privileges required for rootfs loop mount and chroot.${RESET}"
        echo -e "${YELLOW}[*] Waiting for administrator authorization (pkexec)...${RESET}"
        exec pkexec env PKEXEC_UID="${REAL_UID}" PKEXEC_GID="${REAL_GID}" bash -c 'cd "$1" && shift && exec bash "$@"' bash "${ORIG_PWD}" "${SCRIPT_PATH}" "$@"
    elif command -v sudo >/dev/null 2>&1; then
        exec sudo env SUDO_UID="${REAL_UID}" SUDO_GID="${REAL_GID}" bash -c 'cd "$1" && shift && exec bash "$@"' bash "${ORIG_PWD}" "${SCRIPT_PATH}" "$@"
    elif command -v doas >/dev/null 2>&1; then
        exec doas env SUDO_UID="${REAL_UID}" SUDO_GID="${REAL_GID}" bash -c 'cd "$1" && shift && exec bash "$@"' bash "${ORIG_PWD}" "${SCRIPT_PATH}" "$@"
    else
        echo -e "${RED}[✗] Root privileges required for loop mounting and chroot.${RESET}" >&2
        exit 1
    fi
fi

REAL_UID="${PKEXEC_UID:-${SUDO_UID:-$(id -u)}}"
REAL_GID="${PKEXEC_GID:-${SUDO_GID:-$(id -g)}}"
PRIV_CMD=""

cleanup() {
    local exit_code=$?
    if [[ -d "${WORK_DIR}/mnt" ]]; then
        echo -e "${YELLOW}[*] Cleaning up mounts at ${WORK_DIR}/mnt...${RESET}"
        umount -l "${WORK_DIR}/mnt/dev/pts" 2>/dev/null || true
        umount -l "${WORK_DIR}/mnt/dev" 2>/dev/null || true
        umount -l "${WORK_DIR}/mnt/proc" 2>/dev/null || true
        umount -l "${WORK_DIR}/mnt/sys" 2>/dev/null || true
        umount -l "${WORK_DIR}/mnt" 2>/dev/null || true
    fi
    if [[ -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}" 2>/dev/null || true
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM

echo -e "${CYAN}==================================================================${RESET}"
echo -e "${CYAN}==> Building NanoKVM Pro Ubuntu 22.04 (arm64) Rootfs${RESET}"
echo -e "${CYAN}    Target: ${OUTPUT_ROOTFS}${RESET}"
echo -e "${CYAN}==================================================================${RESET}"

# 1. Fetch & Verify Ubuntu Base Tarball
mkdir -p "$(dirname "${UBUNTU_TAR_CACHE}")" "${DIST_DIR}"
if [[ ! -f "${UBUNTU_TAR_CACHE}" ]]; then
    echo -e "${CYAN}[+] Downloading pristine Ubuntu Jammy 22.04 base tarball...${RESET}"
    curl -L -f --progress-bar -o "${UBUNTU_TAR_CACHE}" "${UBUNTU_BASE_URL}"
fi

echo -e "${CYAN}[+] Verifying SHA256 checksum...${RESET}"
ACTUAL_SHA=$(sha256sum "${UBUNTU_TAR_CACHE}" | awk '{print $1}')
if [[ "${ACTUAL_SHA}" != "${UBUNTU_BASE_SHA256}" ]]; then
    echo -e "${RED}[✗] Checksum mismatch! Corrupt download. Removing cache.${RESET}" >&2
    rm -f "${UBUNTU_TAR_CACHE}"
    exit 1
fi
echo -e "${GREEN}[✓] Ubuntu base archive verified.${RESET}"

# 2. Check QEMU static emulator
QEMU_STATIC=$(command -v qemu-aarch64-static || echo "/usr/bin/qemu-aarch64-static")
if [[ ! -x "${QEMU_STATIC}" ]]; then
    echo -e "${RED}[✗] qemu-aarch64-static not found! Install with: make setup-tooling${RESET}" >&2
    exit 1
fi

# 3. Create raw ext4 filesystem (4.5 GB)
mkdir -p "${WORK_DIR}/mnt"
RAW_IMG="${WORK_DIR}/rootfs.ext4"
echo -e "${CYAN}[+] Creating empty 4.5 GB ext4 filesystem image...${RESET}"
dd if=/dev/zero of="${RAW_IMG}" bs=1M count=4608 status=none
mkfs.ext4 -F -L "rootfs" -O ^metadata_csum "${RAW_IMG}" >/dev/null

echo -e "${CYAN}[+] Mounting rootfs image...${RESET}"
${PRIV_CMD} mount -o loop "${RAW_IMG}" "${WORK_DIR}/mnt"

echo -e "${CYAN}[+] Unpacking Ubuntu base tarball...${RESET}"
${PRIV_CMD} tar -zxf "${UBUNTU_TAR_CACHE}" -C "${WORK_DIR}/mnt"

# 4. Bind kernel filesystems and set up QEMU chroot
echo -e "${CYAN}[+] Configuring chroot environment...${RESET}"
${PRIV_CMD} cp "${QEMU_STATIC}" "${WORK_DIR}/mnt/usr/bin/qemu-aarch64-static"

# Set up upstream nameservers (avoiding 127.0.0.53 stub-resolver from host systemd-resolved)
${PRIV_CMD} rm -f "${WORK_DIR}/mnt/etc/resolv.conf"
{
    if [[ -f /run/systemd/resolve/resolv.conf ]]; then
        grep '^nameserver' /run/systemd/resolve/resolv.conf | grep -v '127\.' || true
    fi
    echo "nameserver 1.1.1.1"
    echo "nameserver 8.8.8.8"
} | ${PRIV_CMD} tee "${WORK_DIR}/mnt/etc/resolv.conf" >/dev/null

# Ensure ports.ubuntu.com fallback in /etc/hosts to prevent transient DNS failures
${PRIV_CMD} bash -c "grep -q 'ports.ubuntu.com' '${WORK_DIR}/mnt/etc/hosts' 2>/dev/null || printf '\n91.189.91.102 ports.ubuntu.com\n91.189.91.104 ports.ubuntu.com\n' >> '${WORK_DIR}/mnt/etc/hosts'"

${PRIV_CMD} mount -t proc proc "${WORK_DIR}/mnt/proc"
${PRIV_CMD} mount -t sysfs sysfs "${WORK_DIR}/mnt/sys"
${PRIV_CMD} mount -t devtmpfs devtmpfs "${WORK_DIR}/mnt/dev"
${PRIV_CMD} mkdir -p "${WORK_DIR}/mnt/dev/pts"
${PRIV_CMD} mount -t devpts devpts "${WORK_DIR}/mnt/dev/pts"

# 5. Execute APT package installs in chroot
echo -e "${CYAN}[+] Installing base packages inside ARM64 chroot...${RESET}"
${PRIV_CMD} chroot "${WORK_DIR}/mnt" /bin/bash << 'CHROOT_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# Use official Ubuntu ports
sed -i 's@http://archive.ubuntu.com/ubuntu/@http://ports.ubuntu.com/ubuntu-ports/@g' /etc/apt/sources.list || true

apt-get update -o Acquire::ForceIPv4=true
apt-get install -y --no-install-recommends \
    systemd systemd-sysv libpam-systemd libnss-systemd dbus dbus-user-session \
    locales tzdata ca-certificates sudo kmod net-tools ethtool resolvconf ifupdown \
    isc-dhcp-server language-pack-en-base htop bc udev ssh rsyslog iputils-ping \
    python3 alsa-utils udhcpd wpasupplicant avahi-daemon chrony i2c-tools spi-tools \
    udhcpc hostapd rsync etherwake bluez evtest usbutils arping arp-scan zstd dosfstools \
    e2fsprogs fdisk wireguard-tools iptables curl wget nano vim-tiny networkd-dispatcher cron dnsmasq-base

# Set default root credentials and hostname
# Root password must match what reset_to_default.sh restores (stock Sipeed default),
# so a factory reset returns the device to the same credentials it shipped with.
echo "root:sipeed" | chpasswd
echo "kvm" > /etc/hostname
grep -q "127.0.1.1" /etc/hosts 2>/dev/null || printf "127.0.1.1\tkvm\n" >> /etc/hosts

# Ensure /etc/fstab contains the proper AX630C filesystem table
cat << 'FSTAB_EOF' > /etc/fstab
# <file system>	<mount pt>	<type>	<options>	<dump>	<pass>
/dev/root	/		ext4	rw,noatime,nodiratime,errors=remount-ro	0	1
proc		/proc		proc	defaults	0	0
devpts		/dev/pts	devpts	defaults,gid=5,mode=620,ptmxmode=0666	0	0
tmpfs		/dev/shm	tmpfs	mode=1777,nosuid,nodev	0	0
tmpfs		/tmp		tmpfs	mode=1777,nosuid,nodev	0	0
tmpfs		/run		tmpfs	mode=0755,nosuid,nodev	0	0
sysfs		/sys		sysfs	defaults	0	0
/dev/mmcblk0p16	/boot		vfat	defaults,umask=000,utf8=true	0	0
FSTAB_EOF

# OpenSSH PrivSep safeguard (prevents sshd startup failures on boot tmpfs /run)
mkdir -p /etc/tmpfiles.d && echo 'd /run/sshd 0755 root root -' > /etc/tmpfiles.d/sshd.conf
mkdir -p /etc/systemd/system/ssh.service.d
cat << 'SSH_CONF_EOF' > /etc/systemd/system/ssh.service.d/override.conf
[Unit]
Description=OpenBSD Secure Shell server

[Service]
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
ExecStartPre=/bin/mkdir -p -m 0755 /run/sshd
SSH_CONF_EOF

# The web UI's "change password" sets the root password; Ubuntu's default
# PermitRootLogin prohibit-password would make sshd reject it outright.
# Keep in sync with kvmcomm/overlay/etc/ssh/sshd_config.d/10-nanokvm.conf.
mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/10-nanokvm.conf

locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Volatile journald to preserve flash
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=16M\n' > /etc/systemd/journald.conf.d/00-volatile.conf

# Delegate eth0 dynamically to ifplugd on physical cable carrier, preventing boot dhclient loops
sed -i '/allow-hotplug eth0/d' /etc/network/interfaces 2>/dev/null || true

# Clean up apt caches to save space
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/*
CHROOT_EOF

# 6. Overlay Silicon Blobs and Sipeed Board Services
if [[ -d "${SDK_ROOTFS_DIR}" ]]; then
    echo -e "${CYAN}[+] Merging Sipeed AX630C NanoKVM board rootfs overlay...${RESET}"
    ${PRIV_CMD} cp -a "${SDK_ROOTFS_DIR}/." "${WORK_DIR}/mnt/"
fi

if [[ -d "${BLOBS_DIR}/rootfs" ]]; then
    echo -e "${CYAN}[+] Injecting proprietary Axera hardware blobs and drivers...${RESET}"
    ${PRIV_CMD} cp -a "${BLOBS_DIR}/rootfs/." "${WORK_DIR}/mnt/"
    ${PRIV_CMD} sed -i '/192\.168\.100\.200/d' "${WORK_DIR}/mnt/etc/rc.local" 2>/dev/null || true
    ${PRIV_CMD} chmod 0755 "${WORK_DIR}/mnt/etc/rc.local" 2>/dev/null || true
    ${PRIV_CMD} chown 0:0 "${WORK_DIR}/mnt/etc/rc.local" 2>/dev/null || true
    ${PRIV_CMD} mkdir -p "${WORK_DIR}/mnt/etc/systemd/system/multi-user.target.wants"
    ${PRIV_CMD} ln -sf /lib/systemd/system/rc-local.service "${WORK_DIR}/mnt/etc/systemd/system/multi-user.target.wants/rc-local.service"
    if [[ -f "${WORK_DIR}/mnt/opt/swupdate/bin/fw_printenv" ]]; then
        ${PRIV_CMD} ln -sf /opt/swupdate/bin/fw_printenv "${WORK_DIR}/mnt/usr/bin/fw_printenv"
        ${PRIV_CMD} ln -sf fw_printenv "${WORK_DIR}/mnt/usr/bin/fw_setenv"
    fi
    ${PRIV_CMD} chroot "${WORK_DIR}/mnt" ldconfig || true
fi

# 7. Usrmerge and Init link verification
for sym in lib bin sbin; do
    if [[ ! -L "${WORK_DIR}/mnt/${sym}" ]]; then
        echo -e "${YELLOW}[!] Warning: /${sym} is not a symlink; repairing usrmerge link.${RESET}"
    fi
done

if [[ ! -e "${WORK_DIR}/mnt/sbin/init" && ! -L "${WORK_DIR}/mnt/sbin/init" ]]; then
    echo -e "${CYAN}[+] Establishing /sbin/init -> /lib/systemd/systemd symlink...${RESET}"
    ${PRIV_CMD} ln -sf /lib/systemd/systemd "${WORK_DIR}/mnt/sbin/init"
fi

# 8. Unmount chroot
echo -e "${CYAN}[+] Unmounting chroot filesystems...${RESET}"
${PRIV_CMD} rm -f "${WORK_DIR}/mnt/usr/bin/qemu-aarch64-static"
${PRIV_CMD} rm -f "${WORK_DIR}/mnt/etc/resolv.conf"
${PRIV_CMD} ln -sf ../run/systemd/resolve/stub-resolv.conf "${WORK_DIR}/mnt/etc/resolv.conf"
${PRIV_CMD} umount -l "${WORK_DIR}/mnt/dev/pts"
${PRIV_CMD} umount -l "${WORK_DIR}/mnt/dev"
${PRIV_CMD} umount -l "${WORK_DIR}/mnt/proc"
${PRIV_CMD} umount -l "${WORK_DIR}/mnt/sys"
${PRIV_CMD} umount -l "${WORK_DIR}/mnt"

# 9. Filesystem check & move to destination
echo -e "${CYAN}[+] Checking filesystem integrity and zeroing free space...${RESET}"
${PRIV_CMD} e2fsck -fy "${RAW_IMG}" || true
${PRIV_CMD} resize2fs -M "${RAW_IMG}" || true
${PRIV_CMD} resize2fs "${RAW_IMG}" 4500M || true

mkdir -p "$(dirname "${OUTPUT_ROOTFS}")" "$(dirname "${CACHED_ROOTFS}")"
mv -f "${RAW_IMG}" "${OUTPUT_ROOTFS}"
chown "${REAL_UID}:${REAL_GID}" "${OUTPUT_ROOTFS}"

# Keep persistent rootfs cache updated for future builds
if [[ "$(realpath "${OUTPUT_ROOTFS}")" != "$(realpath "${CACHED_ROOTFS}" 2>/dev/null || echo "")" ]]; then
    echo -e "${CYAN}[+] Updating persistent rootfs cache at ${CACHED_ROOTFS}...${RESET}"
    cp --sparse=always -f "${OUTPUT_ROOTFS}" "${CACHED_ROOTFS}"
    chown "${REAL_UID}:${REAL_GID}" "${CACHED_ROOTFS}" 2>/dev/null || true
fi

echo -e "${GREEN}==================================================================${RESET}"
echo -e "${GREEN}[✓] Root filesystem generated successfully:${RESET}"
echo -e "${GREEN}    ${OUTPUT_ROOTFS} ($(ls -lh "${OUTPUT_ROOTFS}" | awk '{print $5}'))${RESET}"
echo -e "${GREEN}==================================================================${RESET}"
