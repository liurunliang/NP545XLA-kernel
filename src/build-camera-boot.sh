#!/usr/bin/env bash
# Append an opt-in camera entry to the accepted Samsung lid-edge desktop menu.
set -euo pipefail
export LC_ALL=C
if [[ $# != 3 || ! -f $1 || -e $3 || -L $3 ]]; then
    echo "Usage: $0 DEBIAN_MANIFEST VERIFIED_LID_EDGE_DIR NEW_OUTPUT_DIR" >&2; exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
base=$(realpath "$2")
out=$(realpath -m "$3")
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.camera.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
(cd "$base" && sha256sum --strict -c SHA256SUMS)
sha() { sha256sum < "$1" | cut -d' ' -f1; }
parent=$(sha "$base/BOOTAA64.EFI")
read -r bundle _ daily overlay < "$base/base.txt"
[[ $bundle == "$(awk '$1=="Bundle:" {print $2}' "$1")" &&
   $parent == e5d1ce10259cb74788d63479a75b34f4144576207bd672ed94e1866a3c0a6830 ]]
dt=$stage/camera.dtb
tlmm=/soc@0/pinctrl@3100000
hog=$tlmm/camera-enable-hog
cp "$base/lid.dtb" "$dt"
[[ $(fdtget "$dt" / compatible) == 'samsung,np545xla qcom,sc8180x' &&
   $(fdtget "$dt" /soc@0/ufshc@1d84000 status) == disabled &&
   $(fdtget -d okay "$dt" /soc@0/usb@a4f8800 status) == okay &&
   $(fdtget -t u "$dt" "$tlmm" '#gpio-cells') == 2 ]]
# RHUB._PS0 sets the CAME output high. The hog requests it only for this boot.
fdtput -c "$dt" "$hog"
fdtput "$dt" "$hog" gpio-hog
fdtput -t u "$dt" "$hog" gpios 166 0
fdtput "$dt" "$hog" output-high
fdtput -t s "$dt" "$hog" line-name np545-camera-enable
# Prove that removing this single node recovers the entire source tree.
cp "$dt" "$stage/check.dtb"
fdtput -r "$stage/check.dtb" "$hog"
cmp <(dtc -q -s -I dtb -O dts "$base/lid.dtb") <(dtc -q -s -I dtb -O dts "$stage/check.dtb")
rm "$stage/check.dtb"
python3 "$here/read-grub-menu.py" "$base/BOOTAA64.EFI" > "$stage/menu"
python3 - "$stage/menu" "$(sha "$dt")" "$(sha "$base/lid.dtb")" <<'PY'
import re
import sys
from pathlib import Path

menu, camera, lid = sys.argv[1:]
path = Path(menu)
text = path.read_text()
entry = re.search(r"\nmenuentry 'Debian 13 - Lid edge kernel \(Samsung\)' --id lid-edge \{.*?\n\}", text, re.S)
if not entry or "--id camera-720p" in text:
    sys.exit("Expected the tested Samsung lid-edge entry")
old = entry[0]
required = ["lid_edge_prepare", f"devicetree /boot/lid-{lid}.dtb", "np545.lid_edge=1"]
if not all(old.count(s) == 1 for s in required):
    sys.exit("Unexpected lid-edge entry")
new = old.replace("Lid edge kernel (Samsung)' --id lid-edge", "Camera 720p test (Samsung)' --id camera-720p")
new = new.replace("set diag_entry=Debian-lid-edge", "set diag_entry=Debian-camera")
new = new.replace(f"lid-{lid}.dtb", f"camera-{camera}.dtb").replace(
    "np545.lid_edge=1", "np545.lid_edge=1 np545.camera=1 systemd.wants=np545xla-camera.service")
new = new.replace("Verified Samsung lid DT unavailable", "Samsung camera trial DT unavailable")
with path.open("a") as dest:
    dest.write(new + '\n')
    # An optional environment block on the USB FAT allows one unattended trial.
    # Clear the request before boot; a failed clear always leaves the daily default.
    dest.write("""
if search --no-floppy --file --set=camera_esp /boot/np545-camera.env; then
    set camera_env="(${camera_esp})/boot/np545-camera.env"
    load_env --file "$camera_env" np545_camera_once
    if [ "$np545_camera_once" = 1 ]; then
        set np545_camera_once=0
        if save_env --file "$camera_env" np545_camera_once; then
            set default=camera-720p
        fi
    fi
fi
""")
PY
bash "$here/build-daily-efi.sh" --config-ext4-once "$stage/menu" "$stage/BOOTAA64.EFI"
python3 "$here/read-grub-menu.py" "$stage/BOOTAA64.EFI" | cmp - "$stage/menu"
rm "$stage/menu"
printf '%s %s %s %s\n' "$bundle" "$parent" "$daily" "$overlay" > "$stage/base.txt"
(cd "$stage" && sha256sum BOOTAA64.EFI camera.dtb base.txt > SHA256SUMS)
mv -nT "$stage" "$out"; [[ ! -e $stage ]]
