#!/usr/bin/env bash
# Run from the persistent USB Debian. The edge trial also stores its kernel on the USB root.
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
die() { echo "$*" >&2; exit 1; }
trial=
lid_trial=
lid_mode=
battery_trial=
if [[ ${1:-} == --adreno && $# == 4 ]]; then
    trial=$(realpath "$2")
    set -- "$3" "$4" "$trial/BOOTAA64.EFI"
elif [[ $# == 3 && ( $1 == --lid || $1 == --lid-edge || $1 == --camera || $1 == --battery || $1 == --battery-diag || $1 == --battery-keepalive || $1 == --battery-hotplug || $1 == --battery-ic10irq ) ]]; then
    lid_mode=$1
    lid_trial=$(realpath "$2")
    trial_dt=lid.dtb
    if [[ $lid_mode == --camera ]]; then trial_dt=camera.dtb; fi
    if [[ $lid_mode == --battery* ]]; then trial_dt=battery.dtb; battery_trial=1; fi
    set -- "$3" "$lid_trial/$trial_dt" "$lid_trial/BOOTAA64.EFI"
fi
[[ $# == 3 && $EUID == 0 ]] || die "Usage: sudo $0 manifest.txt daily.dtb BOOTAA64.EFI | --adreno TRIAL_DIR manifest.txt CURRENT_daily.dtb | --lid LID_DIR manifest.txt | --lid-edge EDGE_DIR manifest.txt | --camera CAMERA_DIR manifest.txt | --battery BATTERY_DIR manifest.txt | --battery-diag UPDATED_BATTERY_DIR manifest.txt | --battery-keepalive KEEPALIVE_DIR manifest.txt | --battery-hotplug HOTPLUG_DIR manifest.txt | --battery-ic10irq IRQ_DIR manifest.txt"
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
if [[ -n $lid_trial ]]; then
    names=$'BOOTAA64.EFI\nlid.dtb\nbase.txt'
    if [[ $lid_mode == --camera ]]; then names=$'BOOTAA64.EFI\ncamera.dtb\nbase.txt'; fi
    if [[ -n $battery_trial ]]; then names=$'BOOTAA64.EFI\nbattery.dtb\nbase.txt'; fi
    if [[ $lid_mode == --lid-edge ]]; then names+=$'\nImage\nImage.sum'; fi
    [[ $(awk '{print $2}' "$lid_trial/SHA256SUMS") == "$names" ]] || die 'Invalid lid package'
    (cd "$lid_trial" && sha256sum --strict -c SHA256SUMS)
    read -r lid_bundle base_efi base_dt base_overlay extra < "$lid_trial/base.txt"
    [[ $lid_bundle == "$bundle" && -z $extra && $base_efi =~ ^[0-9a-f]{64}$ &&
       $base_dt =~ ^[0-9a-f]{64}$ && $base_overlay =~ ^[0-9a-f]{64}$ ]] || die 'Invalid lid package base identifiers'
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
if [[ -n $lid_trial ]]; then
    # The accepted EFI + DT + exact unified DRM overlay must already be present.
    # Install only the content-addressed trial DT, then publish its menu last.
    [[ -s $loader.baseline && -s $loader.pre-adreno ]] || die 'Expected the existing Debian and Adreno loader backups'
    printf '%s  %s\n' "$base_dt" "$current" "$base_overlay" "$boot/adreno-$base_overlay.cpio.gz" | sha256sum --strict -c -
    if ! cmp -s "$efi" "$loader"; then
        printf '%s  %s\n' "$base_efi" "$loader" | sha256sum --strict -c - || die 'Current EFI differs from the accepted base'
    fi
    lid_digest=$(sha256sum < "$dt" | cut -d' ' -f1)
    target="$boot/lid-$lid_digest.dtb"
    if [[ $lid_mode == --camera ]]; then
        target="$boot/camera-$lid_digest.dtb"
        hog=/soc@0/pinctrl@3100000/camera-enable-hog
        [[ $(fdtget -t u "$dt" "$hog" gpios) == '166 0' ]] || die 'Wrong camera GPIO'
        fdtget "$dt" "$hog" output-high >/dev/null
        modprobe -d /usr/lib/np545xla-camera --show-depends uvcvideo >/dev/null ||
            die 'Install the matching np545xla-camera package first'
        [[ -s /usr/lib/systemd/system/np545xla-camera.service && -x /usr/bin/np545xla-camera-test ]] ||
            die 'Missing camera service or capture test'
    elif [[ -n $battery_trial ]]; then
        bus=/soc@0/geniqup@cc0000/i2c@c88000
        target="$boot/battery-$lid_digest.dtb"
        [[ $(fdtget "$dt" "$bus" status) == okay &&
           $(fdtget -l "$dt" "$bus") == battery@b &&
           $(fdtget "$dt" "$bus/battery@b" compatible) == samsung,np545xla-battery-ro &&
           $(fdtget -t u "$dt" "$bus/battery@b" reg) == 11 ]] || die 'Unexpected battery DT'
        modinfo -n np545_battery >/dev/null || die 'Install the read-only battery package first'
        [[ -x /usr/bin/np545xla-battery-sample && -s /usr/lib/systemd/system/np545-battery-sample.service ]] ||
            die 'Missing battery recorder'
        if [[ $lid_mode != --battery ]]; then
            [[ -x /usr/bin/np545xla-charge-observe && -s /usr/lib/systemd/system/np545-charge-observe.service ]] ||
                die 'Missing read-only PD and charger observer'
            for port in /soc@0/geniqup@ac0000/i2c@a84000 /soc@0/geniqup@cc0000/i2c@c84000; do
                [[ $(fdtget "$dt" "$port" status) == okay && -z $(fdtget -l "$dt" "$port") ]] ||
                    die 'Unexpected PD bus or bound child'
            done
        fi
        if [[ $lid_mode == --battery-ic10irq ]]; then
            [[ -x /usr/lib/np545xla-power/ic10_irq.py && -s /usr/lib/systemd/system/np545-ic10-irq.service ]] ||
                die 'Install the IC10 input edge recorder first'
        fi
        if [[ $lid_mode == --battery-hotplug || $lid_mode == --battery-ic10irq ]]; then
            [[ -x /usr/lib/np545xla-power/hotplug.py && -s /usr/lib/systemd/system/np545-pd-hotplug.service ]] ||
                die 'Install the hotplug test package first'
        fi
        if [[ $lid_mode == --battery-keepalive || $lid_mode == --battery-hotplug || $lid_mode == --battery-ic10irq ]]; then
            [[ -x /usr/lib/np545xla-power/keepcharge.py && -s /usr/lib/systemd/system/np545-charge-keepalive.service ]] ||
                die 'Install the charge keepalive trial package first'
        fi
    fi
    if [[ $lid_mode == --camera || -n $battery_trial ]]; then
        backup="$loader.pre-${lid_mode#--}"
        if [[ ! -e $backup ]]; then
            printf '%s  %s\n' "$base_efi" "$loader" | sha256sum --strict -c -
            install_verified "$loader" "$backup"
        fi
        printf '%s  %s\n' "$base_efi" "$backup" | sha256sum --strict -c -
    fi
    [[ ! -e $target ]] || cmp -s "$dt" "$target" || die 'Conflicting content-addressed lid DT'
    if [[ $lid_mode == --lid-edge ]]; then
        # GRUB reads its Image from the third GPT partition on this same disk.
        [[ $(lsblk -ndro PARTN "$rootdev") == 3 && $(lsblk -ndro PARTN "$esp") == 2 ]] ||
            die 'Unexpected root or ESP partition number'
        cmp "$dt" "$target" || die 'Install and verify the original lid entry first'
        digest=$(sha256sum < "$lid_trial/Image" | cut -d' ' -f1)
        directory=/boot/np545xla-lid-edge
        path="$directory/Image-$digest"
        [[ $(realpath -m "$directory") == "$directory" && $(findmnt -n -o TARGET -T /boot) == / ]] ||
            die 'Candidate Image must be on the USB root filesystem'
        mkdir -p "$directory"
        [[ $(findmnt -n -o TARGET -T "$directory") == / && ! -L $path ]] || die 'Unexpected candidate Image location'
        printf '%s  %s\n' "$digest" "$path" | cmp - "$lid_trial/Image.sum" || die 'Invalid trial Image checksum record'
        [[ ! -e $path ]] || cmp -s "$lid_trial/Image" "$path" || die 'Conflicting content-addressed Image'
        install_verified "$lid_trial/Image" "$path"
        checksum="$boot/lid-edge-$digest.sum"
        [[ ! -e $checksum ]] || cmp -s "$lid_trial/Image.sum" "$checksum" || die 'Conflicting trial checksum'
        install_verified "$lid_trial/Image.sum" "$checksum"
        sha256sum --strict -c "$checksum"
        backup="$loader.pre-lid-edge"
        if [[ ! -e $backup ]]; then
            printf '%s  %s\n' "$base_efi" "$loader" | sha256sum --strict -c -
            install_verified "$loader" "$backup"
        fi
        printf '%s  %s\n' "$base_efi" "$backup" | sha256sum --strict -c -
    fi
    install_verified "$dt" "$target"
    install_verified "$efi" "$loader"
    sha256sum "$loader" "$target" "$current" "$boot/adreno-$base_overlay.cpio.gz"
    echo "Installed the optional ${lid_mode#--} menu entry. The default is the verified Adreno desktop."
    exit 0
fi
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
