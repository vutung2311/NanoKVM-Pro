#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# NanoKVM-Pro Standalone Kernel Build & Packaging Pipeline
# Targets: Axera AX630C (Dual Cortex-A53, ARM64, Linux 4.19.125)
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." &>/dev/null && pwd -P)"

SUPPORT_DIR="${REPO_ROOT}/support"
KERNEL_DIR="${SUPPORT_DIR}/kernel"
LINUX_SRC="${KERNEL_DIR}/linux/linux-4.19.125"
SDK_META_DIR="${SUPPORT_DIR}/sdk/meta"
SDK_MSP_DIR="${SUPPORT_DIR}/sdk/msp"
KERNEL_TOOLS_DIR="${SUPPORT_DIR}/scripts/kernel_tools"
TOOLCHAINS_DIR="${SUPPORT_DIR}/toolchains/armv8-toolchains"
VENV_PYTHON="${SUPPORT_DIR}/scripts/build_image/.venv/bin/python3"
DIST_DIR="${REPO_ROOT}/build_dist"

PROJECT="AX630C_emmc_arm64_k419_sipeed_nanokvm"
ARCH="arm64"
LIBC="glibc"
DEFCONFIG="axera_${PROJECT}_defconfig"
DTS_FILE="arch/${ARCH}/boot/dts/axera/${PROJECT}.dts"
DTB_OUT="${LINUX_SRC}/arch/${ARCH}/boot/dts/axera/${PROJECT}.dtb"
IMAGE_OUT="${LINUX_SRC}/arch/${ARCH}/boot/Image"
SIGNED_BOOT="${SUPPORT_DIR}/kernel/boot_signed.bin"
SIGNED_DTB="${SUPPORT_DIR}/kernel/${PROJECT}_signed.dtb"

CROSS_COMPILE="${TOOLCHAINS_DIR}/bin/aarch64-none-linux-gnu-"

# ANSI Colors
RED="\033[31;1m"
GREEN="\033[32;1m"
YELLOW="\033[33;1m"
CYAN="\033[36;1m"
RESET="\033[0m"

# -----------------------------------------------------------------------------
# Pre-flight environment check
# -----------------------------------------------------------------------------
ensure_toolchain() {
    if [[ ! -x "${CROSS_COMPILE}gcc" ]]; then
        echo -e "${CYAN}[*] Setting up cross-toolchain...${RESET}"
        bash "${SUPPORT_DIR}/scripts/toolchain_setup.sh" --yes
    fi
}

ensure_source_and_sdk() {
    mkdir -p "${SUPPORT_DIR}/sdk" "${KERNEL_TOOLS_DIR}"

    if [[ ! -e "${KERNEL_DIR}/.git" ]]; then
        echo -e "${CYAN}[*] Initializing kernel submodule...${RESET}"
        git -C "${REPO_ROOT}" submodule update --init --depth 1 support/kernel
    fi

    if [[ ! -d "${SDK_META_DIR}/.git" ]]; then
        echo -e "${CYAN}[*] Cloning SDK metadata...${RESET}"
        rm -rf "${SDK_META_DIR}"
        git clone --depth=1 https://github.com/sipeed/maix_ax620e_sdk.git "${SDK_META_DIR}"
    fi

    if [[ ! -d "${SDK_MSP_DIR}/.git" ]]; then
        echo -e "${CYAN}[*] Cloning SDK MSP headers...${RESET}"
        rm -rf "${SDK_MSP_DIR}"
        git clone --depth=1 https://github.com/sipeed/maix_ax620e_sdk_msp.git "${SDK_MSP_DIR}"
    fi

    # Wire SDK symlinks so Makefiles find internal BSP dependencies
    rm -rf "${SDK_META_DIR}/kernel" "${SDK_META_DIR}/msp"
    ln -sfn "${KERNEL_DIR}" "${SDK_META_DIR}/kernel"
    ln -sfn "${SDK_MSP_DIR}" "${SDK_META_DIR}/msp"

    # Ensure packaging and signing tools are in place (prefer local SDK clone, fallback to curl)
    if [[ ! -x "${KERNEL_TOOLS_DIR}/ax_gzip" ]]; then
        if [[ -x "${SDK_META_DIR}/tools/ax_gzip_tool/ax_gzip" ]]; then
            echo -e "${CYAN}[*] Copying ax_gzip utility from local SDK...${RESET}"
            cp -f "${SDK_META_DIR}/tools/ax_gzip_tool/ax_gzip" "${KERNEL_TOOLS_DIR}/ax_gzip"
        else
            echo -e "${CYAN}[*] Fetching ax_gzip compression utility...${RESET}"
            curl -fsSL https://raw.githubusercontent.com/sipeed/maix_ax620e_sdk/main/tools/ax_gzip_tool/ax_gzip -o "${KERNEL_TOOLS_DIR}/ax_gzip"
        fi
        chmod +x "${KERNEL_TOOLS_DIR}/ax_gzip"
    fi

    if [[ ! -f "${KERNEL_TOOLS_DIR}/sec_boot_AX620E_sign.py" ]]; then
        if [[ -f "${SDK_META_DIR}/build/tools/imgsign/sec_boot_AX620E_sign.py" ]]; then
            echo -e "${CYAN}[*] Copying Axera signing script and keys from local SDK...${RESET}"
            cp -f "${SDK_META_DIR}/build/tools/imgsign/sec_boot_AX620E_sign.py" "${KERNEL_TOOLS_DIR}/sec_boot_AX620E_sign.py"
            cp -f "${SDK_META_DIR}/tools/imgsign/public.pem" "${KERNEL_TOOLS_DIR}/public.pem"
            cp -f "${SDK_META_DIR}/tools/imgsign/private.pem" "${KERNEL_TOOLS_DIR}/private.pem"
        else
            echo -e "${CYAN}[*] Fetching Axera signing script and keys...${RESET}"
            curl -fsSL https://raw.githubusercontent.com/sipeed/maix_ax620e_sdk/main/build/tools/imgsign/sec_boot_AX620E_sign.py -o "${KERNEL_TOOLS_DIR}/sec_boot_AX620E_sign.py"
            curl -fsSL https://raw.githubusercontent.com/sipeed/maix_ax620e_sdk/main/tools/imgsign/public.pem -o "${KERNEL_TOOLS_DIR}/public.pem"
            curl -fsSL https://raw.githubusercontent.com/sipeed/maix_ax620e_sdk/main/tools/imgsign/private.pem -o "${KERNEL_TOOLS_DIR}/private.pem"
        fi
        chmod +x "${KERNEL_TOOLS_DIR}/sec_boot_AX620E_sign.py"
    fi

    # Ensure build virtual environment and python rsa library are available
    if [[ ! -f "${VENV_PYTHON}" ]]; then
        echo -e "${CYAN}[*] Setting up build virtual environment...${RESET}"
        bash "${SUPPORT_DIR}/scripts/setup_tooling.sh" --skip-packages --skip-toolchain
    fi

    if ! "${VENV_PYTHON}" -c "import rsa" &>/dev/null; then
        echo -e "${CYAN}[*] Installing rsa library in build venv...${RESET}"
        "${VENV_PYTHON}" -m pip install -q rsa pyasn1
    fi
}

ensure_initramfs() {
    local cpio_file="${KERNEL_TOOLS_DIR}/initramfs_rootfs.cpio"
    local base_axp="${SUPPORT_DIR}/base_firmware/20260529_NanoKVMPro_1_0_15.axp"

    if [[ ! -f "${cpio_file}" ]]; then
        if [[ ! -f "${base_axp}" ]]; then
            echo -e "${YELLOW}[!] Base AXP image missing for initramfs extraction. Fetching base firmware...${RESET}"
            make -C "${REPO_ROOT}" fetch-base
        fi

        echo -e "${YELLOW}[!] initramfs archive not found, extracting from base firmware...${RESET}"
        python3 -c "
import zipfile, subprocess, tempfile, os

axp_path = '${base_axp}'
ax_gzip = '${KERNEL_TOOLS_DIR}/ax_gzip'
out_cpio = '${cpio_file}'

with tempfile.TemporaryDirectory() as tmpdir:
    payload_gz = os.path.join(tmpdir, 'kpayload.axgzip')
    payload_bin = os.path.join(tmpdir, 'kpayload.axgzip.bin')

    with zipfile.ZipFile(axp_path) as z:
        with open(payload_gz, 'wb') as f:
            f.write(z.open('boot_signed.bin').read()[1024:])

    subprocess.run([ax_gzip, '-d', payload_gz], check=True, stdout=subprocess.DEVNULL)

    with open(payload_bin, 'rb') as f:
        data = f.read()

    start = 12139748
    trailer_pos = data.find(b'TRAILER!!!', start)
    end = trailer_pos + len('TRAILER!!!\0')
    while end % 512 != 0:
        end += 1

    with open(out_cpio, 'wb') as f:
        f.write(data[start:end])
"
    fi
}

ensure_dts_reserve_mem() {
    local def_dir="${LINUX_SRC}/include/dt-bindings/memory"
    local def_header="${def_dir}/AX620E_reserve_mem_define.h"
    mkdir -p "${def_dir}"
    cat > "${def_header}" << 'EOF'
#ifndef __DTS_AX620E_RESERVE_MEM_DEFINE_H
#define __DTS_AX620E_RESERVE_MEM_DEFINE_H

#define ATF_RESERVED_START_HI 0x00
#define ATF_RESERVED_START_LO 0x40040000
#define ATF_RESERVED_SIZE_HI  0x00
#define ATF_RESERVED_SIZE_LO  0x40000

#define SUPPORT_ATF

#define OPTEE_BOOT
#define OPTEE_RESERVED_START_HI 0x00
#define OPTEE_RESERVED_START_LO 0x44200000
#define OPTEE_RESERVED_SIZE_HI  0x00
#define OPTEE_RESERVED_SIZE_LO  0x2000000

#define BOOTARGS "mem=256M console=ttyS0,115200n8 earlycon=uart8250,mmio32,0x4880000 board_id=0x0,boot_reason=0x00,initcall_debug=0 loglevel=8 usbcore.autosuspend=-1 root=/dev/mmcblk0p17 rootfstype=ext4 rw rootwait blkdevparts=mmcblk0:768K(spl),512K(ddrinit),256K(atf),256K(atf_b),1536K(uboot),1536K(uboot_b),1M(env),6M(logo),6M(logo_b),1M(optee),1M(optee_b),1M(dtb),1M(dtb_b),64M(kernel),64M(kernel_b),128M(boot),-(rootfs)"

#endif /* __DTS_AX620E_RESERVE_MEM_DEFINE_H */
EOF
}

# -----------------------------------------------------------------------------
# Configuration & Build Steps
# -----------------------------------------------------------------------------
configure_kernel() {
    echo -e "${CYAN}==> Generating kernel .config from ${DEFCONFIG}...${RESET}"
    make -C "${LINUX_SRC}" \
        ARCH="${ARCH}" \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        PROJECT="${PROJECT}" \
        HOME_PATH="${SDK_META_DIR}" \
        LIBC="${LIBC}" \
        "${DEFCONFIG}"

    # Ensure initramfs points to our extracted archive (handle enabled, disabled or missing)
    if grep -q "^CONFIG_INITRAMFS_SOURCE=" "${LINUX_SRC}/.config"; then
        sed -i "s|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE=\"${KERNEL_TOOLS_DIR}/initramfs_rootfs.cpio\"|" "${LINUX_SRC}/.config"
    elif grep -q "^# CONFIG_INITRAMFS_SOURCE is not set" "${LINUX_SRC}/.config"; then
        sed -i "s|^# CONFIG_INITRAMFS_SOURCE is not set|CONFIG_INITRAMFS_SOURCE=\"${KERNEL_TOOLS_DIR}/initramfs_rootfs.cpio\"|" "${LINUX_SRC}/.config"
    else
        echo "CONFIG_INITRAMFS_SOURCE=\"${KERNEL_TOOLS_DIR}/initramfs_rootfs.cpio\"" >> "${LINUX_SRC}/.config"
    fi
}

run_menuconfig() {
    ensure_toolchain
    ensure_source_and_sdk
    ensure_initramfs
    ensure_dts_reserve_mem

    if [[ ! -f "${LINUX_SRC}/.config" ]]; then
        configure_kernel
    fi

    echo -e "${CYAN}==> Opening kernel menuconfig...${RESET}"
    make -C "${LINUX_SRC}" \
        ARCH="${ARCH}" \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        PROJECT="${PROJECT}" \
        HOME_PATH="${SDK_META_DIR}" \
        LIBC="${LIBC}" \
        menuconfig

    # Re-verify initramfs setting after menuconfig exits
    sed -i "s|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE=\"${KERNEL_TOOLS_DIR}/initramfs_rootfs.cpio\"|" "${LINUX_SRC}/.config"
    echo -e "${GREEN}[✓] Kernel configuration updated.${RESET}"
}

compile_kernel() {
    ensure_toolchain
    ensure_source_and_sdk
    ensure_initramfs
    ensure_dts_reserve_mem

    if [[ ! -f "${LINUX_SRC}/.config" ]]; then
        configure_kernel
    fi

    local jobs=$(nproc)
    echo -e "${CYAN}==> Compiling Device Tree (${PROJECT}.dtb)...${RESET}"
    make -j"${jobs}" -C "${LINUX_SRC}" \
        ARCH="${ARCH}" \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        PROJECT="${PROJECT}" \
        HOME_PATH="${SDK_META_DIR}" \
        LIBC="${LIBC}" \
        dtbs

    echo -e "${CYAN}==> Compiling Kernel Image across ${jobs} threads...${RESET}"
    make -j"${jobs}" -C "${LINUX_SRC}" \
        ARCH="${ARCH}" \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        PROJECT="${PROJECT}" \
        HOME_PATH="${SDK_META_DIR}" \
        LIBC="${LIBC}" \
        Image

    echo -e "${CYAN}==> Compiling Kernel Modules...${RESET}"
    make -j"${jobs}" -C "${LINUX_SRC}" \
        ARCH="${ARCH}" \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        PROJECT="${PROJECT}" \
        HOME_PATH="${SDK_META_DIR}" \
        LIBC="${LIBC}" \
        modules

    sign_artifacts
}

sign_artifacts() {
    echo -e "${CYAN}==> Compressing & Signing kernel artifacts with Axera RSA-2048 keys...${RESET}"

    # Compress Image
    "${KERNEL_TOOLS_DIR}/ax_gzip" -9 "${IMAGE_OUT}"

    # Sign Image
    "${VENV_PYTHON}" "${KERNEL_TOOLS_DIR}/sec_boot_AX620E_sign.py" \
        -i "${IMAGE_OUT}.axgzip" \
        -pub "${KERNEL_TOOLS_DIR}/public.pem" \
        -prv "${KERNEL_TOOLS_DIR}/private.pem" \
        -o "${SIGNED_BOOT}" \
        -cap 0x54FAFE -key_bit 2048

    # Compress DTB
    "${KERNEL_TOOLS_DIR}/ax_gzip" -9 "${DTB_OUT}"

    # Sign DTB
    "${VENV_PYTHON}" "${KERNEL_TOOLS_DIR}/sec_boot_AX620E_sign.py" \
        -i "${DTB_OUT}.axgzip" \
        -pub "${KERNEL_TOOLS_DIR}/public.pem" \
        -prv "${KERNEL_TOOLS_DIR}/private.pem" \
        -o "${SIGNED_DTB}" \
        -cap 0x54FAFE -key_bit 2048

    mkdir -p "${DIST_DIR}"
    cp -f "${SIGNED_BOOT}" "${DIST_DIR}/boot_signed.bin"
    cp -f "${SIGNED_DTB}" "${DIST_DIR}/${PROJECT}_signed.dtb"

    echo -e "${GREEN}[✓] Custom Signed Kernel Ready:${RESET}"
    echo -e "    * Kernel: ${SIGNED_BOOT} ($(du -h "${SIGNED_BOOT}" | cut -f1))"
    echo -e "    * DTB:    ${SIGNED_DTB} ($(du -h "${SIGNED_DTB}" | cut -f1))"
    echo -e "    * Raw:    ${IMAGE_OUT} ($(du -h "${IMAGE_OUT}" | cut -f1))"
}

# -----------------------------------------------------------------------------
# Live volatile testing via kexec (Zero-flash)
# -----------------------------------------------------------------------------
run_kexec() {
    local target_host="${1:-}"
    if [[ -z "${target_host}" ]]; then
        echo -e "${RED}Error: Host IP required for kexec live testing.${RESET}"
        echo -e "${YELLOW}Usage: $0 kexec <IP_OR_HOSTNAME>${RESET}"
        exit 1
    fi

    if [[ ! -f "${IMAGE_OUT}" || ! -f "${DTB_OUT}" ]]; then
        echo -e "${YELLOW}[!] Kernel Image or DTB not found. Building first...${RESET}"
        compile_kernel
    fi

    if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" && -x /usr/bin/ksshaskpass && -z "${SSH_ASKPASS:-}" ]]; then
        export SSH_ASKPASS="/usr/bin/ksshaskpass"
    fi

    echo -e "${CYAN}==> Staging kernel Image and DTB to root@${target_host}:/tmp via SCP...${RESET}"
    scp -o StrictHostKeyChecking=accept-new "${IMAGE_OUT}" "${DTB_OUT}" "root@${target_host}:/tmp/"

    echo -e "${CYAN}==> Preparing volatile kexec memory handoff on ${target_host}...${RESET}"
    ssh -o StrictHostKeyChecking=accept-new "root@${target_host}" '
        set -e
        if ! command -v kexec >/dev/null 2>&1; then
            echo "[*] Installing kexec-tools..."
            DEBIAN_FRONTEND=noninteractive apt-get update && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends kexec-tools
        fi
        echo "[*] Loading custom kernel & DTB into RAM..."
        kexec -i -l /tmp/Image --dtb=/tmp/'"${PROJECT}"'.dtb --reuse-cmdline --append="panic=10"
        echo "[*] Scheduling memory handoff in 1 second..."
        sync
        nohup sh -c "sleep 1 && (systemctl kexec || kexec -e)" >/dev/null 2>&1 &
        exit 0
    ' || true

    echo -e "${GREEN}[✓] kexec handoff command issued! Kernel jumping in RAM.${RESET}"
    echo -e "${CYAN}[*] Waiting for device to reboot and open SSH port 22...${RESET}"

    local booted=0
    # Wait for old kernel to drop and new kernel to initialize network/sshd (up to 60s)
    sleep 5
    for i in {1..30}; do
        if nc -z -w 1 "${target_host}" 22 &>/dev/null; then
            booted=1
            break
        fi
        # Poke ARP cache to assist wireless AP intra-BSS packet routing
        arping -c 1 -w 1 "${target_host}" &>/dev/null || true
        sleep 2
    done

    if [[ ${booted} -eq 1 ]]; then
        echo -e "${GREEN}[✓] Device successfully rebooted into RAM kernel and SSH port 22 is online!${RESET}"
        echo -e "${CYAN}[*] Verify the new kernel with: ssh root@${target_host} uname -a${RESET}"
        echo -e "${YELLOW}[*] Safety Note: This kernel is running entirely in volatile RAM.${RESET}"
        echo -e "${YELLOW}    To revert to the stock eMMC kernel at any time, simply power-cycle the device.${RESET}"
    else
        echo -e "${YELLOW}[!] Device did not answer on port 22 within 45 seconds.${RESET}"
        echo -e "${YELLOW}[*] Check connectivity or ping: ping ${target_host}${RESET}"
        echo -e "${YELLOW}[*] Note: If the test kernel hangs, power-cycle the device to safely revert to eMMC.${RESET}"
    fi
}

# -----------------------------------------------------------------------------
# Kernel Release & Device Health Diagnostics
# -----------------------------------------------------------------------------
get_kernel_release() {
    local kver=""
    if [[ -f "${LINUX_SRC}/include/config/kernel.release" ]]; then
        kver=$(tr -d ' \t\r\n' < "${LINUX_SRC}/include/config/kernel.release")
    fi
    if [[ -z "${kver}" ]] && [[ -d "${LINUX_SRC}" ]]; then
        kver=$(make -s -C "${LINUX_SRC}" ARCH="${ARCH}" kernelrelease 2>/dev/null || true)
    fi
    if [[ -z "${kver}" ]]; then
        kver="4.19.325"
    fi
    echo "${kver}"
}

check_device_health() {
    local target_host="${1:-}"
    if [[ -z "${target_host}" ]]; then
        echo -e "${RED}Error: Target IP required for health check.${RESET}"
        echo -e "${YELLOW}Usage: $0 check <IP_OR_HOSTNAME>${RESET}"
        exit 1
    fi

    echo -e "${CYAN}======================================================${RESET}"
    echo -e "${CYAN}==> Pre-Flight Health Diagnostics: ${target_host}${RESET}"
    echo -e "${CYAN}======================================================${RESET}"

    # 1. SSH Connectivity
    if ! ssh -q -o ConnectTimeout=5 "root@${target_host}" "true"; then
        echo -e "${RED}[✗] Cannot establish SSH connection to root@${target_host}.${RESET}"
        return 1
    fi
    echo -e "${GREEN}[✓] SSH connectivity verified.${RESET}"

    # 2. Remote System Info & Current Boot Slot
    local dev_info
    dev_info=$(ssh "root@${target_host}" "
        kver=\$(uname -r)
        uptime_str=\$(uptime | sed 's/.*up \([^,]*\), .*/\1/')
        reg=\$(devmem 0x2390024 32 2>/dev/null || echo 'unknown')
        boot=\$(fw_printenv bootsystem 2>/dev/null | cut -d= -f2 || echo 'unknown')
        root_avail=\$(df -m / | awk 'NR==2 {print \$4}')
        tmp_avail=\$(df -m /tmp | awk 'NR==2 {print \$4}')
        echo \"\${kver}|\${uptime_str}|\${reg}|\${boot}|\${root_avail}|\${tmp_avail}\"
    ")

    local r_kver r_uptime r_reg r_boot r_root_avail r_tmp_avail
    IFS='|' read -r r_kver r_uptime r_reg r_boot r_root_avail r_tmp_avail <<< "${dev_info}"

    echo -e "  - Active Kernel:       ${CYAN}${r_kver}${RESET} (Uptime: ${r_uptime})"
    echo -e "  - Active Boot Slot:    ${CYAN}${r_boot}${RESET} (Hardware Register: ${r_reg})"
    echo -e "  - Rootfs Available:    ${CYAN}${r_root_avail} MB${RESET}"
    echo -e "  - /tmp Available:      ${CYAN}${r_tmp_avail} MB${RESET}"

    if [[ "${r_root_avail}" -lt 50 ]]; then
        echo -e "${RED}[✗] Insufficient disk space on / (<50MB). Flash aborted.${RESET}"
        return 1
    fi
    if [[ "${r_tmp_avail}" -lt 30 ]]; then
        echo -e "${RED}[✗] Insufficient memory/disk space on /tmp (<30MB). Flash aborted.${RESET}"
        return 1
    fi

    # 3. Failsafe Slot A Verification
    local slot_a_ok
    slot_a_ok=$(ssh "root@${target_host}" "
        if [ -b /dev/mmcblk0p12 ] && [ -b /dev/mmcblk0p14 ]; then
            head -c 1024 /dev/mmcblk0p12 >/dev/null && head -c 1024 /dev/mmcblk0p14 >/dev/null && echo 'OK'
        else
            echo 'FAIL'
        fi
    ")
    if [[ "${slot_a_ok}" != "OK" ]]; then
        echo -e "${RED}[✗] Slot A failsafe partitions are unreadable! Aborting flash.${RESET}"
        return 1
    fi
    echo -e "${GREEN}[✓] Slot A failsafe partitions intact (/dev/mmcblk0p12, /dev/mmcblk0p14).${RESET}"

    # 4. Stock 4.19.125 Module Preservation
    local has_stock_modules
    has_stock_modules=$(ssh "root@${target_host}" "
        if [ -d /kvmcomm/ko_4.19.125 ] && [ -f /kvmcomm/ko_4.19.125/lt6911_manage.ko ]; then
            echo 'EXISTS'
        else
            mkdir -p /kvmcomm/ko_4.19.125
            cp -n /kvmcomm/ko/*.ko /kvmcomm/ko_4.19.125/ 2>/dev/null || true
            cp -n /soc/ko/*.ko /kvmcomm/ko_4.19.125/ 2>/dev/null || true
            echo 'BACKED_UP'
        fi
    ")
    if [[ "${has_stock_modules}" == "EXISTS" ]]; then
        echo -e "${GREEN}[✓] Stock 4.19.125 modules preserved in /kvmcomm/ko_4.19.125/.${RESET}"
    else
        echo -e "${YELLOW}[!] Stock modules were missing in /kvmcomm/ko_4.19.125/; backed up safely.${RESET}"
    fi

    # 5. Hardware Subsystems & Services
    local hw_status
    hw_status=$(ssh "root@${target_host}" "
        lt_chip=\$(cat /proc/lt6911_info/chip_id 2>/dev/null || echo 'not_found')
        lt_status=\$(cat /proc/lt6911_info/status 2>/dev/null || echo 'unpowered')
        fb_ok=\$( [ -e /dev/fb0 ] && echo 'OK' || echo 'FAIL' )
        wifi_ok=\$(lsmod | grep -q aic8800 && echo 'OK' || echo 'FAIL')
        kvmcomm_st=\$(systemctl is-active kvmcomm 2>/dev/null || echo 'inactive')
        nanokvm_st=\$(systemctl is-active nanokvm 2>/dev/null || systemctl is-active kvmd 2>/dev/null || echo 'inactive')
        vin_ok=\$(pgrep -f kvm_vin >/dev/null && echo 'OK' || echo 'FAIL')
        echo \"\${lt_chip}|\${lt_status}|\${fb_ok}|\${wifi_ok}|\${kvmcomm_st}|\${nanokvm_st}|\${vin_ok}\"
    ")

    local h_chip h_status h_fb h_wifi h_kvmcomm h_nanokvm h_vin
    IFS='|' read -r h_chip h_status h_fb h_wifi h_kvmcomm h_nanokvm h_vin <<< "${hw_status}"

    echo -e "  - LT6911 HDMI Bridge:  ${CYAN}${h_chip}${RESET} (Status: ${h_status})"
    echo -e "  - Framebuffer Display: ${CYAN}${h_fb}${RESET} (/dev/fb0)"
    echo -e "  - Wi-Fi (AIC8800):     ${CYAN}${h_wifi}${RESET}"
    echo -e "  - kvmcomm Service:     ${CYAN}${h_kvmcomm}${RESET}"
    echo -e "  - nanokvm Service:     ${CYAN}${h_nanokvm}${RESET}"
    echo -e "  - Video Input Daemon:  ${CYAN}${h_vin}${RESET}"

    if [[ "${h_chip}" == "lt6911d" && "${h_fb}" == "OK" && "${h_wifi}" == "OK" && "${h_kvmcomm}" == "active" ]]; then
        echo -e "${GREEN}[✓] All device hardware subsystems and services are healthy.${RESET}"
    else
        echo -e "${YELLOW}[!] Warning: Some hardware subsystems or services reported non-optimal states.${RESET}"
    fi
    echo -e "${CYAN}------------------------------------------------------${RESET}"
    return 0
}

stage_modules() {
    local dest_dir="${1:-}"
    local kver=$(get_kernel_release)

    if [[ -z "${dest_dir}" ]]; then
        echo -e "${RED}Error: Destination directory required for stage-modules.${RESET}" >&2
        echo -e "${YELLOW}Usage: $0 stage-modules <DEST_DIR>${RESET}" >&2
        return 1
    fi

    local ko_kver_dir="${dest_dir}/kvmcomm/ko_${kver}"

    mkdir -p "${ko_kver_dir}"

    echo -e "${CYAN}==> Staging compiled kernel modules (${kver}) to ${ko_kver_dir}...${RESET}"
    local count=0

    # Search and stage all compiled .ko files from kernel tree (excluding build scripts)
    while IFS= read -r -d '' ko_file; do
        cp -f "${ko_file}" "${ko_kver_dir}/"
        ((count++)) || true
    done < <(find "${LINUX_SRC}" -type f -name "*.ko" -not -path "*/scripts/*" -print0 2>/dev/null)

    echo -e "${GREEN}[✓] Staged ${count} kernel modules to ${ko_kver_dir}${RESET}"
}

# -----------------------------------------------------------------------------
# Slot A/B Management & Safe Flashing
# -----------------------------------------------------------------------------
flash_slot_b() {
    local target_host="${1:-}"
    if [[ -z "${target_host}" ]]; then
        echo -e "${RED}Error: Host IP required for flashing Slot B.${RESET}"
        echo -e "${YELLOW}Usage: $0 flash-slot-b <IP_OR_HOSTNAME>${RESET}"
        exit 1
    fi

    # Run comprehensive pre-flight health checks
    check_device_health "${target_host}" || {
        echo -e "${RED}[✗] Pre-flight health check failed. Aborting flash to prevent soft-brick.${RESET}"
        exit 1
    }

    if [[ ! -f "${SIGNED_BOOT}" || ! -f "${SIGNED_DTB}" ]]; then
        echo -e "${YELLOW}[!] Signed artifacts missing. Running compilation & signing first...${RESET}"
        compile_kernel
    fi

    local kernel_size=$(stat -c%s "${SIGNED_BOOT}")
    local dtb_size=$(stat -c%s "${SIGNED_DTB}")
    local kernel_md5=$(md5sum "${SIGNED_BOOT}" | awk '{print $1}')
    local dtb_md5=$(md5sum "${SIGNED_DTB}" | awk '{print $1}')

    echo -e "${CYAN}==> Staging signed kernel and DTB to root@${target_host}:/tmp via SCP...${RESET}"
    scp "${SIGNED_BOOT}" "${SIGNED_DTB}" "root@${target_host}:/tmp/"

    echo -e "${CYAN}==> Flashing DTB to Slot B (/dev/mmcblk0p13)...${RESET}"
    ssh "root@${target_host}" "dd if=/tmp/$(basename "${SIGNED_DTB}") of=/dev/mmcblk0p13 bs=64k conv=fsync status=none"

    echo -e "${CYAN}==> Flashing Kernel to Slot B (/dev/mmcblk0p15)...${RESET}"
    ssh "root@${target_host}" "dd if=/tmp/$(basename "${SIGNED_BOOT}") of=/dev/mmcblk0p15 bs=1M conv=fsync status=none"

    echo -e "${CYAN}==> Verifying partition hashes on device...${RESET}"
    local dev_dtb_md5=$(ssh "root@${target_host}" "head -c ${dtb_size} /dev/mmcblk0p13 | md5sum" | awk '{print $1}')
    local dev_kernel_md5=$(ssh "root@${target_host}" "head -c ${kernel_size} /dev/mmcblk0p15 | md5sum" | awk '{print $1}')

    if [[ "${dtb_md5}" != "${dev_dtb_md5}" || "${kernel_md5}" != "${dev_kernel_md5}" ]]; then
        echo -e "${RED}[✗] Hash verification failed! Slot B flash aborted.${RESET}"
        exit 1
    fi
    echo -e "${GREEN}[✓] Slot B partition hashes verified successfully.${RESET}"

    # Clean up staging files
    ssh "root@${target_host}" "rm -f /tmp/$(basename "${SIGNED_BOOT}") /tmp/$(basename "${SIGNED_DTB}")"

    local kver=$(get_kernel_release)
    echo -e "${CYAN}==> Syncing ${kver} kernel modules to /kvmcomm/ko_${kver}/ and /lib/modules/${kver}/ on ${target_host}...${RESET}"
    local tmp_stage
    tmp_stage=$(mktemp -d -t nanokvm_mod_stage_XXXXXX)
    stage_modules "${tmp_stage}"

    ssh "root@${target_host}" "mkdir -p /kvmcomm/ko_${kver} /lib/modules/${kver}/kernel/drivers/net/wireless/aic8800"
    if compgen -G "${tmp_stage}/kvmcomm/ko_${kver}/*.ko" >/dev/null; then
        scp -q -p "${tmp_stage}/kvmcomm/ko_${kver}"/*.ko "root@${target_host}:/kvmcomm/ko_${kver}/"
    fi
    if compgen -G "${tmp_stage}/lib/modules/${kver}/kernel/drivers/net/wireless/aic8800/*.ko" >/dev/null; then
        scp -q -p "${tmp_stage}/lib/modules/${kver}/kernel/drivers/net/wireless/aic8800"/*.ko "root@${target_host}:/lib/modules/${kver}/kernel/drivers/net/wireless/aic8800/"
    fi
    ssh "root@${target_host}" "depmod -a ${kver} 2>/dev/null || true"
    rm -rf "${tmp_stage}"

    echo -e "${CYAN}==> Arming Slot B via native boot registers (0x2390028=0x28, 0x239002C=0x94) and U-Boot...${RESET}"
    ssh "root@${target_host}" "devmem 0x239002C 32 0x80 && devmem 0x239002C 32 0x14 && devmem 0x2390028 32 0x28 && fw_setenv bootsystem B"
    echo -e "${GREEN}[✓] Slot B armed successfully (0x2390024=0x28, bootsystem=B).${RESET}"
    echo -e "${YELLOW}[*] Slot A (/dev/mmcblk0p14 and /dev/mmcblk0p12) remains untouched as failsafe.${RESET}"
    echo -e "${YELLOW}[*] To reboot now: ssh root@${target_host} 'sync && reboot'${RESET}"
}

switch_boot_slot() {
    local slot="${1:-}"
    local target_host="${2:-}"
    if [[ -z "${slot}" || -z "${target_host}" ]]; then
        echo -e "${RED}Error: Slot (A or B) and target IP required.${RESET}"
        echo -e "${YELLOW}Usage: $0 boot-slot <A|B> <IP_OR_HOSTNAME>${RESET}"
        exit 1
    fi

    slot=$(echo "${slot}" | tr '[:lower:]' '[:upper:]')
    if [[ "${slot}" == "A" ]]; then
        echo -e "${CYAN}==> Setting active boot slot to A on ${target_host}...${RESET}"
        ssh "root@${target_host}" "devmem 0x239002C 32 0x80 && devmem 0x239002C 32 0x28 && devmem 0x2390028 32 0x14 && fw_setenv bootsystem A"
        echo -e "${GREEN}[✓] Slot A set (0x2390024=0x14, bootsystem=A).${RESET}"
    elif [[ "${slot}" == "B" ]]; then
        echo -e "${CYAN}==> Setting active boot slot to B on ${target_host}...${RESET}"
        ssh "root@${target_host}" "devmem 0x239002C 32 0x80 && devmem 0x239002C 32 0x14 && devmem 0x2390028 32 0x28 && fw_setenv bootsystem B"
        echo -e "${GREEN}[✓] Slot B set (0x2390024=0x28, bootsystem=B).${RESET}"
    else
        echo -e "${RED}Invalid slot '${slot}'. Must be A or B.${RESET}"
        exit 1
    fi
}

clean_kernel() {
    if [[ -d "${LINUX_SRC}" ]]; then
        echo -e "${CYAN}==> Cleaning kernel build tree...${RESET}"
        make -C "${LINUX_SRC}" \
            ARCH="${ARCH}" \
            CROSS_COMPILE="${CROSS_COMPILE}" \
            PROJECT="${PROJECT}" \
            HOME_PATH="${SDK_META_DIR}" \
            LIBC="${LIBC}" \
            clean
        rm -f "${SIGNED_BOOT}" "${SIGNED_DTB}" "${IMAGE_OUT}.axgzip" "${DTB_OUT}.axgzip"
        rm -f "${DIST_DIR}/boot_signed.bin" "${DIST_DIR}/${PROJECT}_signed.dtb"
        echo -e "${GREEN}[✓] Clean complete.${RESET}"
    fi
}

# -----------------------------------------------------------------------------
# CLI Entrypoint
# -----------------------------------------------------------------------------
case "${1:-build}" in
    build|compile)
        compile_kernel
        ;;
    menuconfig|config)
        run_menuconfig
        ;;
    setup)
        ensure_toolchain
        ensure_source_and_sdk
        ensure_initramfs
        configure_kernel
        echo -e "${GREEN}[✓] Kernel environment initialized successfully.${RESET}"
        ;;
    sign)
        sign_artifacts
        ;;
    kver|kernelrelease|version)
        get_kernel_release
        ;;
    stage-modules|modules)
        shift
        stage_modules "$@"
        ;;
    check|check-device|health|status)
        shift
        check_device_health "$@"
        ;;
    kexec)
        shift
        run_kexec "$@"
        ;;
    flash-slot-b|flash-b)
        shift
        flash_slot_b "$@"
        ;;
    boot-slot)
        shift
        switch_boot_slot "$@"
        ;;
    clean)
        clean_kernel
        ;;
    *)
        echo "Usage: $(basename "$0") [setup|build|menuconfig|kver|stage-modules <DIR>|check <IP>|flash-slot-b <IP>|boot-slot <A|B> <IP>|kexec <IP>|clean]"
        exit 1
        ;;
esac
