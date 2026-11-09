#!/usr/bin/env bash
# Publish the integrated trial; promote only after physical acceptance.
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
[[ $# == 2 && ( $1 == --trial || $1 == --promote ) && $EUID == 0 ]] || {
    echo "Usage: sudo $0 --trial|--promote BOOT_PACKAGE_DIR" >&2; exit 2
}
mode=$1
package=$(realpath "$2")
here=$(cd "$(dirname "$0")" && pwd)
[[ $(uname -r) == 7.0.0 && $(cat /sys/class/dmi/id/product_name) == 'Galaxy Book Go 5G' ]]
[[ $(findmnt -no UUID /) == aeb13805-ba45-4385-8a98-067b839ca579 && $(findmnt -no FSTYPE /) == ext4 ]]
rootdev=$(findmnt -no SOURCE /)
disk=$(lsblk -ndo PKNAME "$rootdev")
[[ $(lsblk -ndo TRAN "/dev/$disk") == usb && $(lsblk -ndro PARTN "$rootdev") == 3 ]]
[[ $(awk '{print $2}' "$package/SHA256SUMS") == $'trial.EFI\nlatest.EFI\ndaily.dtb\nbase-menu\ntrial-menu\nlatest-menu\nmetadata.json' ]]
(cd "$package"; sha256sum --strict -c SHA256SUMS)
mapfile -t ids < <(python3 - "$package/metadata.json" <<'PY'
import json,re,sys
d=json.load(open(sys.argv[1]))
assert set(d)=={'base_efi','image','dt'}
assert all(re.fullmatch('[0-9a-f]{64}',v) for v in d.values())
for key in ('base_efi','image','dt'): print(d[key])
PY
)
[[ ${#ids[@]} == 3 ]]
base=${ids[0]} image=${ids[1]} dt=${ids[2]}
[[ $base == 30b61d900d8c1496981bc7afade869bfc27ae67473790ab41b59f03a24ba6f3b && $image == 163b71d2e6ae7deb2e0500de71d2b4639f1da80c68edb81a3477d1551e64735b ]]
echo "$image  /boot/np545xla-bluetooth-enable/Image-$image" | sha256sum --strict -c -
echo '509f2ff696f9dfc090e58bbe3a38593d8184561f6099fd328188243eb190561f  /boot/np545xla-lid-edge/Image-509f2ff696f9dfc090e58bbe3a38593d8184561f6099fd328188243eb190561f' | sha256sum --strict -c -
echo "$dt  $package/daily.dtb" | sha256sum --strict -c -
[[ $(fdtget "$package/daily.dtb" / compatible) == 'samsung,np545xla qcom,sc8180x' ]]
[[ $(fdtget "$package/daily.dtb" /soc@0/ufshc@1d84000 status) == disabled ]]
[[ $(fdtget -t u "$package/daily.dtb" /soc@0/pinctrl@3100000/camera-enable-hog gpios) == '166 0' ]]
fdtget "$package/daily.dtb" /soc@0/pinctrl@3100000/camera-enable-hog output-high >/dev/null
modprobe -d /usr/lib/np545xla-camera --show-depends uvcvideo >/dev/null
modprobe -d /usr/lib/np545xla-bluetooth --show-depends hci_uart >/dev/null
for variant in trial latest; do
    grub-file --is-arm64-efi "$package/$variant.EFI"
    python3 "$here/read-grub-menu.py" "$package/$variant.EFI" | cmp - "$package/$variant-menu"
done
variant=trial
expected=$base
expected_menu=base-menu
if [[ $mode == --promote ]]; then
    variant=latest
    expected=$(sha256sum "$package/trial.EFI" | cut -d' ' -f1)
    expected_menu=trial-menu
    grep -qw np545.media=1 /proc/cmdline
    for service in np545-bluetooth np545xla-camera bluetooth lightdm; do systemctl is-active --quiet "$service"; done
    [[ -d /sys/class/bluetooth/hci0 && -d /sys/class/video4linux/video0 ]]
    # GRUB adds /chosen properties; verify the running Image and the two
    # integrated hardware properties without requiring binary DT identity.
    grep -Fq "/boot/np545xla-bluetooth-enable/Image-$image " /proc/cmdline
    [[ $(fdtget -t u /sys/firmware/fdt /soc@0/pinctrl@3100000/camera-enable-hog gpios) == '166 0' ]]
    fdtget /sys/firmware/fdt /soc@0/pinctrl@3100000/camera-enable-hog output-high >/dev/null
    [[ $(fdtget -t bx /sys/firmware/fdt /soc@0/geniqup@cc0000/serial@c8c000/bluetooth local-bd-address) == "$(fdtget -t bx "$package/daily.dtb" /soc@0/geniqup@cc0000/serial@c8c000/bluetooth local-bd-address)" ]]
fi
mapfile -t esps < <(lsblk -nrpo NAME,PARTTYPE "/dev/$disk" | awk 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print $1}')
[[ ${#esps[@]} == 1 && $(lsblk -ndro PARTN "${esps[0]}") == 2 ]]
exec 9>/run/np545-daily-boot.lock
flock -n 9
! findmnt -rn -S "${esps[0]}" >/dev/null
m=$(mktemp -d /run/np545-media-esp.XXXXXX)
trap 'if mountpoint -q "$m"; then umount "$m"; fi; rmdir "$m"' EXIT
mount -t vfat -o nosuid,nodev,noexec,umask=0077 "${esps[0]}" "$m"
loader="$m/EFI/BOOT/BOOTAA64.EFI"
echo "$expected  $loader" | sha256sum --strict -c -
python3 "$here/read-grub-menu.py" "$loader" | cmp - "$package/$expected_menu"
mapfile -t flags < <(for e in "$m"/boot/np545-*.env; do grub-editenv "$e" list; done)
if [[ $mode == --trial ]]; then [[ ${#flags[@]} == 8 ]]; else [[ ${#flags[@]} == 9 ]]; fi
for flag in "${flags[@]}"; do [[ $flag =~ ^np545_[a-z0-9]+_once=0$ ]]; done
backup="$loader.pre-media-${expected:0:16}"
[[ ! -e $backup ]] || cmp "$backup" "$loader"
[[ -e $backup ]] || cp "$loader" "$backup"
cmp "$backup" "$loader"
# Scoped by np545.media=1 inside the helper; old independent entries retain
# their original system-wakeup behavior. Require review of conflicting files.
helper=/usr/lib/np545xla-bluetooth/set-media-wakeup
dropin=/etc/systemd/system/np545-bluetooth.service.d/80-media-wakeup.conf
[[ ! -e $helper ]] || cmp "$here/debian-bluetooth-media-wakeup" "$helper"
[[ ! -e $dropin ]] || cmp "$here/debian-bluetooth-media.conf" "$dropin"
install -Dm755 "$here/debian-bluetooth-media-wakeup" "$helper"
install -Dm644 "$here/debian-bluetooth-media.conf" "$dropin"
systemd-analyze verify np545-bluetooth.service
systemctl daemon-reload
"$helper"
publish() {
    local input=$1 target=$2
    cp "$input" "$target.new"
    cmp "$input" "$target.new"
    sync -f "$target.new"
    mv "$target.new" "$target"
    sync -f "$target"
    cmp "$input" "$target"
}
target="$m/boot/daily-media-$dt.dtb"
if [[ $mode == --trial ]]; then
    [[ ! -e $target ]] || cmp "$target" "$package/daily.dtb"
    publish "$package/daily.dtb" "$target"
    [[ ! -e $m/boot/np545-media.env ]]
    grub-editenv "$m/boot/np545-media.tmp" create
    grub-editenv "$m/boot/np545-media.tmp" set np545_media_once=0
    mv "$m/boot/np545-media.tmp" "$m/boot/np545-media.env"
else
    cmp "$package/daily.dtb" "$target"
fi
sha256sum --strict -c "$m/boot/bluetooth-enable-$image.sum"
publish "$package/$variant.EFI" "$loader"
python3 "$here/read-grub-menu.py" "$loader" | cmp - "$package/$variant-menu"
if [[ $mode == --trial ]]; then grub-editenv "$m/boot/np545-media.env" set np545_media_once=1; fi
sync -f "$m/boot"
umount "$m"
# Reopen the actual USB read-only and verify the published payload and flags.
mount -t vfat -o ro,nosuid,nodev,noexec "${esps[0]}" "$m"
cmp "$package/$variant.EFI" "$loader"
cmp "$package/daily.dtb" "$target"
sha256sum "$loader" "$target" "$backup"
for e in "$m"/boot/np545-*.env; do grub-editenv "$e" list; done
umount "$m"
echo "Installed $variant; original Latest payload and rollback preserved."
