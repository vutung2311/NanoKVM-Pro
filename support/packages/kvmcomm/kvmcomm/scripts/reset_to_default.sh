#!/bin/bash

set -eo pipefail

readonly LOG_DIR="/var/log/kvmcomm"
readonly LOG_FILE="${LOG_DIR}/kvm_reset_to_default.log"
readonly TMP_LOG_FILE="/tmp/kvm_reset.log"
readonly LOCK_FILE="/dev/shm/reset_in_progress.lock"

exec 1>>"$TMP_LOG_FILE"
exec 2>&1

PIKVM_VERSION="0.0.0"
NANOKVM_VERSION="0.0.0"
KVMCOMM_VERSION="0.0.0"

create_reset_lock() {
    if [ -f "$LOCK_FILE" ]; then
        echo "$(date) - Reset lock file already exists: $LOCK_FILE" >>"$LOG_FILE"
        echo "Error: Reset operation is already in progress or previous reset did not complete properly"
        exit 1
    fi

    echo "$(date) - Creating reset lock file: $LOCK_FILE" >>"$LOG_FILE"
    mkdir -p /kvmcomm
    touch "$LOCK_FILE"
    if [ $? -eq 0 ]; then
        echo "$(date) - Reset lock file created successfully" >>"$LOG_FILE"
        echo "Reset lock created"
    else
        echo "$(date) - Failed to create reset lock file" >>"$LOG_FILE"
        echo "Error: Failed to create reset lock file"
        exit 1
    fi
}

# Remove lock file when reset is completed
remove_reset_lock() {
    echo "$(date) - Removing reset lock file: $LOCK_FILE" >>"$LOG_FILE"
    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
        if [ $? -eq 0 ]; then
            echo "$(date) - Reset lock file removed successfully" >>"$LOG_FILE"
            echo "Reset lock removed"
        else
            echo "$(date) - Failed to remove reset lock file" >>"$LOG_FILE"
            echo "Warning: Failed to remove reset lock file"
        fi
    else
        echo "$(date) - Reset lock file does not exist" >>"$LOG_FILE"
    fi
}

cleanup_on_exit() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "$(date) - Script exiting with error (exit code: $exit_code)" >>"$LOG_FILE"
    fi
    remove_reset_lock
    exit $exit_code
}

trap 'echo "$(date) - Script interrupted by signal" >>"$LOG_FILE"; cleanup_on_exit' SIGINT SIGTERM
trap 'cleanup_on_exit' ERR

echo "$(date) - Starting reset to default..." >>"$LOG_FILE"

create_reset_lock

echo "Restoring default configuration files..."

rm -rf /etc/kvm/ || true
rm -rf /etc/kvmd/ || true
rm -rf /userapp || true
rm -rf /kvmcomm || true
rm -rf /kvmapp || true
rm -f /boot/usb* /boot/rndis* /boot/ncm* || true
rm -f /boot/force* || true
touch /boot/usb.ncm || true
touch /boot/first_time_boot || true

systemctl stop tailscaled || true
systemctl disable tailscaled || true
rm -rf /root/.tailscale || true
rm -rf /var/lib/tailscale || true
rm -rf /var/cache/tailscale || true
rm -f /usr/bin/tailscale || true
rm -f /usr/sbin/tailscaled || true
rm -f /etc/systemd/system/tailscaled.service || true
rm -f /etc/default/tailscaled || true

systemctl stop kvmadmin.service || true
systemctl disable kvmadmin.service || true
rm -rf /etc/kvmadmin || true
rm -rf /kvmadmin || true
rm -f /etc/systemd/system/kvmadmin.service || true

rm -f /boot/eth.nodhcp || true

systemctl daemon-reload

echo "Get deb packages versions..."

if dpkg -s nanokvm >/dev/null 2>&1; then
    NANOKVM_VERSION=$(dpkg -s nanokvm | grep '^Version:' | awk '{print $2}')
    echo "$(date) - nanokvm version: $NANOKVM_VERSION" >>"$LOG_FILE"
else
    echo "$(date) - nanokvm package not found" >>"$LOG_FILE"
fi

if dpkg -s pikvm >/dev/null 2>&1; then
    PIKVM_VERSION=$(dpkg -s pikvm | grep '^Version:' | awk '{print $2}')
    echo "$(date) - pikvm version: $PIKVM_VERSION" >>"$LOG_FILE"
else
    echo "$(date) - pikvm package not found" >>"$LOG_FILE"
fi

if dpkg -s kvmcomm >/dev/null 2>&1; then
    KVMCOMM_VERSION=$(dpkg -s kvmcomm | grep '^Version:' | awk '{print $2}')
    echo "$(date) - kvmcomm version: $KVMCOMM_VERSION" >>"$LOG_FILE"
else
    echo "$(date) - kvmcomm package not found" >>"$LOG_FILE"
fi

echo "Package versions - nanokvm: $NANOKVM_VERSION, pikvm: $PIKVM_VERSION, kvmcomm: $KVMCOMM_VERSION"

readonly CDN_URLS=(
    "https://cdn.sipeed.com/nanokvm"
    "https://cdn.sipeed.com/nanokvm/preview"
)

readonly CACHE_BASE_DIR="/root/.kvmcache"

# Check if package exists in cache
has_cached_package() {
    local pkg_name="$1"
    local arch="arm64"

    local deb_pkg_name
    case "$pkg_name" in
        "nanokvm")
            deb_pkg_name="nanokvmpro"
            ;;
        "pikvm")
            deb_pkg_name="pikvm"
            ;;
        "kvmcomm")
            deb_pkg_name="kvmcomm"
            ;;
        *)
            return 1
            ;;
    esac

    # Check if any version of this package exists in cache
    if [ -d "$CACHE_BASE_DIR" ]; then
        for version_dir in "${CACHE_BASE_DIR}"/nanokvm_pro_*/; do
            if [ -d "$version_dir" ] && ls "${version_dir}${deb_pkg_name}_"*"_${arch}.deb" >/dev/null 2>&1; then
                local cached_file=$(ls "${version_dir}${deb_pkg_name}_"*"_${arch}.deb" | head -1)
                echo "$(date) - Found cached package: $(basename "$cached_file") in $(basename "$version_dir")" >>"$LOG_FILE"
                return 0
            fi
        done
    fi
    return 1
}

get_latest_version() {
    # Get latest version from nanokvm_pro_latest.json (all packages share the same version)
    for cdn_url in "${CDN_URLS[@]}"; do
        local json_url="${cdn_url}/nanokvm_pro_latest.json"
        echo "$(date) - Trying to get latest version from: $json_url" >>"$LOG_FILE"

        # Get version from JSON endpoint
        local latest_version
        latest_version=$(curl -fsSL "$json_url" 2>/dev/null | \
            grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | \
            sed 's/"version"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')

        if [ -n "$latest_version" ]; then
            echo "$(date) - Found latest version: $latest_version" >>"$LOG_FILE"
            echo "$latest_version"
            return 0
        fi
    done

    echo "$(date) - Failed to get latest version" >>"$LOG_FILE"
    return 1
}

get_latest_package_info() {
    # Get latest package information (version, filename, sha512, size)
    for cdn_url in "${CDN_URLS[@]}"; do
        local json_url="${cdn_url}/nanokvm_pro_latest.json"
        echo "$(date) - Trying to get latest package info from: $json_url" >>"$LOG_FILE"

        local json_content
        json_content=$(curl -fsSL "$json_url" 2>/dev/null)

        if [ -n "$json_content" ]; then
            local version=$(echo "$json_content" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/"version"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
            local filename=$(echo "$json_content" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/"name"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
            local sha512=$(echo "$json_content" | grep -o '"sha512"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/"sha512"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
            local size=$(echo "$json_content" | grep -o '"size"[[:space:]]*:[[:space:]]*[0-9]*' | sed 's/"size"[[:space:]]*:[[:space:]]*\([0-9]*\)/\1/')

            if [ -n "$version" ] && [ -n "$filename" ]; then
                echo "$(date) - Found latest package: version=$version, filename=$filename, sha512=$sha512, size=$size" >>"$LOG_FILE"
                # Return in format: version|filename|sha512|size
                echo "${version}|${filename}|${sha512}|${size}"
                return 0
            fi
        fi
    done

    echo "$(date) - Failed to get latest package info" >>"$LOG_FILE"
    return 1
}

check_package() {
    local pkg_name="$1"
    local version="$2"
    local arch="arm64"

    # If version is 0.0.0, check if we have cached package
    if [ "$version" = "0.0.0" ]; then
        if has_cached_package "$pkg_name"; then
            echo "$(date) - Package $pkg_name version is 0.0.0 but found cached package, using cached version" >>"$LOG_FILE"
            echo "Found cached $pkg_name package (version was 0.0.0)"
            return 0
        else
            # No cached package, get latest version
            version=$(get_latest_version)
            echo "$(date) - Package $pkg_name version is 0.0.0 and no cached package, using latest version: $version" >>"$LOG_FILE"
            echo "Package $pkg_name version is 0.0.0 and no cached package found, need to download version: $version"
        fi
    fi

    local deb_pkg_name
    case "$pkg_name" in
        "nanokvm")
            deb_pkg_name="nanokvmpro"
            ;;
        "pikvm")
            deb_pkg_name="pikvm"
            ;;
        "kvmcomm")
            deb_pkg_name="kvmcomm"
            ;;
        *)
            echo "$(date) - Unknown package name: $pkg_name" >>"$LOG_FILE"
            return 1
            ;;
    esac

    local deb_file="${deb_pkg_name}_${version}_${arch}.deb"
    local cache_dir="${CACHE_BASE_DIR}/nanokvm_pro_${version}"
    local cache_path="${cache_dir}/${deb_file}"

    if [ -f "$cache_path" ]; then
        echo "$(date) - Found cached package: $deb_file" >>"$LOG_FILE"
        echo "Found cached $pkg_name package: $deb_file"
        return 0
    fi

    if [ -d "$CACHE_BASE_DIR" ]; then
        local found_file=$(find "$CACHE_BASE_DIR" -maxdepth 2 -type f -name "${deb_pkg_name}_*_${arch}.deb" 2>/dev/null | head -1)
        if [ -n "$found_file" ] && [ -f "$found_file" ]; then
            echo "$(date) - Found cached package: $(basename "$found_file") at $found_file" >>"$LOG_FILE"
            return 0
        fi
    fi

    echo "$(date) - Package $deb_pkg_name not found in cache" >>"$LOG_FILE"
    echo "Package $pkg_name not found in cache"
    return 1
}

# Download and extract package bundle from CDN
download_packages() {
    local version="$1"
    local tar_file=""

    # If version is 0.0.0, get latest version and package info
    if [ "$version" = "0.0.0" ]; then
        local pkg_info=$(get_latest_package_info)
        if [ -z "$pkg_info" ]; then
            echo "$(date) - Failed to get latest package info" >>"$LOG_FILE"
            echo "Error: Failed to get latest package info"
            return 1
        fi

        # Parse package info (format: version|filename|sha512|size)
        version=$(echo "$pkg_info" | cut -d'|' -f1)
        tar_file=$(echo "$pkg_info" | cut -d'|' -f2)
        local sha512=$(echo "$pkg_info" | cut -d'|' -f3)
        local size=$(echo "$pkg_info" | cut -d'|' -f4)

        echo "$(date) - Using latest version: $version, file: $tar_file" >>"$LOG_FILE"
    else
        # Use version-based filename if specific version provided
        tar_file="nanokvm_pro_${version}.tar.gz"
    fi

    local cache_dir="${CACHE_BASE_DIR}/nanokvm_pro_${version}"
    local tar_path="${CACHE_BASE_DIR}/${tar_file}"

    if [ ! -d "$CACHE_BASE_DIR" ]; then
        echo "$(date) - Creating cache base directory: $CACHE_BASE_DIR" >>"$LOG_FILE"
        mkdir -p "$CACHE_BASE_DIR"
    fi

    # Check if packages already extracted
    if [ -d "$cache_dir" ] && [ -f "${cache_dir}/nanokvmpro_${version}_arm64.deb" ] && \
       [ -f "${cache_dir}/pikvm_${version}_arm64.deb" ] && \
       [ -f "${cache_dir}/kvmcomm_${version}_arm64.deb" ]; then
        echo "$(date) - All packages already exist in cache directory" >>"$LOG_FILE"
        echo "All packages already extracted in cache"
        return 0
    fi

    echo "$(date) - Downloading package bundle $tar_file..." >>"$LOG_FILE"
    echo "Downloading package bundle: $tar_file"

    local downloaded=false
    for cdn_url in "${CDN_URLS[@]}"; do
        local download_url="${cdn_url}/${tar_file}"
        echo "$(date) - Trying to download from: $download_url" >>"$LOG_FILE"

        if curl -fsSL "$download_url" -o "$tar_path"; then
            echo "$(date) - Successfully downloaded from: $download_url" >>"$LOG_FILE"
            echo "Successfully downloaded $tar_file"
            downloaded=true
            break
        else
            echo "$(date) - Failed to download from: $download_url" >>"$LOG_FILE"
        fi
    done

    if [ "$downloaded" = false ]; then
        echo "$(date) - Failed to download $tar_file from all CDN sources" >>"$LOG_FILE"
        echo "Error: Failed to download $tar_file from all CDN sources"
        return 1
    fi

    # Extract tar.gz file
    echo "$(date) - Extracting $tar_file to $CACHE_BASE_DIR..." >>"$LOG_FILE"
    echo "Extracting package bundle..."

    if tar -xzf "$tar_path" -C "$CACHE_BASE_DIR" 2>>"$LOG_FILE"; then
        echo "$(date) - Successfully extracted $tar_file" >>"$LOG_FILE"
        echo "Successfully extracted all packages"

        # Remove tar file after extraction
        rm -f "$tar_path"
        echo "$(date) - Removed tar file: $tar_path" >>"$LOG_FILE"

        return 0
    else
        echo "$(date) - Failed to extract $tar_file" >>"$LOG_FILE"
        echo "Error: Failed to extract $tar_file"
        rm -f "$tar_path"
        return 1
    fi
}

echo "Checking and downloading backup deb packages..."

# Determine which version to use (all packages should have same version)
VERSION_TO_USE="$NANOKVM_VERSION"
if [ "$VERSION_TO_USE" = "0.0.0" ]; then
    VERSION_TO_USE="$PIKVM_VERSION"
fi
if [ "$VERSION_TO_USE" = "0.0.0" ]; then
    VERSION_TO_USE="$KVMCOMM_VERSION"
fi

echo "$(date) - Using version: $VERSION_TO_USE" >>"$LOG_FILE"

need_download=false
for pkg in "nanokvm:$VERSION_TO_USE" "pikvm:$VERSION_TO_USE" "kvmcomm:$VERSION_TO_USE"; do
    pkg_name="${pkg%:*}"
    pkg_version="${pkg#*:}"

    if ! check_package "$pkg_name" "$pkg_version"; then
        echo "$(date) - Package $pkg_name not cached, will download all packages" >>"$LOG_FILE"
        need_download=true
        break
    fi
done

if [ "$need_download" = true ]; then
    echo "Downloading all packages..."
    download_packages "$VERSION_TO_USE"
else
    echo "$(date) - All packages found in cache" >>"$LOG_FILE"
    echo "All packages found in cache"
fi

echo "Resetting system user passwords..."

# Reset root password
echo "$(date) - Resetting root password" >>"$LOG_FILE"
echo "root:sipeed" | chpasswd
if [ $? -eq 0 ]; then
    echo "$(date) - Successfully reset root password" >>"$LOG_FILE"
    echo "Root password reset to: sipeed"
else
    echo "$(date) - Failed to reset root password" >>"$LOG_FILE"
    echo "Error: Failed to reset root password"
fi

echo "Reinstalling deb packages..."

# Function to reinstall packages from cache
reinstall_packages() {
    echo "$(date) - Starting package reinstallation" >>"$LOG_FILE"

    local packages=("nanokvm" "pikvm" "kvmcomm")
    local arch="arm64"

    for pkg_name in "${packages[@]}"; do
        local deb_pkg_name
        case "$pkg_name" in
            "nanokvm")
                deb_pkg_name="nanokvmpro"
                ;;
            "pikvm")
                deb_pkg_name="pikvm"
                ;;
            "kvmcomm")
                deb_pkg_name="kvmcomm"
                ;;
        esac

        # Find the cached package file
        local cached_file=""
        if [ -d "$CACHE_BASE_DIR" ]; then
            cached_file=$(find "$CACHE_BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "${deb_pkg_name}_*_${arch}.deb" 2>/dev/null | sort -V -r | head -1)
            if [ -z "$cached_file" ]; then
                cached_file=$(find "$CACHE_BASE_DIR" -maxdepth 1 -type f -name "${deb_pkg_name}_*_${arch}.deb" 2>/dev/null | sort -V -r | head -1)
            fi
        fi

        if [ -n "$cached_file" ] && [ -f "$cached_file" ]; then
            echo "$(date) - Reinstalling $pkg_name from: $(basename "$cached_file")" >>"$LOG_FILE"
            echo "Reinstalling $pkg_name package: $(basename "$cached_file")"

            # Use dpkg to install/reinstall the package
            if DEBIAN_FRONTEND=noninteractive dpkg -i --force-confmiss "$cached_file" 2>>"$TMP_LOG_FILE"; then
                echo "$(date) - Successfully reinstalled $pkg_name" >>"$LOG_FILE"
                echo "Successfully reinstalled $pkg_name"
            else
                echo "$(date) - Failed to reinstall $pkg_name" >>"$LOG_FILE"
                echo "Error: Failed to reinstall $pkg_name"
            fi
        else
            echo "$(date) - No cached package found for $pkg_name, skipping reinstall" >>"$LOG_FILE"
            echo "Warning: No cached package found for $pkg_name, skipping reinstall"
        fi
    done

    echo "$(date) - Running apt-get install -f to fix dependencies" >>"$LOG_FILE"
    echo "Fixing package dependencies..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -f -y >>"$LOG_FILE" 2>&1; then
        echo "$(date) - Successfully fixed package dependencies" >>"$LOG_FILE"
        echo "Package dependencies fixed successfully"
    else
        echo "$(date) - Failed to fix package dependencies" >>"$LOG_FILE"
        echo "Warning: Failed to fix some package dependencies"
    fi
}

reinstall_packages

if [ -f "/etc/kvmd/scripts/pikvm_init.sh" ]; then
    echo "$(date) - Executing PiKVM initialization script" >>"$LOG_FILE"
    if bash /etc/kvmd/scripts/pikvm_init.sh >>"$LOG_FILE" 2>&1; then
        echo "$(date) - Successfully executed pikvm_init.sh" >>"$LOG_FILE"
        echo "PiKVM initialization completed successfully"
    else
        echo "$(date) - Failed to execute pikvm_init.sh" >>"$LOG_FILE"
        echo "Warning: Failed to execute PiKVM initialization script"
    fi
else
    echo "$(date) - pikvm_init.sh not found, skipping initialization" >>"$LOG_FILE"
fi

if [ -f "/usr/share/zoneinfo/Asia/Shanghai" ]; then
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    echo "Asia/Shanghai" > /etc/timezone
    if [ $? -eq 0 ]; then
        echo "$(date) - Successfully reset timezone to Asia/Shanghai" >>"$LOG_FILE"
    else
        echo "$(date) - Failed to reset timezone" >>"$LOG_FILE"
    fi
else
    echo "$(date) - Timezone file not found: /usr/share/zoneinfo/Asia/Shanghai" >>"$LOG_FILE"
fi

cat /kvmcomm/edid/E56-2K60FPS.bin > /proc/lt6911_info/edid

echo "$(date) - Reset to default completed" >>"$LOG_FILE"
echo "Reset to default process completed successfully"

remove_reset_lock
systemctl reboot
