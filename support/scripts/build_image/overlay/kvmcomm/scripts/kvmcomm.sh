#!/usr/bin/env bash

readonly APP_ROOT="/dev/shm/kvmcomm"
readonly SCRIPTS_ROOT="${APP_ROOT}/scripts"
readonly LOG_DIR="/var/log/kvmcomm"
readonly LOG_FILE="${LOG_DIR}/kvmcommd.log"
readonly SERVER_SEL_FILE_BOOT="/boot/.server.txt"
readonly SERVER_SEL_FILE="/etc/kvm/server.txt"
readonly SERVER_DEF="nanokvm"
readonly TARGETS=(
    "${APP_ROOT}/ui/kvm_ui"
    "${APP_ROOT}/vin/kvm_vin"
)
readonly REQUIRED_FIRMWARE_VERSION="v1.0.15"
readonly LVSRCS="/kvmcomm/ui/srcs"
readonly LVDST="/kvmcomm/ui/dst"
readonly LVFRAME_FORGE="/kvmcomm/ui/frameforge"
readonly LVSRCS_GEN_CMD="${LVFRAME_FORGE} --auto2 ${LVSRCS} ${LVDST}"

declare -A CHILD_PIDS=()
declare -A FAIL_COUNTS=()
declare -A WAS_RESTARTED=()

graceful_stop() {
    echo "$(date) - Received stop signal, terminating child processes..." >>"$LOG_FILE"
    # Terminate all daemons
    for pid in "${CHILD_PIDS[@]}"; do
        kill -SIGTERM "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
    done
    # Stop hardware devices
    "${SCRIPTS_ROOT}/gpio.sh" stop >>"$LOG_FILE" 2>&1
    echo "Service has stopped" >>"$LOG_FILE"
    exit 0
}

start_nanokvm() {
    echo "$(date) - Starting server -- nanokvm" >>"$LOG_FILE"
    systemctl start nanokvm
}

start_pikvm() {
    echo "$(date) - Starting server -- pikvm" >>"$LOG_FILE"
    systemd-tmpfiles --create /usr/lib/tmpfiles.d/kvmd.conf

    if [ ! -d "/run/kvmd" ] && [ -f "/etc/kvmd/scripts/pikvm_init.sh" ]; then
        /etc/kvmd/scripts/pikvm_init.sh
        sleep 1
        systemd-tmpfiles --create /usr/lib/tmpfiles.d/kvmd.conf
    fi

    systemctl start kvmd-nginx.service
    systemctl start kvmd.service kvmd-ipmi.service kvmd-janus.service kvmd-media.service kvmd-otg.service kvmd-vnc.service kvmd-webterm.service
}

stop_service_and_wait() {
    local svc_name=$1
    systemctl stop "$svc_name"

    echo "$(date) - Waiting for $svc_name to fully stop..." >>"$LOG_FILE"
    for i in {1..10}; do
        if ! systemctl is-active --quiet "$svc_name"; then
            echo "$(date) - $svc_name stopped." >>"$LOG_FILE"
            return
        fi
        sleep 1
    done
    echo "$(date) - Warning: $svc_name still running after 10s" >>"$LOG_FILE"
}

start_kvm_vin() {
    echo "$(date) - Starting server -- kvm_vin" >>"$LOG_FILE"

    # stop kvm_ui if running
    pkill -f kvm_ui >/dev/null 2>&1 || true

    if systemctl is-active --quiet nanokvm.service; then
        echo "$(date) - nanokvm.service is active, restarting..." >>"$LOG_FILE"
        stop_service_and_wait nanokvm.service
        "${APP_ROOT}/vin/kvm_vin" &
        sleep 0.5
        systemctl start nanokvm.service
    elif systemctl is-active --quiet kvmd.service; then
        echo "$(date) - kvmd.service is active, restarting..." >>"$LOG_FILE"
        stop_service_and_wait kvmd.service
        "${APP_ROOT}/vin/kvm_vin" &
        sleep 0.5
        systemctl start kvmd.service
    else
        "${APP_ROOT}/vin/kvm_vin" &
    fi
}

unload_ko() {
    local ko_input="$1"
    local ko_name

    if [ -z "$ko_input" ]; then
        echo "$(date) - Error: No module name provided." >>"$LOG_FILE"
        return 1
    fi

    ko_name=$(basename "$ko_input" .ko)

    if lsmod | grep -q "^$ko_name"; then
        echo "$(date) - Module '$ko_name' is loaded, unloading..." >>"$LOG_FILE"
        if rmmod "$ko_name"; then
            echo "$(date) - Module '$ko_name' unloaded successfully." >>"$LOG_FILE"
            return 0
        else
            echo "$(date) - Error: Failed to unload module '$ko_name'." >>"$LOG_FILE"
            return 1
        fi
    else
        echo "$(date) - Module '$ko_name' not loaded, skipping unload." >>"$LOG_FILE"
        return 0
    fi
}

load_ko() {
    local ko_input="$1"
    local ko_path="$ko_input"
    local kver
    kver=$(uname -r)
    local specific_path="/kvmcomm/ko_${kver}/$(basename "$ko_input")"
    if [ -f "$specific_path" ]; then
        ko_path="$specific_path"
    fi

    if [ ! -f "$ko_path" ]; then
        echo "$(date) - Error: Kernel module file '$ko_path' not found." >>"$LOG_FILE"
        return 1
    fi

    local ko_name
    ko_name=$(basename "$ko_path" .ko)

    if lsmod | grep -q "^$ko_name"; then
        echo "$(date) - Module '$ko_name' already loaded." >>"$LOG_FILE"
        return 0
    fi

    if insmod "$ko_path"; then
        echo "$(date) - Module '$ko_name' loaded successfully." >>"$LOG_FILE"
        return 0
    else
        echo "$(date) - Error: Failed to load module '$ko_name'." >>"$LOG_FILE"
        return 1
    fi
}

version_lt() {
    [ "$1" = "$2" ] && return 1
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i = ${#ver1[@]}; i < ${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    for ((i = 0; i < ${#ver2[@]}; i++)); do
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 0
        elif ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
    done
    return 1
}

check_firmware_update() {
    local current_version="unknown"

    if [ -f /boot/ver ]; then
        current_version=$(</boot/ver)

        if echo "$current_version" | grep -qi 'custom'; then
            current_version="custom"
        fi
    fi
    echo "$(date) - Current firmware version: $current_version" >>"$LOG_FILE"

    if [ "$current_version" = "custom" ]; then
        echo "$(date) - Custom firmware detected, skipping update check." >>"$LOG_FILE"
        return
    fi

    if [[ "$current_version" =~ v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        current_version="${BASH_REMATCH[0]}"
        cur="${current_version#v}"
        req="${REQUIRED_FIRMWARE_VERSION#v}"
    else
        echo "$(date) - Firmware version is invalid or missing ('$current_version'), forcing update." >>"$LOG_FILE"
        cur="0.0.0"
        req="${REQUIRED_FIRMWARE_VERSION#v}"
    fi

    if version_lt "$cur" "$req"; then
        echo "$(date) - Updating firmware to version $REQUIRED_FIRMWARE_VERSION" >>"$LOG_FILE"

        local cache_dir="/root/.kvmcache"
        local req_ver="${REQUIRED_FIRMWARE_VERSION#v}"
        local firmware_file="$cache_dir/axera_firmware_v${req_ver}.tar.xz"

        if [ -f "$firmware_file" ]; then
            echo "$(date) - Found cached firmware package: $firmware_file" >>"$LOG_FILE"
            "$SCRIPTS_ROOT/firmware_update.sh" update "$firmware_file" >>"$LOG_FILE" 2>&1
        else
            echo "$(date) - No cached firmware found, updating by download $REQUIRED_FIRMWARE_VERSION" >>"$LOG_FILE"
            "$SCRIPTS_ROOT/firmware_update.sh" update "$REQUIRED_FIRMWARE_VERSION" >>"$LOG_FILE" 2>&1
        fi
    else
        echo "$(date) - Firmware is up-to-date." >>"$LOG_FILE"
    fi

    if [ -f "/var/run/reboot-required" ]; then
        echo "$(date) - Firmware update reboot required." >>"$LOG_FILE"
        sync
        echo "Rebooting in 3 seconds..." >>"$LOG_FILE"
        sleep 3
        systemctl reboot
    fi
}

#==================== main ====================#
mkdir -p "$LOG_DIR"
echo "$(date) - Starting kvmcomm service (PID:$$)" >>"$LOG_FILE"

# Ensure active boot slot remains armed after successful boot
bootsystem=$(fw_printenv bootsystem 2>/dev/null | awk -F = '{ print $2 }')
if [ "$bootsystem" = "B" ]; then
    devmem 0x239002C 32 0x80 2>/dev/null || true
    devmem 0x2390028 32 0x28 2>/dev/null || true
    devmem 0x239002C 32 0x4 2>/dev/null || true
fi

# ensure /bin/sh points to bash
shell_target=$(readlink /bin/sh)
if [ "$shell_target" != "bash" ] && [ "$shell_target" != "/bin/bash" ]; then
    echo "Updating /bin/sh to point to bash..." >>"$LOG_FILE"
    ln -sf bash /bin/sh
    sleep 3
    systemctl reboot
fi

check_firmware_update

"${SCRIPTS_ROOT}/gen_hw_info.sh" >>"$LOG_FILE" 2>&1
"${SCRIPTS_ROOT}/gpio.sh" start >>"$LOG_FILE" 2>&1

if [ -f /dev/shm/reset_in_progress.lock ]; then
    rm -f /dev/shm/reset_in_progress.lock
fi

if [ -e "/sys/class/usb_role/8000000.dwc3-role-switch/role" ]; then
    echo "device" >/sys/class/usb_role/8000000.dwc3-role-switch/role
fi

# Auto-restore Wi-Fi connection on boot if previously configured
if [ -s /etc/kvm/wifi.conf ] || [ -s /etc/kvm/wifi_save ] || ( [ -f /etc/wpa_supplicant/wpa_supplicant.conf ] && grep -q 'network=' /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null ); then
    echo "$(date) - Triggering Wi-Fi auto-connect on boot..." >>"$LOG_FILE"
    nohup "${SCRIPTS_ROOT}/wifi.sh" try_connect >>"$LOG_FILE" 2>&1 &
fi

load_ko /kvmcomm/ko/rotary_encoder.ko
load_ko /kvmcomm/ko/gpio_keys.ko
load_ko /kvmcomm/ko/f_udisp_drv.ko
unload_ko /kvmcomm/ko/lt6911_manage.ko

INS_MOD_PARAMS=""
read_numeric_param() {
    local file="$1"
    local varname="$2"
    if [ -e "$file" ]; then
        local val
        val=$(tr -d ' \t\r\n' <"$file")
        if [ -n "$val" ] && echo "$val" | grep -qE '^[0-9]+$'; then
            eval "$varname=$val"
        fi
    fi
}

read_numeric_param "/boot/force_width" force_width
read_numeric_param "/boot/force_height" force_height
read_numeric_param "/boot/force_fps" force_fps

[ -n "$force_width" ] && [ -n "$force_height" ] && INS_MOD_PARAMS="force_width=$force_width force_height=$force_height"
[ -n "$force_fps" ] && [ -n "$INS_MOD_PARAMS" ] && INS_MOD_PARAMS="$INS_MOD_PARAMS force_fps=$force_fps"

[ -z "$INS_MOD_PARAMS" ] && [ -n "$force_fps" ] && INS_MOD_PARAMS="force_fps=$force_fps"

LT6911_KO="/kvmcomm/ko/lt6911_manage.ko"
if [ -f "/kvmcomm/ko_$(uname -r)/lt6911_manage.ko" ]; then
    LT6911_KO="/kvmcomm/ko_$(uname -r)/lt6911_manage.ko"
fi

if [ -n "$INS_MOD_PARAMS" ]; then
    echo "$(date) - Loading $LT6911_KO with params: $INS_MOD_PARAMS" >>"$LOG_FILE"
    insmod "$LT6911_KO" $INS_MOD_PARAMS || (sleep 1 && insmod "$LT6911_KO" $INS_MOD_PARAMS) || true
else
    echo "$(date) - Loading $LT6911_KO with default parameters" >>"$LOG_FILE"
    insmod "$LT6911_KO" || (sleep 1 && insmod "$LT6911_KO") || true
fi

# Restore HDMI passthrough state if configured
readonly HDMI_PASSTHROUGH_CONF="/etc/kvm/hdmi_passthrough"
if [ -f "$HDMI_PASSTHROUGH_CONF" ]; then
    pt_val=$(tr -d ' \t\r\n' <"$HDMI_PASSTHROUGH_CONF")
    if [ "$pt_val" = "0" ] || [ "$pt_val" = "off" ]; then
        echo "$(date) - Restoring HDMI passthrough: disabled" >>"$LOG_FILE"
        echo 0 > /proc/lt6911_info/loopout_power 2>/dev/null || true
        echo 0 > /proc/lt6911_info/hdmi_power 2>/dev/null || true
        usleep 10000 2>/dev/null || sleep 0.01 2>/dev/null || true
        echo 1 > /proc/lt6911_info/hdmi_power 2>/dev/null || true
    elif [ "$pt_val" = "1" ] || [ "$pt_val" = "on" ]; then
        echo "$(date) - Restoring HDMI passthrough: enabled" >>"$LOG_FILE"
        echo 0 > /proc/lt6911_info/hdmi_power 2>/dev/null || true
        usleep 10000 2>/dev/null || sleep 0.01 2>/dev/null || true
        echo 1 > /proc/lt6911_info/loopout_power 2>/dev/null || true
        echo 1 > /proc/lt6911_info/hdmi_power 2>/dev/null || true
    fi
fi

ver=$(cat /boot/ver | awk -F- '{print $5}' | sed 's/^v//')
if ! version_lt "$ver" "1.0.12"; then
    load_ko /kvmcomm/ko/wireguard.ko
fi


start_kvm_vin

if [ ! -f "$SERVER_SEL_FILE_BOOT" ]; then
    echo "$SERVER_DEF" >"$SERVER_SEL_FILE_BOOT"
fi

if [ -e "$SERVER_SEL_FILE" ] && [ ! -L "$SERVER_SEL_FILE" ]; then
    mv -f "$SERVER_SEL_FILE" "$SERVER_SEL_FILE_BOOT"
fi

if [ ! -L "$SERVER_SEL_FILE" ] || [ "$(readlink -f "$SERVER_SEL_FILE")" != "$(readlink -f "$SERVER_SEL_FILE_BOOT")" ]; then
    ln -sf "$SERVER_SEL_FILE_BOOT" "$SERVER_SEL_FILE"
fi

server=$(<"$SERVER_SEL_FILE")
echo "$(date) - Use server -- $server" >>"$LOG_FILE"
case "$server" in
"nanokvm")
    start_nanokvm
    ;;
"pikvm")
    start_pikvm
    ;;
*)
    echo "$(date) - Unknown server...fix" >>"$LOG_FILE"
    echo "$SERVER_DEF" >"$SERVER_SEL_FILE"
    start_nanokvm
    ;;
esac

load_ko /kvmcomm/ko/fbtft.ko
echo 1 >/sys/class/backlight/backlight/bl_power
load_ko /kvmcomm/ko/fb_jd9853.ko
echo 0 >/sys/class/backlight/backlight/bl_power

trap graceful_stop SIGTERM SIGINT

while true; do
    for target in "${TARGETS[@]}"; do
        exe_name=$(basename $(echo $target | awk '{print $1}'))
        if ! pgrep -f "$exe_name" >/dev/null; then
            echo "$(date) - Restart: $target" >>"$LOG_FILE"
            # $target >>"$LOG_DIR/${exe_name}.log" 2>&1 &
            # CHILD_PIDS["$exe_name"]=$!

            if [ "$exe_name" = "kvm_vin" ]; then
                start_kvm_vin
            elif [ "$exe_name" = "kvm_ui" ]; then
                if [ ! -d "${LVDST}" ]; then
                    echo "gen lvsrcs..." >>"$LOG_FILE" 2>&1
                    ${LVSRCS_GEN_CMD} >>"$LOG_FILE" 2>&1
                fi
                "$SCRIPTS_ROOT"/gpio_write.sh 76 1 >>/dev/null 2>&1
                "$SCRIPTS_ROOT"/gpio_write.sh 76 0 >>/dev/null 2>&1
                "$SCRIPTS_ROOT"/gpio_write.sh 76 1 >>/dev/null 2>&1
                $target >>"$LOG_DIR/${exe_name}.log" 2>&1 &
            else
                $target >>"$LOG_DIR/${exe_name}.log" 2>&1 &
            fi

            pid=$!
            CHILD_PIDS["$exe_name"]=$pid
            echo "$(date) - Started $exe_name (PID:$pid, parent PID:$$)" >>"$LOG_FILE"

            if [ "${WAS_RESTARTED[$exe_name]:-no}" = "yes" ]; then
                ((FAIL_COUNTS["$exe_name"]++)) || true
            else
                FAIL_COUNTS["$exe_name"]=1
            fi
            WAS_RESTARTED["$exe_name"]="yes"

            if [ ${FAIL_COUNTS["$exe_name"]} -ge 3 ]; then
                # touch "$FACTORY_RESET_FLAG"
                exit 1
            fi
        else
            FAIL_COUNTS["$exe_name"]=0
            WAS_RESTARTED["$exe_name"]="no"
        fi
    done
    sleep 2 &
    wait $!
done
