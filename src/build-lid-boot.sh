#!/usr/bin/env bash
# Append one Samsung lid-test entry to the exact accepted Adreno menu.
set -euo pipefail
export LC_ALL=C
if [[ $# != 5 || -e $5 || -L $5 ]]; then
    echo "Usage: $0 MANIFEST VERIFIED_ADRENO_DIR CURRENT_DAILY.dtb LID.dtb NEW_OUTPUT_DIR" >&2
    exit 2
fi
src=$(cd "$(dirname "$0")" && pwd)
bundle=$(awk '$1 == "Bundle:" {print $2}' "$1")
[[ $bundle =~ ^[0-9a-f]{16}$ ]]
base=$(realpath "$2")
daily=$(realpath "$3")
lid=$(realpath "$4")
out=$(realpath -m "$5")
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.lid-boot.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
[[ $(awk '{print $2}' "$base/SHA256SUMS") == $'BOOTAA64.EFI\nadreno.cpio.gz\nfirmware.sha256' ]]
(cd "$base" && sha256sum --strict -c SHA256SUMS)
grub-file --is-arm64-efi "$base/BOOTAA64.EFI"
# Re-derive the single approved DT change, including the other input devices and USB root checks.
bash "$src/build-debian-lid-dtb.sh" "$daily" "$stage/lid.dtb"
cmp "$lid" "$stage/lid.dtb"
sha() { sha256sum < "$1" | cut -d' ' -f1; }
overlay=$(sha "$base/adreno.cpio.gz")
printf '%s %s %s %s\n' "$bundle" "$(sha "$base/BOOTAA64.EFI")" "$(sha "$daily")" "$overlay" > "$stage/base.txt"
python3 "$src/read-grub-menu.py" "$base/BOOTAA64.EFI" > "$stage/base.cfg"
python3 - "$stage/base.cfg" "$bundle" "$overlay" "$(sha "$lid")" > "$stage/grub.cfg" <<'PY'
import re
import sys
from pathlib import Path

path, bundle, overlay, lid_hash = sys.argv[1:]
cfg = Path(path).read_text()
required = [f'desktop_boot /boot/daily-{bundle}.dtb unified',
            'if [ "$default" = daily ]; then set default=adreno-unified; fi',
            f'initrd /boot/debian-initramfs.cpio.gz /boot/adreno-{overlay}.cpio.gz; then']
if any(s not in cfg for s in required) or '--id lid-test' in cfg:
    sys.exit('Expected the accepted default Adreno menu for this bundle and overlay')
# Inherit the arguments used by this exact EFI for the Samsung DT boot path.
args = re.findall(r'^\s*\$handoff (acpi=off [\w.,=/ -]+)$', cfg, re.MULTILINE)
if len(args) != 1 or 'np545.daily=1' not in args[0].split():
    sys.exit('Unrecognized Samsung desktop handoff arguments')
sys.stdout.write(cfg)
print(f'''
menuentry 'Debian 13 - Lid test (Samsung)' --id lid-test {{
    set diag_entry=Debian-lid
    if search --no-floppy --file --set=root /boot/lid-{lid_hash}.dtb; then
        if devicetree /boot/lid-{lid_hash}.dtb; then
            adreno_boot {args[0]} np545.lid=1
        fi
    fi
    diag_stop 'Lid test DT unavailable. Restart and use the default desktop.'
}}''')
PY
bash "$src/build-daily-efi.sh" --config "$stage/grub.cfg" "$stage/BOOTAA64.EFI"
rm "$stage/grub.cfg" "$stage/base.cfg"
(cd "$stage" && sha256sum BOOTAA64.EFI lid.dtb base.txt > SHA256SUMS)
mv -nT "$stage" "$out"
[[ ! -e $stage ]]
cat "$out/SHA256SUMS"
