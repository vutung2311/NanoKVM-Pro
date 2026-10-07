#!/bin/bash

# Argument validation
if [ $# -ne 2 ]; then
    echo "Error: Incorrect number of arguments"
    echo "Usage: $0 <gpio_number> <0|1>"
    echo "Example: Set GPIO70 to high level → $0 70 1"
    exit 1
fi

GPIO=$1
VALUE=$2
SYSFS_GPIO="/sys/class/gpio/gpio$GPIO"

# Permission check
if [ $(id -u) -ne 0 ]; then
    echo "Error: Root permission required to execute this script" >&2
    exit 1
fi

# Value parameter check
if [ "$VALUE" != "0" ] && [ "$VALUE" != "1" ]; then
    echo "Error: Value must be 0 or 1" >&2
    exit 1
fi

# Export GPIO if not exported
if [ ! -d "$SYSFS_GPIO" ]; then
    echo "Warning: GPIO$GPIO is not exported, exporting now..."
    echo $GPIO >/sys/class/gpio/export 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "Error: Unable to export GPIO$GPIO" >&2
        exit 1
    fi
    # Set direction to output
    echo "out" >$SYSFS_GPIO/direction
fi

# Direction validation (must be output)
CURRENT_DIR=$(cat $SYSFS_GPIO/direction)
if [ "$CURRENT_DIR" != "out" ]; then
    echo "Warning: GPIO$GPIO direction is $CURRENT_DIR, forcing to output mode"
    echo "out" >$SYSFS_GPIO/direction
fi

# Set value
echo $VALUE >$SYSFS_GPIO/value 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Error: Unable to set GPIO$GPIO value" >&2
    exit 1
fi

echo "Successfully set GPIO$GPIO value to $VALUE"
