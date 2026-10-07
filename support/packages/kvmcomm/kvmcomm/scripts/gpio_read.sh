#!/bin/bash

# Parameter validity check
if [ $# -ne 1 ] || ! [[ $1 =~ ^[0-9]+$ ]]; then
    echo "Error: Must specify a valid GPIO number"
    echo "Usage: sudo $0 <gpio_number>"
    echo "Example: Read GPIO69 → sudo $0 69"
    exit 1
fi

GPIO=$1
SYSFS_PATH="/sys/class/gpio/gpio$GPIO"
EXPORT_FILE="/sys/class/gpio/export"

# Permission check (requires root permission)
if [ $(id -u) -ne 0 ]; then
    echo "Error: Requires root privileges to execute this script" >&2
    exit 1
fi

# Automatically export GPIO if not exported
if [ ! -d "$SYSFS_PATH" ]; then
    echo "Warning: GPIO$GPIO is not exported, exporting now..."
    echo $GPIO >$EXPORT_FILE 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "Error: Failed to export GPIO$GPIO (may not exist or be occupied)" >&2
        exit 1
    fi
    # Set direction to input mode (default direction for newly exported GPIO)
    echo "in" >"$SYSFS_PATH/direction" 2>/dev/null || :
fi

# Verify GPIO direction
CURRENT_DIR=$(cat "$SYSFS_PATH/direction" 2>/dev/null)
if [ "$CURRENT_DIR" != "in" ]; then
    echo "Warning: GPIO$GPIO current direction is $CURRENT_DIR, forcing input mode"
    echo "in" >"$SYSFS_PATH/direction" || {
        echo "Error: Unable to set input mode" >&2
        exit 1
    }
fi

# Read the voltage level value
VALUE=$(cat "$SYSFS_PATH/value" 2>/dev/null)
case $VALUE in
0) echo "GPIO$GPIO voltage level: Low (0)" ;;
1) echo "GPIO$GPIO voltage level: High (1)" ;;
*)
    echo "Error: Invalid value read '$VALUE'" >&2
    exit 1
    ;;
esac

exit 0
