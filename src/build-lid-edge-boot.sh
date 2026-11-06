#!/usr/bin/env bash
# Extend the tested lid menu with an independently addressed trial kernel.
set -euo pipefail
export LC_ALL=C
if [[ $# != 4 || -e $4 || -L $4 ]]; then
    echo "Usage: $0 DEBIAN_MANIFEST VERIFIED_LID_DIR TRIAL_KERNEL_DIR NEW_OUTPUT_DIR" >&2
    exit 2
fi
src=$(cd "$(dirname "$0")" && pwd)
base=$(realpath "$2")
kernel=$(realpath "$3")
out=$(realpath -m "$4")
bundle=$(awk '$1 == "Bundle:" {print $2}' "$1")
uuid=$(awk '$1 == "Root" && $2 == "UUID:" {print $3}' "$1")
[[ $bundle =~ ^[0-9a-f]{16}$ && $uuid =~ ^[0-9a-f-]{36}$ ]]
(cd "$base"; sha256sum --strict -c SHA256SUMS)
(cd "$kernel"; sha256sum --strict -c SHA256SUMS)
base_efi=81e381fe2af8aeb5095fc25b6b1b8bd7f73be499f4dd1ed8f4ef24725e481278
sha() { sha256sum < "$1" | cut -d' ' -f1; }
[[ $(sha "$base/BOOTAA64.EFI") == "$base_efi" ]]
image=$(sha "$kernel/Image")
[[ $(awk '$2=="Image" {print $1}' "$kernel/SHA256SUMS") == "$image" ]]
[[ $image != "$(awk '$2=="Image" {print $1}' "$1")" ]]
grub-file --is-arm64-efi "$kernel/Image"
read -r old_bundle previous_efi daily overlay extra < "$base/base.txt"
[[ $old_bundle == "$bundle" && -z $extra && $daily =~ ^[0-9a-f]{64}$ && $overlay =~ ^[0-9a-f]{64}$ ]]
lid=$(sha "$base/lid.dtb")
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.lid-edge-boot.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
python3 "$src/read-grub-menu.py" "$base/BOOTAA64.EFI" > "$stage/grub.cfg"
python3 - "$stage/grub.cfg" "$src/lid-edge-grub.cfg" "$uuid" "$image" "$lid" "$overlay" <<'PY'
from pathlib import Path
import re
import sys

menu, template, uuid, image, lid, overlay = sys.argv[1:]
cfg = Path(menu).read_text()
if '--id lid-edge' in cfg or '--id lid-test' not in cfg or cfg.count('function adreno_boot {') != 1:
    sys.exit('Unexpected base menu')
handoff = re.search(r'^function adreno_boot \{.*?^\}', cfg, re.M | re.S).group()
args = re.findall(r'^\s*adreno_boot (acpi=off [^\n]* np545\.lid=1)$', cfg, re.M)
if (len(args) != 1 or handoff.count('linux /boot/Image ') != 1 or
        f'initrd /boot/debian-initramfs.cpio.gz /boot/adreno-{overlay}.cpio.gz' not in handoff or
        f'devicetree /boot/lid-{lid}.dtb' not in cfg):
    sys.exit('Trial must use the accepted DT, arguments and both initrds')
handoff = handoff.replace('function adreno_boot', 'function lid_edge_boot').replace(
    'linux /boot/Image ', f'linux "($edge_part)/boot/np545xla-lid-edge/Image-{image}" ')
with Path(menu).open('a') as dest:
    dest.write('\n' + handoff + '\n' + Path(template).read_text()
               .replace('@UUID@', uuid).replace('@IMAGE@', image)
               .replace('@LID@', lid).replace('@SAMSUNG_ARGS@', args[0]))
PY
bash "$src/build-daily-efi.sh" --config-ext4 "$stage/grub.cfg" "$stage/BOOTAA64.EFI"
rm "$stage/grub.cfg"
install -m 644 "$base/lid.dtb" "$stage/lid.dtb"
install -m 644 "$kernel/Image" "$stage/Image"
printf '%s  /boot/np545xla-lid-edge/Image-%s\n' "$image" "$image" > "$stage/Image.sum"
printf '%s %s %s %s\n' "$bundle" "$base_efi" "$daily" "$overlay" > "$stage/base.txt"
(cd "$stage"; sha256sum BOOTAA64.EFI lid.dtb base.txt Image Image.sum > SHA256SUMS)
mv -nT "$stage" "$out"
[[ ! -e $stage ]]
cat "$out/SHA256SUMS"
