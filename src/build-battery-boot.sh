#!/usr/bin/env bash
# Extend the installed camera menu using the proven lid-edge kernel and DT as the battery base.
set -euo pipefail
export LC_ALL=C
if [[ $# != 4 || -e $4 || -L $4 ]]; then
    echo "Usage: $0 MANIFEST CAMERA_BOOT_DIR LID_EDGE_BOOT_DIR NEW_OUTPUT_DIR" >&2; exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
camera=$(realpath "$2")
edge=$(realpath "$3")
out=$(realpath -m "$4")
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.battery.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
for dir in "$camera" "$edge"; do (cd "$dir"; sha256sum --strict -c SHA256SUMS); done
sha() { sha256sum < "$1" | cut -d' ' -f1; }
read -r bundle edge_efi daily overlay < "$camera/base.txt"
[[ $bundle == "$(awk '$1=="Bundle:" {print $2}' "$1")" && $edge_efi == "$(sha "$edge/BOOTAA64.EFI")" ]]
dt=$stage/battery.dtb
cp "$edge/lid.dtb" "$dt"
bus=/soc@0/geniqup@cc0000/i2c@c88000
pins=/soc@0/pinctrl@3100000/battery-i2c-state
gauge=$bus/battery@b
[[ $(fdtget "$dt" / compatible) == 'samsung,np545xla qcom,sc8180x' &&
   $(fdtget "$dt" /soc@0/ufshc@1d84000 status) == disabled &&
   $(fdtget "$dt" "$bus" compatible) == qcom,geni-i2c &&
   $(fdtget "$dt" "$bus" status) == disabled && -z $(fdtget -l "$dt" "$bus") &&
   $(fdtget "$dt" "${bus/i2c@/spi@}" status) == disabled &&
   $(fdtget "$dt" "${bus/i2c@/serial@}" status) == disabled ]]
# ACPI IC20 D0 selects TLMM GPIO181/182, function 1 (qup19); EMEC lists 0x0b at 100 kHz.
handle=$(dtc -q -I dtb -O dts "$dt" | python3 -c 'import re,sys; print(max(int(x,16) for x in re.findall(r"\bphandle = <0x([0-9a-f]+)>", sys.stdin.read()))+1)')
fdtput -c "$dt" "$pins"
fdtput -t u "$dt" "$pins" phandle "$handle"
fdtput -t s "$dt" "$pins" pins gpio181 gpio182
fdtput -t s "$dt" "$pins" function qup19
fdtput -t s "$dt" "$bus" status okay
fdtput -t u "$dt" "$bus" clock-frequency 100000
fdtput -t s "$dt" "$bus" pinctrl-names default
fdtput -t u "$dt" "$bus" pinctrl-0 "$handle"
fdtput -c "$dt" "$gauge"
fdtput -t s "$dt" "$gauge" compatible samsung,np545xla-battery-ro
fdtput -t u "$dt" "$gauge" reg 11
cp "$dt" "$stage/check.dtb"
fdtput -r "$stage/check.dtb" "$gauge" "$pins"
fdtput -d "$stage/check.dtb" "$bus" pinctrl-0 pinctrl-names clock-frequency
fdtput -t s "$stage/check.dtb" "$bus" status disabled
cmp <(dtc -q -s -I dtb -O dts "$edge/lid.dtb") <(dtc -q -s -I dtb -O dts "$stage/check.dtb")
rm "$stage/check.dtb"
python3 "$here/read-grub-menu.py" "$camera/BOOTAA64.EFI" > "$stage/menu"
python3 - "$stage/menu" "$(sha "$dt")" "$(sha "$edge/lid.dtb")" <<'PY'
from pathlib import Path
import re
import sys

path, new_hash, lid_hash = sys.argv[1:]
menu = Path(path)
text = menu.read_text()
entry = re.search(r"\nmenuentry 'Debian 13 - Lid edge kernel \(Samsung\)' --id lid-edge \{.*?\n\}", text, re.S)
if not entry or '--id camera-720p' not in text or '--id battery-ro' in text:
    sys.exit('Expected the current Samsung camera menu')
original = entry[0]
for word in ('lid_edge_prepare', f'devicetree /boot/lid-{lid_hash}.dtb', 'np545.lid_edge=1'):
    if original.count(word) != 1:
        sys.exit('Unrecognized lid-edge boot')
trial = original.replace('Lid edge kernel (Samsung)\' --id lid-edge', "Battery read-only test (Samsung)' --id battery-ro")
trial = trial.replace('set diag_entry=Debian-lid-edge', 'set diag_entry=Debian-battery')
trial = trial.replace(f'lid-{lid_hash}.dtb', f'battery-{new_hash}.dtb').replace(
    'np545.lid_edge=1', 'np545.lid_edge=1 np545.battery=1 systemd.wants=np545-battery-sample.service')
trial = trial.replace('Verified Samsung lid DT unavailable', 'Battery trial DT unavailable')
with menu.open('a') as out:
    out.write(trial + '\n')
    out.write(f"""
if search --no-floppy --file --set=battery_esp /boot/battery-{new_hash}.dtb; then
    set battery_env="(${{battery_esp}})/boot/np545-battery.env"
    if [ -f "$battery_env" ]; then
        load_env --file "$battery_env" np545_battery_once
        if [ "$np545_battery_once" = 1 ]; then
            set np545_battery_once=0
            if save_env --file "$battery_env" np545_battery_once; then set default=battery-ro; fi
        fi
    fi
fi
""")
PY
bash "$here/build-daily-efi.sh" --config-ext4-once "$stage/menu" "$stage/BOOTAA64.EFI"
python3 "$here/read-grub-menu.py" "$stage/BOOTAA64.EFI" | cmp - "$stage/menu"
rm "$stage/menu"
printf '%s %s %s %s\n' "$bundle" "$(sha "$camera/BOOTAA64.EFI")" "$daily" "$overlay" > "$stage/base.txt"
(cd "$stage"; sha256sum BOOTAA64.EFI battery.dtb base.txt > SHA256SUMS)
mv -nT "$stage" "$out"; [[ ! -e $stage ]]
