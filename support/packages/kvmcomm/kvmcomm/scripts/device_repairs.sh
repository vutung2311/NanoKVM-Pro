#!/bin/bash
# Idempotent one-time repairs of device state that older images or packages
# left behind. Run from kvmcomm's postinst (dpkg installs) and from kvmcomm.sh
# at boot, so a firmware-package update, which only copies /kvmcomm/scripts and
# a few /etc files and never runs postinst, gets them as well. Every repair is
# a no-op once applied.
set -u

# Images built before the build scripts emptied /etc/machine-id shipped one
# fixed id, shared by every device flashed from them (and with it the
# systemd-derived eth0 MAC and DHCP identity). Give this device its own,
# once. Inside an image-build chroot (no systemd running) only mark it done:
# the image is finalized with an empty id, which systemd fills on first boot.
IDENTITY_MARKER=/etc/kvm/.identity-v1
if [ ! -e "$IDENTITY_MARKER" ]; then
    if [ -d /run/systemd/system ] && [ -s /etc/machine-id ]; then
        old_id=$(cat /etc/machine-id)
        # systemd-machine-id-setup copies /var/lib/dbus/machine-id when that
        # is a regular file, and these images ship one holding the shared id:
        # point it at /etc/machine-id first, so a new id is generated.
        mkdir -p /var/lib/dbus
        ln -sfn /etc/machine-id /var/lib/dbus/machine-id
        : >/etc/machine-id
        systemd-machine-id-setup >/dev/null 2>&1 || true
        new_id=$(cat /etc/machine-id 2>/dev/null)
        if [ -n "$new_id" ] && [ "$new_id" != "$old_id" ]; then
            echo "kvmcomm: replaced the shared machine-id ${old_id} with a per-device one"
        else
            echo "$old_id" >/etc/machine-id # never leave it empty on a running system
            echo "kvmcomm: could not generate a new machine-id; kept ${old_id}" >&2
        fi
    fi
    if [ ! -d /run/systemd/system ] || [ "$(cat /etc/machine-id 2>/dev/null)" != "${old_id:-}" ]; then
        mkdir -p "$(dirname "$IDENTITY_MARKER")"
        : >"$IDENTITY_MARKER"
    fi
fi
