#!/usr/bin/env bash

readonly APP_ROOT="/dev/shm/kvmapp"
readonly SCRIPTS_ROOT="${APP_ROOT}/scripts"
readonly LOG_DIR="/var/log/nanokvm"
readonly LOG_FILE="${LOG_DIR}/nanokvmd.log"
readonly TARGETS=(
    "${APP_ROOT}/server/NanoKVM-Server"
)

declare -A CHILD_PIDS=()
declare -A FAIL_COUNTS=()
declare -A WAS_RESTARTED=()

# Logs live on a size-capped tmpfs (var-log-nanokvm.mount). Cut any *.log that
# has grown past LOG_MAX_KB back to its last LOG_KEEP_KB, kept as *.log.1, so
# the newest output is never the part that is lost. O_APPEND writers (the
# shell redirections) carry on at the new end; du counts allocated blocks, so a
# writer that does not append (sparse after the cut) is not trimmed in a loop.
readonly LOG_MAX_KB=2048
readonly LOG_KEEP_KB=256
trim_logs() {
    local f kb
    for f in "$LOG_DIR"/*.log; do
        [ -f "$f" ] || continue
        kb=$(du -k "$f" 2>/dev/null | cut -f1)
        if [ "${kb:-0}" -gt "$LOG_MAX_KB" ]; then
            tail -c "${LOG_KEEP_KB}K" "$f" >"$f.1" 2>/dev/null || true
            : >"$f"
        fi
    done
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

# The pair is usable: both parse, and the key is the certificate's (any key
# type, so a user's own ECDSA or RSA certificate passes).
https_crt_valid() {
    local crt=$1 key=$2 crt_pub key_pub
    crt_pub=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null) || return 1
    key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null) || return 1
    [ -n "$crt_pub" ] && [ "$crt_pub" = "$key_pub" ]
}

# The RSA certificate this script and postinst used to generate: self-signed
# for CN=localhost. ECDSA replaces it once; RSA-2048 signing costs 13.7 ms per
# TLS handshake on this CPU, P-256 0.4 ms. Any other certificate is the user's.
https_crt_is_old_default() {
    local crt=$1
    openssl x509 -in "$crt" -noout -text 2>/dev/null | grep -q "Public Key Algorithm: rsaEncryption" || return 1
    [ "$(openssl x509 -in "$crt" -noout -subject -nameopt RFC2253 2>/dev/null)" = "subject=CN=localhost" ] &&
        [ "$(openssl x509 -in "$crt" -noout -issuer -nameopt RFC2253 2>/dev/null)" = "issuer=CN=localhost" ]
}

makesure_https_crt() {
    local key=/etc/kvm/server.key crt=/etc/kvm/server.crt reason=""

    echo "$(date) - Starting certificate verification..." >>"$LOG_FILE"

    if [ ! -f "$key" ] || [ ! -f "$crt" ]; then
        reason="is missing"
    elif ! https_crt_valid "$crt" "$key"; then
        reason="is invalid, or the key does not match it"
    elif https_crt_is_old_default "$crt"; then
        reason="is the old self-signed RSA default"
    fi

    if [ -z "$reason" ]; then
        echo "$(date) - All certificates valid" >>"$LOG_FILE"
        return 0
    fi

    echo "$(date) - Certificate $reason: generating an ECDSA P-256 one" >>"$LOG_FILE"
    mkdir -p /etc/kvm
    rm -f "$key" "$crt"
    # umask: the key is never readable by others, not even before the chmod.
    if (umask 077; openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key" -out "$crt" \
        -days 3650 -nodes -subj "/CN=localhost") >>"$LOG_FILE" 2>&1; then
        chmod 600 "$key"
        chmod 644 "$crt"
        sync
        echo "$(date) - SSL certificates generated successfully" >>"$LOG_FILE"
    else
        echo "$(date) - Error: SSL certificate generation failed" >>"$LOG_FILE"
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

loop_count=0
while true; do
    # Every ~60 s (the loop sleeps 2 s).
    if [ $((loop_count++ % 30)) -eq 0 ]; then
        trim_logs
    fi
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
