#!/usr/bin/env bash

# Wi-Fi reconnect on boot is kvmcomm.sh's job (`wifi.sh try_connect`); a
# second trigger here flushed the address and restarted DHCP on a link that
# was already up.

trap 'exit 0' SIGINT SIGTERM

while true; do
    sleep 10
done
