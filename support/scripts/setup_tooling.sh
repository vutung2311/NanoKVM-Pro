#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# NanoKVM Pro - Host Tooling & Dependency Installer
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." &>/dev/null && pwd -P)"
BUILD_IMAGE_DIR="${SCRIPT_DIR}/build_image"
VENV_DIR="${BUILD_IMAGE_DIR}/.venv"
TOOLCHAINS_DIR="${SCRIPT_DIR}/../toolchains"

# Formatting
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
BOLD='\033[1m'
RESET='\033[0m'

# Flags
CHECK_ONLY=false
SKIP_PACKAGES=false
SKIP_TOOLCHAIN=false
FORCE_REINSTALL=false

# CLI parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--check-only)
            CHECK_ONLY=true
            shift
            ;;
        --skip-packages)
            SKIP_PACKAGES=true
            shift
            ;;
        --skip-toolchain)
            SKIP_TOOLCHAIN=true
            shift
            ;;
        -f|--force)
            FORCE_REINSTALL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [options]"
            echo ""
            echo "Options:"
            echo "  -c, --check-only    Scan and report missing tools without making changes"
            echo "  --skip-packages     Skip host system package installation"
            echo "  --skip-toolchain    Skip cross-compilation toolchain setup"
            echo "  -f, --force         Force reinstall of virtual environment and toolchain"
            echo "  -h, --help          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Privilege escalation helper (strictly pkexec per system policy)
get_priv_esc() {
    if [[ $(id -u) -eq 0 ]]; then
        echo ""
    elif command -v pkexec &>/dev/null; then
        echo "pkexec"
    elif command -v sudo &>/dev/null; then
        echo "sudo"
    elif command -v doas &>/dev/null; then
        echo "doas"
    else
        echo ""
    fi
}

PRIV_ESC=$(get_priv_esc)

# Detect host distribution family
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        local id_like="${ID_LIKE:-}"
        local id="${ID:-}"

        if [[ "$id" == "arch" || "$id" == "cachyos" || "$id" == "manjaro" || "$id" == "endeavouros" || "$id_like" =~ arch ]]; then
            echo "arch"
        elif [[ "$id" == "ubuntu" || "$id" == "debian" || "$id" == "pop" || "$id" == "linuxmint" || "$id_like" =~ (ubuntu|debian) ]]; then
            echo "debian"
        elif [[ "$id" == "fedora" || "$id" == "rhel" || "$id" == "centos" || "$id" == "rocky" || "$id_like" =~ (fedora|rhel) ]]; then
            echo "fedora"
        elif [[ "$id" =~ suse || "$id_like" =~ suse ]]; then
            echo "suse"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

DISTRO_FAMILY=$(detect_distro)

# Function to check binary presence
check_bin() {
    local cmd=$1
    if command -v "$cmd" &>/dev/null; then
        return 0
    fi
    return 1
}

# Scan all required tools
scan_prerequisites() {
    local all_ok=true

    echo -e "${BOLD}NanoKVM Pro Build Tooling Status:${RESET}"
    echo "------------------------------------------------------------"

    # Core Host Tools
    local tools=(
        "go:Go Compiler (ARM64 cross-build):golang"
        "node:Node.js (Frontend build):nodejs"
        "pnpm:PNPM package manager:pnpm"
        "patchelf:ELF patch utility (RPATH injection):patchelf"
        "dpkg-deb:Debian package builder:dpkg"
        "simg2img:Android Sparse Ext4 converter:android-tools"
        "img2simg:Android Raw-to-Sparse converter:android-tools"
        "ar:Archive tool (GNU binutils):binutils"
        "tar:Tape archive utility:tar"
        "xz:XZ compression utility:xz"
        "zstd:Zstandard compression utility:zstd"
        "curl:HTTP transfer client:curl"
        "rsync:File synchronizer (overlay):rsync"
        "unshare:Namespace isolation (util-linux):util-linux"
        "xxd:Hex dump / binary converter:xxd"
        "unzip:ZIP archive extractor:unzip"
    )

    for item in "${tools[@]}"; do
        IFS=":" read -r bin desc pkg <<< "$item"
        if check_bin "$bin"; then
            printf "  %-18s ${GREEN}[INSTALLED]${RESET} %s\n" "$bin" "$desc"
        else
            printf "  %-18s ${RED}[MISSING]${RESET}   %s (pkg: %s)\n" "$bin" "$desc" "$pkg"
            all_ok=false
        fi
    done

    # QEMU User Static
    if check_bin "qemu-aarch64-static" || [[ -x /usr/bin/qemu-aarch64-static ]]; then
        printf "  %-18s ${GREEN}[INSTALLED]${RESET} %s\n" "qemu-aarch64-static" "QEMU ARM64 user emulation"
    else
        printf "  %-18s ${RED}[MISSING]${RESET}   %s (pkg: qemu-user-static)\n" "qemu-aarch64-static" "QEMU ARM64 user emulation"
        all_ok=false
    fi

    # axp2img (in PATH or in build_image venv)
    if check_bin "axp2img" || [[ -x "${VENV_DIR}/bin/axp2img" ]]; then
        local axp_loc
        if check_bin "axp2img"; then
            axp_loc="$(command -v axp2img)"
        else
            axp_loc="${VENV_DIR}/bin/axp2img"
        fi
        printf "  %-18s ${GREEN}[INSTALLED]${RESET} %s (%s)\n" "axp2img" "AXP disk image converter" "$axp_loc"
    else
        printf "  %-18s ${RED}[MISSING]${RESET}   %s (pip: axp-tools)\n" "axp2img" "AXP disk image converter"
        all_ok=false
    fi

    # Python tqdm
    if python3 -c "import tqdm" &>/dev/null || { [[ -f "${VENV_DIR}/bin/python3" ]] && "${VENV_DIR}/bin/python3" -c "import tqdm" &>/dev/null; }; then
        printf "  %-18s ${GREEN}[INSTALLED]${RESET} %s\n" "python-tqdm" "Python progress bar library"
    else
        printf "  %-18s ${RED}[MISSING]${RESET}   %s (pip: tqdm)\n" "python-tqdm" "Python progress bar library"
        all_ok=false
    fi

    # Cross Compiler Toolchain
    if "${SCRIPT_DIR}/toolchain_setup.sh" --check &>/dev/null; then
        printf "  %-18s ${GREEN}[INSTALLED]${RESET} %s\n" "arm64-toolchain" "ARM64 GCC & sysroot (support/toolchains)"
    else
        printf "  %-18s ${RED}[MISSING]${RESET}   %s\n" "arm64-toolchain" "ARM64 GCC & sysroot (support/toolchains)"
        all_ok=false
    fi

    echo "------------------------------------------------------------"
    if [[ "$all_ok" == "true" ]]; then
        echo -e "${GREEN}[✓] All build tooling requirements are satisfied!${RESET}"
        return 0
    else
        echo -e "${YELLOW}[!] Some required tools are missing.${RESET}"
        return 1
    fi
}

install_host_packages() {
    echo -e "${CYAN}==> Installing required host packages for distribution: ${DISTRO_FAMILY}...${RESET}"

    if [[ -z "$PRIV_ESC" && $(id -u) -ne 0 ]]; then
        echo -e "${RED}Error: Administrator privileges required (pkexec or sudo not found).${RESET}"
        return 1
    fi

    case "$DISTRO_FAMILY" in
        arch)
            local arch_pkgs=(
                dpkg
                pnpm
                qemu-user-static
                qemu-user-static-binfmt
                android-tools
                patchelf
                go
                nodejs
                python
                binutils
                tar
                xz
                zstd
                curl
                rsync
                e2fsprogs
                util-linux
                xxd
                unzip
            )
            echo -e "${YELLOW}[*] Running: $PRIV_ESC pacman -S --needed --noconfirm ${arch_pkgs[*]}${RESET}"
            $PRIV_ESC pacman -S --needed --noconfirm "${arch_pkgs[@]}"

            # Ensure systemd-binfmt service is started/active
            if check_bin systemctl; then
                $PRIV_ESC systemctl restart systemd-binfmt.service 2>/dev/null || true
            fi
            ;;

        debian)
            echo -e "${YELLOW}[*] Updating APT package index...${RESET}"
            $PRIV_ESC apt-get update -y
            local deb_pkgs=(
                dpkg-dev
                android-sdk-libsparse-utils
                qemu-user-static
                binfmt-support
                patchelf
                golang
                nodejs
                python3
                python3-venv
                binutils
                tar
                xz-utils
                zstd
                curl
                rsync
                e2fsprogs
                util-linux
                xxd
                unzip
            )
            echo -e "${YELLOW}[*] Running: $PRIV_ESC apt-get install -y --no-install-recommends ${deb_pkgs[*]}${RESET}"
            $PRIV_ESC apt-get install -y --no-install-recommends "${deb_pkgs[@]}"

            # Ensure pnpm is installed
            if ! check_bin pnpm; then
                if check_bin corepack; then
                    $PRIV_ESC corepack enable || true
                    corepack prepare pnpm@latest --activate || true
                elif check_bin npm; then
                    $PRIV_ESC npm install -g pnpm || true
                fi
            fi
            ;;

        fedora)
            local fedora_pkgs=(
                dpkg-dev
                android-tools
                qemu-user-static
                patchelf
                golang
                nodejs
                python3
                binutils
                tar
                xz
                zstd
                curl
                rsync
                e2fsprogs
                util-linux
                xxd
                unzip
            )
            echo -e "${YELLOW}[*] Running: $PRIV_ESC dnf install -y ${fedora_pkgs[*]}${RESET}"
            $PRIV_ESC dnf install -y "${fedora_pkgs[@]}"

            # Ensure pnpm is installed
            if ! check_bin pnpm; then
                if check_bin npm; then
                    $PRIV_ESC npm install -g pnpm || true
                fi
            fi
            ;;

        *)
            echo -e "${RED}[!] Unsupported or unknown distribution: ${DISTRO_FAMILY}${RESET}"
            echo -e "Please install manually: dpkg-deb, pnpm, qemu-user-static, android-tools (simg2img/img2simg), patchelf, go, nodejs, xxd, unzip"
            return 1
            ;;
    esac

    echo -e "${GREEN}[✓] Host system packages installed successfully.${RESET}"
}

setup_python_venv() {
    echo -e "${CYAN}==> Setting up isolated Python build environment in ${VENV_DIR}...${RESET}"

    if [[ "$FORCE_REINSTALL" == "true" ]]; then
        rm -rf "$VENV_DIR"
    fi

    if [[ ! -d "$VENV_DIR" ]]; then
        python3 -m venv "$VENV_DIR"
        echo -e "${GREEN}[✓] Created virtual environment at ${VENV_DIR}${RESET}"
    fi

    # Install axp-tools, tqdm, and Axera signing dependencies inside the venv
    echo -e "${CYAN}==> Installing axp-tools, tqdm, rsa, pyasn1 into .venv...${RESET}"
    "${VENV_DIR}/bin/pip" install --upgrade --quiet pip setuptools wheel 2>/dev/null || true
    "${VENV_DIR}/bin/pip" install --upgrade --quiet axp-tools tqdm rsa pyasn1

    # Test axp2img in venv
    if [[ -x "${VENV_DIR}/bin/axp2img" ]]; then
        echo -e "${GREEN}[✓] axp2img installed: $(${VENV_DIR}/bin/axp2img -h 2>&1 | head -n1)${RESET}"
    else
        echo -e "${RED}[!] Failed to install axp2img into virtual environment.${RESET}"
        return 1
    fi
}

setup_toolchain() {
    echo -e "${CYAN}==> Setting up ARM64 GNU cross-compiler and target sysroot...${RESET}"

    local flags=("--non-interactive")
    if [[ "$FORCE_REINSTALL" == "true" ]]; then
        flags+=("--reinstall")
    fi

    "${SCRIPT_DIR}/toolchain_setup.sh" "${flags[@]}"
    echo -e "${GREEN}[✓] ARM64 toolchain configured.${RESET}"
}

main() {
    if [[ "$CHECK_ONLY" == "true" ]]; then
        scan_prerequisites
        exit $?
    fi

    echo -e "${BOLD}${CYAN}Starting NanoKVM Pro Tooling & Build Environment Setup${RESET}"
    echo "============================================================"

    if [[ "$SKIP_PACKAGES" != "true" ]]; then
        install_host_packages
    fi

    setup_python_venv

    if [[ "$SKIP_TOOLCHAIN" != "true" ]]; then
        setup_toolchain
    fi

    echo ""
    echo -e "${CYAN}==> Final Verification...${RESET}"
    scan_prerequisites
}

main "$@"
