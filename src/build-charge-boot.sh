#!/usr/bin/env bash
# Update only the DT used by the existing battery-ro menu entry.
set -euo pipefail
export LC_ALL=C
if [[ $# != 2 || -e $2 || -L $2 ]]; then
    echo "Usage: $0 INSTALLED_BATTERY_BOOT_DIR NEW_OUTPUT_DIR" >&2; exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
base=$(realpath "$1")
out=$(realpath -m "$2")
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.charge.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
(cd "$base"; sha256sum --strict -c SHA256SUMS)
sha() { sha256sum < "$1" | cut -d' ' -f1; }
read -r bundle _ daily overlay < "$base/base.txt"
dt=$stage/battery.dtb
cp "$base/battery.dtb" "$dt"
tlmm=/soc@0/pinctrl@3100000
handle=$(dtc -q -I dtb -O dts "$dt" | python3 -c 'import re,sys; print(max(int(x,16) for x in re.findall(r"\bphandle = <0x([0-9a-f]+)>",sys.stdin.read()))+1)')
# From the Samsung PEP IC10 and IC19 D0 resources. No PD or charger driver binds.
enable_bus() {
    local bus=$1 name=$2 mux=$3 sda=$4 scl=$5
    local pins=$tlmm/$name
    [[ $(fdtget "$dt" "$bus" status) == disabled && -z $(fdtget -l "$dt" "$bus") &&
       $(fdtget "$dt" "${bus/i2c@/spi@}" status) == disabled &&
       $(fdtget "$dt" "${bus/i2c@/serial@}" status) == disabled ]]
    fdtput -c "$dt" "$pins"
    fdtput -t u "$dt" "$pins" phandle "$handle"
    fdtput -t s "$dt" "$pins" function "$mux"
    fdtput -t s "$dt" "$pins" pins "$sda" "$scl"
    fdtput -t s "$dt" "$bus" status okay
    fdtput -t u "$dt" "$bus" clock-frequency 400000
    fdtput -t s "$dt" "$bus" pinctrl-names default
    fdtput -t u "$dt" "$bus" pinctrl-0 "$handle"
    handle=$((handle + 1))
}
ic10=/soc@0/geniqup@ac0000/i2c@a84000
ic19=/soc@0/geniqup@cc0000/i2c@c84000
enable_bus "$ic10" pd-ic10-state qup9 gpio39 gpio40
enable_bus "$ic19" pd-ic19-state qup18 gpio23 gpio24
cp "$dt" "$stage/check.dtb"
for bus in "$ic10" "$ic19"; do
    fdtput -d "$stage/check.dtb" "$bus" pinctrl-0 pinctrl-names clock-frequency
    fdtput -t s "$stage/check.dtb" "$bus" status disabled
done
fdtput -r "$stage/check.dtb" "$tlmm/pd-ic10-state" "$tlmm/pd-ic19-state"
cmp <(dtc -q -s -I dtb -O dts "$stage/check.dtb") <(dtc -q -s -I dtb -O dts "$base/battery.dtb")
rm "$stage/check.dtb"
python3 "$here/read-grub-menu.py" "$base/BOOTAA64.EFI" > "$stage/menu"
python3 - "$stage/menu" "$(sha "$base/battery.dtb")" "$(sha "$dt")" <<'PY'
from pathlib import Path
import sys
path, old, new = sys.argv[1:]
p = Path(path)
text = p.read_text()
dt = f"/boot/battery-{old}.dtb"
arg = "np545.battery=1 systemd.wants=np545-battery-sample.service"
if text.count(dt) != 2 or text.count(arg) != 1 or text.count("--id battery-ro") != 1:
    sys.exit("Unexpected installed battery menu")
p.write_text(text.replace(dt, f"/boot/battery-{new}.dtb").replace(arg, arg+" systemd.wants=np545-charge-observe.service"))
PY
bash "$here/build-daily-efi.sh" --config-ext4-once "$stage/menu" "$stage/BOOTAA64.EFI"
python3 "$here/read-grub-menu.py" "$stage/BOOTAA64.EFI" | cmp - "$stage/menu"
rm "$stage/menu"
printf '%s %s %s %s\n' "$bundle" "$(sha "$base/BOOTAA64.EFI")" "$daily" "$overlay" > "$stage/base.txt"
(cd "$stage"; sha256sum BOOTAA64.EFI battery.dtb base.txt > SHA256SUMS)
mv -nT "$stage" "$out"; [[ ! -e $stage ]]
