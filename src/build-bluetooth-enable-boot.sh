#!/usr/bin/env bash
# Package the GPIO170 fix and this machine's trusted Bluetooth address.
set -euo pipefail
export LC_ALL=C
[[ $# == 4 && ! -e $4 && ! -L $4 ]] || {
    echo "Usage: $0 BASE_BOOT_DIR TEST_IMAGE TRUSTED_ADDRESS_FILE NEW_OUTPUT_DIR" >&2
    exit 2
}
here=$(cd "$(dirname "$0")" && pwd)
base=$(realpath "$1")
image=$(realpath "$2")
address_file=$(realpath "$3")
out=$(realpath -m "$4")
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.bt-enable.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
(cd "$base"; sha256sum --strict -c <<'BASE'
d86e7ec81e18cebd1feba385cd5494d790f2bb1540330f1c39c0f9773cd96fea  BOOTAA64.EFI
1fed2cfb015e92fe3b3a2cd00707c85174b3384c302800a12ad005dd811e9b1d  bluetooth.dtb
BASE
)
grep -aFq 'NP545XLA Bluetooth GPIO170: APSS ownership enabled' "$image"
grep -aFq 'NP545XLA lid GPIO50: alternating PDC edges' "$image"
if grep -aFq NP545_NATIVE_SETUP "$image"; then
    echo 'The acceptance image must use the original GENI driver' >&2; exit 1
fi
cp "$image" "$stage/Image"
cp "$base/bluetooth.dtb" "$stage/bluetooth.dtb"
node=/soc@0/geniqup@cc0000/serial@c8c000/bluetooth
[[ $(fdtget "$stage/bluetooth.dtb" "$node" compatible) == qcom,qca6390-bt ]]
[[ $(fdtget -t u "$stage/bluetooth.dtb" "$node" max-speed) == 3000000 ]]
! fdtget "$stage/bluetooth.dtb" "$node" local-bd-address >/dev/null 2>&1
python3 - "$address_file" "$stage/address.txt" "$stage/address-le.txt" <<'PY'
import re, sys
from pathlib import Path
address=Path(sys.argv[1]).read_text().strip().upper()
assert re.fullmatch(r'(?:[0-9A-F]{2}:){5}[0-9A-F]{2}',address), 'invalid address'
raw=bytes.fromhex(address.replace(':',''))
assert not raw[0]&1 and raw != bytes(6) and address != '00:00:00:00:5A:AD'
Path(sys.argv[2]).write_text(address+'\n')
Path(sys.argv[3]).write_text(' '.join(f'{b:x}' for b in raw[::-1])+'\n')
PY
read -ra bytes < "$stage/address-le.txt"
fdtput -t bx "$stage/bluetooth.dtb" "$node" local-bd-address "${bytes[@]}"
[[ $(fdtget -t bx "$stage/bluetooth.dtb" "$node" local-bd-address) == "${bytes[*]}" ]]
# Prove the personalized address is the only device-tree change.
cp "$stage/bluetooth.dtb" "$stage/without-address.dtb"
fdtput -d "$stage/without-address.dtb" "$node" local-bd-address
dtc -q -s -I dtb -O dts "$base/bluetooth.dtb" > "$stage/before.dts"
dtc -q -s -I dtb -O dts "$stage/without-address.dtb" > "$stage/after.dts"
cmp "$stage/before.dts" "$stage/after.dts"
python3 "$here/read-grub-menu.py" "$base/BOOTAA64.EFI" > "$stage/base-menu"
python3 - "$stage" <<'PY'
from pathlib import Path
import hashlib, re
w=Path(__import__('sys').argv[1])
base=(w/'base-menu').read_text()
sha=lambda name:hashlib.sha256((w/name).read_bytes()).hexdigest()
image_sha,dt_sha=sha('Image'),sha('bluetooth.dtb')
image_path=f'/boot/np545xla-bluetooth-enable/Image-{image_sha}'
sum_name=f'bluetooth-enable-{image_sha}.sum'
functions=[]
for name in ('boot','prepare'):
    match=re.search(r'^function lid_edge_'+name+r' \{.*?^\}',base,re.M|re.S)
    assert match
    function=match.group().replace('function lid_edge_'+name,'function bt_enable_'+name)
    function=function.replace('/boot/np545xla-lid-edge/Image-509f2ff696f9dfc090e58bbe3a38593d8184561f6099fd328188243eb190561f',image_path)
    function=function.replace('lid-edge-509f2ff696f9dfc090e58bbe3a38593d8184561f6099fd328188243eb190561f.sum',sum_name)
    functions.append(function)
match=re.search(r"^menuentry 'Debian 13 - QCA6390 Bluetooth test \(Samsung\)' --id bluetooth \{.*?^\}",base,re.M|re.S)
assert match and base.count('--id bluetooth ')==1
old=match.group()
entry=old.replace('lid_edge_prepare','bt_enable_prepare').replace('lid_edge_boot','bt_enable_boot')
entry=entry.replace('bluetooth-1fed2cfb015e92fe3b3a2cd00707c85174b3384c302800a12ad005dd811e9b1d.dtb',f'bluetooth-{dt_sha}.dtb')
entry=entry.replace(' np545.bluetooth=1 ',' np545.bluetooth=1 np545.bt_enable=1 pinctrl_msm.np545_bt_egpio=1 ')
extra='\n\n'.join(functions)+'\n\n'
new=base[:match.start()]+extra+entry+base[match.end():]
assert new.replace(extra+entry,old)==base
assert 'then set default=gpiocharge; fi' in new
(w/'menu').write_text(new)
(w/'Image.sum').write_text(f'{image_sha}  {image_path}\n')
(w/'image.sha256').write_text(image_sha+'\n')
(w/'dt.sha256').write_text(dt_sha+'\n')
(w/'sum-name').write_text(sum_name+'\n')
PY
bash "$here/build-daily-efi.sh" --config-ext4-once "$stage/menu" "$stage/BOOTAA64.EFI"
python3 "$here/read-grub-menu.py" "$stage/BOOTAA64.EFI" | cmp - "$stage/menu"
rm "$stage/without-address.dtb" "$stage/before.dts" "$stage/after.dts" "$stage/address-le.txt"
(cd "$stage"; sha256sum BOOTAA64.EFI Image Image.sum bluetooth.dtb menu address.txt image.sha256 dt.sha256 sum-name > SHA256SUMS)
mv -nT "$stage" "$out"
[[ ! -e $stage ]]
cat "$out/SHA256SUMS"
