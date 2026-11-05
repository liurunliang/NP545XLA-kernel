#!/usr/bin/env bash
# Assemble a persistent ARM64 USB stick from the accepted diagnostic artifacts.
set -euo pipefail
export LC_ALL=C PATH="/usr/sbin:/sbin:$PATH"
repo=$(cd "$(dirname "$0")/.." && pwd)
usage() {
    echo "Usage: $0 --public-key FILE --diag-work DIR --diag-manifest FILE --work-dir DIR [--output DIR] [--keyboard disabled|enabled]"
}
die() { echo "$*" >&2; exit 1; }
key= diag= manifest= work=
output="$repo/output/debian-usb"
keyboard=enabled
while (($#)); do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --public-key|--diag-work|--diag-manifest|--work-dir|--output|--keyboard)
            (($# >= 2)) || { usage >&2; exit 2; }
            case $1 in
                --public-key) key=$2 ;;
                --diag-work) diag=$2 ;;
                --diag-manifest) manifest=$2 ;;
                --work-dir) work=$2 ;;
                --output) output=$2 ;;
                --keyboard) keyboard=$2 ;;
            esac
            shift 2 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ $(uname -sm) == 'Linux aarch64' && -r $key && -d $diag && -r $manifest && -n $work ]] ||
    { usage >&2; exit 2; }
[[ $keyboard == disabled || $keyboard == enabled ]] || die 'Invalid keyboard setting'
key=$(realpath "$key")
manifest=$(realpath "$manifest")
diag=$(realpath "$diag")
artifacts="$diag/artifacts"
mkdir -p "$work" "$output"
work=$(realpath "$work")
output=$(realpath "$output")
exec 9>"$work/.build.lock"
flock -n 9 || die "Another build is using $work"
stage=$(mktemp -d "$work/usb.XXXXXXXX")
publish=$(mktemp -d "$output/.debian-usb.XXXXXXXX")
trap 'rm -rf "$stage" "$publish"' EXIT

# Verify every input used by both the new entry and the three recovery entries.
for file in Image samsung.dtb initramfs.cpio.gz kernel.config display-modules.tar.gz; do
    awk -v f="$file" '$2 == f && length($1) == 64 {print; n++} END {exit n != 1}' "$manifest" |
        (cd "$artifacts"; sha256sum -c -)
done
for option in EXT4_FS USB_STORAGE BLK_DEV_INITRD; do
    grep -Fxq "CONFIG_${option}=y" "$artifacts/kernel.config" || die "Missing built-in $option"
done
key_id=$(ssh-keygen -E sha256 -lf "$key" | awk '{print $2}')
rescue_key=$(gzip -dc "$artifacts/initramfs.cpio.gz" | cpio --quiet -i --to-stdout root/.ssh/authorized_keys |
    ssh-keygen -E sha256 -lf - | awk '{print $2}')
[[ -n $key_id && $key_id == "$rescue_key" ]] || die 'Diagnostic rescue uses a different SSH key'

tree="$stage/media"
boot="$tree/boot"
mkdir -p "$boot" "$tree/EFI/BOOT"
cp "$artifacts"/{Image,samsung.dtb,initramfs.cpio.gz} "$boot/"
dt="$boot/debian-samsung.dtb"
cp "$boot/samsung.dtb" "$dt"
ufs=/soc@0/ufshc@1d84000
hid=/soc@0/geniqup@ac0000/i2c@a80000/keyboard@5
[[ $(fdtget "$dt" "$ufs" compatible) == *qcom,sc8180x-ufshc* ]] || die 'Unexpected UFS node'
[[ $(fdtget "$dt" "$hid" compatible) == hid-over-i2c ]] || die 'Unexpected keyboard node'
fdtput -t s "$dt" "$ufs" status disabled
hid_status=okay
if [[ $keyboard == disabled ]]; then
    hid_status=disabled
    fdtput -t s "$dt" "$hid" status disabled
fi
[[ $(fdtget "$dt" "$ufs" status) == disabled && $(fdtget -d okay "$dt" "$hid" status) == "$hid_status" ]] ||
    die 'Invalid Debian DT'

uuid=$(uuidgen --random)
# Linux accepts concatenated compressed newc archives. Keep the original /init
# and SSH keys intact; only the Debian entries set rdinit=/debian-init.
overlay="$stage/overlay"
mkdir -p "$overlay/bin" "$overlay/etc"
install -m 755 "$repo/src/debian-init" "$overlay/debian-init"
echo "$uuid" > "$overlay/etc/np545-root-uuid"
blkid=$(command -v blkid)
install -m 755 "$blkid" "$overlay/bin/blkid"
ldd "$blkid" > "$stage/blkid-libs"
if grep -q 'not found' "$stage/blkid-libs"; then die 'Missing blkid library'; fi
while IFS= read -r lib; do install -D -m 755 "$lib" "$overlay$lib"; done < <(
    awk '{for (i=1;i<=NF;i++) if ($i ~ /^\//) print $i}' "$stage/blkid-libs" | sort -u
)
cp "$boot/initramfs.cpio.gz" "$boot/debian-initramfs.cpio.gz"
(cd "$overlay"; find . -print0 | sort -z | cpio --quiet --null -o -H newc --owner=0:0) |
    gzip -n >> "$boot/debian-initramfs.cpio.gz"
bundle=$(cd "$boot"; sha256sum Image *.dtb *.cpio.gz | sha256sum | cut -c1-16)
touch "$boot/media-$bundle"
sed "s/@BUNDLE@/$bundle/g" "$repo/src/diag-grub.cfg" > "$stage/grub.cfg"
cat "$repo/src/debian-grub.cfg" >> "$stage/grub.cfg"
grub-script-check "$stage/grub.cfg"
modules='part_gpt fat iso9660 normal configfile linux fdt search search_fs_file echo sleep test boot smbios'
grub-mkstandalone -O arm64-efi --locales='' --fonts='' --themes='' --install-modules="$modules" --modules="$modules" \
    -o "$tree/EFI/BOOT/BOOTAA64.EFI" "boot/grub/grub.cfg=$stage/grub.cfg"
mb=$(( $(du -sm "$tree" | cut -f1) + 32 ))
truncate -s "${mb}M" "$stage/esp.fat"
mkfs.fat -F 32 -n NP545BOOT "$stage/esp.fat"
mcopy -s -i "$stage/esp.fat" "$tree/EFI" "$boot" ::/

# Root privileges are used only to populate the offline Debian filesystem.
rootfs="$stage/debian.ext4"
sudo "$repo/src/build-debian-rootfs.sh" --public-key "$key" --work-dir "$work/rootfs-cache" \
    --output "$rootfs" --uuid "$uuid" --modules "$artifacts/display-modules.tar.gz" --kernel-build "$diag/obj" \
    --firmware-deb "$diag/firmware-realtek.deb"
[[ $(stat -c %s "$rootfs") == 12884901888 && $(blkid -p -s UUID -o value "$rootfs") == "$uuid" ]] ||
    die 'Rootfs size or UUID differs'

# xorriso preserves the proven EFI El Torito image and also describes both
# appended partitions in GPT. Stream its output so empty ext4 blocks stay sparse.
name=np545xla-debian.img
image="$stage/$name"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
xorriso -as mkisofs -quiet -r -J -iso-level 3 -V NP545_DEBIAN \
    -append_partition 2 0xef "$stage/esp.fat" -append_partition 3 "$type" "$rootfs" -appended_part_as_gpt \
    -e '--interval:appended_partition_2:all::' -no-emul-boot -o - "$tree" |
    dd of="$image" bs=1M iflag=fullblock conv=sparse status=none
# Relocate the secondary GPT to the real end of the selected 15.38 GB stick.
stick_bytes=15376318464
(( $(stat -c %s "$image") < stick_bytes )) || die 'Image exceeds SanDisk capacity'
truncate -s "$stick_bytes" "$image"
sgdisk -e "$image" >/dev/null
sgdisk --verify "$image" > "$stage/gpt-check"
grep -Fq 'No problems found.' "$stage/gpt-check" || { cat "$stage/gpt-check"; exit 1; }
xorriso -indev "$image" -report_el_torito plain 2>/dev/null | grep -E 'UEFI.*y' >/dev/null
esp=$(sgdisk -i 2 "$image")
data=$(sgdisk -i 3 "$image")
grep -Fq 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B' <<<"$esp"
grep -Fq "$type" <<<"$data"
offset=$(( $(awk '/First sector:/ {print $3}' <<<"$esp") * 512 ))
mcopy -i "$image@@$offset" ::/EFI/BOOT/BOOTAA64.EFI "$stage/esp-readback.efi"
cmp "$stage/esp-readback.efi" "$tree/EFI/BOOT/BOOTAA64.EFI"
offset=$(( $(awk '/First sector:/ {print $3}' <<<"$data") * 512 ))
[[ $(blkid -p -O "$offset" -s UUID -o value "$image") == "$uuid" ]] || die 'Packaged root UUID differs'
# Shared Linux/macOS filesystems may allocate the gap on a write past EOF.
# Establish the final length first, then only overwrite nonzero blocks.
truncate -s "$stick_bytes" "$publish/$name"
dd if="$image" of="$publish/$name" bs=1M iflag=fullblock conv=sparse,notrunc status=none
(
    cd "$publish"
    sha256sum "$name" > "$name.sha256"
    {
        echo "Debian 13 arm64 / Samsung Galaxy Book Go 5G NP545XLA"
        echo "Source revision: $(git -C "$repo" rev-parse HEAD)"
        if [[ -n $(git -C "$repo" status --porcelain) ]]; then echo 'Source tree: modified'; fi
        echo "Root UUID: $uuid"
        echo "Media bytes: $stick_bytes"
        echo "Root bytes: $(stat -c %s "$rootfs")"
        echo "Bundle: $bundle"
        echo "Public key: $key_id"
        echo "Debian DT internal UFS: disabled; keyboard: $keyboard"
        (cd "$boot"; sha256sum Image *.dtb *.cpio.gz)
        (cd "$artifacts"; sha256sum kernel.config display-modules.tar.gz)
        cat "$name.sha256"
    } > manifest.txt
)
for file in "$name" "$name.sha256" manifest.txt; do mv -f "$publish/$file" "$output/$file"; done
echo "Built $output/$name ($uuid)"
