#!/usr/bin/env bash
# Combine the verified Bluetooth tree with the verified camera power node.
# Build both an opt-in trial and its later promotion, retaining the old Latest.
set -euo pipefail
export LC_ALL=C PATH="/usr/sbin:/sbin:$PATH"
[[ $# == 3 && ! -e $3 && ! -L $3 ]] || {
    echo "Usage: $0 VERIFIED_BT_BOOT_DIR VERIFIED_CAMERA_DTB NEW_OUTPUT_DIR" >&2
    exit 2
}
here=$(cd "$(dirname "$0")" && pwd)
base=$(realpath "$1")
camera=$(realpath "$2")
out=$(realpath -m "$3")
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.latest-media.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
(cd "$base"; sha256sum --strict -c <<'BASE'
30b61d900d8c1496981bc7afade869bfc27ae67473790ab41b59f03a24ba6f3b  BOOTAA64.EFI
163b71d2e6ae7deb2e0500de71d2b4639f1da80c68edb81a3477d1551e64735b  Image
3858666a0fd7b511d3b47fc8d2bedbbf4076f4d77bf21a345163c1fd69370ddf  bluetooth.dtb
BASE
)
echo "447f8187a23d247dc36584a3c206d27204fe88318dc58d6bfde7854a43aed02f  $camera" | sha256sum --strict -c -
cp "$base/bluetooth.dtb" "$stage/daily.dtb"
hog=/soc@0/pinctrl@3100000/camera-enable-hog
! fdtget -l "$stage/daily.dtb" "$hog" >/dev/null 2>&1
[[ $(fdtget -t u "$camera" "$hog" gpios) == '166 0' ]]
fdtget "$camera" "$hog" gpio-hog >/dev/null
fdtget "$camera" "$hog" output-high >/dev/null
fdtput -c "$stage/daily.dtb" "$hog"
fdtput "$stage/daily.dtb" "$hog" gpio-hog
fdtput -t u "$stage/daily.dtb" "$hog" gpios 166 0
fdtput "$stage/daily.dtb" "$hog" output-high
fdtput -t s "$stage/daily.dtb" "$hog" line-name "$(fdtget "$camera" "$hog" line-name)"
cp "$stage/daily.dtb" "$stage/check.dtb"
fdtput -r "$stage/check.dtb" "$hog"
cmp <(dtc -q -s -I dtb -O dts "$base/bluetooth.dtb") <(dtc -q -s -I dtb -O dts "$stage/check.dtb")
rm "$stage/check.dtb"
python3 "$here/read-grub-menu.py" "$base/BOOTAA64.EFI" > "$stage/base-menu"
python3 - "$stage" <<'PY'
from pathlib import Path
import hashlib, json, re, sys
w=Path(sys.argv[1])
base=(w/'base-menu').read_text()
dt=hashlib.sha256((w/'daily.dtb').read_bytes()).hexdigest()
def entry(text, ident):
    hits=re.findall(r"^menuentry [^\n]* --id "+re.escape(ident)+r" \{.*?^\}",text,re.M|re.S)
    assert len(hits)==1, ident
    return hits[0]
bt=entry(base,'bluetooth')
old=entry(base,'gpiocharge')
assert '--id latest-media ' not in base
combined=bt.replace("QCA6390 Bluetooth test (Samsung)' --id bluetooth", "Latest candidate - Bluetooth + camera (Samsung)' --id latest-media")
combined=combined.replace('set diag_entry=Debian-bluetooth','set diag_entry=Debian-latest-media')
combined=combined.replace('bluetooth-3858666a0fd7b511d3b47fc8d2bedbbf4076f4d77bf21a345163c1fd69370ddf.dtb',f'daily-media-{dt}.dtb')
combined=combined.replace(' np545.daily=1 ',' np545.daily=1 np545.media=1 np545.camera=1 systemd.wants=np545xla-camera.service ')
combined=combined.replace('Bluetooth trial DT unavailable','Combined daily DT unavailable')
once='''
if search --no-floppy --file --set=media_esp /boot/np545-media.env; then
    set media_env="(${media_esp})/boot/np545-media.env"
    load_env --file "$media_env" np545_media_once
    if [ "$np545_media_once" = 1 ]; then
        set np545_media_once=0
        if save_env --file "$media_env" np545_media_once; then set default=latest-media; fi
    fi
fi
'''
trial=base+'\n'+combined+'\n'+once
default='if [ "$default" = adreno-unified ]; then set default=gpiocharge; fi'
assert trial.count(default)==1
previous=old.replace("Latest (Samsung)'", "Previous Latest - before Bluetooth + camera (Samsung)'")
latest=trial.replace(old,previous).replace(combined,combined.replace('Latest candidate - Bluetooth + camera (Samsung)', 'Latest (Samsung)'))
latest=latest.replace(default,default.replace('set default=gpiocharge','set default=latest-media'))
# Promotion changes only two labels and the ordinary default, preserving
# all one-time selections and the old Latest entry's complete boot body.
assert entry(latest,'gpiocharge').split('\n',1)[1]==old.split('\n',1)[1]
assert trial[:len(base)]==base
for ident in re.findall(r"^menuentry [^\n]* --id ([\w-]+) \{",base,re.M):
    if ident!='gpiocharge':
        assert entry(latest,ident)==entry(base,ident)
(w/'trial-menu').write_text(trial)
(w/'latest-menu').write_text(latest)
(w/'metadata.json').write_text(json.dumps(dict(
    base_efi='30b61d900d8c1496981bc7afade869bfc27ae67473790ab41b59f03a24ba6f3b',
    image='163b71d2e6ae7deb2e0500de71d2b4639f1da80c68edb81a3477d1551e64735b',
    dt=dt),indent=2)+'\n')
PY
for variant in trial latest; do
    bash "$here/build-daily-efi.sh" --config-ext4-once "$stage/$variant-menu" "$stage/$variant.EFI"
    python3 "$here/read-grub-menu.py" "$stage/$variant.EFI" | cmp - "$stage/$variant-menu"
done
(cd "$stage"; sha256sum trial.EFI latest.EFI daily.dtb base-menu trial-menu latest-menu metadata.json > SHA256SUMS)
mv -nT "$stage" "$out"
[[ ! -e $stage ]]
cat "$out/SHA256SUMS"
