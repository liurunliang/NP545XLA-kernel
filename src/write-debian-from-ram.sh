#!/bin/sh
# Run under the diagnostic BusyBox ash, with a compressed image staged in /run.
set -eu
set -o pipefail
die() { echo "$*" >&2; exit 1; }
[ "$#" -eq 8 ] || die "Usage: $0 /dev/sdX SERIAL DISK_BYTES OLD_IMG_BYTES OLD_SHA256 /run/IMAGE.gz NEW_IMG_BYTES NEW_SHA256"
disk=$1 serial=$2 disk_bytes=$3 old_bytes=$4 old_hash=$5 image=$6 new_bytes=$7 new_hash=$8
for size in "$old_bytes" "$disk_bytes" "$new_bytes"; do
    case "$size" in ''|*[!0-9]*) die "Invalid byte count";; esac
    [ "$size" -gt 0 ] && [ $((size % 512)) -eq 0 ] || die "Expected whole sectors"
done
[ "$new_bytes" -le "$disk_bytes" ] && [ "$old_bytes" -le "$disk_bytes" ] || die "Image exceeds disk"
case "$(readlink -f "$image")" in /run/*) ;; *) die "Stage compressed image in RAM";; esac
grep -q '^rootfs / rootfs ' /proc/mounts && grep -q '^tmpfs /run tmpfs ' /proc/mounts ||
    die "Start the RAM diagnostic system first"
grep -q '^NP545XLA DIAG ' /run/diagnostics/status || die "Missing diagnostic identity"

check_disk() {
    name=${disk#/dev/}
    case "$name" in sd[a-z]|sd[a-z][a-z]) ;; *) die "Expected a whole SCSI disk";; esac
    block=/sys/class/block/$name
    [ "$disk" = "/dev/$name" ] && [ -b "$disk" ] && [ ! -e "$block/partition" ] &&
        [ "$(cat "$block/removable")" = 1 ] && [ "$(cat "$block/ro")" = 0 ] &&
        [ $(( $(cat "$block/size") * 512 )) -eq "$disk_bytes" ] || die "Wrong disk geometry or flags"
    parent=$(readlink -f "$block/device")
    while [ -n "$parent" ] && [ ! -r "$parent/idVendor" ]; do parent=${parent%/*}; done
    [ -r "$parent/idVendor" ] && [ "$(readlink -f "$parent/subsystem")" = /sys/bus/usb ] &&
        [ "$(cat "$parent/serial")" = "$serial" ] && [ -n "$serial" ] || die "USB serial mismatch"
    echo "Matched $disk $(cat "$parent/idVendor"):$(cat "$parent/idProduct") $parent ($disk_bytes bytes)"
    awk '$1 ~ /^\/dev\// {bad=1} END{exit bad}' /proc/mounts || die "Block devices mounted"
    [ "$(wc -l < /proc/swaps)" -eq 1 ] || die "Swap active"
    for holder in "$block"/holders/* "$block"/"$name"*/holders/*; do
        [ ! -e "$holder" ] || die "Block device is in use"
    done
}

hash_disk() {
    dd if="$disk" bs=1M iflag=direct,count_bytes count="$1" status=none | sha256sum | cut -d ' ' -f1
}
header_hex() { od -An -tx1 -j "$2" -N "$3" "$1" | tr -d ' \n'; }

check_disk
echo "Checking staged image before writing"
[ "$(gzip -dc "$image" | sha256sum | cut -d ' ' -f1)" = "$new_hash" ] || die "Source hash mismatch"
[ "$(hash_disk "$old_bytes")" = "$old_hash" ] || die "Existing image mismatch"
tmp=$(mktemp -d /run/usb-gpt.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
last=$((disk_bytes / 512 - 1))
dd if="$disk" of="$tmp/primary" bs=512 skip=1 count=1 status=none
dd if="$disk" of="$tmp/last" bs=512 skip="$last" count=1 status=none
[ "$(header_hex "$tmp/primary" 0 8)" = 4546492050415254 ] || die "Missing old GPT"
stale=no
if [ "$new_bytes" -lt "$disk_bytes" ] && [ "$(header_hex "$tmp/last" 0 8)" = 4546492050415254 ]; then
    [ "$(header_hex "$tmp/primary" 56 16)" = "$(header_hex "$tmp/last" 56 16)" ] ||
        die "Unexpected GPT at the physical end of the disk"
    stale=yes
fi
check_disk
echo "Writing $new_bytes bytes"
gzip -dc "$image" | dd of="$disk" bs=1M iflag=fullblock,count_bytes count="$new_bytes" conv=notrunc,fsync
if [ "$stale" = yes ]; then
    dd if=/dev/zero of="$disk" bs=512 count=1 seek="$last" conv=notrunc,fsync
fi
blockdev --flushbufs "$disk"
echo "Reading back all $new_bytes bytes"
actual=$(hash_disk "$new_bytes")
[ "$actual" = "$new_hash" ] || die "Readback mismatch: $actual"
echo "Verified $disk: $new_bytes bytes, SHA256 $actual"
