#!/usr/bin/env bash
# Append one opt-in entry to the installed battery diagnostic menu.
set -euo pipefail
export LC_ALL=C
mode=keepcharge
case ${1:-} in
    --hotplug|--ic10irq) mode=${1#--}; shift ;;
esac
if [[ $# != 2 || -e $2 || -L $2 ]]; then
    echo "Usage: $0 [--hotplug|--ic10irq] INSTALLED_BOOT_DIR NEW_OUTPUT_DIR" >&2; exit 2
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
python3 - "$stage/menu" "$(sha "$stage/battery.dtb")" "$mode" <<'PY'
from pathlib import Path
import re
import sys

menu = Path(sys.argv[1])
text = menu.read_text()
mode = sys.argv[3]
base_name = "Battery read-only test (Samsung)' --id battery-ro"
base_diag = "battery"
if mode == "ic10irq":
    base_name = "USB-C hotplug 12 V test (Samsung)' --id hotplug"
    base_diag = "hotplug"
    title, service = "IC10 GPIO IRQ trace", "np545-ic10-irq"
elif mode == "hotplug":
    title, service = "USB-C hotplug 12 V test", "np545-pd-hotplug"
    if text.count("--id keepcharge ") != 1:
        sys.exit("Expected the installed BQ25710 keepalive menu")
else:
    title, service = "BQ25710 charge keepalive test", "np545-charge-keepalive"
entries = re.findall(r"\nmenuentry 'Debian 13 - " + re.escape(base_name) + r" \{.*?\n\}", text, re.S)
if (len(entries) != 1 or f'np545.{mode}=1' in text or f'--id {mode} ' in text
        or f'devicetree /boot/battery-{sys.argv[2]}.dtb' not in entries[0]
        or entries[0].count('systemd.wants=np545-charge-observe.service') != 1):
    sys.exit('Unexpected base entry')
if mode == "ic10irq" and entries[0].count("np545.hotplug=1 systemd.wants=np545-pd-hotplug.service") != 1:
    sys.exit("Expected the existing hotplug service")
trial = entries[0].replace(base_name, f"{title} (Samsung)' --id {mode}")
trial = trial.replace(f'set diag_entry=Debian-{base_diag}', f'set diag_entry=Debian-{mode}')
trial = trial.replace('np545.battery=1', f'np545.battery=1 np545.{mode}=1 systemd.wants={service}.service')
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
""".replace("keepcharge", mode))
PY
bash "$here/build-daily-efi.sh" --config-ext4-once "$stage/menu" "$stage/BOOTAA64.EFI"
python3 "$here/read-grub-menu.py" "$stage/BOOTAA64.EFI" | cmp - "$stage/menu"
rm "$stage/menu"
printf '%s %s %s %s\n' "$bundle" "$(sha "$base/BOOTAA64.EFI")" "$daily" "$overlay" > "$stage/base.txt"
(cd "$stage"; sha256sum BOOTAA64.EFI battery.dtb base.txt > SHA256SUMS)
mv -nT "$stage" "$out"; [[ ! -e $stage ]]
