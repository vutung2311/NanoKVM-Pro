#!/bin/bash

exec >/dev/null 2>&1

GPIO_RESET=35  # RST
GPIO_POWER=7   # PWR
GPIO_PWRLED=75 # PWRLED
GPIO_HDDLED=74 # HDLED

GPIO_OUT_DEF_VALUE=0

GPIO_LIST=()
GPIO_LIST+=("$GPIO_RESET")
GPIO_LIST+=("$GPIO_POWER")
GPIO_LIST+=("$GPIO_PWRLED")
GPIO_LIST+=("$GPIO_HDDLED")

GPIO_EXPORT=/sys/class/gpio/export
GPIO_UNEXPORT=/sys/class/gpio/unexport
GPIO_BASE=/sys/class/gpio/gpio

case "$1" in
start)
    devmem 0x02302024 32 0x00000003
    # export GPIO_RESET
    gpionum=${GPIO_RESET}
    if [ -n "$gpionum" ]; then
        if [ ! -d "${GPIO_BASE}${gpionum}" ]; then
            echo "export GPIO<${gpionum}>"
            echo ${gpionum} >${GPIO_EXPORT}
        fi
        gpio_root="/sys/class/gpio/gpio${gpionum}"
        echo out >"${gpio_root}/direction"
        echo "$GPIO_OUT_DEF_VALUE" >"${gpio_root}/value"

        ### change mode to 777
        chmod +x "${gpio_root}/value"
    fi

    # export GPIO_POWER
    gpionum=${GPIO_POWER}
    if [ -n "$gpionum" ]; then
        if [ ! -d "${GPIO_BASE}${gpionum}" ]; then
            echo "export GPIO<${gpionum}>"
            echo ${gpionum} >${GPIO_EXPORT}
        fi
        gpio_root="/sys/class/gpio/gpio${gpionum}"
        echo out >"${gpio_root}/direction"
        echo "$GPIO_OUT_DEF_VALUE" >"${gpio_root}/value"

        ### change mode to 777
        chmod +x "${gpio_root}/value"
    fi

    # export GPIO_PWRLED
    gpionum=${GPIO_PWRLED}
    if [ -n "$gpionum" ]; then
        if [ ! -d "${GPIO_BASE}${gpionum}" ]; then
            echo "export GPIO<${gpionum}>"
            echo ${gpionum} >${GPIO_EXPORT}
        fi
        gpio_root="/sys/class/gpio/gpio${gpionum}"
        echo in >"${gpio_root}/direction"
        chmod +x "${gpio_root}/value"
    fi

    # export GPIO_HDDLED
    gpionum=${GPIO_HDDLED}
    if [ -n "$gpionum" ]; then
        if [ ! -d "${GPIO_BASE}${gpionum}" ]; then
            echo "export GPIO<${gpionum}>"
            echo ${gpionum} >${GPIO_EXPORT}
        fi
        gpio_root="/sys/class/gpio/gpio${gpionum}"
        echo in >"${gpio_root}/direction"
        chmod +x "${gpio_root}/value"
    fi

    ;;
stop)
    #unexport
    for gpio in "${GPIO_LIST[@]}"; do
        if [ -n "$gpio" ] && [ -d "${GPIO_BASE}${gpio}" ]; then
            echo "unexport GPIO<${gpio}>"
            echo ${gpio} >${GPIO_UNEXPORT}
        fi
    done
    ;;
esac
