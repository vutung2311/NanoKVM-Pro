#!/bin/sh
# Give eth0 its per-device MAC before ifplugd brings the link up.
#
# The vendor initramfs derives a stable MAC from the device key on every boot
# and writes it to /etc/network/interfaces as "hwaddress ether <mac>". ifupdown
# was the only reader of that line, and eth0 is now managed by ifplugd, so
# without this the MAC is never applied and systemd's MACAddressPolicy picks
# one from /etc/machine-id instead. Run as ExecStartPre of ifplugd.service.
#
# Never fails: a missing or odd value leaves the current MAC alone.
IFACE="${1:-eth0}"
INTERFACES="${ETH_MAC_INTERFACES:-/etc/network/interfaces}" # overridable for tests
SYSFS="${ETH_MAC_SYSFS:-/sys/class/net}"

mac=$(sed -n 's/^[[:space:]]*hwaddress[[:space:]]\{1,\}ether[[:space:]]\{1,\}\([0-9A-Fa-f:]\{17\}\)[[:space:]]*$/\1/p' \
    "$INTERFACES" 2>/dev/null | tail -n 1 | tr 'A-F' 'a-f')

case "$mac" in
"" | 00:00:00:00:00:00) exit 0 ;;
esac
case "$mac" in
[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
*)
    echo "eth_mac: ignoring malformed hwaddress '$mac'" >&2
    exit 0
    ;;
esac
# Must be unicast (least significant bit of the first octet clear).
if [ $((0x${mac%%:*} & 1)) -ne 0 ]; then
    echo "eth_mac: ignoring multicast hwaddress $mac" >&2
    exit 0
fi

[ -e "$SYSFS/$IFACE" ] || exit 0
[ "$(cat "$SYSFS/$IFACE/address" 2>/dev/null)" = "$mac" ] && exit 0

ip link set dev "$IFACE" down 2>/dev/null || true
if ip link set dev "$IFACE" address "$mac"; then
    echo "eth_mac: $IFACE MAC set to $mac"
else
    echo "eth_mac: could not set $IFACE MAC to $mac" >&2
fi
exit 0
