#!/usr/bin/env bash
# Add a board-test entry to the accepted USB menu without rebuilding the root.
set -euo pipefail
export LC_ALL=C
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

pack_menu() {
    local config=$1 output=$2
    local modules='part_gpt fat iso9660 normal configfile linux fdt search search_fs_file echo sleep test boot smbios'
    if [[ ${3:-} == ext4 ]]; then modules+=" ext2 regexp probe hashsum gcry_sha256"; fi
    grub-script-check "$config"
    grub-mkstandalone -O arm64-efi --locales='' --fonts='' --themes='' --install-modules="$modules" --modules="$modules" \
        -o "$stage/BOOTAA64.EFI" "boot/grub/grub.cfg=$config"
    grub-file --is-arm64-efi "$stage/BOOTAA64.EFI"
    install -m 644 "$stage/BOOTAA64.EFI" "$output"
}

if [[ $# == 3 && ( $1 == --config || $1 == --config-ext4 ) ]]; then
    pack_menu "$2" "$3" "${1#--config-}"
    exit
fi
overlay=
overlay_mode=${1:-}
if [[ $# == 4 && ( $overlay_mode == --adreno-overlay || $overlay_mode == --default-adreno-overlay ) ]]; then
    overlay=$(sha256sum "$2" | cut -d' ' -f1)
    shift 2
fi
[[ $# == 2 ]] || { echo "Usage: $0 [--adreno-overlay FILE | --default-adreno-overlay FILE] debian-image-manifest.txt BOOTAA64.EFI" >&2; exit 2; }
src=$(cd "$(dirname "$0")" && pwd)
bundle=$(awk '$1 == "Bundle:" {print $2}' "$1")
[[ $bundle =~ ^[0-9a-f]{16}$ ]] || { echo 'Invalid Debian image manifest' >&2; exit 1; }
out=$(realpath -m "$2")
{
    cat "$src/diag-grub.cfg" "$src/debian-grub.cfg"
    cat <<'GRUB'
function desktop_boot {
    set diag_entry=Debian-daily
    set handoff=debian_boot
    if [ "$2" = unified ]; then
        set diag_entry=Debian-unified
        set handoff=adreno_boot
    fi
    # These DTs exist only on the writable FAT ESP. Its original boot
    # directory also exists on ISO9660.
    if search --no-floppy --file --set=root "$1"; then
        if devicetree "$1"; then
            $handoff acpi=off efi=novamap clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=ttyMSM0,115200 console=tty0 loglevel=3 log_buf_len=16M diag.mode=dt diag.display=native np545.daily=1
        fi
    fi
    diag_stop 'Daily DT unavailable. Restart and select the original Debian entry.'
}
menuentry 'Debian 13 - daily desktop (Samsung)' --id daily {
    desktop_boot /boot/daily-@BUNDLE@.dtb
}
if search --no-floppy --file --set=daily_previous /boot/previous-@BUNDLE@.dtb; then
    menuentry 'Debian 13 - previous daily device tree' --id daily-previous {
        desktop_boot /boot/previous-@BUNDLE@.dtb
    }
fi
if [ "$default" = debian ]; then set default=daily; fi
GRUB
    if [[ -n $overlay ]]; then
        sed "s/@OVERLAY_SHA256@/$overlay/g" "$src/adreno-grub.cfg"
        if [[ $overlay_mode == --default-adreno-overlay ]]; then
            echo 'if [ "$default" = daily ]; then set default=adreno-unified; fi'
        fi
    fi
} | sed "s/@BUNDLE@/$bundle/g" > "$stage/grub.cfg"
pack_menu "$stage/grub.cfg" "$out"
