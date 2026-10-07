#!/bin/bash

DEBUG="false"
readonly CFG_ROOT="/etc/kvm/hw"

### hw
readonly HW_CFG_PATH="$CFG_ROOT/hw"
readonly HW_CFG_ITEM_PCIE="NanoKVM-Pro-PCIe"
readonly HW_CFG_ITEM_OTHER="NanoKVM-Pro-Other"
readonly HW_CFG_LIST=(
    "$HW_CFG_ITEM_PCIE"
    "$HW_CFG_ITEM_OTHER"
)

### hw version
readonly HW_VER_ITEM_UNKNOWN="unknown"
readonly HW_VER_ITEM_ALPHA="alpha"
readonly HW_VER_ITEM_BETA="beta"
readonly HW_VER_LIST=(
    "$HW_VER_ITEM_UNKNOWN"
    "$HW_VER_ITEM_ALPHA"
    "$HW_VER_ITEM_BETA"
)

### screen
readonly SCREEN_CFG_PATH="$CFG_ROOT/screen"
readonly SCREEN_CFG_ITEM_OLED="OLED"
readonly SCREEN_CFG_ITEM_OTHER="OTHER"

# Print debug messages when DEBUG is true
debug_print() {
    [[ "$DEBUG" == "true" ]] && printf "[DEBUG] %s\n" "$*"
}

# Check if a file's content matches any element in a named array
file_match_array() {
    local file="$1"
    local arr_name="$2"
    declare -n patterns="$arr_name"

    if [[ ! -f "$file" ]]; then
        # File does not exist or is empty
        return 1
    fi

    for pat in "${patterns[@]}"; do
        # Match line exactly
        if grep -Fxq "$pat" "$file"; then
            return 0
        fi
    done

    return 1
}

# Detect I2C device on a given bus and address
# Usage: i2c_device_exists <bus> <0xhexaddr>
i2c_device_exists() {
    local bus="$1"
    local addr="${2#0x}"
    addr=$(echo "$addr" | tr '[:upper:]' '[:lower:]')

    # Look for address in i2cdetect output
    if i2cdetect -y "$bus" 2>/dev/null | grep -qw "$addr"; then
        return 0
    fi

    return 1
}

adc_device_exists() {
    local adc_path="/sys/bus/iio/devices/iio:device0/in_voltage2_raw"

    if [[ -f "$adc_path" ]] && [[ -r "$adc_path" ]]; then
        return 0
    fi

    return 1
}

main() {
    # Ensure configuration directory exists
    if [[ ! -d "$CFG_ROOT" ]]; then
        debug_print "$CFG_ROOT does not exist, creating"
        mkdir -p "$CFG_ROOT"
    fi

    # Check for OLED on I2C bus 3
    local oled_exists=false
    if i2c_device_exists 3 0x3c; then
        oled_exists=true
    fi
    debug_print "i2c oled exists: $oled_exists"

    # Initialize hardware config if missing or invalid
    if ! file_match_array "$HW_CFG_PATH" HW_CFG_LIST; then
        debug_print "$HW_CFG_PATH invalid or missing"
        if [[ "$oled_exists" == true ]]; then
            echo "$HW_CFG_ITEM_PCIE" >"$HW_CFG_PATH"
        else
            echo "$HW_CFG_ITEM_OTHER" >"$HW_CFG_PATH"
        fi
    fi

    # Set screen config based on OLED presence
    if [[ "$oled_exists" == true ]]; then
        echo "$SCREEN_CFG_ITEM_OLED" >"$SCREEN_CFG_PATH"
    else
        echo "$SCREEN_CFG_ITEM_OTHER" >"$SCREEN_CFG_PATH"
    fi

    # Check for ADC device
    local adc_exists=false
    if adc_device_exists; then
        adc_exists=true
    fi
    debug_print "ADC device exists: $adc_exists"

    if $adc_exists; then
        local adc_value
        adc_value=$(cat /sys/bus/iio/devices/iio:device0/in_voltage2_raw 2>/dev/null)
        
        if [[ -n "$adc_value" && "$adc_value" -ge 483 && "$adc_value" -le 540 ]]; then
            hw_ver="$HW_VER_ITEM_ALPHA"
        else
            hw_ver="$HW_VER_ITEM_UNKNOWN"
        fi

        debug_print "ADC value: $adc_value, hw_version: $hw_ver"
    else
        hw_ver="$HW_VER_ITEM_UNKNOWN"
    fi

    # Write hardware version to config
    local hw_ver_path="$CFG_ROOT/hw_ver"
    echo "$hw_ver" > "$hw_ver_path"
}

main
