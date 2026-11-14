#!/bin/bash

###
### NanoKVM WiFi Manager — Wireless Network Connection and Hotspot Management Tool
###
### Usage:
###   $0 [command] [parameters]
###
### Commands:
### try_scan                         Scan for available WiFi networks and display results
### try_connect                      Read configuration file and try to connect
### connect_start <SSID> [Password]  Connect to the specified WiFi network (automatically saves the configuration to /etc/kvm/wifi.conf)
###                                  Password is optional - omit for open networks
### connect_stop                     Disconnect from the current WiFi connection
### connect_remove <SSID>            Remove a saved WiFi network from configuration
### enterprise_connect <SSID> <EAP_METHOD> <IDENTITY> [options...]
###                                  Connect to an Enterprise (802.1X) WiFi network
###                                  EAP_METHOD: PEAP, TLS, or TTLS
###                                  IDENTITY: username for authentication
###                                  Options (key=value pairs):
###                                    password=<password>       Password for PEAP/TTLS
###                                    phase2=<method>           Inner auth (default: MSCHAPv2 for PEAP, PAP for TTLS)
###                                    ca_cert=<path>            Path to CA certificate file
###                                    client_cert=<path>        Path to client certificate (EAP-TLS)
###                                    private_key=<path>        Path to private key file (EAP-TLS)
###                                    private_key_passwd=<pass> Private key password (EAP-TLS)
###                                    anonymous_identity=<id>   Anonymous/outer identity
###                                    domain=<domain>           Domain suffix match for server cert
### ap_start <SSID> <Password>       Start the WiFi hotspot (default subnet: 192.168.12.0/24)
### ap_stop                          Turn off the WiFi hotspot and restore the network
### ap_has_device                    Detect if there is device access to the hotspot (returns true/false)
### ap_ip                            Get the hotspot gateway IP address
### interface                        Display the name of the current wireless network card
### list_networks                    List saved WiFi networks in wpa_supplicant
### reset                            Remove all saved WiFi networks and reset configuration
### check_previous_wifi              Check whether it should reconnect to the previous Wi-Fi
### if_previous_wifi                 Return whether there is a previous Wi-Fi SSID
### try_previous_wifi                Try to reconnect to the previous Wi-Fi network
###
### Options:
###   -h, --help        Display this help information
###   -d, --debug      Enable debug mode (show detailed logs)
###
### Configuration:
###   Temporary Directory: /dev/shm/tmp/wifi
###   Driver Type: nl80211
###   Ethernet Interface: eth0
### Persistent Configuration: /etc/kvm/wifi.conf
###
### Example:
###   $0 ap_start MyHotspot mypassword  # Create a hotspot
###   $0 connect_start MyWiFi 12345678  # Connect to WiFi with password
###   $0 connect_start OpenWiFi         # Connect to open WiFi
###   $0 enterprise_connect CorpWiFi PEAP user@corp.com password=secret
###   $0 enterprise_connect CorpWiFi PEAP user@corp.com password=secret ca_cert=/etc/certs/ca.pem
###   $0 enterprise_connect CorpWiFi TLS user@corp.com client_cert=/etc/certs/client.pem private_key=/etc/certs/key.pem
###   $0 enterprise_connect CorpWiFi TTLS user@corp.com password=secret phase2=PAP ca_cert=/etc/certs/ca.pem
###

DEBUG="false"
for arg in "$@"; do
    if [[ "$arg" == "-d" || "$arg" == "--debug" ]]; then
        DEBUG="true"
        break
    fi
done

# Configuration Constants
readonly TMP_DIR="/dev/shm/tmp/wifi"
readonly WPA_CONF_FILE="/etc/wpa_supplicant/wpa_supplicant.conf"
readonly WPA_PID_FILE="${TMP_DIR}/wpa.pid"
readonly DRIVER="nl80211"
readonly ETH_IFACE="eth0"
readonly SUBNET="192.168.12"
readonly GATEWAY="$SUBNET.1"
readonly HOSTAPD_CONF="$TMP_DIR/hostapd.conf"
readonly UDHCPD_CONF="$TMP_DIR/udhcpd.wlan0.conf"
readonly WIFI_CFG_PATH="/etc/kvm/wifi.conf"
readonly HW_WIFI_CFG_PATH="/etc/kvm/hw/wifi"
readonly LOCK_FILE="${TMP_DIR}/wifi.lock"
readonly LOCK_FD=200
readonly PREVIOUS_WIFI_SAVE="/etc/kvm/wifi_save"
readonly PREVIOUS_WIFI="$TMP_DIR/previous_wifi"

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LC_CTYPE=en_US.UTF-8

# set -x

debug_print() {
    [[ "${DEBUG}" == "true" ]] && printf "[DEBUG] %s\n" "$*"
}

show_help() {
    sed -rn 's/^### ?//;T;p' "$0" | awk '
        BEGIN { in_example = 0 }
        /^EXAMPLE: / { in_example = 1 }
        in_example && /^###   \S/ { sub("###   ", "  "); print }
        !in_example { print }
    '
}

# Ensure temporary directory exists
mkdir -p "${TMP_DIR}" || {
    debug_print "[wifi] failed to create temporary directory: ${TMP_DIR}" >&2
    exit 1
}

# Everything created from here on holds or may hold Wi-Fi secrets:
# wpa_supplicant.conf (save_config rewrites it with wpa_supplicant's umask,
# inherited from here), hostapd.conf, ap.pass, wifi.conf. Only root reads them.
umask 077

acquire_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        debug_print "[wifi] another instance is running, waiting for lock..." >&2
        if ! flock -w 30 200; then
            echo "[wifi] failed to acquire lock after 30 seconds" >&2
            exit 1
        fi
    fi
}

release_lock() {
    flock -u 200 2>/dev/null || true
}

# Set by connect_wifi while a new profile is being tried, so that a SIGTERM
# from the caller (server timeout) can undo it before the script exits.
CONNECT_ABORT_HANDLER=""

on_signal() {
    local code="$1"
    trap - TERM INT
    if [[ -n "$CONNECT_ABORT_HANDLER" ]]; then
        "$CONNECT_ABORT_HANDLER"
    fi
    exit "$code"
}

# EXIT always releases the lock; TERM/INT must also terminate the script
# (a bare release_lock handler would drop the lock and keep running).
trap release_lock EXIT
trap 'on_signal 143' TERM
trap 'on_signal 130' INT

acquire_lock

validate_arguments() {
    local expected=$1
    local actual=$2
    ((actual >= expected)) || {
        debug_print "[wifi] invalid argument count. Expected: ${expected}, Received: ${actual}" >&2
        exit 1
    }
}

get_wireless_interface() {
    local interfaces
    interfaces=$(ip -o link show | grep -oP 'wlan\w+(?=:)' | head -1)

    if [[ -z "${interfaces}" ]]; then
        # debug_print "No available wireless interfaces detected" >&2
        return 1
    fi

    echo "${interfaces}"
}

ensure_wpa_conf() {
    if [[ ! -s "$WPA_CONF_FILE" ]]; then
        cat <<EOF >"$WPA_CONF_FILE"
ctrl_interface=/run/wpa_supplicant
update_config=1
sae_pwe=2
EOF
        debug_print "[wifi] created default wpa config at $WPA_CONF_FILE"
    else
        if ! grep -q "^sae_pwe=" "$WPA_CONF_FILE"; then
            echo "sae_pwe=2" >> "$WPA_CONF_FILE"
            debug_print "[wifi] added sae_pwe=2 to $WPA_CONF_FILE"
        fi
    fi
    # Files from older releases are 0644 and hold plaintext passphrases.
    chmod 600 "$WPA_CONF_FILE" 2>/dev/null || true
    if [[ -f "$WIFI_CFG_PATH" ]] && grep -q '^WIFI_CFG_PASSWD=' "$WIFI_CFG_PATH" 2>/dev/null; then
        chmod 600 "$WIFI_CFG_PATH" 2>/dev/null || true
    fi
}

# PIDs of wpa_supplicant processes, optionally only those started with
# "-i IFACE". Matches the process name exactly (pgrep -x): "pgrep -f
# wpa_supplicant" also matched editors, greps and anything else with the word
# in its command line.
wpa_supplicant_pids() {
    local iface="${1:-}" pid args
    for pid in $(pgrep -x wpa_supplicant 2>/dev/null); do
        if [[ -n "$iface" ]]; then
            args=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || continue
            [[ " $args" =~ \ -i\ ?${iface}( |$) ]] || continue
        fi
        echo "$pid"
    done
}

# SIGTERM first so wpa_supplicant deauthenticates from the AP and removes its
# control socket; SIGKILL only what is still alive after ~2 s.
kill_wpa_supplicant() {
    local pids i
    pids=$(wpa_supplicant_pids "${1:-}")
    [[ -n "$pids" ]] || return 0
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    for ((i = 0; i < 20; i++)); do
        pids=$(for pid in $pids; do kill -0 "$pid" 2>/dev/null && echo "$pid"; done)
        [[ -n "$pids" ]] || return 0
        sleep 0.1
    done
    debug_print "[wifi] wpa_supplicant ignored SIGTERM, killing: $pids"
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || true
}

# Append an iptables rule only if it is not there yet, so restarting the AP
# (for example for a new SSID, which skips stop_wifi_ap) never stacks copies.
# Usage: ipt_add TABLE CHAIN RULE...
ipt_add() {
    local table="$1" chain="$2"
    shift 2
    iptables -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -t "$table" -A "$chain" "$@"
}

# Delete every copy of a rule (older releases could add duplicates).
ipt_del_all() {
    local table="$1" chain="$2" i
    shift 2
    for ((i = 0; i < 16; i++)); do
        iptables -t "$table" -D "$chain" "$@" 2>/dev/null || break
    done
}

start_service() {
    local WIFI_IFACE
    WIFI_IFACE=$(get_wireless_interface) || exit 1

    ensure_wpa_conf

    if [[ -z "$(wpa_supplicant_pids "$WIFI_IFACE")" ]]; then
        # Ensure any unmanaged or stale wpa_supplicant instances are terminated to prevent EAPOL packet race conditions
        kill_wpa_supplicant
        debug_print "[wifi] starting wpa_supplicant..."
        mkdir -p /run/wpa_supplicant
        wpa_supplicant -D "${DRIVER}" -i "$WIFI_IFACE" -c "$WPA_CONF_FILE" -B -P "$WPA_PID_FILE" >/dev/null 2>&1 200>&-
        local WPA_PID=$(cat "$WPA_PID_FILE")
        echo $WPA_PID > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
        sleep 1
    fi

    if [[ ! -S "/run/wpa_supplicant/$WIFI_IFACE" ]]; then
        debug_print "[wifi] warning: control socket not found!"
    else
        debug_print "[wifi] wpa_supplicant is running on $WIFI_IFACE"
        wpa_cli -i "$WIFI_IFACE" set sae_pwe 2 >/dev/null 2>&1 || true
    fi

    ip link set dev "$WIFI_IFACE" up
}

stop_service() {
    local WIFI_IFACE
    WIFI_IFACE=$(get_wireless_interface) || { debug_print "[wifi] no wireless interface found"; return 1; }

    debug_print "[wifi] stopping wpa_supplicant on $WIFI_IFACE..."

    if [[ -f "$WPA_PID_FILE" ]]; then
        local pid
        pid=$(<"$WPA_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" && debug_print "[wifi] wpa_supplicant (PID $pid) terminated"
        fi
        rm -f "$WPA_PID_FILE"
    fi

    ip addr flush dev "$WIFI_IFACE"
}

start_wifi_ap() {
    local WIFI_IFACE=$(get_wireless_interface)
    local WIFI_SSID="$1"
    local WIFI_PSW="$2"

    if pgrep -x hostapd >/dev/null; then
        local current_ssid
        current_ssid=$(awk -F= '/^ssid=/{print $2}' "$HOSTAPD_CONF" 2>/dev/null)
        if [[ "$current_ssid" == "$WIFI_SSID" ]]; then
            debug_print "[wifi] AP '$WIFI_SSID' already active on $WIFI_IFACE, skipping reconfiguration"
            return 0
        else
            debug_print "[wifi] hostapd running with SSID '$current_ssid', restarting for new SSID '$WIFI_SSID'"
        fi
    fi

    disconnect_wifi
    stop_service

    local retry=0
    while [[ -n "$(wpa_supplicant_pids "$WIFI_IFACE")" ]] && [ $retry -lt 10 ]; do
        sleep 0.5
        ((retry++))
    done
    kill_wpa_supplicant "$WIFI_IFACE"

    pkill -x hostapd || true
    pkill -x udhcpd || true

    debug_print "[wifi] configuring interface: ${WIFI_IFACE}"
    ip addr flush dev "$WIFI_IFACE"
    ip addr add "$GATEWAY/24" dev "$WIFI_IFACE"
    ip link set dev "$WIFI_IFACE" up

    debug_print "[wifi] generating hostapd configuration"
    cat >"$HOSTAPD_CONF" <<EOF
interface=$WIFI_IFACE
driver=nl80211
ssid=$WIFI_SSID
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
ht_capab=[HT40+][SHORT-GI-20][SHORT-GI-40]
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$WIFI_PSW
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
EOF

    debug_print "[wifi] starting hostapd service"
    hostapd -B "$HOSTAPD_CONF" >/dev/null 2>&1 200>&-

    debug_print "[wifi] generating udhcpd configuration"
    cat >"$UDHCPD_CONF" <<EOF
start           ${SUBNET}.100
end             ${SUBNET}.200
interface       ${WIFI_IFACE}
opt     subnet  255.255.255.0
opt     router  ${GATEWAY}
opt     dns     8.8.8.8
lease_file      ${TMP_DIR}/udhcpd.leases
option  lease   86400
EOF

    debug_print "[wifi] starting udhcpd service"
    udhcpd "$UDHCPD_CONF" >/dev/null 2>&1 200>&-

    debug_print "[wifi] configuring network routing"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    ipt_add nat POSTROUTING -o "$ETH_IFACE" -j MASQUERADE
    ipt_add filter FORWARD -i "$WIFI_IFACE" -o "$ETH_IFACE" -j ACCEPT
    ipt_add filter FORWARD -i "$ETH_IFACE" -o "$WIFI_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT

    printf "%s" "$WIFI_PSW" > /tmp/ap.pass
    touch /tmp/wifi_config

    debug_print "[wifi] access point activated - SSID: ${WIFI_SSID} | Password: ${WIFI_PSW}"
}

stop_wifi_ap() {
    local WIFI_IFACE=$(get_wireless_interface)

    debug_print "[wifi] terminating ap services"
    pkill -x hostapd || true
    pkill -x udhcpd || true
    rm -f /tmp/ap.pass /tmp/wifi_config || true

    debug_print "[wifi] cleaning network configuration"
    ipt_del_all nat POSTROUTING -o "$ETH_IFACE" -j MASQUERADE
    ipt_del_all filter FORWARD -i "$WIFI_IFACE" -o "$ETH_IFACE" -j ACCEPT
    ipt_del_all filter FORWARD -i "$ETH_IFACE" -o "$WIFI_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT

    sysctl -w net.ipv4.ip_forward=0 >/dev/null

    debug_print "[wifi] resetting interface configuration: ${WIFI_IFACE}"
    ip addr flush dev "$WIFI_IFACE"

    debug_print "[wifi] access point deactivated successfully"
}

device_check() {
    local WIFI_IFACE
    WIFI_IFACE=$(get_wireless_interface) || {
        echo "false"
        return 1
    }

    if hostapd_cli -i "$WIFI_IFACE" list_sta 2>/dev/null | grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'; then
        echo "true"
    else
        echo "false"
    fi

    return 0
}

get_ap_ip() {
    echo "$GATEWAY"
}

try_scan() {
    local WIFI_IFACE=$(get_wireless_interface)

    if [ -z "$WIFI_IFACE" ]; then
        debug_print "[wifi] no wireless interface found" >&2
        echo "[]"
        return 1
    fi

    start_service
    debug_print "[wifi] scanning for available networks..."

    if ! wpa_cli -i "${WIFI_IFACE}" scan > /dev/null 2>&1; then
        debug_print "[wifi] scan command failed" >&2
        echo "[]"
        return 1
    fi

    sleep 2

    local scan_output
    scan_output=$(wpa_cli -i "${WIFI_IFACE}" scan_results 2>/dev/null)

    if [ -z "$scan_output" ]; then
        debug_print "[wifi] no scan results received" >&2
        echo "[]"
        return 1
    fi

    echo "$scan_output" | awk '
    NR > 1 && NF >= 5 {
        # Skip header line
        bssid = $1
        frequency = $2
        signal = $3
        flags = $4

        # Extract SSID (everything after 4th field)
        ssid = ""
        for (i = 5; i <= NF; i++) {
            ssid = ssid (i > 5 ? " " : "") $i
        }

        # Determine security type
        security = "OPEN"
        if (index(flags, "WPA2-EAP") > 0 || index(flags, "WPA-EAP") > 0) security = "EAP"
        else if (index(flags, "EAP") > 0) security = "EAP"
        else if (index(flags, "WPA2-PSK") > 0 || index(flags, "WPA2") > 0) security = "WPA2"
        else if (index(flags, "WPA-PSK") > 0 || index(flags, "WPA") > 0) security = "WPA"
        else if (index(flags, "WEP") > 0) security = "WEP"

        # Skip empty SSIDs
        if (length(ssid) == 0) next

        # Store network info using composite key, keep only the strongest signal for each SSID
        key = ssid
        if (!(key in seen) || signal > ssid_signal[key]) {
            ssid_ssid[key] = ssid
            ssid_bssid[key] = bssid
            ssid_signal[key] = signal
            ssid_freq[key] = frequency
            ssid_sec[key] = security
            seen[key] = 1
        }
    }
    END {
        # Sort by signal strength (descending)
        n = 0
        for (key in seen) {
            sorted[n] = key
            n++
        }

        # Bubble sort by signal strength
        for (i = 0; i < n-1; i++) {
            for (j = 0; j < n-i-1; j++) {
                if (ssid_signal[sorted[j]] < ssid_signal[sorted[j+1]]) {
                    temp = sorted[j]
                    sorted[j] = sorted[j+1]
                    sorted[j+1] = temp
                }
            }
        }

        # Output JSON
        print "["
        for (i = 0; i < n; i++) {
            key = sorted[i]
            if (i > 0) print ","
            printf "  {\"ssid\":\"%s\",\"bssid\":\"%s\",\"signal\":%d,\"frequency\":%d,\"security\":\"%s\"}",
                   ssid_ssid[key],
                   ssid_bssid[key],
                   ssid_signal[key],
                   ssid_freq[key],
                   ssid_sec[key]
        }
        print ""
        print "]"
    }'

    return 0
}

# True when wpa_supplicant reports COMPLETED and the interface holds an IPv4
# address.
wifi_is_connected() {
    local iface="$1"
    [[ -S "/run/wpa_supplicant/${iface}" ]] || return 1
    wpa_cli -i "$iface" status 2>/dev/null | grep -qx 'wpa_state=COMPLETED' || return 1
    ip -4 -o addr show dev "$iface" 2>/dev/null | grep -q ' inet '
}

try_connect() {
    local WIFI_IFACE
    local retry=0
    while [ $retry -lt 10 ]; do
        WIFI_IFACE=$(get_wireless_interface)
        [[ -n "$WIFI_IFACE" ]] && break
        sleep 1
        ((retry++))
    done

    if [ -z "$WIFI_IFACE" ]; then
        echo "false" >"$HW_WIFI_CFG_PATH"
        return 1
    else
        echo "true" >"$HW_WIFI_CFG_PATH"
    fi

    # Already associated with a lease (kvmcomm restarted, or a second
    # trigger): reconnecting would flush the address and restart DHCP.
    if wifi_is_connected "$WIFI_IFACE"; then
        debug_print "[wifi] already connected on $WIFI_IFACE; nothing to do"
        return 0
    fi

    local WIFI_CFG_SSID="" WIFI_CFG_PASSWD=""

    # 1. Try reading SSID from WIFI_CFG_PATH (/etc/kvm/wifi.conf)
    if [[ -r "$WIFI_CFG_PATH" ]]; then
        while IFS="=" read -r key value; do
            case "$key" in
            "WIFI_CFG_SSID") WIFI_CFG_SSID="$value" ;;
            "WIFI_CFG_PASSWD") WIFI_CFG_PASSWD="$value" ;;
            esac
        done <"$WIFI_CFG_PATH"
    fi

    # 2. Fall back to PREVIOUS_WIFI_SAVE (/etc/kvm/wifi_save)
    if [[ -z "$WIFI_CFG_SSID" && -s "$PREVIOUS_WIFI_SAVE" ]]; then
        WIFI_CFG_SSID=$(<"$PREVIOUS_WIFI_SAVE")
        debug_print "[wifi] recovered SSID from $PREVIOUS_WIFI_SAVE: $WIFI_CFG_SSID"
    fi

    # 3. Fall back to existing network in wpa_supplicant
    if [[ -z "$WIFI_CFG_SSID" ]]; then
        start_service
        local unescaped_first
        unescaped_first=$(wpa_cli -i "$WIFI_IFACE" list_networks 2>/dev/null | awk -F'\t' 'NR==2 {print $2}')
        if [[ -n "$unescaped_first" ]]; then
            WIFI_CFG_SSID=$(unescape_non_ascii "$unescaped_first")
            debug_print "[wifi] recovered SSID from wpa_supplicant: $WIFI_CFG_SSID"
        fi
    fi

    if [[ -z "$WIFI_CFG_SSID" ]]; then
        debug_print "[wifi] no saved SSID available for reconnect" >&2
        return 3
    fi

    debug_print "[wifi] connecting to SSID: $WIFI_CFG_SSID"

    # A legacy wifi.conf may carry the passphrase for a network that has no
    # wpa_supplicant profile yet (this replaces the separate connect_start the
    # kvmcomm postinst used to fire). Use it only then, so a saved profile is
    # never duplicated.
    local migrate_psk=""
    if [[ -n "$WIFI_CFG_PASSWD" ]]; then
        start_service
        if [[ -z "$(find_network_id "$WIFI_IFACE" "$WIFI_CFG_SSID")" ]]; then
            migrate_psk="$WIFI_CFG_PASSWD"
        fi
    fi

    if ! connect_wifi "$WIFI_CFG_SSID" "$migrate_psk"; then
        debug_print "[wifi] error: failed to connect to SSID: $WIFI_CFG_SSID" >&2
        return 4
    fi

    # Keep both persistent save and tmp previous_wifi in sync
    echo "$WIFI_CFG_SSID" > "$PREVIOUS_WIFI_SAVE" 2>/dev/null || true
    echo "$WIFI_CFG_SSID" > "$PREVIOUS_WIFI" 2>/dev/null || true

    return 0
}

escape_non_ascii() {
    local input="$1"
    local escaped=""
    local i c ord b

    for ((i=0; i<${#input}; i++)); do
        c="${input:i:1}"
        LC_CTYPE=C
        ord=$(printf "%d" "'$c" 2>/dev/null || ord=0)
        if [ "$ord" -ge 32 ] && [ "$ord" -le 126 ]; then
            if [ "$c" = "\\" ]; then
                escaped+="\\\\"
            elif [ "$c" = '"' ]; then
                # wpa_cli prints '"' in SSIDs as \" (printf_encode)
                escaped+='\"'
            else
                escaped+="$c"
            fi
        else
            while read -r b; do
                escaped+="\\x$b"
            done < <(echo -n "$c" | xxd -p -c1)
        fi
    done

    printf '%s' "$escaped"
}

unescape_non_ascii() {
    local input="$1"
    local result=""
    local i=0

    while [ $i -lt ${#input} ]; do
        local c="${input:i:1}"

        if [ "$c" = "\\" ]; then
            local next="${input:i+1:1}"

            if [ "$next" = "\\" ]; then
                result+="\\\\"
                ((i+=2))
            elif [ "$next" = '"' ]; then
                result+='"'
                ((i+=2))
            elif [ "$next" = "x" ]; then
                local hex="${input:i+2:2}"
                if [[ "$hex" =~ ^[0-9a-fA-F]{2}$ ]]; then
                    result+=$(printf "\\x$hex")
                    ((i+=4))
                else
                    result+="$c"
                    ((i+=1))
                fi
            else
                result+="$c"
                ((i+=1))
            fi
        else
            result+="$c"
            ((i+=1))
        fi
    done

    printf '%b' "$result"
}

# ---------------------------------------------------------------------------
# Station connect
#
# Time budget. A failed connect_start must finish well inside the server's
# connect timeout (connectTimeout in server/service/network/wifi.go, 45 s),
# otherwise the server SIGTERMs us mid-attempt:
#   stop_wifi_ap + disconnect_wifi + start_service      ~3 s
#   association wait (ASSOC_WAIT polls of ~1 s)         ~16 s
#   DHCP probe: DISCOVER DHCP_TRIES x DHCP_TIMEOUT       6 s
#               (+ REQUEST retries if offered, rare)    (+6 s)
#   rollback (non-blocking: no association wait)        ~1 s
#   worst case                                          ~26 s (32 s extreme)
# ---------------------------------------------------------------------------
readonly ASSOC_WAIT=15
readonly ENT_ASSOC_WAIT=20   # EAP handshakes are slower; enterprise_connect has no server-side caller
readonly DHCP_TRIES=3
readonly DHCP_TIMEOUT=2
readonly UDHCPC_SCRIPT="/kvmcomm/scripts/udhcpc.script"

# SSID: 1-32 bytes, no control characters (they cannot round-trip through
# wpa_cli / wpa_supplicant.conf).
validate_ssid() {
    local s="$1"
    local LC_ALL=C
    if [[ -z "$s" || ${#s} -gt 32 ]]; then
        echo "[wifi] invalid SSID: must be 1-32 bytes" >&2
        return 1
    fi
    if [[ "$s" == *[[:cntrl:]]* ]]; then
        echo "[wifi] invalid SSID: contains control characters" >&2
        return 1
    fi
    return 0
}

# Access point passphrase for hostapd's wpa_passphrase=: 8-63 printable ASCII
# characters (hostapd's own rule). A newline would start a new hostapd.conf
# line, so this also keeps the config from being injected into.
validate_ap_psk() {
    local p="$1"
    local LC_ALL=C
    if [[ ${#p} -lt 8 || ${#p} -gt 63 || ! "$p" =~ ^[[:print:]]+$ ]]; then
        echo "[wifi] invalid AP password: must be 8-63 printable ASCII characters" >&2
        return 1
    fi
    return 0
}

# WPA passphrase: 8-63 bytes without control characters, or a raw 64-hex PSK.
validate_psk() {
    local p="$1"
    local LC_ALL=C
    [[ ${#p} -eq 64 && "$p" =~ ^[0-9a-fA-F]{64}$ ]] && return 0
    if [[ ${#p} -lt 8 || ${#p} -gt 63 ]]; then
        echo "[wifi] invalid password: must be 8-63 characters or 64 hex digits" >&2
        return 1
    fi
    if [[ "$p" == *[[:cntrl:]]* ]]; then
        echo "[wifi] invalid password: contains control characters" >&2
        return 1
    fi
    return 0
}

# Print the id of the first saved network whose SSID matches. The SSID goes
# through ENVIRON, not "awk -v", because -v would process the \xNN / \\ / \"
# escapes that wpa_cli prints, so non-ASCII SSIDs would never match.
find_network_id() {
    local iface="$1" ssid_esc
    ssid_esc=$(escape_non_ascii "$2")
    wpa_cli -i "$iface" list_networks 2>/dev/null | WIFI_SSID_ESC="$ssid_esc" awk -F'\t' 'NR>1 && $2==ENVIRON["WIFI_SSID_ESC"] {print $1; exit}'
}

# Print the ids of all saved networks whose SSID matches.
find_network_ids() {
    local iface="$1" ssid_esc
    ssid_esc=$(escape_non_ascii "$2")
    wpa_cli -i "$iface" list_networks 2>/dev/null | WIFI_SSID_ESC="$ssid_esc" awk -F'\t' 'NR>1 && $2==ENVIRON["WIFI_SSID_ESC"] {print $1}'
}

wait_for_assoc() {
    local iface="$1" secs="$2" i
    for ((i = 0; i < secs; i++)); do
        if wpa_cli -i "$iface" status 2>/dev/null | grep -qF "wpa_state=COMPLETED"; then
            return 0
        fi
        sleep 1
    done
    wpa_cli -i "$iface" status 2>/dev/null | grep -qF "wpa_state=COMPLETED"
}

stop_dhcp_client() {
    pkill -f "udhcpc.*-i $1" 2>/dev/null || true
}

# Bounded foreground DHCP attempt. Without -b/-f, busybox udhcpc stays in the
# foreground until it has a lease and then forks itself into the background
# to keep renewing it; with -n it instead exits 1 when no lease was obtained
# after DHCP_TRIES x DHCP_TIMEOUT seconds. So the exit status is real (unlike
# "udhcpc -b", which always exits 0) and a successful probe leaves the
# renewing client running with no gap.
dhcp_acquire() {
    local iface="$1"
    stop_dhcp_client "$iface"
    udhcpc -i "$iface" -s "$UDHCPC_SCRIPT" -n -t "$DHCP_TRIES" -T "$DHCP_TIMEOUT" \
        >/dev/null 2>&1 </dev/null 200>&-
}

# Start a DHCP client that keeps retrying in the background, without waiting.
# Started in its own session so a process-group kill of this script cannot
# take it down during its first (foreground) discovery round.
start_dhcp_background() {
    local iface="$1"
    stop_dhcp_client "$iface"
    if command -v setsid >/dev/null 2>&1; then
        setsid udhcpc -i "$iface" -s "$UDHCPC_SCRIPT" -b >/dev/null 2>&1 </dev/null 200>&- &
    else
        udhcpc -i "$iface" -s "$UDHCPC_SCRIPT" -b >/dev/null 2>&1 </dev/null 200>&- &
    fi
}

# Re-select the previous network. Does not wait for association:
# wpa_supplicant associates on its own and the background DHCP client keeps
# retrying until it gets a lease, so the device recovers even if the previous
# AP is slow or temporarily away.
rollback_wifi() {
    local prev_id="$1"
    local prev_ssid="$2"
    local WIFI_IFACE
    WIFI_IFACE=$(get_wireless_interface) || return 1

    debug_print "[wifi] attempting rollback to previous network (id=$prev_id, ssid=$prev_ssid)..."

    if [[ -z "$prev_id" && -n "$prev_ssid" ]]; then
        prev_id=$(find_network_id "$WIFI_IFACE" "$prev_ssid")
    fi

    if [[ -z "$prev_id" ]]; then
        local fallback_ssid=""
        if [[ -s "$PREVIOUS_WIFI_SAVE" ]]; then
            fallback_ssid=$(<"$PREVIOUS_WIFI_SAVE")
        elif [[ -s "$PREVIOUS_WIFI" ]]; then
            fallback_ssid=$(<"$PREVIOUS_WIFI")
        elif [[ -s "$WIFI_CFG_PATH" ]]; then
            fallback_ssid=$(grep -E '^WIFI_CFG_SSID=' "$WIFI_CFG_PATH" | cut -d= -f2-)
        fi
        if [[ -n "$fallback_ssid" ]]; then
            prev_id=$(find_network_id "$WIFI_IFACE" "$fallback_ssid")
            prev_ssid="$fallback_ssid"
        fi
    fi

    if [[ -z "$prev_id" ]]; then
        debug_print "[wifi] rollback: no previous network available to restore"
        return 1
    fi

    debug_print "[wifi] rollback: re-enabling network id=$prev_id (ssid=$prev_ssid)"
    wpa_cli -i "$WIFI_IFACE" enable_network "$prev_id" >/dev/null 2>&1
    wpa_cli -i "$WIFI_IFACE" select_network "$prev_id" >/dev/null 2>&1
    # The failed profile has already been removed, so this persists exactly the
    # pre-attempt profile set, with the previous network enabled again (it was
    # disabled and saved by disconnect_wifi).
    wpa_cli -i "$WIFI_IFACE" save_config >/dev/null 2>&1
    ip addr flush dev "$WIFI_IFACE" 2>/dev/null || true
    start_dhcp_background "$WIFI_IFACE"
    debug_print "[wifi] rollback started for $prev_ssid"
    return 0
}

# Undo after a failed attempt (the failed new profile is already removed):
# go back to the previous network; if there is none but an already-saved
# profile was being reused, keep that one enabled and keep retrying DHCP so
# the device recovers when its AP comes back.
restore_after_failure() {
    local iface="$1" prev_id="$2" prev_ssid="$3" reused_id="$4"
    rollback_wifi "$prev_id" "$prev_ssid" && return 0
    if [[ -n "$reused_id" ]]; then
        wpa_cli -i "$iface" enable_network "$reused_id" >/dev/null 2>&1 || true
        wpa_cli -i "$iface" select_network "$reused_id" >/dev/null 2>&1 || true
        wpa_cli -i "$iface" save_config >/dev/null 2>&1 || true
        start_dhcp_background "$iface"
    fi
    return 0
}

# State for connect_abort (SIGTERM/SIGINT while connect_start is running).
CA_IFACE=""
CA_NEW_ID=""
CA_PREV_ID=""
CA_PREV_SSID=""
CA_REUSED_ID=""

# Fast, non-blocking undo of an in-flight connect attempt; runs from the
# signal trap, so it must finish within the caller's SIGTERM grace period
# (a few wpa_cli calls, no waits).
connect_abort() {
    CONNECT_ABORT_HANDLER=""
    [[ -n "$CA_IFACE" ]] || return 0
    echo "[wifi] connect aborted by signal, rolling back" >&2
    stop_dhcp_client "$CA_IFACE"
    if [[ -n "$CA_NEW_ID" ]]; then
        wpa_cli -i "$CA_IFACE" remove_network "$CA_NEW_ID" >/dev/null 2>&1 || true
    fi
    restore_after_failure "$CA_IFACE" "$CA_PREV_ID" "$CA_PREV_SSID" "$CA_REUSED_ID"
}

# SSID of the network to fall back to if an attempt fails.
previous_ssid() {
    if [[ -s "$PREVIOUS_WIFI_SAVE" ]]; then
        cat "$PREVIOUS_WIFI_SAVE"
    elif [[ -s "$PREVIOUS_WIFI" ]]; then
        cat "$PREVIOUS_WIFI"
    elif [[ -s "$WIFI_CFG_PATH" ]]; then
        grep -E '^WIFI_CFG_SSID=' "$WIFI_CFG_PATH" | cut -d= -f2-
    fi
}

# After a proven connection (associated + DHCP lease): drop the profiles the
# new one supersedes, persist wpa_supplicant.conf and record the SSID.
commit_profile() {
    local iface="$1" ssid="$2" new_id="$3" old_id
    CONNECT_ABORT_HANDLER=""
    if [[ -n "$new_id" ]]; then
        for old_id in $(find_network_ids "$iface" "$ssid"); do
            [[ "$old_id" == "$new_id" ]] && continue
            debug_print "[wifi] removing superseded network id=$old_id"
            wpa_cli -i "$iface" remove_network "$old_id" >/dev/null 2>&1 || true
        done
    fi
    wpa_cli -i "$iface" save_config >/dev/null

    cat <<EOF >"$WIFI_CFG_PATH"
WIFI_CFG_SSID=${ssid}
EOF
    echo "$ssid" > "$PREVIOUS_WIFI_SAVE" 2>/dev/null || true
    echo "$ssid" > "$PREVIOUS_WIFI" 2>/dev/null || true
    sync 2>/dev/null || true
}

# Undo a failed attempt that has not been committed: stop its DHCP client,
# remove the new profile (never saved) and restore the previous network.
fail_attempt() {
    local iface="$1" new_id="$2" prev_id="$3" prev_ssid="$4" reused_id="$5"
    CONNECT_ABORT_HANDLER=""
    stop_dhcp_client "$iface"
    ip addr flush dev "$iface" 2>/dev/null || true
    if [[ -n "$new_id" ]]; then
        wpa_cli -i "$iface" remove_network "$new_id" >/dev/null 2>&1 || true
    fi
    restore_after_failure "$iface" "$prev_id" "$prev_ssid" "$reused_id"
}

connect_wifi() {
    local ssid="$1"
    local password="$2"
    local WIFI_IFACE
    WIFI_IFACE=$(get_wireless_interface) || {
        echo "[wifi] no wireless interface found" >&2
        return 1
    }

    validate_ssid "$ssid" || return 2
    if [[ -n "$password" ]]; then
        validate_psk "$password" || return 2
    fi

    start_service

    if [[ ! -S "/run/wpa_supplicant/${WIFI_IFACE}" ]]; then
        echo "[wifi] wpa_supplicant socket not found for $WIFI_IFACE" >&2
        return 1
    fi

    # Ensure sae_pwe is set for SAE/WPA3 support
    wpa_cli -i "$WIFI_IFACE" set sae_pwe 2 >/dev/null 2>&1 || true

    # Record previous network for rollback in case connection fails
    local prev_ssid prev_id=""
    prev_ssid=$(previous_ssid)
    if [[ -n "$prev_ssid" ]]; then
        prev_id=$(find_network_id "$WIFI_IFACE" "$prev_ssid")
    fi

    local existing
    existing=$(find_network_id "$WIFI_IFACE" "$ssid")
    debug_print "[wifi] existing network id: $existing, previous network id: $prev_id"

    # From here on a signal must restore the previous network.
    CA_IFACE="$WIFI_IFACE"
    CA_PREV_ID="$prev_id"
    CA_PREV_SSID="$prev_ssid"
    CONNECT_ABORT_HANDLER=connect_abort

    local id="" new_id=""
    if [[ -n "$password" || -z "$existing" ]]; then
        # Add the new profile *alongside* any existing profile for this SSID.
        # The old one is removed only after the new one has associated and got
        # a DHCP lease, so a mistyped password never destroys a working profile.
        debug_print "[wifi] adding new network: $ssid"
        new_id=$(wpa_cli -i "$WIFI_IFACE" add_network 2>/dev/null | tail -n1)
        if [[ ! "$new_id" =~ ^[0-9]+$ ]]; then
            echo "[wifi] add_network failed" >&2
            CONNECT_ABORT_HANDLER=""
            restore_after_failure "$WIFI_IFACE" "$prev_id" "$prev_ssid" ""
            return 1
        fi
        id="$new_id"
        CA_NEW_ID="$new_id"

        local ok=true
        # wpa_supplicant takes everything between the first and the last '"'
        # verbatim (no unescaping), so SSID and passphrase are passed raw.
        [[ "$(wpa_cli -i "$WIFI_IFACE" set_network "$id" ssid "\"$ssid\"" 2>/dev/null)" == "OK" ]] || ok=false
        if [[ -z "$password" ]]; then
            wpa_cli -i "$WIFI_IFACE" set_network "$id" key_mgmt NONE >/dev/null
        else
            # Support both WPA2-PSK and WPA3-Personal (SAE)
            wpa_cli -i "$WIFI_IFACE" set_network "$id" key_mgmt "WPA-PSK SAE" >/dev/null
            wpa_cli -i "$WIFI_IFACE" set_network "$id" ieee80211w 1 >/dev/null
            local psk_arg
            if [[ ${#password} -eq 64 && "$password" =~ ^[0-9a-fA-F]{64}$ ]]; then
                psk_arg="$password"
            else
                psk_arg="\"$password\""
            fi
            [[ "$(wpa_cli -i "$WIFI_IFACE" set_network "$id" psk "$psk_arg" 2>/dev/null)" == "OK" ]] || ok=false
        fi

        if [[ "$ok" != "true" ]]; then
            echo "[wifi] wpa_supplicant rejected the network parameters" >&2
            CONNECT_ABORT_HANDLER=""
            wpa_cli -i "$WIFI_IFACE" remove_network "$id" >/dev/null 2>&1 || true
            restore_after_failure "$WIFI_IFACE" "$prev_id" "$prev_ssid" ""
            return 2
        fi
    else
        id="$existing"
        CA_REUSED_ID="$existing"
        debug_print "[wifi] found existing network id=$existing, reusing."
    fi

    # No save_config until the new profile is proven to work.
    wpa_cli -i "$WIFI_IFACE" set_network "$id" mesh_fwding 0 >/dev/null
    wpa_cli -i "$WIFI_IFACE" enable_network "$id" >/dev/null
    wpa_cli -i "$WIFI_IFACE" select_network "$id" >/dev/null

    stop_dhcp_client "$WIFI_IFACE"
    ip addr flush dev "$WIFI_IFACE"

    local result="ok"
    debug_print "[wifi] waiting for connection..."
    if ! wait_for_assoc "$WIFI_IFACE" "$ASSOC_WAIT"; then
        echo "[wifi] association timeout after ${ASSOC_WAIT}s" >&2
        result="assoc"
    else
        debug_print "[wifi] connection established, requesting IP address via DHCP..."
        if ! dhcp_acquire "$WIFI_IFACE"; then
            echo "[wifi] DHCP failed on $WIFI_IFACE" >&2
            result="dhcp"
        fi
    fi

    if [[ "$result" != "ok" ]]; then
        fail_attempt "$WIFI_IFACE" "$new_id" "$prev_id" "$prev_ssid" "$CA_REUSED_ID"
        return 1
    fi

    commit_profile "$WIFI_IFACE" "$ssid" "$new_id"
    debug_print "[wifi] connected to $ssid"
    return 0
}

connect_enterprise_wifi() {
    local ssid="$1"
    local eap_method="$2"
    local identity="$3"
    shift 3

    local password="" phase2="" ca_cert="" client_cert="" private_key="" private_key_passwd=""
    local anonymous_identity="" domain=""

    for param in "$@"; do
        case "$param" in
            password=*)         password="${param#password=}" ;;
            phase2=*)           phase2="${param#phase2=}" ;;
            ca_cert=*)          ca_cert="${param#ca_cert=}" ;;
            client_cert=*)      client_cert="${param#client_cert=}" ;;
            private_key=*)      private_key="${param#private_key=}" ;;
            private_key_passwd=*) private_key_passwd="${param#private_key_passwd=}" ;;
            anonymous_identity=*) anonymous_identity="${param#anonymous_identity=}" ;;
            domain=*)           domain="${param#domain=}" ;;
            -d|--debug)         ;;
            *)
                debug_print "[wifi] unknown enterprise parameter: $param" >&2
                ;;
        esac
    done

    eap_method=$(echo "$eap_method" | tr '[:lower:]' '[:upper:]')

    case "$eap_method" in
        PEAP|TLS|TTLS) ;;
        *)
            echo "[wifi] unsupported EAP method: $eap_method (supported: PEAP, TLS, TTLS)" >&2
            return 1
            ;;
    esac

    case "$eap_method" in
        PEAP)
            if [[ -z "$password" ]]; then
                echo "[wifi] PEAP requires password parameter" >&2
                return 1
            fi
            [[ -z "$phase2" ]] && phase2="auth=MSCHAPV2"
            ;;
        TLS)
            if [[ -z "$client_cert" || -z "$private_key" ]]; then
                echo "[wifi] EAP-TLS requires client_cert and private_key parameters" >&2
                return 1
            fi
            if [[ ! -f "$client_cert" ]]; then
                echo "[wifi] client certificate not found: $client_cert" >&2
                return 1
            fi
            if [[ ! -f "$private_key" ]]; then
                echo "[wifi] private key not found: $private_key" >&2
                return 1
            fi
            ;;
        TTLS)
            if [[ -z "$password" ]]; then
                echo "[wifi] EAP-TTLS requires password parameter" >&2
                return 1
            fi
            [[ -z "$phase2" ]] && phase2="auth=PAP"
            ;;
    esac

    if [[ -n "$ca_cert" && ! -f "$ca_cert" ]]; then
        echo "[wifi] CA certificate not found: $ca_cert" >&2
        return 1
    fi

    validate_ssid "$ssid" || return 2
    # A newline or other control character would end the quoted value early
    # in wpa_cli / wpa_supplicant.conf (and could inject config lines).
    local field
    for field in "$identity" "$password" "$phase2" "$ca_cert" "$client_cert" \
        "$private_key" "$private_key_passwd" "$anonymous_identity" "$domain"; do
        if [[ "$field" == *[[:cntrl:]]* ]]; then
            echo "[wifi] enterprise parameters must not contain control characters" >&2
            return 2
        fi
    done

    local WIFI_IFACE
    WIFI_IFACE=$(get_wireless_interface) || {
        echo "[wifi] no wireless interface found" >&2
        return 1
    }

    start_service

    if [[ ! -S "/run/wpa_supplicant/${WIFI_IFACE}" ]]; then
        echo "[wifi] wpa_supplicant socket not found for $WIFI_IFACE" >&2
        return 1
    fi

    debug_print "[wifi] enterprise connect: ssid=$ssid eap=$eap_method identity=$identity"

    local prev_ssid prev_id=""
    prev_ssid=$(previous_ssid)
    if [[ -n "$prev_ssid" ]]; then
        prev_id=$(find_network_id "$WIFI_IFACE" "$prev_ssid")
    fi

    # From here on a signal must restore the previous network.
    CA_IFACE="$WIFI_IFACE"
    CA_PREV_ID="$prev_id"
    CA_PREV_SSID="$prev_ssid"
    CA_REUSED_ID=""
    CONNECT_ABORT_HANDLER=connect_abort

    # Add the new profile alongside any existing one for this SSID; the old
    # one is removed only once the new one has associated and got a lease.
    local id
    id=$(wpa_cli -i "$WIFI_IFACE" add_network 2>/dev/null | tail -n1)
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        echo "[wifi] add_network failed" >&2
        fail_attempt "$WIFI_IFACE" "" "$prev_id" "$prev_ssid" ""
        return 1
    fi
    CA_NEW_ID="$id"
    debug_print "[wifi] added enterprise network id=$id"

    # Values are passed raw inside quotes: wpa_supplicant keeps everything
    # between the first and the last '"' verbatim.
    local ok=true
    ent_set() {
        if [[ "$(wpa_cli -i "$WIFI_IFACE" set_network "$id" "$1" "$2" 2>/dev/null)" != "OK" ]]; then
            echo "[wifi] wpa_supplicant rejected $1" >&2
            ok=false
        fi
    }

    ent_set ssid "\"$ssid\""
    ent_set key_mgmt "WPA-EAP"
    ent_set eap "$eap_method"
    ent_set identity "\"$identity\""
    [[ -n "$anonymous_identity" ]] && ent_set anonymous_identity "\"$anonymous_identity\""
    [[ -n "$ca_cert" ]] && ent_set ca_cert "\"$ca_cert\""
    [[ -n "$domain" ]] && ent_set domain_suffix_match "\"$domain\""

    case "$eap_method" in
        PEAP|TTLS)
            ent_set password "\"$password\""
            ent_set phase2 "\"$phase2\""
            debug_print "[wifi] $eap_method configured with phase2=$phase2"
            ;;
        TLS)
            ent_set client_cert "\"$client_cert\""
            ent_set private_key "\"$private_key\""
            [[ -n "$private_key_passwd" ]] && ent_set private_key_passwd "\"$private_key_passwd\""
            debug_print "[wifi] EAP-TLS configured with cert=$client_cert key=$private_key"
            ;;
    esac
    ent_set mesh_fwding 0
    unset -f ent_set

    if [[ "$ok" != "true" ]]; then
        fail_attempt "$WIFI_IFACE" "$id" "$prev_id" "$prev_ssid" ""
        return 2
    fi

    # No save_config until the new profile is proven to work.
    wpa_cli -i "$WIFI_IFACE" enable_network "$id" >/dev/null
    wpa_cli -i "$WIFI_IFACE" select_network "$id" >/dev/null

    stop_dhcp_client "$WIFI_IFACE"
    ip addr flush dev "$WIFI_IFACE"

    debug_print "[wifi] waiting for enterprise connection..."
    if ! wait_for_assoc "$WIFI_IFACE" "$ENT_ASSOC_WAIT"; then
        echo "[wifi] enterprise connection timeout after ${ENT_ASSOC_WAIT}s" >&2
        local eap_status
        eap_status=$(wpa_cli -i "$WIFI_IFACE" status 2>/dev/null | grep "EAP state=" | cut -d= -f2)
        [[ -n "$eap_status" ]] && echo "[wifi] EAP state at timeout: $eap_status" >&2
        fail_attempt "$WIFI_IFACE" "$id" "$prev_id" "$prev_ssid" ""
        return 1
    fi

    debug_print "[wifi] requesting IP address via DHCP..."
    if ! dhcp_acquire "$WIFI_IFACE"; then
        echo "[wifi] DHCP failed on $WIFI_IFACE" >&2
        fail_attempt "$WIFI_IFACE" "$id" "$prev_id" "$prev_ssid" ""
        return 1
    fi

    commit_profile "$WIFI_IFACE" "$ssid" "$id"
    debug_print "[wifi] connected to enterprise network: $ssid (EAP: $eap_method)"
    return 0
}

disconnect_wifi() {
    debug_print "[wifi] disconnecting..."
    local WIFI_IFACE=$(get_wireless_interface)

    local udhcpc_pids
    udhcpc_pids=$(pgrep -f "udhcpc.*-i ${WIFI_IFACE}")
    if [ -n "$udhcpc_pids" ]; then
        while IFS= read -r pid; do
            if [ -n "$pid" ]; then
                kill -TERM "$pid" 2>/dev/null && debug_print "[wifi] udhcpc (PID $pid) terminated"
            fi
        done <<< "$udhcpc_pids"
    else
        debug_print "[wifi] no udhcpc process found for interface ${WIFI_IFACE}"
    fi

    if [[ -S "/run/wpa_supplicant/$WIFI_IFACE" ]]; then
        start_service

        # Straight from wpa_cli's tab-separated list: matching the JSON from
        # list_networks with [^"]* lost SSIDs that contain '"' (printed as \").
        local current network_id network_ssid
        current=$(wpa_cli -i "$WIFI_IFACE" list_networks 2>/dev/null | awk -F'\t' 'NR>1 && index($4, "[CURRENT]") {print $1 "\t" $2; exit}')
        network_id="${current%%$'\t'*}"
        network_ssid="${current#*$'\t'}"

        if [[ -n "$network_id" && -n "$network_ssid" ]]; then
            local unescaped_current=$(unescape_non_ascii "$network_ssid")
            debug_print "[wifi] disabling network id=$network_id, ssid=$network_ssid"
            wpa_cli -i "$WIFI_IFACE" disable_network "$network_id" >/dev/null
            echo "$unescaped_current" > "$PREVIOUS_WIFI_SAVE"
            echo "$unescaped_current" > "$PREVIOUS_WIFI" 2>/dev/null || true
        elif [[ -f "$WIFI_CFG_PATH" && ! -s "$PREVIOUS_WIFI_SAVE" ]]; then
            local cfg_ssid
            cfg_ssid=$(grep -E '^WIFI_CFG_SSID=' "$WIFI_CFG_PATH" | cut -d= -f2-)
            if [[ -n "$cfg_ssid" ]]; then
                echo "$cfg_ssid" > "$PREVIOUS_WIFI_SAVE"
                echo "$cfg_ssid" > "$PREVIOUS_WIFI" 2>/dev/null || true
            fi
        fi

        wpa_cli -i "$WIFI_IFACE" disconnect >/dev/null
        wpa_cli -i "$WIFI_IFACE" save_config >/dev/null
    fi

    ip addr flush dev "${WIFI_IFACE}"

    # Note: WIFI_CFG_PATH is preserved across normal disconnect/AP-mode transitions.
    # It is only removed on explicit reset or connect_remove operations.

    return 0
}

remove_wifi() {
    local ssid="$1"
    local WIFI_IFACE
    WIFI_IFACE=$(get_wireless_interface)

    start_service

    if [[ ! -S "/run/wpa_supplicant/${WIFI_IFACE}" ]]; then
        debug_print "[wifi] wpa_supplicant socket not found for $WIFI_IFACE" >&2
        return 1
    fi

    debug_print "[wifi] removing network: $ssid"

    # All saved profiles for this SSID (there can be more than one), looked up
    # via find_network_ids so non-ASCII / '\' / '"' SSIDs match.
    local network_ids
    network_ids=$(find_network_ids "$WIFI_IFACE" "$ssid")

    if [[ -z "$network_ids" ]]; then
        debug_print "[wifi] network not found: $ssid" >&2
        return 1
    fi

    local ssid_escaped is_current
    ssid_escaped=$(escape_non_ascii "$ssid")
    is_current=$(wpa_cli -i "$WIFI_IFACE" list_networks 2>/dev/null | WIFI_SSID_ESC="$ssid_escaped" \
        awk -F'\t' 'NR>1 && $2==ENVIRON["WIFI_SSID_ESC"] && $4~/\[CURRENT\]/ {print "true"; exit}')
    [[ "$is_current" != "true" ]] && is_current="false"

    if [[ "$is_current" == "true" ]]; then
        debug_print "[wifi] network is currently connected, disconnecting first..."
        disconnect_wifi
        sleep 1
    fi

    local network_id failed=false
    for network_id in $network_ids; do
        debug_print "[wifi] found network id=$network_id, removing..."
        wpa_cli -i "$WIFI_IFACE" remove_network "$network_id" >/dev/null || failed=true
    done

    if [[ "$failed" != "true" ]]; then
        wpa_cli -i "$WIFI_IFACE" save_config >/dev/null
        debug_print "[wifi] network removed and config saved: $ssid"

        if [[ -f "$WIFI_CFG_PATH" ]]; then
            local cfg_ssid
            cfg_ssid=$(grep -E '^WIFI_CFG_SSID=' "$WIFI_CFG_PATH" | cut -d= -f2-)
            if [[ "$cfg_ssid" == "$ssid" ]]; then
                rm -f "$WIFI_CFG_PATH"
                debug_print "[wifi] removed wifi config file as it matched removed network"
            fi
        fi
        if [[ -f "$PREVIOUS_WIFI_SAVE" ]]; then
            local prev_ssid
            prev_ssid=$(<"$PREVIOUS_WIFI_SAVE")
            if [[ "$prev_ssid" == "$ssid" ]]; then
                rm -f "$PREVIOUS_WIFI_SAVE"
            fi
        fi
        rm -f "$PREVIOUS_WIFI" || true
    else
        debug_print "[wifi] failed to remove network: $ssid" >&2
        return 1
    fi

    return 0
}

wireless_ip_exists() {
    local WIFI_IFACE=$(get_wireless_interface)

    if [ -z "$WIFI_IFACE" ]; then
        echo "false"
        return 1
    fi

    if ! ip link show "$WIFI_IFACE" &>/dev/null; then
        echo "false"
        return 1
    fi

    if ip addr show "$WIFI_IFACE" 2>/dev/null | grep -E 'inet ' &>/dev/null; then
        echo "true"
        return 0
    else
        echo "false"
        return 0
    fi
}

has_wifi_config() {
    if [[ ! -f "$WIFI_CFG_PATH" ]]; then
        echo "false"
        return 1
    fi

    local ssid
    ssid=$(grep -E '^WIFI_CFG_SSID=' "$WIFI_CFG_PATH" | cut -d= -f2-)

    if [[ -n "$ssid" ]]; then
        echo "true"
    else
        echo "false"
    fi

    return 0
}

list_networks() {
    local WIFI_IFACE=$(get_wireless_interface)

    if [ -z "$WIFI_IFACE" ]; then
        echo "[]"
        return 1
    fi

    if [[ ! -S "/run/wpa_supplicant/$WIFI_IFACE" ]]; then
        echo "[]"
        return 1
    fi

    local networks_output
    networks_output=$(wpa_cli -i "$WIFI_IFACE" list_networks 2>/dev/null)

    if [ -z "$networks_output" ]; then
        echo "[]"
        return 1
    fi

    echo "$networks_output" | awk '
    NR > 1 && NF >= 3 {
        network_id = $1

        if ($NF ~ /^\[/) {
            flags = $NF
            bssid = $(NF-1)
            ssid = ""
            for (i = 2; i < NF - 1; i++) {
                ssid = ssid (i > 2 ? " " : "") $i
            }
        } else {
            flags = ""
            bssid = $NF
            ssid = ""
            for (i = 2; i < NF; i++) {
                ssid = ssid (i > 2 ? " " : "") $i
            }
        }

        flag_status = ""
        is_current = 0
        if (index(flags, "[CURRENT]") > 0) {
            flag_status = "CURRENT"
            is_current = 1
        } else if (index(flags, "[DISABLED]") > 0) {
            flag_status = "DISABLED"
        } else {
            flag_status = ""
        }

        network_json = sprintf("{\"ssid\":\"%s\",\"flags\":\"%s\"}", ssid, flag_status)

        if (is_current) {
            current_network = network_json
        } else {
            other_networks[other_count++] = network_json
        }
    }
    END {
        print "["

        count = 0
        if (current_network) {
            printf "  %s", current_network
            count++
        }

        for (i = 0; i < other_count; i++) {
            if (count > 0) print ","
            printf "  %s", other_networks[i]
            count++
        }

        print ""
        print "]"
    }'

    return 0
}

check_previous_wifi() {
    local WIFI_IFACE=$(get_wireless_interface)

    if [ -z "$WIFI_IFACE" ]; then
        echo "false"
        return 1
    fi

    start_service

    rm -f "$PREVIOUS_WIFI" || true

    if wpa_cli -i "$WIFI_IFACE" status 2>/dev/null | grep -qF "wpa_state=COMPLETED"; then
        debug_print "[wifi] already connected to WiFi"
        echo "false"
        return 0
    fi

    local saved_ssid=""
    if [[ -s "$PREVIOUS_WIFI_SAVE" ]]; then
        saved_ssid=$(<"$PREVIOUS_WIFI_SAVE")
    elif [[ -s "$WIFI_CFG_PATH" ]]; then
        saved_ssid=$(grep -E '^WIFI_CFG_SSID=' "$WIFI_CFG_PATH" | cut -d= -f2-)
    fi

    if [[ -z "$saved_ssid" ]]; then
        local unescaped_first
        unescaped_first=$(wpa_cli -i "$WIFI_IFACE" list_networks 2>/dev/null | awk -F'\t' 'NR==2 {print $2}')
        [[ -n "$unescaped_first" ]] && saved_ssid=$(unescape_non_ascii "$unescaped_first")
    fi

    if [[ -z "$saved_ssid" ]]; then
        debug_print "[wifi] no previous WiFi save file found"
        echo "false"
        return 0
    fi

    local unescaped_ssid=$(escape_non_ascii "$saved_ssid")
    local scan_results=$(try_scan)

    if echo "$scan_results" | grep -qF "\"ssid\":\"$unescaped_ssid\""; then
        debug_print "[wifi] saved network $saved_ssid is available in scan results"
        echo "true"
        echo "$saved_ssid" > "$PREVIOUS_WIFI"
        [[ ! -s "$PREVIOUS_WIFI_SAVE" ]] && echo "$saved_ssid" > "$PREVIOUS_WIFI_SAVE"
    else
        debug_print "[wifi] saved network $saved_ssid is not available in scan results"
        echo "false"
        return 0
    fi

    return 0
}

if_previous_wifi() {
    if [[ -s "$PREVIOUS_WIFI" ]]; then
        echo "true"
    elif [[ -s "$PREVIOUS_WIFI_SAVE" ]]; then
        cp "$PREVIOUS_WIFI_SAVE" "$PREVIOUS_WIFI" 2>/dev/null || true
        echo "true"
    elif [[ -s "$WIFI_CFG_PATH" ]]; then
        local cfg_ssid
        cfg_ssid=$(grep -E '^WIFI_CFG_SSID=' "$WIFI_CFG_PATH" | cut -d= -f2-)
        if [[ -n "$cfg_ssid" ]]; then
            echo "$cfg_ssid" > "$PREVIOUS_WIFI" 2>/dev/null || true
            echo "true"
        else
            echo "false"
        fi
    else
        local WIFI_IFACE
        WIFI_IFACE=$(get_wireless_interface)
        if [[ -n "$WIFI_IFACE" ]] && [[ -S "/run/wpa_supplicant/$WIFI_IFACE" ]]; then
            local count
            count=$(wpa_cli -i "$WIFI_IFACE" list_networks 2>/dev/null | awk 'NR>1 {print $1}' | wc -l)
            if [[ "$count" -gt 0 ]]; then
                echo "true"
            else
                echo "false"
            fi
        else
            echo "false"
        fi
    fi
}

try_previous_wifi() {
    local ssid=""
    if [[ -s "$PREVIOUS_WIFI" ]]; then
        ssid=$(<"$PREVIOUS_WIFI")
    elif [[ -s "$PREVIOUS_WIFI_SAVE" ]]; then
        ssid=$(<"$PREVIOUS_WIFI_SAVE")
    elif [[ -s "$WIFI_CFG_PATH" ]]; then
        ssid=$(grep -E '^WIFI_CFG_SSID=' "$WIFI_CFG_PATH" | cut -d= -f2-)
    fi

    if [[ -z "$ssid" ]]; then
        local WIFI_IFACE
        WIFI_IFACE=$(get_wireless_interface)
        if [[ -n "$WIFI_IFACE" ]] && [[ -S "/run/wpa_supplicant/$WIFI_IFACE" ]]; then
            local unescaped_first
            unescaped_first=$(wpa_cli -i "$WIFI_IFACE" list_networks 2>/dev/null | awk -F'\t' 'NR==2 {print $2}')
            [[ -n "$unescaped_first" ]] && ssid=$(unescape_non_ascii "$unescaped_first")
        fi
    fi

    if [[ -n "$ssid" ]]; then
        debug_print "[wifi] attempting to connect to previous WiFi: $ssid"
        connect_wifi "$ssid"
    else
        debug_print "[wifi] no previous WiFi to connect to"
    fi
}

ARGS=()
for arg in "$@"; do
    if [[ "$arg" != "-d" && "$arg" != "--debug" ]]; then
        ARGS+=("$arg")
    fi
done
set -- "${ARGS[@]}"

case "$1" in
"try_scan")
    try_scan
    ;;
"try_connect")
    try_connect
    ;;
"connect_start")
    validate_arguments 1 $#
    if [[ -z "$2" ]]; then
        echo "Error: SSID cannot be empty" >&2
        exit 1
    fi
    # Reject bad input before tearing down the current connection.
    validate_ssid "$2" || exit 2
    if [[ -n "${3:-}" ]]; then
        validate_psk "$3" || exit 2
    fi
    # A signal from here on restores the previous network (found via
    # PREVIOUS_WIFI_SAVE, which disconnect_wifi records).
    CA_IFACE=$(get_wireless_interface)
    CONNECT_ABORT_HANDLER=connect_abort
    stop_wifi_ap
    disconnect_wifi
    connect_wifi "$2" "${3:-}"
    ;;
"connect_stop")
    disconnect_wifi
    ;;
"connect_remove")
    validate_arguments 1 $#
    if [[ -z "$2" ]]; then
        echo "Error: SSID cannot be empty" >&2
        exit 1
    fi
    remove_wifi "$2"
    ;;
"enterprise_connect")
    validate_arguments 3 $#
    if [[ -z "$2" ]]; then
        echo "Error: SSID cannot be empty" >&2
        exit 1
    fi
    if [[ -z "$3" ]]; then
        echo "Error: EAP method cannot be empty (PEAP, TLS, TTLS)" >&2
        exit 1
    fi
    if [[ -z "$4" ]]; then
        echo "Error: Identity cannot be empty" >&2
        exit 1
    fi
    validate_ssid "$2" || exit 2
    # Reject bad input before tearing down the current connection.
    for ent_arg in "${@:3}"; do
        if [[ "$ent_arg" == *[[:cntrl:]]* ]]; then
            echo "[wifi] enterprise parameters must not contain control characters" >&2
            exit 2
        fi
    done
    # A signal from here on restores the previous network.
    CA_IFACE=$(get_wireless_interface)
    CONNECT_ABORT_HANDLER=connect_abort
    stop_wifi_ap
    disconnect_wifi
    connect_enterprise_wifi "$2" "$3" "$4" "${@:5}"
    ;;
"ap_start")
    validate_arguments 2 $#
    # Both values are written into hostapd.conf; reject anything that could
    # add lines to it before the current link is torn down.
    validate_ssid "$2" || exit 2
    validate_ap_psk "$3" || exit 2
    start_wifi_ap "$2" "$3"
    ;;
"ap_stop")
    stop_wifi_ap
    ;;
"ap_has_device")
    device_check
    ;;
"ap_ip")
    get_ap_ip
    ;;
"interface")
    get_wireless_interface
    ;;
"ip_exists")
    wireless_ip_exists
    ;;
"has_config")
    has_wifi_config
    ;;
"list_networks")
    list_networks
    ;;
"reset")
    stop_wifi_ap
    disconnect_wifi
    stop_service
    rm -f "$WIFI_CFG_PATH" || true
    rm -f "$WPA_CONF_FILE" || true
    rm -f "$PREVIOUS_WIFI_SAVE" || true
    rm -f "$PREVIOUS_WIFI" || true
    rm -f /tmp/ap.pass /tmp/wifi_config || true
    ;;
"check_previous_wifi")
    check_previous_wifi
    ;;
"if_previous_wifi")
    if_previous_wifi
    ;;
"try_previous_wifi")
    try_previous_wifi
    ;;
*)
    show_help
    ;;
esac
