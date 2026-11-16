#!/bin/bash
# Idempotent one-time repairs of device state that older images or packages
# left behind. Run from kvmcomm's postinst (dpkg installs) and from kvmcomm.sh
# at boot, so a firmware-package update, which only copies /kvmcomm/scripts and
# a few /etc files and never runs postinst, gets them as well. Every repair is
# a no-op once applied.
set -u

# The vendor initramfs appends "hwaddress ether <mac>" to this file on every
# boot. Without an iface stanza before it ifupdown rejects the whole file
# ("misplaced option") and networking.service fails. Move such orphaned lines
# into an "iface eth0 inet manual" stanza; the initramfs then updates the
# line in place. Idempotent: a file whose hwaddress already follows an iface
# line is left alone.
if [ -f /etc/network/interfaces ]; then
    orphan_mac=$(awk '
        /^[[:space:]]*iface[[:space:]]/ { seen = 1 }
        !seen && /^[[:space:]]*hwaddress[[:space:]]+ether[[:space:]]/ { mac = $3 }
        END { print mac }' /etc/network/interfaces)
    if [ -n "$orphan_mac" ]; then
        tmp_if=$(mktemp /etc/network/interfaces.XXXXXX)
        awk '
            /^[[:space:]]*iface[[:space:]]/ { seen = 1 }
            !seen && /^[[:space:]]*hwaddress[[:space:]]+ether[[:space:]]/ { next }
            { print }' /etc/network/interfaces >"$tmp_if"
        printf '\n# eth0 is managed by ifplugd; the initramfs fills in the MAC below.\niface eth0 inet manual\n    hwaddress ether %s\n' \
            "$orphan_mac" >>"$tmp_if"
        chmod 644 "$tmp_if"
        mv -f "$tmp_if" /etc/network/interfaces
        echo "kvmcomm: moved the orphaned eth0 hwaddress line into an iface stanza"
    fi
fi

# kvmcomm points /bin/sh at bash (see kvmcomm.sh), but ifupdown's resolved
# hooks are written for dash: they leave early with a top-level "return",
# which dash treats as exit and bash rejects. The hook then fails with code 2,
# ifup fails on lo, and networking.service fails at every boot. Make those
# returns the exits dash takes them as. Idempotent: no top-level return left.
for hook in /etc/network/if-up.d/resolved /etc/network/if-down.d/resolved; do
    [ -f "$hook" ] || continue
    if grep -qE '^[[:space:]]+return[[:space:]]*$' "$hook"; then
        sed -i -E 's/^([[:space:]]+)return[[:space:]]*$/\1exit 0/' "$hook"
        echo "kvmcomm: made ${hook} exit instead of return (/bin/sh is bash)"
    fi
done

# apt enables Ubuntu's hostapd.service when the image is built, but nothing
# here uses it: wifi.sh starts hostapd itself, from a config it writes under
# /dev/shm. With no /etc/hostapd/hostapd.conf the unit fails at once, and
# Restart=on-failure retries it every 2 s for as long as the device runs
# (3800 restarts in a little over two hours). Disable it while that config is
# absent, so a hand-made AP setup that provides one is left alone.
if [ ! -e /etc/hostapd/hostapd.conf ] &&
    [ "$(systemctl is-enabled hostapd.service 2>/dev/null)" = enabled ]; then
    systemctl disable hostapd.service >/dev/null 2>&1 || true
    if [ -d /run/systemd/system ]; then
        systemctl stop hostapd.service >/dev/null 2>&1 || true
        systemctl reset-failed hostapd.service >/dev/null 2>&1 || true
    fi
    echo "kvmcomm: disabled hostapd.service (no /etc/hostapd/hostapd.conf; wifi.sh runs hostapd itself)"
fi

# fw_printenv/fw_setenv need the bundled libubootenv in /opt/swupdate/lib,
# which is not on the loader path. Images built before build_image.py wrote
# wrappers ship bare symlinks instead, so every call fails with
# "libubootenv.so.0: cannot open shared object file" (S99checkota among
# them). Replace such symlinks with the wrapper build_rootfs.sh installs.
# Idempotent: a wrapper is a regular file and is left alone.
if [ -d /opt/swupdate/lib ] && [ -f /opt/swupdate/bin/fw_printenv ]; then
    for tool in fw_printenv fw_setenv; do
        [ -L "/usr/bin/${tool}" ] || continue
        case $(readlink "/usr/bin/${tool}") in
            /opt/swupdate/bin/* | fw_printenv) ;;
            *) continue ;; # someone else's link: leave it
        esac
        # libubootenv's tool picks printenv/setenv mode from argv[0]
        [ -e /opt/swupdate/bin/fw_setenv ] || ln -s fw_printenv /opt/swupdate/bin/fw_setenv
        tmp_tool=$(mktemp "/usr/bin/.${tool}.XXXXXX")
        # shellcheck disable=SC2016 # expanded when the wrapper runs
        printf '#!/bin/sh\nLD_LIBRARY_PATH=/opt/swupdate/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} exec /opt/swupdate/bin/%s "$@"\n' "$tool" >"$tmp_tool"
        chmod 0755 "$tmp_tool"
        # mv replaces the link itself, never the vendor binary it points to
        mv -f "$tmp_tool" "/usr/bin/${tool}"
        echo "kvmcomm: replaced the /usr/bin/${tool} symlink with a libubootenv wrapper"
    done
fi

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
