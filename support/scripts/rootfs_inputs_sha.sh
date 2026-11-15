#!/usr/bin/env bash
# Print a sha256 over everything build_rootfs.sh turns into the rootfs image:
# the script itself (which also pins the Ubuntu base tarball by sha256), the
# repository rootfs blobs and the SDK board rootfs overlay. Paths, modes and
# symlink targets count as well as file contents, since cp -a carries them
# into the image. build_rootfs.sh stamps its output with this value, and the
# image targets rebuild a rootfs whose stamp no longer matches.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." &>/dev/null && pwd -P)"

inputs=(
    "support/blobs/rootfs"
    "support/sdk/meta/build/projects/AX630C_emmc_arm64_k419_sipeed_nanokvm/rootfs"
)

{
    echo "script $(sha256sum <"${SCRIPT_DIR}/build_rootfs.sh" | cut -d' ' -f1)"
    for rel in "${inputs[@]}"; do
        dir="${REPO_ROOT}/${rel}"
        echo "dir ${rel}"
        [[ -d "${dir}" ]] || { echo "missing"; continue; }
        # Layout: every path with its mode and (for symlinks) target.
        (cd "${dir}" && find . \( -type f -o -type l -o -type d \) -printf '%p %m %y %l\n' | LC_ALL=C sort)
        # Contents of regular files.
        (cd "${dir}" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
    done
} | sha256sum | cut -d' ' -f1
