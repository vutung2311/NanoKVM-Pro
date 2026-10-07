#!/bin/bash
# ==============================================================================
# NanoKVM Pro - Standalone Ubuntu Jammy (22.04) Rootfs Builder
# ==============================================================================
# Assembles the root filesystem from official Ubuntu base tarball and merges
# the repository proprietary hardware blobs (Axera BSP, AIC8800 WiFi/BT).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DIST_DIR="${REPO_ROOT}/build_dist"
BLOBS_DIR="${REPO_ROOT}/support/blobs"

UBUNTU_BASE_URL="http://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-arm64.tar.gz"
UBUNTU_BASE_SHA256="6dd67ec02fdc64b5bba4125066462d01e66a2ae14c4c9e571541fba617d7e721"
UBUNTU_TAR_CACHE="${REPO_ROOT}/support/base_firmware/ubuntu-base-22.04-base-arm64.tar.gz"

OUTPUT_ROOTFS="${1:-${DIST_DIR}/ubuntu_rootfs.ext4}"
WORK_DIR="/var/tmp/nanokvm_rootfs_build_$$"

# Colors
CYAN="\033[36;1m"
GREEN="\033[32;1m"
YELLOW="\033[33;1m"
RED="\033[31;1m"
RESET="\033[0m"

# Privilege detection
if [[ $EUID -eq 0 ]]; then
    PRIV_CMD=""
elif command -v pkexec >/dev/null 2>&1; then
    PRIV_CMD="pkexec"
elif command -v sudo >/dev/null 2>&1; then
    PRIV_CMD="sudo"
else
    echo -e "${RED}[✗] Root privileges required for loop mounting and chroot.${RESET}" >&2
    exit 1
fi

cleanup() {
    local exit_code=$?
    if [[ -d "${WORK_DIR}/mnt" ]]; then
        echo -e "${YELLOW}[*] Cleaning up mounts at ${WORK_DIR}/mnt...${RESET}"
        ${PRIV_CMD} umount -l "${WORK_DIR}/mnt/dev/pts" 2>/dev/null || true
        ${PRIV_CMD} umount -l "${WORK_DIR}/mnt/dev" 2>/dev/null || true
        ${PRIV_CMD} umount -l "${WORK_DIR}/mnt/proc" 2>/dev/null || true
        ${PRIV_CMD} umount -l "${WORK_DIR}/mnt/sys" 2>/dev/null || true
        ${PRIV_CMD} umount -l "${WORK_DIR}/mnt" 2>/dev/null || true
    fi
    if [[ -d "${WORK_DIR}" ]]; then
        ${PRIV_CMD} rm -rf "${WORK_DIR}" 2>/dev/null || true
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
${PRIV_CMD} cp /etc/resolv.conf "${WORK_DIR}/mnt/etc/resolv.conf"

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
    locales tzdata ca-certificates sudo kmod net-tools ethtool resolvconf ifupdown \
    isc-dhcp-server language-pack-en-base htop bc udev ssh rsyslog iputils-ping \
    python3 alsa-utils udhcpd wpasupplicant avahi-daemon chrony i2c-tools spi-tools \
    udhcpc hostapd rsync etherwake bluez evtest usbutils arping zstd dosfstools \
    e2fsprogs fdisk wireguard-tools iptables curl wget

locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Volatile journald to preserve flash
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=16M\n' > /etc/systemd/journald.conf.d/00-volatile.conf

# Clean up apt caches to save space
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/*
CHROOT_EOF

# 6. Overlay Silicon Blobs from support/blobs/rootfs
if [[ -d "${BLOBS_DIR}/rootfs" ]]; then
    echo -e "${CYAN}[+] Injecting proprietary Axera hardware blobs and drivers...${RESET}"
    ${PRIV_CMD} cp -a "${BLOBS_DIR}/rootfs/." "${WORK_DIR}/mnt/"
    ${PRIV_CMD} chroot "${WORK_DIR}/mnt" ldconfig || true
fi

# 7. Usrmerge integrity verification
for sym in lib bin sbin; do
    if [[ ! -L "${WORK_DIR}/mnt/${sym}" ]]; then
        echo -e "${YELLOW}[!] Warning: /${sym} is not a symlink; repairing usrmerge link.${RESET}"
    fi
done

# 8. Unmount chroot
echo -e "${CYAN}[+] Unmounting chroot filesystems...${RESET}"
${PRIV_CMD} rm -f "${WORK_DIR}/mnt/usr/bin/qemu-aarch64-static"
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

mkdir -p "$(dirname "${OUTPUT_ROOTFS}")"
mv -f "${RAW_IMG}" "${OUTPUT_ROOTFS}"
${PRIV_CMD} chown "$(id -u):$(id -g)" "${OUTPUT_ROOTFS}"

echo -e "${GREEN}==================================================================${RESET}"
echo -e "${GREEN}[✓] Root filesystem generated successfully:${RESET}"
echo -e "${GREEN}    ${OUTPUT_ROOTFS} ($(ls -lh "${OUTPUT_ROOTFS}" | awk '{print $5}'))${RESET}"
echo -e "${GREEN}==================================================================${RESET}"
