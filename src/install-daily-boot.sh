#!/usr/bin/env bash
# Run in the persistent USB Debian. Only its sibling EFI partition is updated.
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
die() { echo "$*" >&2; exit 1; }
trial=
if [[ ${1:-} == --adreno && $# == 4 ]]; then
    trial=$(realpath "$2")
    set -- "$3" "$4" "$trial/BOOTAA64.EFI"
fi
[[ $# == 3 && $EUID == 0 ]] || die "Usage: sudo $0 manifest.txt daily.dtb BOOTAA64.EFI | --adreno TRIAL_DIR manifest.txt CURRENT_daily.dtb"
manifest=$(realpath "$1")
dt=$(realpath "$2")
efi=$(realpath "$3")
bundle=$(awk '$1 == "Bundle:" {print $2}' "$manifest")
uuid=$(awk '$1 == "Root" && $2 == "UUID:" {print $3}' "$manifest")
[[ $bundle =~ ^[0-9a-f]{16}$ && $uuid =~ ^[0-9a-f-]{36}$ ]] || die 'Invalid Debian image manifest'
[[ $(findmnt -no FSTYPE /) == ext4 && $(findmnt -no UUID /) == "$uuid" ]] || die 'This is not the selected USB root'
rootdev=$(findmnt -no SOURCE /)
disk=$(lsblk -ndo PKNAME "$rootdev")
[[ -n $disk && $(lsblk -ndo TRAN "/dev/$disk") == usb ]] || die 'Root is not on a physical USB disk'
if [[ -n $trial ]]; then
    # Verify the EFI, overlay and firmware list as a set. Require exactly
    # these three package filenames before following any checksum paths.
    [[ $(awk '{print $2}' "$trial/SHA256SUMS") == $'BOOTAA64.EFI\nadreno.cpio.gz\nfirmware.sha256' ]] ||
        die 'Invalid Adreno trial package'
    (cd "$trial" && sha256sum --strict -c SHA256SUMS)
    (cd /var/lib/np545xla-adreno/firmware && sha256sum --strict -c "$trial/firmware.sha256")
fi
[[ $(fdtget "$dt" / compatible) == *samsung,np545xla* ]] || die 'DT belongs to a different machine'
[[ $(fdtget "$dt" /soc@0/ufshc@1d84000 status) == disabled ]] || die 'Daily DT must disable internal UFS'
keyboard=/soc@0/geniqup@ac0000/i2c@a80000/keyboard@5
[[ $(fdtget -d okay "$dt" "$keyboard" status) == okay ]] || die 'Keyboard is disabled'
if [[ $(fdtget "$dt" "$keyboard" compatible) == samsung,np545xla-eckb ]]; then
    [[ $(modprobe -R 'of:NkeyboardT(null)Csamsung,np545xla-eckb') == np545_eckb ]] ||
        die 'Install the np545xla-eckb package for this kernel before updating the daily DT'
fi
grub-file --is-arm64-efi "$efi" || die 'Invalid ARM64 EFI program'
mapfile -t esps < <(lsblk -nrpo NAME,PARTTYPE "/dev/$disk" | awk 'tolower($2) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print $1}')
[[ ${#esps[@]} == 1 ]] || die 'Expected one EFI partition on the same disk as root'
esp=${esps[0]}
exec 9>/run/np545-daily-boot.lock
flock -n 9 || die 'Another boot update is running'
if findmnt -rn -S "$esp" >/dev/null; then die 'USB EFI partition already mounted'; fi
mountpoint=$(mktemp -d /run/np545-esp.XXXXXX)
trap 'if mountpoint -q "$mountpoint"; then umount "$mountpoint"; fi; rmdir "$mountpoint"' EXIT
mount -t vfat -o nosuid,nodev,noexec,umask=0077 "$esp" "$mountpoint"
boot="$mountpoint/boot"
loader="$mountpoint/EFI/BOOT/BOOTAA64.EFI"
[[ -f $boot/media-$bundle && -s $loader ]] || die 'Wrong USB boot bundle'
for name in Image initramfs.cpio.gz debian-initramfs.cpio.gz debian-samsung.dtb samsung.dtb; do
    awk -v n="$name" '$2==n && length($1)==64 {print; hits++} END {exit hits!=1}' "$manifest" |
        (cd "$boot" && sha256sum -c -)
done
# Preserve the original loader and all original menu payloads. Write and verify
# each replacement before renaming it on the same filesystem.
install_verified() {
    local input=$1 target=$2
    if cmp -s "$input" "$target"; then return; fi
    cp "$input" "$target.new"
    cmp "$input" "$target.new"
    sync -f "$target.new"
    mv -f "$target.new" "$target"
    sync -f "$target"
    cmp "$input" "$target"
}
current="$boot/daily-$bundle.dtb"
if [[ -n $trial ]]; then
    cmp -s "$dt" "$current" || die 'Adreno trial requires the currently installed daily DT'
    [[ -s $loader.baseline ]] || die 'Install and test the standard daily entry first'
    digest=$(sha256sum "$trial/adreno.cpio.gz" | cut -d' ' -f1)
    if [[ ! -f $loader.pre-adreno ]]; then install_verified "$loader" "$loader.pre-adreno"; fi
    install_verified "$trial/adreno.cpio.gz" "$boot/adreno-$digest.cpio.gz"
fi
if [[ ! -f $loader.baseline ]]; then install_verified "$loader" "$loader.baseline"; fi
if [[ -s $current ]] && ! cmp -s "$dt" "$current"; then
    install_verified "$current" "$boot/previous-$bundle.dtb"
fi
install_verified "$dt" "$current"
install_verified "$efi" "$loader"
sha256sum "$loader" "$loader.baseline" "$boot/daily-$bundle.dtb"
echo "Updated $esp on /dev/$disk. Original Debian and the three diagnostic entries are available."
