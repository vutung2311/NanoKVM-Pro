#!/bin/bash

# Check for valid arguments
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <gpio_number> [in|out]"
    echo "Example:"
    echo "  Export GPIO69 as output: $0 69 out"
    echo "  Unexport GPIO69: $0 69"
    exit 1
fi

GPIO=$1
DIRECTION=$2
SYSFS_GPIO="/sys/class/gpio/gpio$GPIO"

# Permission check
if [ $(id -u) -ne 0 ]; then
    echo "Error: Root privileges required to run this script" >&2
    exit 1
fi

# Unexport logic
if [ $# -eq 1 ]; then
    if [ ! -d "$SYSFS_GPIO" ]; then
        echo "Error: GPIO$GPIO is not exported" >&2
        exit 1
    fi

    echo $GPIO >/sys/class/gpio/unexport 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "Error: Unable to unexport GPIO$GPIO" >&2
        exit 1
    fi
    echo "Successfully unexported GPIO$GPIO"
    exit 0
fi

# Export logic
if [ "$DIRECTION" != "in" ] && [ "$DIRECTION" != "out" ]; then
    echo "Error: Direction parameter must be 'in' or 'out'" >&2
    exit 1
fi

# Check if already exported
if [ -d "$SYSFS_GPIO" ]; then
    echo "Warning: GPIO$GPIO is already exported, unexporting first" >&2
    echo $GPIO >/sys/class/gpio/unexport
fi

# Perform export
echo $GPIO >/sys/class/gpio/export
if [ $? -ne 0 ]; then
    echo "Error: Unable to export GPIO$GPIO" >&2
    exit 1
fi

# Set direction
echo $DIRECTION >$SYSFS_GPIO/direction
if [ $? -ne 0 ]; then
    echo "Error: Unable to set GPIO$GPIO direction" >&2
    exit 1
fi

echo "Successfully exported GPIO$GPIO as $DIRECTION"
