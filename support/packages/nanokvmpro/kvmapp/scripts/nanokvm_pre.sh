#!/bin/bash
set -e

readonly RAMFS_ROOT="/dev/shm"
readonly APP_ROOT="/kvmapp"

# Eliminate ~40MB of RAM bloat on 1GB SoC by replacing duplicate file copy with symlink.
# Retains full backwards compatibility with all paths pointing to /dev/shm/kvmapp/...
rm -rf "${RAMFS_ROOT}${APP_ROOT}"
ln -sfn "${APP_ROOT}" "${RAMFS_ROOT}${APP_ROOT}"

# Ensure OpenSSH privilege separation and app directories exist
mkdir -p -m 0755 /run/sshd
mkdir -p /etc/kvm /var/log/nanokvm

