#!/usr/bin/env bash

readonly APP_ROOT="/dev/shm/kvmapp"
readonly SCRIPTS_ROOT="${APP_ROOT}/scripts"
readonly LOG_DIR="/var/log/nanokvm"
readonly LOG_FILE="${LOG_DIR}/nanokvmd.log"
readonly TARGETS=(
    "${APP_ROOT}/server/NanoKVM-Server"
)
readonly HTTPS_CRT=(
    "/etc/kvm/server.key"
    "/etc/kvm/server.crt"
)

declare -A CHILD_PIDS=()
declare -A FAIL_COUNTS=()
declare -A WAS_RESTARTED=()

check_log_size() {
    if [ -f "$LOG_FILE" ]; then
        local log_size
        log_size=$(stat -c%s "$LOG_FILE")
        if [ "$log_size" -gt $((10 * 1024 * 1024)) ]; then
            echo "$(date) - Log file exceeded 10MB, rotating..." >>"$LOG_FILE"
            rm -f "$LOG_FILE"
            echo "$(date) - Log file cleared" >>"$LOG_FILE"
        fi
    fi
}

graceful_stop() {
    echo "$(date) - Received stop signal, terminating child processes..." >>"$LOG_FILE"
    for pid in "${CHILD_PIDS[@]}"; do
        kill -SIGTERM "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
    done
    "${SCRIPTS_ROOT}/usbdev.sh" stop >>"$LOG_FILE" 2>&1
    echo "Service has stopped" >>"$LOG_FILE"
    exit 0
}

makesure_https_crt() {
    local need_delete=0

    echo "$(date) - Starting certificate verification..." >>"$LOG_FILE"

    for cert in "${HTTPS_CRT[@]}"; do
        if [ ! -f "$cert" ]; then
            echo "$(date) - Certificate file not found: $cert" >>"$LOG_FILE"
            need_delete=1
        fi
    done

    if [ $need_delete -eq 0 ]; then
        if ! openssl x509 -in /etc/kvm/server.crt -noout -text >/dev/null 2>&1; then
            echo "$(date) - Invalid certificate: /etc/kvm/server.crt" >>"$LOG_FILE"
            need_delete=1
        fi

        if ! openssl rsa -in /etc/kvm/server.key -check -noout >/dev/null 2>&1; then
            echo "$(date) - Invalid private key: /etc/kvm/server.key" >>"$LOG_FILE"
            need_delete=1
        fi

        if [ $need_delete -eq 0 ]; then
            crt_mod=$(openssl x509 -noout -modulus -in /etc/kvm/server.crt 2>/dev/null | openssl md5)
            key_mod=$(openssl rsa -noout -modulus -in /etc/kvm/server.key 2>/dev/null | openssl md5)
            if [ "$crt_mod" != "$key_mod" ]; then
                echo "$(date) - Certificate and private key do not match" >>"$LOG_FILE"
                need_delete=1
            fi
        fi
    fi

    if [ $need_delete -eq 1 ]; then
        echo "$(date) - Invalid or missing certificates, initiating cleanup..." >>"$LOG_FILE"

        for cert in "${HTTPS_CRT[@]}"; do
            if [ -e "$cert" ]; then
                rm -f "$cert" && echo "$(date) - Deleted: $cert" >>"$LOG_FILE"
            fi
        done

        echo "$(date) - Generating new SSL certificates..." >>"$LOG_FILE"
        mkdir -p /etc/kvm
        openssl req -x509 -newkey rsa:2048 \
            -keyout /etc/kvm/server.key \
            -out /etc/kvm/server.crt \
            -days 3650 -nodes -subj "/CN=localhost" 2>&1 >>"$LOG_FILE"
        chmod 600 /etc/kvm/server.key
        chmod 644 /etc/kvm/server.crt
        sync
        echo "$(date) - SSL certificates generated successfully" >>"$LOG_FILE"
    else
        echo "$(date) - All certificates valid" >>"$LOG_FILE"
    fi
}

#==================== main ====================#
mkdir -p "$LOG_DIR"
mkdir -p /etc/kvm
export LD_LIBRARY_PATH="/opt/lib:${APP_ROOT}/server/dl_lib:${LD_LIBRARY_PATH:-}"
echo "$(date) - Starting kvmcomm service" >>"$LOG_FILE"

makesure_https_crt

"${SCRIPTS_ROOT}/usbdev.sh" start >>"$LOG_FILE" 2>&1

trap graceful_stop SIGTERM SIGINT

while true; do
    check_log_size
    for target in "${TARGETS[@]}"; do
        exe_name=$(basename $(echo $target | awk '{print $1}'))
        if ! pgrep -x "$exe_name" >/dev/null; then
            echo "$(date) - Restart: $target" >>"$LOG_FILE"
            (cd "${APP_ROOT}/server" && $target >>"$LOG_DIR/${exe_name}.log" 2>&1) &
            pid=$!
            CHILD_PIDS["$exe_name"]=$pid
            echo "$(date) - Started $exe_name (PID:$pid)" >>"$LOG_FILE"

            if [ "${WAS_RESTARTED[$exe_name]:-no}" = "yes" ]; then
                FAIL_COUNTS["$exe_name"]=$((FAIL_COUNTS["$exe_name"] + 1))
            else
                FAIL_COUNTS["$exe_name"]=1
            fi
            WAS_RESTARTED["$exe_name"]="yes"

            if [ ${FAIL_COUNTS["$exe_name"]} -ge 3 ]; then
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
