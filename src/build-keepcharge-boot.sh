#!/usr/bin/env bash
# Append one opt-in entry to the installed battery diagnostic menu.
set -euo pipefail
export LC_ALL=C
if [[ $# != 2 || -e $2 || -L $2 ]]; then
    echo "Usage: $0 CHARGE_DIAG_BOOT_DIR NEW_OUTPUT_DIR" >&2; exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
base=$(realpath "$1")
out=$(realpath -m "$2")
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.keepcharge.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
(cd "$base"; sha256sum --strict -c SHA256SUMS)
sha() { sha256sum < "$1" | cut -d' ' -f1; }
read -r bundle _ daily overlay < "$base/base.txt"
cp "$base/battery.dtb" "$stage/"
python3 "$here/read-grub-menu.py" "$base/BOOTAA64.EFI" > "$stage/menu"
python3 - "$stage/menu" "$(sha "$stage/battery.dtb")" <<'PY'
from pathlib import Path
import re
import sys

menu = Path(sys.argv[1])
text = menu.read_text()
entries = re.findall(r"\nmenuentry 'Debian 13 - Battery read-only test \(Samsung\)' --id battery-ro \{.*?\n\}", text, re.S)
if (len(entries) != 1 or 'np545.keepcharge' in text or '--id keepcharge' in text
        or f'devicetree /boot/battery-{sys.argv[2]}.dtb' not in entries[0]
        or entries[0].count('systemd.wants=np545-charge-observe.service') != 1):
    sys.exit('Expected the installed read-only charge diagnostic entry')
trial = entries[0].replace("Battery read-only test (Samsung)' --id battery-ro",
                           "BQ25710 charge keepalive test (Samsung)' --id keepcharge")
trial = trial.replace('set diag_entry=Debian-battery','set diag_entry=Debian-keepcharge')
trial = trial.replace('np545.battery=1', 'np545.battery=1 np545.keepcharge=1 systemd.wants=np545-charge-keepalive.service')
with menu.open('a') as out:
    out.write(trial + '\n')
    out.write("""
if search --no-floppy --file --set=keepcharge_esp /boot/np545-keepcharge.env; then
    set keepcharge_env="(${keepcharge_esp})/boot/np545-keepcharge.env"
    load_env --file "$keepcharge_env" np545_keepcharge_once
    if [ "$np545_keepcharge_once" = 1 ]; then
        set np545_keepcharge_once=0
        if save_env --file "$keepcharge_env" np545_keepcharge_once; then set default=keepcharge; fi
    fi
fi
""")
PY
bash "$here/build-daily-efi.sh" --config-ext4-once "$stage/menu" "$stage/BOOTAA64.EFI"
python3 "$here/read-grub-menu.py" "$stage/BOOTAA64.EFI" | cmp - "$stage/menu"
rm "$stage/menu"
printf '%s %s %s %s\n' "$bundle" "$(sha "$base/BOOTAA64.EFI")" "$daily" "$overlay" > "$stage/base.txt"
(cd "$stage"; sha256sum BOOTAA64.EFI battery.dtb base.txt > SHA256SUMS)
mv -nT "$stage" "$out"; [[ ! -e $stage ]]
