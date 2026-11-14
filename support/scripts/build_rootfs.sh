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

# Marker appended to temporary build-time /etc/hosts entries so they can be stripped before shipping
HOSTS_TMP_MARKER="# nanokvm-build-tmp"

# Chroot mount points, innermost first (unmount order)
CHROOT_MOUNTS=(dev/pts dev/shm dev proc sys)

# List every mount point at or below a path (empty output = nothing mounted).
# Fails closed: if the mount table cannot be read, report the path itself as mounted.
mounts_under() {
    if [[ ! -r /proc/self/mounts ]]; then
        echo "$1 (mount table unreadable)"
        return 0
    fi
    awk -v p="$1" '$2 == p || index($2, p "/") == 1 { print $2 }' /proc/self/mounts
}

# Unmount one path non-lazily, retrying while it is busy. Returns non-zero if it stays mounted.
umount_retry() {
    local target="$1" i
    mountpoint -q "${target}" || return 0
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if umount "${target}" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    echo -e "${RED}[✗] Failed to unmount ${target} after ${i} attempts.${RESET}" >&2
    return 1
}

unmount_chroot() {
    local rc=0 m
    for m in "${CHROOT_MOUNTS[@]}"; do
        umount_retry "${WORK_DIR}/mnt/${m}" || rc=1
    done
    sync
    umount_retry "${WORK_DIR}/mnt" || rc=1
    return $rc
}

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    set +e
    if [[ -d "${WORK_DIR}/mnt" ]]; then
        echo -e "${YELLOW}[*] Cleaning up mounts at ${WORK_DIR}/mnt...${RESET}"
        unmount_chroot
    fi
    if [[ -d "${WORK_DIR}" ]]; then
        local remaining
        remaining="$(mounts_under "${WORK_DIR}")"
        if [[ -n "${remaining}" ]]; then
            # Never recurse into a live mount (proc/sys/dev or the image): leave the tree for manual cleanup.
            echo -e "${RED}[✗] Refusing to delete ${WORK_DIR}: still mounted:${RESET}" >&2
            echo "${remaining}" >&2
            echo -e "${RED}    Unmount these manually, then remove ${WORK_DIR}.${RESET}" >&2
            [[ $exit_code -eq 0 ]] && exit_code=1
        else
            rm -rf --one-file-system "${WORK_DIR}"
        fi
    fi
    exit "$exit_code"
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

# Build-time-only ports.ubuntu.com fallback in /etc/hosts to ride out transient DNS failures.
# Tagged with HOSTS_TMP_MARKER and stripped again in step 8 so it never ships on the device.
if ! grep -q 'ports.ubuntu.com' "${WORK_DIR}/mnt/etc/hosts" 2>/dev/null; then
    # Terminate a last line lacking '\n' so the tagged entries (and their later removal) stay separate
    if [[ -s "${WORK_DIR}/mnt/etc/hosts" && -n "$(tail -c1 "${WORK_DIR}/mnt/etc/hosts")" ]]; then
        echo | ${PRIV_CMD} tee -a "${WORK_DIR}/mnt/etc/hosts" >/dev/null
    fi
    printf '91.189.91.102 ports.ubuntu.com %s\n91.189.91.104 ports.ubuntu.com %s\n' \
        "${HOSTS_TMP_MARKER}" "${HOSTS_TMP_MARKER}" | ${PRIV_CMD} tee -a "${WORK_DIR}/mnt/etc/hosts" >/dev/null
fi

${PRIV_CMD} mount -t proc proc "${WORK_DIR}/mnt/proc"
${PRIV_CMD} mount -t sysfs -o ro sysfs "${WORK_DIR}/mnt/sys"
# Private /dev: a fresh tmpfs with only the nodes apt/dpkg need, so the chroot never shares
# (and cleanup can never recurse into) the host's devtmpfs.
${PRIV_CMD} mount -t tmpfs -o mode=0755,nosuid,size=16M devtmpfs-private "${WORK_DIR}/mnt/dev"
(
    cd "${WORK_DIR}/mnt/dev"
    mknod -m 0666 null    c 1 3
    mknod -m 0666 zero    c 1 5
    mknod -m 0666 full    c 1 7
    mknod -m 0666 random  c 1 8
    mknod -m 0666 urandom c 1 9
    mknod -m 0666 tty     c 5 0
    ln -s /proc/self/fd   fd
    ln -s /proc/self/fd/0 stdin
    ln -s /proc/self/fd/1 stdout
    ln -s /proc/self/fd/2 stderr
    ln -s pts/ptmx        ptmx
    mkdir -m 0755 pts
    mkdir -m 1777 shm
)
${PRIV_CMD} mount -t devpts -o newinstance,ptmxmode=0666,mode=0620,gid=5 devpts "${WORK_DIR}/mnt/dev/pts"
${PRIV_CMD} mount -t tmpfs -o mode=1777,nosuid,nodev shm "${WORK_DIR}/mnt/dev/shm"

# Keep maintainer scripts from starting services (sshd, dnsmasq, ifplugd, ...) inside the chroot
printf '#!/bin/sh\nexit 101\n' | ${PRIV_CMD} tee "${WORK_DIR}/mnt/usr/sbin/policy-rc.d" >/dev/null
${PRIV_CMD} chmod 0755 "${WORK_DIR}/mnt/usr/sbin/policy-rc.d"

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
    e2fsprogs fdisk wireguard-tools iptables curl wget nano vim-tiny networkd-dispatcher cron dnsmasq-base \
    ifplugd isc-dhcp-client

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

# Delegate eth0 dynamically to ifplugd on physical cable carrier, preventing boot dhclient loops.
# Only when ifplugd is actually present; otherwise ifupdown must keep bringing eth0 up.
if [ -x /usr/sbin/ifplugd ]; then
    sed -i '/allow-hotplug eth0/d' /etc/network/interfaces 2>/dev/null || true
fi

# Clean up apt caches to save space
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/*
CHROOT_EOF

# apt phase done: allow services to start normally on the device
${PRIV_CMD} rm -f "${WORK_DIR}/mnt/usr/sbin/policy-rc.d"

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
    # fw_printenv/fw_setenv need the bundled libubootenv in /opt/swupdate/lib. Use per-command
    # wrappers instead of /etc/ld.so.conf.d: that directory also carries vendor libcurl/libz,
    # which must not override the system copies for every other program.
    SWU_BIN="${WORK_DIR}/mnt/opt/swupdate/bin"
    if [[ -f "${SWU_BIN}/fw_printenv" ]]; then
        if [[ ! -e "${SWU_BIN}/fw_setenv" ]]; then
            # libubootenv's tool picks printenv/setenv mode from argv[0]
            ${PRIV_CMD} ln -s fw_printenv "${SWU_BIN}/fw_setenv"
        fi
        for tool in fw_printenv fw_setenv; do
            # rm first: writing through an existing symlink would clobber the vendor binary
            ${PRIV_CMD} rm -f "${WORK_DIR}/mnt/usr/bin/${tool}"
            # shellcheck disable=SC2016 # expanded on the device, not here
            printf '#!/bin/sh\nLD_LIBRARY_PATH=/opt/swupdate/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} exec /opt/swupdate/bin/%s "$@"\n' "${tool}" \
                | ${PRIV_CMD} tee "${WORK_DIR}/mnt/usr/bin/${tool}" >/dev/null
            ${PRIV_CMD} chmod 0755 "${WORK_DIR}/mnt/usr/bin/${tool}"
        done
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
# Strip the build-time ports.ubuntu.com pins so they do not ship on the device
${PRIV_CMD} sed -i "/${HOSTS_TMP_MARKER}\$/d" "${WORK_DIR}/mnt/etc/hosts"
${PRIV_CMD} rm -f "${WORK_DIR}/mnt/usr/sbin/policy-rc.d"
sync
if ! unmount_chroot; then
    echo -e "${RED}[✗] Could not cleanly unmount the rootfs image; refusing to fsck/ship it.${RESET}" >&2
    exit 1
fi

# 9. Filesystem check & move to destination
echo -e "${CYAN}[+] Checking filesystem integrity and shrinking/regrowing the image...${RESET}"
# e2fsck: 0 = clean, 1 = errors corrected; anything else means the image is not trustworthy
fsck_rc=0
${PRIV_CMD} e2fsck -fy "${RAW_IMG}" || fsck_rc=$?
if [[ ${fsck_rc} -gt 1 ]]; then
    echo -e "${RED}[✗] e2fsck failed on ${RAW_IMG} (exit ${fsck_rc}).${RESET}" >&2
    exit 1
fi
${PRIV_CMD} resize2fs -M "${RAW_IMG}"
${PRIV_CMD} resize2fs "${RAW_IMG}" 4500M

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
