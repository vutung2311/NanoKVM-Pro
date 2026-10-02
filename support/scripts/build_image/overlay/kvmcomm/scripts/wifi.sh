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
    flock -u 200
}

trap release_lock EXIT INT TERM

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
EOF
        debug_print "[wifi] created default wpa config at $WPA_CONF_FILE"
    fi
}

start_service() {
    local WIFI_IFACE
    WIFI_IFACE=$(get_wireless_interface) || exit 1

    ensure_wpa_conf

    if ! pgrep -f "wpa_supplicant.*${WIFI_IFACE}" >/dev/null; then
        debug_print "[wifi] starting wpa_supplicant..."
        mkdir -p /run/wpa_supplicant
        wpa_supplicant -D "${DRIVER}" -i "$WIFI_IFACE" -c "$WPA_CONF_FILE" -B -P "$WPA_PID_FILE" >/dev/null 2>&1
        local WPA_PID=$(cat "$WPA_PID_FILE")
        echo $WPA_PID > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
        sleep 1
    fi

    if [[ ! -S "/run/wpa_supplicant/$WIFI_IFACE" ]]; then
        debug_print "[wifi] warning: control socket not found!"
    else
        debug_print "[wifi] wpa_supplicant is running on $WIFI_IFACE"
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

    if pgrep hostapd >/dev/null; then
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
    while pgrep -f "wpa_supplicant.*${WIFI_IFACE}" >/dev/null && [ $retry -lt 10 ]; do
        sleep 0.5
        ((retry++))
    done

    if pgrep -f "wpa_supplicant.*${WIFI_IFACE}" >/dev/null; then
        pkill -9 -f "wpa_supplicant.*${WIFI_IFACE}" || true
        sleep 0.5
    fi

    pkill hostapd || true
    pkill udhcpd || true

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
    hostapd -B "$HOSTAPD_CONF" >/dev/null 2>&1

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
    udhcpd "$UDHCPD_CONF" >/dev/null 2>&1

    debug_print "[wifi] configuring network routing"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    iptables -t nat -A POSTROUTING -o "$ETH_IFACE" -j MASQUERADE
    iptables -A FORWARD -i "$WIFI_IFACE" -o "$ETH_IFACE" -j ACCEPT
    iptables -A FORWARD -i "$ETH_IFACE" -o "$WIFI_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT

    printf "%s" "$WIFI_PSW" > /tmp/ap.pass
    touch /tmp/wifi_config

    debug_print "[wifi] access point activated - SSID: ${WIFI_SSID} | Password: ${WIFI_PSW}"
}

stop_wifi_ap() {
    local WIFI_IFACE=$(get_wireless_interface)

    debug_print "[wifi] terminating ap services"
    pkill hostapd || true
    pkill udhcpd || true
    rm -f /tmp/ap.pass /tmp/wifi_config || true

    debug_print "[wifi] cleaning network configuration"
    iptables -t nat -D POSTROUTING -o "$ETH_IFACE" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "$WIFI_IFACE" -o "$ETH_IFACE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$ETH_IFACE" -o "$WIFI_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

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

    local WIFI_CFG_SSID=""

    # 1. Try reading SSID from WIFI_CFG_PATH (/etc/kvm/wifi.conf)
    if [[ -r "$WIFI_CFG_PATH" ]]; then
        while IFS="=" read -r key value; do
            case "$key" in
            "WIFI_CFG_SSID") WIFI_CFG_SSID="$value" ;;
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

    if ! connect_wifi "$WIFI_CFG_SSID"; then
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

connect_wifi() {
    local ssid="$1"
    local password="$2"
    local WIFI_IFACE
    WIFI_IFACE=$(get_wireless_interface)

    start_service

    if [[ ! -S "/run/wpa_supplicant/${WIFI_IFACE}" ]]; then
        echo "[wifi] wpa_supplicant socket not found for $WIFI_IFACE" >&2
        return 1
    fi

    local ssid_escaped
    ssid_escaped=$(escape_non_ascii "$ssid")
    debug_print "[wifi] ssid_escaped: $ssid_escaped"

    local existing
    existing=$(wpa_cli -i "$WIFI_IFACE" list_networks | awk -F'\t' -v s="$ssid_escaped" 'NR>1 && $2==s {print $1; exit}')
    debug_print "[wifi] existing network id: $existing"

    if [[ -n "$password" && -n "$existing" ]]; then
        debug_print "[wifi] password provided, deleting existing network id=$existing"
        wpa_cli -i "$WIFI_IFACE" remove_network "$existing" >/dev/null
        existing=""
    fi

    if [[ -n "$existing" ]]; then
        debug_print "[wifi] found existing network id=$existing, reusing."
        wpa_cli -i "$WIFI_IFACE" set_network "$existing" mesh_fwding 0 >/dev/null
        wpa_cli -i "$WIFI_IFACE" enable_network "$existing" >/dev/null
        wpa_cli -i "$WIFI_IFACE" select_network "$existing" >/dev/null
        wpa_cli -i "$WIFI_IFACE" save_config >/dev/null
    else
        debug_print "[wifi] adding new network: $ssid"
        local id
        id=$(wpa_cli -i "$WIFI_IFACE" add_network | tail -n1)
        wpa_cli -i "$WIFI_IFACE" set_network "$id" ssid "\"$ssid\"" >/dev/null

        if [[ -z "$password" ]]; then
            wpa_cli -i "$WIFI_IFACE" set_network "$id" key_mgmt NONE >/dev/null
        else
            local psk
            psk=$(wpa_passphrase "$ssid" "$password" 2>/dev/null | awk -F= '/^[ \t]*psk=[^#]/{print $2; exit}')
            wpa_cli -i "$WIFI_IFACE" set_network "$id" psk "$psk" >/dev/null
        fi

        wpa_cli -i "$WIFI_IFACE" set_network "$id" mesh_fwding 0 >/dev/null
        wpa_cli -i "$WIFI_IFACE" enable_network "$id" >/dev/null
        wpa_cli -i "$WIFI_IFACE" select_network "$id" >/dev/null
        wpa_cli -i "$WIFI_IFACE" save_config >/dev/null
        debug_print "[wifi] saved new WiFi to config"
    fi

    debug_print "[wifi] waiting for connection..."
    local retry=0
    while [ $retry -lt 10 ]; do
        if wpa_cli -i "$WIFI_IFACE" status | grep -qF "wpa_state=COMPLETED"; then
            debug_print "[wifi] connection established"
            break
        fi
        sleep 1
        ((retry++))
    done

    if [ $retry -eq 10 ]; then
        debug_print "[wifi] connection timeout" >&2
        return 1
    fi

    ip addr flush dev "$WIFI_IFACE"

    debug_print "[wifi] requesting IP address via DHCP..."
    if ! udhcpc -i "${WIFI_IFACE}" -s /kvmcomm/scripts/udhcpc.script >/dev/null 2>&1; then
        echo "[wifi] DHCP failed on $WIFI_IFACE" >&2
        return 1
    fi

    cat <<EOF >"$WIFI_CFG_PATH"
WIFI_CFG_SSID=${ssid}
EOF
    echo "$ssid" > "$PREVIOUS_WIFI_SAVE" 2>/dev/null || true
    echo "$ssid" > "$PREVIOUS_WIFI" 2>/dev/null || true
    sync 2>/dev/null || true

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

    local WIFI_IFACE
    WIFI_IFACE=$(get_wireless_interface)

    start_service

    if [[ ! -S "/run/wpa_supplicant/${WIFI_IFACE}" ]]; then
        echo "[wifi] wpa_supplicant socket not found for $WIFI_IFACE" >&2
        return 1
    fi

    local ssid_escaped
    ssid_escaped=$(escape_non_ascii "$ssid")
    debug_print "[wifi] enterprise connect: ssid=$ssid eap=$eap_method identity=$identity"

    local existing
    existing=$(wpa_cli -i "$WIFI_IFACE" list_networks | awk -F'\t' -v s="$ssid_escaped" 'NR>1 && $2==s {print $1; exit}')
    if [[ -n "$existing" ]]; then
        debug_print "[wifi] removing existing network id=$existing for reconfiguration"
        wpa_cli -i "$WIFI_IFACE" remove_network "$existing" >/dev/null
    fi

    local id
    id=$(wpa_cli -i "$WIFI_IFACE" add_network | tail -n1)
    debug_print "[wifi] added enterprise network id=$id"

    wpa_cli -i "$WIFI_IFACE" set_network "$id" ssid "\"$ssid\"" >/dev/null
    wpa_cli -i "$WIFI_IFACE" set_network "$id" key_mgmt "WPA-EAP" >/dev/null
    wpa_cli -i "$WIFI_IFACE" set_network "$id" eap "$eap_method" >/dev/null
    wpa_cli -i "$WIFI_IFACE" set_network "$id" identity "\"$identity\"" >/dev/null

    if [[ -n "$anonymous_identity" ]]; then
        wpa_cli -i "$WIFI_IFACE" set_network "$id" anonymous_identity "\"$anonymous_identity\"" >/dev/null
    fi

    if [[ -n "$ca_cert" ]]; then
        wpa_cli -i "$WIFI_IFACE" set_network "$id" ca_cert "\"$ca_cert\"" >/dev/null
    fi

    if [[ -n "$domain" ]]; then
        wpa_cli -i "$WIFI_IFACE" set_network "$id" domain_suffix_match "\"$domain\"" >/dev/null
    fi

    case "$eap_method" in
        PEAP)
            wpa_cli -i "$WIFI_IFACE" set_network "$id" password "\"$password\"" >/dev/null
            wpa_cli -i "$WIFI_IFACE" set_network "$id" phase2 "\"$phase2\"" >/dev/null
            debug_print "[wifi] PEAP configured with phase2=$phase2"
            ;;
        TLS)
            wpa_cli -i "$WIFI_IFACE" set_network "$id" client_cert "\"$client_cert\"" >/dev/null
            wpa_cli -i "$WIFI_IFACE" set_network "$id" private_key "\"$private_key\"" >/dev/null
            if [[ -n "$private_key_passwd" ]]; then
                wpa_cli -i "$WIFI_IFACE" set_network "$id" private_key_passwd "\"$private_key_passwd\"" >/dev/null
            fi
            debug_print "[wifi] EAP-TLS configured with cert=$client_cert key=$private_key"
            ;;
        TTLS)
            wpa_cli -i "$WIFI_IFACE" set_network "$id" password "\"$password\"" >/dev/null
            wpa_cli -i "$WIFI_IFACE" set_network "$id" phase2 "\"$phase2\"" >/dev/null
            debug_print "[wifi] EAP-TTLS configured with phase2=$phase2"
            ;;
    esac

    wpa_cli -i "$WIFI_IFACE" set_network "$id" mesh_fwding 0 >/dev/null
    wpa_cli -i "$WIFI_IFACE" enable_network "$id" >/dev/null
    wpa_cli -i "$WIFI_IFACE" select_network "$id" >/dev/null
    wpa_cli -i "$WIFI_IFACE" save_config >/dev/null

    debug_print "[wifi] waiting for enterprise connection..."
    local retry=0
    while [ $retry -lt 20 ]; do
        local state
        state=$(wpa_cli -i "$WIFI_IFACE" status 2>/dev/null | grep "wpa_state=" | cut -d= -f2)
        if [[ "$state" == "COMPLETED" ]]; then
            debug_print "[wifi] enterprise connection established"
            break
        fi
        sleep 1
        ((retry++))
    done

    if [ $retry -eq 20 ]; then
        echo "[wifi] enterprise connection timeout after 20 seconds" >&2
        local status_output
        status_output=$(wpa_cli -i "$WIFI_IFACE" status 2>/dev/null)
        local eap_status
        eap_status=$(echo "$status_output" | grep "EAP state=" | cut -d= -f2)
        if [[ -n "$eap_status" ]]; then
            debug_print "[wifi] EAP state at timeout: $eap_status"
        fi
        return 1
    fi

    ip addr flush dev "$WIFI_IFACE"

    debug_print "[wifi] requesting IP address via DHCP..."
    if ! udhcpc -i "${WIFI_IFACE}" -s /kvmcomm/scripts/udhcpc.script >/dev/null 2>&1; then
        echo "[wifi] DHCP failed on $WIFI_IFACE" >&2
        return 1
    fi

    cat <<EOF >"$WIFI_CFG_PATH"
WIFI_CFG_SSID=${ssid}
EOF
    echo "$ssid" > "$PREVIOUS_WIFI_SAVE" 2>/dev/null || true
    echo "$ssid" > "$PREVIOUS_WIFI" 2>/dev/null || true
    sync 2>/dev/null || true

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

        local networks=$(list_networks)
        local network_ssid=$(echo "$networks" | grep -o '{"ssid":"[^"]*","flags":"CURRENT"}' | sed -n 's/.*"ssid":"\([^"]*\)".*/\1/p')
        local network_id=$(wpa_cli -i "$WIFI_IFACE" list_networks | grep '\[CURRENT\]' | awk '{print $1}')

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

    local ssid_escaped
    ssid_escaped=$(escape_non_ascii "$ssid")
    debug_print "[wifi] removing network: $ssid (escaped: $ssid_escaped)"

    local network_id
    network_id=$(wpa_cli -i "$WIFI_IFACE" list_networks | awk -F'\t' -v s="$ssid_escaped" 'NR>1 && $2==s {print $1; exit}')

    if [[ -z "$network_id" ]]; then
        debug_print "[wifi] network not found: $ssid" >&2
        return 1
    fi

    local is_current
    is_current=$(wpa_cli -i "$WIFI_IFACE" list_networks | awk -F'\t' -v s="$ssid_escaped" 'NR>1 && $2==s && $4~/\[CURRENT\]/ {print "true"; exit}')
    [[ "$is_current" != "true" ]] && is_current="false"

    if [[ "$is_current" == "true" ]]; then
        debug_print "[wifi] network is currently connected, disconnecting first..."
        disconnect_wifi
        sleep 1
    fi

    debug_print "[wifi] found network id=$network_id, removing..."

    if wpa_cli -i "$WIFI_IFACE" remove_network "$network_id" >/dev/null; then
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
    stop_wifi_ap
    disconnect_wifi
    connect_enterprise_wifi "$2" "$3" "$4" "${@:5}"
    ;;
"ap_start")
    validate_arguments 2 $#
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
    ;;
"try_previous_wifi")
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
    ;;
*)
    show_help
    ;;
esac
