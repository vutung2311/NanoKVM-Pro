#!/usr/bin/env bash
set -euo pipefail

# Determine absolute paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." &>/dev/null && pwd -P)"
CONFIG_FILE="${SCRIPT_DIR}/config.ini"
GETCONFIG_PY="${SCRIPT_DIR}/getconfig.py"
TOOLCHAINS_DIR="${SCRIPT_DIR}/../toolchains"

# Locate Python binary
PYTHON_BIN="$(command -v python3 || command -v python || true)"

# Operational flags
NON_INTERACTIVE=false
FORCE_REINSTALL=false
CHECK_ONLY=false

# Parse CLI options
for arg in "$@"; do
    case "$arg" in
        -y|--yes|--non-interactive)
            NON_INTERACTIVE=true
            ;;
        -f|--force|--reinstall)
            FORCE_REINSTALL=true
            ;;
        -c|--check)
            CHECK_ONLY=true
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [options]"
            echo "Options:"
            echo "  -y, --yes, --non-interactive  Run non-interactively (skip re-install if valid)"
            echo "  -f, --force, --reinstall      Force re-download and re-install of the toolchain"
            echo "  -c, --check                   Check if toolchain is installed and valid (exit 0/1)"
            echo "  -h, --help                    Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            exit 1
            ;;
    esac
done

# Function to check if an executable exists and is executable
check_executable() {
    local exe_path=$1
    local exe_name
    exe_name=$(basename "$exe_path")

    if [[ ! -x "$exe_path" ]]; then
        echo "Error: Executable file does not exist or is not executable [$exe_name]"
        return 1
    fi

    # Try to get version information with a timeout protection
    if ! timeout 5s "$exe_path" --version &>/dev/null; then
        echo "Error: Unable to get version information [$exe_name]"
        return 1
    fi

    echo "Verification passed: $exe_name $("$exe_path" --version | head -n1)"
    return 0
}

# Function to validate the toolchain
validate_toolchain() {
    local target_dir=$1
    local cc cxx ld

    # Build full paths
    cc="${target_dir}/${cc_path}"
    cxx="${target_dir}/${cxx_path}"
    ld="${target_dir}/${ld_path}"

    # Parallel verification of the three executable files
    local check_results=0
    check_executable "$cc" || check_results=$((check_results | 1))
    check_executable "$cxx" || check_results=$((check_results | 2))
    check_executable "$ld" || check_results=$((check_results | 4))

    if [[ $check_results -ne 0 ]]; then
        echo "Key component verification failed, error code: $check_results"
        return 1
    fi
    return 0
}

# Function to generate the toolchain configuration file
gen_toolchain_path() {
    local target_dir=$1
    local cc cxx ld

    # Build full paths
    cc="${target_dir}/${cc_path}"
    cxx="${target_dir}/${cxx_path}"
    ld="${target_dir}/${ld_path}"

    # Create toolchain.ini file in absolute directory
    mkdir -p "${TOOLCHAINS_DIR}"
    cat <<EOF >"${TOOLCHAINS_DIR}/toolchain.ini"
[toolchain]
cc = $cc
cxx = $cxx
ld = $ld
EOF

    return 0
}

# Function to install libopus for ARM64 cross-compilation into target sysroot
install_libopus() {
    local target_dir=$1
    local sysroot="${target_dir}/aarch64-none-linux-gnu/libc"

    # Check if libopus already installed in sysroot
    if [[ -f "${sysroot}/usr/include/opus/opus.h" ]] && { [[ -f "${sysroot}/usr/lib/libopus.so" ]] || [[ -f "${sysroot}/usr/lib/libopus.a" ]]; }; then
        echo "libopus for ARM64 already present in target sysroot, skipping download."
        return 0
    fi

    echo "Installing target ARM64 libopus sysroot libraries (for AX630C Ubuntu 22.04 LTS target)..."

    # Verify prerequisite tools for unpacking deb
    for tool in curl ar tar; do
        if ! command -v "$tool" &>/dev/null; then
            echo "Error: Required tool '$tool' is missing (needed to unpack target libraries)."
            return 1
        fi
    done

    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'cd /; rm -rf "${temp_dir:-}"' RETURN INT TERM

    # Read libopus URLs from config, with defaults for backward compatibility
    local libopus_url libopus_dev_url
    libopus_url=$("$PYTHON_BIN" "$GETCONFIG_PY" "$CONFIG_FILE" "libopus" "url" 2>/dev/null || true)
    libopus_dev_url=$("$PYTHON_BIN" "$GETCONFIG_PY" "$CONFIG_FILE" "libopus" "dev_url" 2>/dev/null || true)

    # Use default values if not configured
    if [[ -z "$libopus_url" ]]; then
        libopus_url="https://ports.ubuntu.com/ubuntu-ports/pool/main/o/opus/libopus0_1.3.1-0.1build2_arm64.deb"
    fi
    if [[ -z "$libopus_dev_url" ]]; then
        libopus_dev_url="https://ports.ubuntu.com/ubuntu-ports/pool/main/o/opus/libopus-dev_1.3.1-0.1build2_arm64.deb"
    fi

    cd "$temp_dir"

    # Download libopus0
    echo "Downloading libopus0..."
    if ! curl -sL -o libopus0.deb "$libopus_url"; then
        echo "Warning: Failed to download libopus0, audio input feature may not work"
        cd - > /dev/null
        rm -rf "$temp_dir"
        return 1
    fi

    # Download libopus-dev
    echo "Downloading libopus-dev..."
    if ! curl -sL -o libopus-dev.deb "$libopus_dev_url"; then
        echo "Warning: Failed to download libopus-dev, audio input feature may not work"
        cd - > /dev/null
        rm -rf "$temp_dir"
        return 1
    fi

    # Extract libopus0
    mkdir -p libopus0
    cd libopus0
    ar x ../libopus0.deb
    if [[ -f data.tar.xz ]]; then
        tar xf data.tar.xz
    elif [[ -f data.tar.zst ]]; then
        zstd -d data.tar.zst -o data.tar && tar xf data.tar
    elif [[ -f data.tar.gz ]]; then
        tar xzf data.tar.gz
    fi
    cd ..

    # Extract libopus-dev
    mkdir -p libopus-dev
    cd libopus-dev
    ar x ../libopus-dev.deb
    if [[ -f data.tar.xz ]]; then
        tar xf data.tar.xz
    elif [[ -f data.tar.zst ]]; then
        zstd -d data.tar.zst -o data.tar && tar xf data.tar
    elif [[ -f data.tar.gz ]]; then
        tar xzf data.tar.gz
    fi
    cd ..

    # Install to sysroot - libraries
    if [[ -d libopus0/usr/lib/aarch64-linux-gnu ]]; then
        mkdir -p "${sysroot}/usr/lib"
        cp -a libopus0/usr/lib/aarch64-linux-gnu/libopus.so* "${sysroot}/usr/lib/" 2>/dev/null || true
    fi

    # Install to sysroot - headers and static library
    if [[ -d libopus-dev/usr/include/opus ]]; then
        mkdir -p "${sysroot}/usr/include"
        cp -a libopus-dev/usr/include/* "${sysroot}/usr/include/" 2>/dev/null || true

        if [[ -d libopus-dev/usr/lib/aarch64-linux-gnu ]]; then
            cp -a libopus-dev/usr/lib/aarch64-linux-gnu/libopus.a "${sysroot}/usr/lib/" 2>/dev/null || true
            cp -a libopus-dev/usr/lib/aarch64-linux-gnu/pkgconfig "${sysroot}/usr/lib/" 2>/dev/null || true
        fi
    fi

    # Cleanup
    cd - > /dev/null
    rm -rf "$temp_dir"

    echo "libopus installation completed"
    return 0
}

# Function to generate the Conan profile file
gen_conan_profile() {
    local target_dir=$1
    local cc cxx ld

    # Build full paths
    cc="${target_dir}/${cc_path}"
    cxx="${target_dir}/${cxx_path}"
    ld="${target_dir}/${ld_path}"

    cat <<EOF >"${SCRIPT_DIR}/NanoKVM-Pro"
[settings]
os=Linux
arch=armv8
compiler=gcc
build_type=Release
compiler.cppstd=gnu23
compiler.libcxx=libstdc++
compiler.version=11
[buildenv]
CC=$cc
CXX=$cxx
LD=$ld
EOF
}

# Function to check if an installation exists
is_installed() {
    local target_dir=$1
    [[ -d "${target_dir}/bin" ]] && return 0 || return 1
}

# Function to prompt the user for reinstallation options
prompt_reinstall() {
    local target_dir=$1
    echo "Detected installed version: $(basename "$target_dir")"
    PS3='Please select an option: '
    select opt in "Skip installation" "Reinstall" "Exit"; do
        case $opt in
        "Skip installation")
            echo "Skipped installation"
            exit 0
            ;;
        "Reinstall")
            echo "Preparing to reinstall..."
            rm -rf "$target_dir" # Delete old version
            mkdir -p "$target_dir"
            return 0
            ;;
        "Exit")
            echo "Operation cancelled"
            exit 1
            ;;
        *)
            echo "Invalid option, please select again"
            ;;
        esac
    done
}

# Main installation process
main() {
    if [[ -z "$PYTHON_BIN" ]]; then
        echo "Error: Python 3 or Python is required to read configuration."
        exit 1
    fi

    if [[ ! -f "$CONFIG_FILE" || ! -f "$GETCONFIG_PY" ]]; then
        echo "Error: Config file ($CONFIG_FILE) or helper script ($GETCONFIG_PY) not found."
        exit 1
    fi

    # Parse configuration
    local section="toolchain"
    local name url sha256
    name=$("$PYTHON_BIN" "$GETCONFIG_PY" "$CONFIG_FILE" "$section" "name")
    url=$("$PYTHON_BIN" "$GETCONFIG_PY" "$CONFIG_FILE" "$section" "url")
    sha256=$("$PYTHON_BIN" "$GETCONFIG_PY" "$CONFIG_FILE" "$section" "sha256")

    cc_path=$("$PYTHON_BIN" "$GETCONFIG_PY" "$CONFIG_FILE" "$section" "cc")
    cxx_path=$("$PYTHON_BIN" "$GETCONFIG_PY" "$CONFIG_FILE" "$section" "cxx")
    ld_path=$("$PYTHON_BIN" "$GETCONFIG_PY" "$CONFIG_FILE" "$section" "ld")

    # Validate key fields
    if [[ -z "$name" || -z "$url" || -z "$sha256" ]]; then
        echo "Error: Missing necessary fields in configuration file"
        echo "Parsed results:"
        echo "Name: $name"
        echo "URL: $url"
        echo "SHA256: $sha256"
        exit 1
    fi
    if [[ -z "$cc_path" || -z "$cxx_path" || -z "$ld_path" ]]; then
        echo "Error: Missing compiler path configuration"
        exit 1
    fi

    local target_dir="${TOOLCHAINS_DIR}/${name}"

    # Check-only mode
    if [[ "$CHECK_ONLY" == "true" ]]; then
        if is_installed "$target_dir" && validate_toolchain "$target_dir" >/dev/null 2>&1; then
            echo "Toolchain is installed and valid: ${target_dir}"
            exit 0
        else
            echo "Toolchain is NOT installed or invalid."
            exit 1
        fi
    fi

    # Installation detection and handling
    if is_installed "$target_dir"; then
        if [[ "$FORCE_REINSTALL" == "true" ]]; then
            echo "Force reinstall requested. Removing old toolchain..."
            rm -rf "$target_dir"
            mkdir -p "$target_dir"
        elif [[ "$NON_INTERACTIVE" == "true" ]]; then
            if validate_toolchain "$target_dir" >/dev/null 2>&1; then
                echo "Toolchain already installed and valid: $(basename "$target_dir")"
                gen_toolchain_path "$target_dir"
                install_libopus "$target_dir"
                exit 0
            else
                echo "Existing toolchain failed validation; reinstalling..."
                rm -rf "$target_dir"
                mkdir -p "$target_dir"
            fi
        else
            prompt_reinstall "$target_dir"
        fi
    else
        mkdir -p "$target_dir"
    fi

    # Download file (supports resuming download)
    local temp_file
    temp_file=$(mktemp "${TMPDIR:-/tmp}/toolchain.XXXXXX")
    trap 'rm -f "${temp_file:-}"' EXIT INT TERM
    echo "Downloading toolchain: ${url}"
    if ! curl -#L -o "$temp_file" "$url"; then
        echo "Download failed, please check:"
        echo "1. URL validity"
        echo "2. Network connection"
        echo "3. Disk space"
        rm -f "$temp_file"
        exit 1
    fi

    # Hash verification
    echo "Verifying file integrity..."
    local computed_sha256
    computed_sha256=$(sha256sum "$temp_file" | awk '{print $1}')
    if [[ "$computed_sha256" != "$sha256" ]]; then
        echo "Security verification failed!"
        echo "Expected value: $sha256"
        echo "Actual value: $computed_sha256"
        rm -f "$temp_file"
        exit 1
    fi

    # Extract installation
    echo "Installing to: ${target_dir}"
    if ! tar -xJf "$temp_file" -C "$target_dir" --strip-components=1; then
        echo "Extraction failed, possible reasons:"
        echo "1. File corruption (please re-download)"
        echo "2. Insufficient disk space"
        echo "3. Permission issues"
        rm -f "$temp_file"
        exit 1
    fi
    rm -f "$temp_file"

    if ! validate_toolchain "$target_dir"; then
        echo "Detected damaged installation, triggering reinstallation..."
        rm -rf "$target_dir"
        main "$@"
        return
    fi

    if ! gen_toolchain_path "$target_dir"; then
        return
    fi

    if ! gen_conan_profile "$target_dir"; then
        return
    fi

    # Install additional libraries for cross-compilation into target sysroot
    install_libopus "$target_dir"
}

main "$@"
