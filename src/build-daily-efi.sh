#!/usr/bin/env bash
# Add a board-test entry to the accepted USB menu without rebuilding the root.
set -euo pipefail
export LC_ALL=C
[[ $# == 2 ]] || { echo "Usage: $0 debian-image-manifest.txt BOOTAA64.EFI" >&2; exit 2; }
src=$(cd "$(dirname "$0")" && pwd)
bundle=$(awk '$1 == "Bundle:" {print $2}' "$1")
[[ $bundle =~ ^[0-9a-f]{16}$ ]] || { echo 'Invalid Debian image manifest' >&2; exit 1; }
out=$(realpath -m "$2")
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
{
    cat "$src/diag-grub.cfg" "$src/debian-grub.cfg"
    cat <<'GRUB'
function desktop_boot {
    set diag_entry=Debian-daily
    # These DTs exist only on the writable FAT ESP. Its original boot
    # directory also exists on ISO9660.
    if search --no-floppy --file --set=root "$1"; then
        if devicetree "$1"; then
            debian_boot acpi=off efi=novamap clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=ttyMSM0,115200 console=tty0 loglevel=3 log_buf_len=16M diag.mode=dt diag.display=native np545.daily=1
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
} | sed "s/@BUNDLE@/$bundle/g" > "$stage/grub.cfg"
grub-script-check "$stage/grub.cfg"
modules='part_gpt fat iso9660 normal configfile linux fdt search search_fs_file echo sleep test boot smbios'
grub-mkstandalone -O arm64-efi --locales='' --fonts='' --themes='' --install-modules="$modules" --modules="$modules" \
    -o "$stage/BOOTAA64.EFI" "boot/grub/grub.cfg=$stage/grub.cfg"
grub-file --is-arm64-efi "$stage/BOOTAA64.EFI"
install -m 644 "$stage/BOOTAA64.EFI" "$out"
