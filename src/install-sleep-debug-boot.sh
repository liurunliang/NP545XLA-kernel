#!/usr/bin/env bash
# --check is read-only; --install adds an unarmed entry; --arm selects it once.
# No mode changes charging, sleep masks, or triggers suspend/reboot.
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
[[ $# == 2 && $EUID == 0 && ( $1 == --check || $1 == --install || $1 == --arm || $1 == --rollback ) ]] || {
    echo "Usage: sudo $0 --check|--install|--arm|--rollback BOOT_PACKAGE_DIR" >&2; exit 2
}
mode=$1 package=$(realpath "$2")
base=7ad52e7e7a2797a1c10f592378e3ebf8438d64f3501ebe486139a66ff11a46fa
image=ffba40697b5364f0e48693e7b0f71bee10eec1284a4d6086664fb940a9188179
old=163b71d2e6ae7deb2e0500de71d2b4639f1da80c68edb81a3477d1551e64735b
imagepath=/boot/np545xla-sleep-debug/Image-$image
sumfile=/boot/sleep-debug-$image.sum
[[ $(uname -r) == 7.0.0 && $(cat /sys/class/dmi/id/product_name) == 'Galaxy Book Go 5G' ]]
[[ $(findmnt -no UUID /) == aeb13805-ba45-4385-8a98-067b839ca579 && $(findmnt -no FSTYPE /) == ext4 ]]
rootdev=$(findmnt -no SOURCE /)
disk=$(lsblk -ndo PKNAME "$rootdev")
[[ $(lsblk -ndo TRAN "/dev/$disk") == usb && $(lsblk -ndro PARTN "$rootdev") == 3 ]]
for target in sleep suspend hibernate hybrid-sleep suspend-then-hibernate; do
    [[ $(readlink "/etc/systemd/system/$target.target") == /dev/null ]]
done
[[ $(awk '{print $2}' "$package/SHA256SUMS") == $'original.EFI\nImage\nImage.sum\nbase-menu\ntrial-menu\ntrial.EFI\nmetadata.json\nread-grub-menu.py\ninstall-sleep-debug-boot.sh\ntools/grub-file\ntools/grub-editenv\ntool-libs/libdevmapper.so.1.02.1\ntool-versions.txt' ]]
(cd "$package"; sha256sum --strict -c SHA256SUMS)
grub-file() { LD_LIBRARY_PATH="$package/tool-libs" "$package/tools/grub-file" "$@"; }
grub-editenv() { LD_LIBRARY_PATH="$package/tool-libs" "$package/tools/grub-editenv" "$@"; }
grub-editenv --version
echo "$base  $package/original.EFI" | sha256sum --strict -c -
echo "$image  $package/Image" | sha256sum --strict -c -
echo "$old  /boot/np545xla-bluetooth-enable/Image-$old" | sha256sum --strict -c -
[[ $(cat "$package/Image.sum") == "$image  $imagepath" ]]
for variant in original trial; do
    grub-file --is-arm64-efi "$package/$variant.EFI"
    menu=trial-menu; [[ $variant != original ]] || menu=base-menu
    python3 "$package/read-grub-menu.py" "$package/$variant.EFI" | cmp - "$package/$menu"
done
mapfile -t esps < <(lsblk -nrpo NAME,PARTTYPE "/dev/$disk" | awk 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print $1}')
[[ ${#esps[@]} == 1 && $(lsblk -ndro PARTN "${esps[0]}") == 2 ]]
[[ $(blkid -s UUID -o value "${esps[0]}") == 9C9B-A87D ]]
exec 9>/run/np545-daily-boot.lock
flock -n 9
! findmnt -rn -S "${esps[0]}" >/dev/null
m=$(mktemp -d /run/np545-pmdebug-esp.XXXXXX)
trap 'if mountpoint -q "$m"; then umount "$m"; fi; rmdir "$m"' EXIT
mount -t vfat -o ro,nosuid,nodev,noexec "${esps[0]}" "$m"
loader="$m/EFI/BOOT/BOOTAA64.EFI"
backup="$loader.pre-pmdebug-${base:0:16}"
envfile="$m/boot/np545-pmdebug.env"
dt="$m/boot/daily-media-2661562ea2c05e2548a1cbb74cf0c70996d0aa31c9d9ce03c94225f9c51a1a25.dtb"
echo "2661562ea2c05e2548a1cbb74cf0c70996d0aa31c9d9ce03c94225f9c51a1a25  $dt" | sha256sum --strict -c -
if [[ $mode == --check || $mode == --install ]]; then
    cmp "$package/original.EFI" "$loader"
    [[ ! -e $envfile ]]
else
    cmp "$package/trial.EFI" "$loader"
    cmp "$package/original.EFI" "$backup"
    cmp "$package/Image" "$imagepath"
    cmp "$package/Image.sum" "$m$sumfile"
    flag=$(grub-editenv "$envfile" list)
    [[ $flag == np545_pmdebug_once=0 || ( $mode == --rollback && $flag == np545_pmdebug_once=1 ) ]]
fi
for e in "$m"/boot/np545-*.env; do
    if [[ $mode == --rollback && $e == "$envfile" ]]; then continue; fi
    [[ $(grub-editenv "$e" list) =~ ^np545_[a-z0-9]+_once=0$ ]]
done
if [[ $mode == --check ]]; then
    echo 'Preflight passed; current EFI, default, sleep masks and files unchanged.'
    exit
fi
mount -o remount,rw "$m"
publish() {
    local input=$1 target=$2
    [[ ! -e $target.new ]]
    cp "$input" "$target.new"
    cmp "$input" "$target.new"
    sync -f "$target.new"
    mv "$target.new" "$target"
    sync -f "$target"
    cmp "$input" "$target"
}
if [[ $mode == --install ]]; then
    [[ ! -e $backup ]] || cmp "$backup" "$package/original.EFI"
    [[ -e $backup ]] || publish "$package/original.EFI" "$backup"
    mkdir -p "$(dirname "$imagepath")"
    [[ ! -e $imagepath ]] || cmp "$imagepath" "$package/Image"
    publish "$package/Image" "$imagepath"
    publish "$package/Image.sum" "$m$sumfile"
    [[ ! -e $envfile.new ]]
    grub-editenv "$envfile.new" create
    grub-editenv "$envfile.new" set np545_pmdebug_once=0
    sync -f "$envfile.new"
    mv "$envfile.new" "$envfile"
    publish "$package/trial.EFI" "$loader"
elif [[ $mode == --arm ]]; then
    grub-editenv "$envfile" set np545_pmdebug_once=1
    sync -f "$envfile"
else
    grub-editenv "$envfile" set np545_pmdebug_once=0
    sync -f "$envfile"
    publish "$package/original.EFI" "$loader"
fi
sync -f "$m"
umount "$m"
mount -t vfat -o ro,nosuid,nodev,noexec "${esps[0]}" "$m"
variant=trial; [[ $mode != --rollback ]] || variant=original
cmp "$package/$variant.EFI" "$loader"
cmp "$package/original.EFI" "$backup"
cmp "$package/Image" "$imagepath"
cmp "$package/Image.sum" "$m$sumfile"
expected=0; [[ $mode != --arm ]] || expected=1
[[ $(grub-editenv "$envfile" list) == np545_pmdebug_once=$expected ]]
sha256sum "$loader" "$backup" "$imagepath"
echo "$mode verified by read-only remount; no reboot or sleep requested."
