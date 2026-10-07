#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# NanoKVM-Pro In-System Firmware Package Builder & Flasher
# Produces: axera_firmware_v<VERSION>.tar.xz
# Compatible with: WebUI manual update, REST API, /kvmcomm/scripts/firmware_update.sh
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." &>/dev/null && pwd -P)"

SUPPORT_DIR="${REPO_ROOT}/support"
KERNEL_DIR="${SUPPORT_DIR}/kernel"
LINUX_SRC="${KERNEL_DIR}/linux/linux-4.19.125"
BASE_FIRMWARE_DIR="${SUPPORT_DIR}/base_firmware"
BASE_AXP="${BASE_FIRMWARE_DIR}/20260529_NanoKVMPro_1_0_15.axp"
OVERLAY_DIR="${SUPPORT_DIR}/scripts/build_image/overlay"
DIST_DIR="${REPO_ROOT}/build_dist"

SIGNED_BOOT="${KERNEL_DIR}/boot_signed.bin"
SIGNED_DTB="${KERNEL_DIR}/AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb"

VERSION="${VERSION:-1.2.15}"
OUTPUT_TAR="${DIST_DIR}/axera_firmware_v${VERSION}.tar.xz"

# ANSI Colors
RED="\033[31;1m"
GREEN="\033[32;1m"
YELLOW="\033[33;1m"
CYAN="\033[36;1m"
RESET="\033[0m"

get_kernel_release() {
    bash "${SCRIPT_DIR}/build_kernel.sh" kver
}

build_firmware_package() {
    local out_tar="${1:-${OUTPUT_TAR}}"
    local kver
    kver=$(get_kernel_release)
    local build_date
    build_date=$(date +"%Y-%m-%d")

    echo -e "${CYAN}==================================================================${RESET}"
    echo -e "${CYAN}==> Packaging In-System Firmware Update: axera_firmware_v${VERSION}.tar.xz${RESET}"
    echo -e "${CYAN}    Kernel Version: ${kver} | Build Date: ${build_date}${RESET}"
    echo -e "${CYAN}==================================================================${RESET}"

    # Locate or build signed kernel artifacts
    if [[ ! -f "${SIGNED_BOOT}" && -f "${DIST_DIR}/boot_signed.bin" ]]; then
        SIGNED_BOOT="${DIST_DIR}/boot_signed.bin"
    fi
    if [[ ! -f "${SIGNED_DTB}" && -f "${DIST_DIR}/AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb" ]]; then
        SIGNED_DTB="${DIST_DIR}/AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb"
    fi

    if [[ ! -f "${SIGNED_BOOT}" || ! -f "${SIGNED_DTB}" ]]; then
        echo -e "${YELLOW}[!] Signed kernel artifacts missing. Building kernel first...${RESET}"
        bash "${SCRIPT_DIR}/build_kernel.sh" build
        # Re-check locations after build
        [[ -f "${SIGNED_BOOT}" ]] || SIGNED_BOOT="${DIST_DIR}/boot_signed.bin"
        [[ -f "${SIGNED_DTB}" ]] || SIGNED_DTB="${DIST_DIR}/AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb"
    fi

    if [[ ! -f "${SIGNED_BOOT}" || ! -f "${SIGNED_DTB}" ]]; then
        echo -e "${RED}[✗] Kernel build failed to produce signed artifacts.${RESET}" >&2
        exit 1
    fi

    if [[ ! -f "${BASE_AXP}" ]]; then
        echo -e "${YELLOW}[!] Base AXP not found at: ${BASE_AXP}. Fetching base firmware...${RESET}"
        make -C "${REPO_ROOT}" fetch-base
    fi

    local stage_dir
    stage_dir=$(mktemp -d -t nanokvm_fw_pkg_XXXXXX)
    mkdir -p "${stage_dir}/firmware" "${stage_dir}/overlay/boot"

    # 1. Stage Firmware Binaries
    echo -e "${CYAN}[+] Staging signed kernel, DTB, and extracting U-Boot...${RESET}"
    cp -f "${SIGNED_BOOT}" "${stage_dir}/firmware/boot_signed.bin"
    cp -f "${SIGNED_DTB}" "${stage_dir}/firmware/AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb"

    # Extract U-Boot using Python zipfile (independent of host unzip utility)
    python3 -c "
import zipfile, sys
with zipfile.ZipFile('${BASE_AXP}') as z:
    with open('${stage_dir}/firmware/u-boot_signed.bin', 'wb') as f:
        f.write(z.read('u-boot_signed.bin'))
"
    if [[ ! -s "${stage_dir}/firmware/u-boot_signed.bin" ]]; then
        echo -e "${RED}[✗] Failed to extract u-boot_signed.bin from base AXP.${RESET}" >&2
        rm -rf "${stage_dir}"
        exit 1
    fi

    # 2. Stage Version & Boot Overlay
    echo -e "${CYAN}[+] Staging rootfs overlay and version metadata...${RESET}"
    if [[ -d "${OVERLAY_DIR}/boot" ]]; then
        cp -af "${OVERLAY_DIR}/boot"/* "${stage_dir}/overlay/boot/" 2>/dev/null || true
    fi
    echo "nanokvm-pro-${build_date}-v${VERSION}" > "${stage_dir}/overlay/boot/ver"

    # Sync custom scripts and web/server assets from overlay dir if present
    if [[ -d "${OVERLAY_DIR}/kvmcomm" ]]; then
        mkdir -p "${stage_dir}/overlay/kvmcomm"
        cp -af "${OVERLAY_DIR}/kvmcomm"/* "${stage_dir}/overlay/kvmcomm/" 2>/dev/null || true
    fi
    if [[ -d "${OVERLAY_DIR}/kvmapp" ]]; then
        mkdir -p "${stage_dir}/overlay/kvmapp"
        cp -af "${OVERLAY_DIR}/kvmapp"/* "${stage_dir}/overlay/kvmapp/" 2>/dev/null || true
    fi

    # Ensure executable permissions on all staged scripts and binaries
    find "${stage_dir}/overlay" -type f -name "*.sh" -exec chmod 755 {} +
    find "${stage_dir}/overlay" -type f -name "*.py" -exec chmod 755 {} +
    if [[ -f "${stage_dir}/overlay/kvmapp/server/NanoKVM-Server" ]]; then
        chmod 755 "${stage_dir}/overlay/kvmapp/server/NanoKVM-Server"
    fi

    # 3. Stage Compiled Kernel Modules (via centralized build_kernel.sh stage-modules)
    echo -e "${CYAN}[+] Staging compiled kernel modules for ${kver}...${RESET}"
    bash "${SCRIPT_DIR}/build_kernel.sh" stage-modules "${stage_dir}/overlay"

    # 4. Generate b2sum Checksums
    echo -e "${CYAN}[+] Generating BLAKE2b (b2sum) integrity manifest...${RESET}"
    (
        cd "${stage_dir}"
        find firmware overlay -type f 2>/dev/null | sort | xargs b2sum > b2sum.txt
    )
    if [[ ! -s "${stage_dir}/b2sum.txt" ]]; then
        echo -e "${RED}[✗] Failed to generate valid b2sum integrity manifest.${RESET}" >&2
        rm -rf "${stage_dir}"
        exit 1
    fi

    # 5. Compress to final tar.xz using parallel XZ compression
    echo -e "${CYAN}[+] Compressing archive with parallel XZ: ${out_tar}...${RESET}"
    mkdir -p "$(dirname "${out_tar}")"
    (
        cd "${stage_dir}"
        tar -I "xz -T0" -cf "${out_tar}" firmware overlay b2sum.txt
    )
    rm -rf "${stage_dir}"

    echo -e "${GREEN}[✓] In-system firmware update package created successfully:${RESET}"
    ls -lh "${out_tar}"
    echo -e "${CYAN}------------------------------------------------------------------${RESET}"
    echo -e "Ready for:"
    echo -e "  1. WebUI Update:  Upload in browser via ${CYAN}Settings -> System -> Update Firmware${RESET}"
    echo -e "  2. CLI Update:    ${CYAN}make firmware-flash IP=<device-ip>${RESET}"
    echo -e "  3. SSH Direct:    ${CYAN}scp ${out_tar} root@<IP>:/tmp/ && ssh root@<IP> '/kvmcomm/scripts/firmware_update.sh update /tmp/$(basename "${out_tar}")'${RESET}"
    echo -e "${CYAN}------------------------------------------------------------------${RESET}"
}

flash_firmware_package() {
    local target_host="${1:-}"
    local pkg_path="${2:-${OUTPUT_TAR}}"

    if [[ -z "${target_host}" ]]; then
        echo -e "${RED}Error: Target IP required for flashing firmware package.${RESET}" >&2
        echo -e "${YELLOW}Usage: $0 flash <IP_OR_HOSTNAME> [PACKAGE_PATH]${RESET}" >&2
        exit 1
    fi

    if [[ ! -f "${pkg_path}" ]]; then
        echo -e "${YELLOW}[!] Firmware package missing at ${pkg_path}. Building now...${RESET}"
        build_firmware_package "${pkg_path}"
    fi

    local pkg_name
    pkg_name=$(basename "${pkg_path}")

    echo -e "${CYAN}==================================================================${RESET}"
    echo -e "${CYAN}==> Triggering In-System Flashing on ${target_host}${RESET}"
    echo -e "${CYAN}    Package: ${pkg_name}${RESET}"
    echo -e "${CYAN}==================================================================${RESET}"

    # Verify device health before flashing
    bash "${SCRIPT_DIR}/build_kernel.sh" check "${target_host}" || {
        echo -e "${RED}[✗] Pre-flight device health check failed. Aborting flash.${RESET}" >&2
        exit 1
    }

    echo -e "${CYAN}==> Staging firmware package to root@${target_host}:/tmp/${pkg_name}...${RESET}"
    scp "${pkg_path}" "root@${target_host}:/tmp/${pkg_name}"

    echo -e "${CYAN}==> Executing native /kvmcomm/scripts/firmware_update.sh update on device...${RESET}"
    ssh "root@${target_host}" "
        set -euo pipefail
        /kvmcomm/scripts/firmware_update.sh update \"/tmp/${pkg_name}\"
        rm -f \"/tmp/${pkg_name}\"
    "

    echo -e "${GREEN}[✓] In-system firmware update completed on device!${RESET}"
    echo -e "${YELLOW}[*] Rebooting target device ${target_host}...${RESET}"
    ssh "root@${target_host}" "sync && reboot" || true
    echo -e "${GREEN}[✓] Device reboot initiated.${RESET}"
}

case "${1:-build}" in
    build|package|pkg)
        shift || true
        build_firmware_package "$@"
        ;;
    flash|deploy)
        shift
        flash_firmware_package "$@"
        ;;
    *)
        echo "Usage: $(basename "$0") [build [OUTPUT_TAR]|flash <IP> [PACKAGE_PATH]]"
        exit 1
        ;;
esac
