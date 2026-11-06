#!/usr/bin/env bash
# Append to the specifically installed Latest desktop menu.
set -euo pipefail
export LC_ALL=C
[[ $# == 2 && ! -e $2 ]] || { echo "Usage: $0 LATEST_BOOT_DIR NEW_OUTPUT_DIR" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
base=$(realpath "$1"); out=$(realpath -m "$2")
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.bluetooth.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
(cd "$base"; sha256sum --strict -c SHA256SUMS)
sha() { sha256sum < "$1" | cut -d' ' -f1; }
read -r bundle _ daily adreno < "$base/base.txt"
cp "$base/battery.dtb" "$stage/base.dtb"
# The deployed tree retains few symbols; resolve these two by verified paths.
for pair in 'tlmm /soc@0/pinctrl@3100000' 'io_1p8 /pm8150-s4-regulator'; do
    read -r symbol path <<< "$pair"
    if ! fdtget "$stage/base.dtb" "$path" phandle >/dev/null 2>&1; then
        fdtget -p "$stage/base.dtb" "$path" >/dev/null
        # Reserve an unused handle before fdtoverlay assigns the local ones.
        handle=$(dtc -q -I dtb -O dts "$stage/base.dtb" |
            python3 -c 'import re,sys; print(1 + max(int(x,16) for x in re.findall(r"\bphandle = <0x([0-9a-fA-F]+)>",sys.stdin.read())))')
        fdtput -t u "$stage/base.dtb" "$path" phandle "$handle"
    fi
    fdtput -t s "$stage/base.dtb" /__symbols__ "$symbol" "$path"
done
dtc -@ -I dts -O dtb -o "$stage/bt.dtbo" "$here/../dts/sc8180xp-np545xla-bluetooth.dtso"
fdtoverlay -i "$stage/base.dtb" -o "$stage/bluetooth.dtb" "$stage/bt.dtbo"
uart=/soc@0/geniqup@cc0000/serial@c8c000
[[ $(fdtget "$stage/bluetooth.dtb" "$uart/bluetooth" compatible) == qcom,qca6390-bt ]]
[[ $(fdtget "$stage/bluetooth.dtb" "$uart" status) == okay ]]
python3 "$here/read-grub-menu.py" "$base/BOOTAA64.EFI" > "$stage/menu"
python3 - "$stage/menu" "$(sha "$base/battery.dtb")" "$(sha "$stage/bluetooth.dtb")" <<'PY'
import re, sys
from pathlib import Path
menu = Path(sys.argv[1])
text = menu.read_text()
title = "menuentry 'Debian 13 - Latest (Samsung)' --id gpiocharge"
entries = re.findall("^" + re.escape(title) + r" \{.*?^\}", text, re.M | re.S)
if (len(entries) != 1 or "--id bluetooth " in text or
        f"/boot/battery-{sys.argv[2]}.dtb" not in entries[0] or
        'then set default=gpiocharge; fi' not in text):
    sys.exit("Unexpected installed GRUB menu")
trial = entries[0].replace(title, "menuentry 'Debian 13 - QCA6390 Bluetooth test (Samsung)' --id bluetooth")
trial = trial.replace("set diag_entry=Debian-gpiocharge", "set diag_entry=Debian-bluetooth")
trial = trial.replace(f"/boot/battery-{sys.argv[2]}.dtb", f"/boot/bluetooth-{sys.argv[3]}.dtb")
trial = trial.replace(" np545.daily=1 ", " np545.daily=1 np545.bluetooth=1 systemd.wants=np545-bluetooth.service ")
trial = trial.replace("Battery trial DT unavailable", "Bluetooth trial DT unavailable")
with menu.open("a") as output:
    output.write("\n" + trial + "\n")
    output.write("""
if search --no-floppy --file --set=bt_esp /boot/np545-bluetooth.env; then
    set bt_env="(${bt_esp})/boot/np545-bluetooth.env"
    load_env --file "$bt_env" np545_bluetooth_once
    if [ "$np545_bluetooth_once" = 1 ]; then
        set np545_bluetooth_once=0
        if save_env --file "$bt_env" np545_bluetooth_once; then set default=bluetooth; fi
    fi
fi
""")
PY
bash "$here/build-daily-efi.sh" --config-ext4-once "$stage/menu" "$stage/BOOTAA64.EFI"
python3 "$here/read-grub-menu.py" "$stage/BOOTAA64.EFI" | cmp - "$stage/menu"
rm "$stage/menu" "$stage/base.dtb" "$stage/bt.dtbo"
printf '%s %s %s %s\n' "$bundle" "$(sha "$base/BOOTAA64.EFI")" "$daily" "$adreno" > "$stage/base.txt"
(cd "$stage"; sha256sum BOOTAA64.EFI bluetooth.dtb base.txt > SHA256SUMS)
mv -nT "$stage" "$out"; [[ ! -e $stage ]]
