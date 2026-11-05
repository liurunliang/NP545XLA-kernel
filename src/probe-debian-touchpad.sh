#!/bin/sh
# Inspect only the Windows SSTP0001 touchpad path. Run as root on Debian.
set -eu
fail() { echo "$*" >&2; exit 1; }
tr '\000' '\n' < /proc/device-tree/compatible | grep -Fxq samsung,np545xla ||
    fail 'Expected Samsung NP545XLA device tree'
bus=
for candidate in /sys/class/i2c-dev/i2c-*; do
    [ -e "$candidate/device/of_node" ] || continue
    case $(readlink -f "$candidate/device/of_node") in
        */soc@0/geniqup@8c0000/i2c@880000)
            [ -z "$bus" ] || fail 'Duplicate matching GENI adapters'
            bus=${candidate##*i2c-}
            ;;
    esac
done
[ -n "$bus" ] || fail 'GENI 880000.i2c has no adapter; check DT pinctrl and kernel probe logs'
client=/sys/bus/i2c/devices/$bus-0040
if [ -e "$client" ]; then
    driver=$(readlink -f "$client/driver" || :)
    [ -L "$client/driver" ] || fail "$client exists but has no driver; inspect kernel logs"
    echo "I2C client $bus-0040 bound to ${driver##*/}"
    path=$(readlink -f "$client")
    found=no
    for hid in /sys/bus/hid/devices/*; do
        case $(readlink -f "$hid") in
            "$path"/*)
                echo "HID report descriptor: ${hid##*/}"
                od -An -tx1 -v "$hid/report_descriptor"
                ;;
        esac
    done
    for event in /sys/class/input/event*; do
        case $(readlink -f "$event/device") in
            "$path"/*)
                found=yes
                node=/dev/input/${event##*/}
                echo "$node: $(cat "$event/device/name")"
                udevadm info -q property "$node" | grep '^ID_INPUT_' || :
                ;;
        esac
    done
    [ "$found" = yes ] || fail 'No evdev node registered for the touchpad'
    echo 'Use evtest on the printed touchpad event node to check motion and clicks.'
    exit 0
fi
command -v i2ctransfer >/dev/null || fail 'Install i2c-tools for a descriptor read on the unclaimed address'

# SSTP0001._DSM specifies 0x000e. No address sweep, reset, power command or
# feature SET_REPORT. i2ctransfer checks address ownership (no force flag).
descriptor=$(i2ctransfer -y "$bus" w2@0x40 0x0e 0x00 r30)
echo "HID descriptor on 880000.i2c bus $bus @0x40: $descriptor"
set -- $descriptor
[ "$#" = 30 ] && [ "$1 $2 $3 $4" = '0x1e 0x00 0x00 0x01' ] ||
    fail 'Unexpected HID descriptor length/version; stopping'
length=$(($5 + 256 * $6))
register_lo=$7
register_hi=$8
[ "$length" -gt 0 ] && [ "$length" -le 4096 ] && [ $((register_lo + 256 * register_hi)) -ne 0 ] ||
    fail 'Invalid report descriptor size or address; stopping'
echo "HID report descriptor ($length bytes):"
i2ctransfer -y "$bus" w2@0x40 "$register_lo" "$register_hi" "r$length"
