#!/usr/bin/env bash
# Build the USB diagnostic image inside an ARM64 Debian Linux guest.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
usage() {
    echo "Usage: $0 --public-key FILE --work-dir DIR [--output DIR] [--kernel-archive FILE]"
}
key=
work=
output="$repo/output/diag"
archive=
while (($#)); do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --public-key|--work-dir|--output|--kernel-archive)
            (($# >= 2)) || { usage >&2; exit 2; }
            case $1 in
                --public-key) key=$2 ;;
                --work-dir) work=$2 ;;
                --output) output=$2 ;;
                --kernel-archive) archive=$2 ;;
            esac
            shift 2 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ -r "$key" && -n "$work" ]] || { usage >&2; exit 2; }
[[ $(uname -sm) == 'Linux aarch64' ]] || { echo 'Use a native ARM64 Linux builder.' >&2; exit 1; }
source_revision=$(git -C "$repo" rev-parse HEAD)
source_status=$(git -C "$repo" status --porcelain --untracked-files=normal)
key=$(realpath "$key")
mkdir -p "$work" "$output"
work=$(realpath "$work")
output=$(realpath "$output")
# Serialize updates of cached sources, objects and the published image.
exec 9>"$work/.build.lock"
flock -n 9 || { echo "Another build is using $work" >&2; exit 1; }
stage=$(mktemp -d "$work/image.XXXXXXXX")
publish=$(mktemp -d "$output/.publish.XXXXXXXX")
trap 'rm -rf "$stage" "$publish"' EXIT

kernel_sha=bb7f6d80b387c757b7d14bb93028fcb90f793c5c0d367736ee815a100b3891f0
firmware_sha=925755a9b0891c7dc39bbb73d28ab8f7193d37303b5022e8bc9d458b9b4aaa4e
verify() { echo "$1  $2" | sha256sum --check --status || { echo "SHA-256 mismatch: $2" >&2; exit 1; }; }
fetch() {
    local url=$1 file=$2 sha=$3
    if [[ ! -f $file ]]; then
        curl --fail --location --retry 3 "$url" --output "$stage/download"
        verify "$sha" "$stage/download"
        mv "$stage/download" "$file"
    fi
    verify "$sha" "$file"
}

if [[ -n $archive ]]; then
    archive=$(realpath "$archive")
    verify "$kernel_sha" "$archive"
else
    archive="$work/linux-7.0.tar.xz"
    fetch https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.0.tar.xz "$archive" "$kernel_sha"
fi
if [[ ! -d "$work/linux-7.0" ]]; then
    tar -xf "$archive" -C "$stage"
    echo "$kernel_sha" > "$stage/linux-7.0/.np545xla-source-sha256"
    mv "$stage/linux-7.0" "$work/linux-7.0"
fi
artifacts="$work/artifacts"
"$repo/src/build-diag-kernel.sh" "$work/linux-7.0" "$work/obj" "$artifacts"
fetch https://deb.debian.org/debian/pool/non-free-firmware/f/firmware-nonfree/firmware-realtek_20250410-2_all.deb \
    "$work/firmware-realtek.deb" "$firmware_sha"
dpkg-deb -x "$work/firmware-realtek.deb" "$stage/firmware"
export RTL_FIRMWARE_DIR="$stage/firmware/usr/lib/firmware/rtl_nic"
"$repo/src/build-diag-initramfs.sh" "$key" "$artifacts"

tree="$stage/media"
mkdir -p "$tree/EFI/BOOT" "$tree/boot"
for file in Image samsung.dtb initramfs.cpio.gz; do
    cp "$artifacts/$file" "$tree/boot/"
done
bundle=$(cd "$tree/boot"; sha256sum Image samsung.dtb initramfs.cpio.gz | sha256sum | cut -c1-16)
touch "$tree/boot/media-$bundle"
sed "s/@BUNDLE@/$bundle/g" "$repo/src/diag-grub.cfg" > "$stage/grub.cfg"
modules="part_gpt fat iso9660 normal configfile linux fdt search search_fs_file echo sleep test boot"
grub-mkstandalone -O arm64-efi --locales="" --fonts="" --themes="" \
    --install-modules="$modules" --modules="$modules" \
    -o "$tree/EFI/BOOT/BOOTAA64.EFI" "boot/grub/grub.cfg=$stage/grub.cfg"

# The same FAT32 image is both the USB GPT ESP and the EFI El Torito boot image.
# Mirror files in ISO9660 as well so GRUB can read its boot device either way.
mb=$(( $(du -sm "$tree" | cut -f1) + 32 ))
((mb >= 64)) || mb=64
truncate -s "${mb}M" "$stage/esp.fat"
mkfs.fat -F 32 -n NP545DIAG "$stage/esp.fat"
mcopy -s -i "$stage/esp.fat" "$tree/EFI" "$tree/boot" ::/
name=np545xla-diag.img
xorriso -as mkisofs -quiet -r -J -iso-level 3 -V NP545_DIAG \
    -append_partition 2 0xef "$stage/esp.fat" -appended_part_as_gpt \
    -e '--interval:appended_partition_2:all::' -no-emul-boot \
    -o "$publish/$name" "$tree"
# Check the generated boot catalog, GPT partition type and the final ESP content.
xorriso -indev "$publish/$name" -report_el_torito plain 2>/dev/null | grep -E 'UEFI.*y' >/dev/null
partition=$(LC_ALL=C sgdisk -i 2 "$publish/$name")
grep -qi 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B' <<<"$partition"
start=$(awk '/First sector:/ {print $3}' <<<"$partition")
offset=$((start * 512))
mcopy -i "$publish/$name@@$offset" ::/EFI/BOOT/BOOTAA64.EFI "$stage/esp-readback.efi"
cmp "$tree/EFI/BOOT/BOOTAA64.EFI" "$stage/esp-readback.efi"
(
    cd "$publish"
    sha256sum "$name" > "$name.sha256"
    {
        echo "Board: Samsung Galaxy Book Go 5G NP545XLA"
        echo "Source revision: $source_revision"
        if [[ -n $source_status ]]; then echo 'Source tree: modified'; fi
        echo "Linux: v7.0 ($kernel_sha, linux-7.0.tar.xz)"
        echo "Firmware: firmware-realtek_20250410-2 ($firmware_sha)"
        echo "Public key: $(ssh-keygen -E sha256 -lf "$key" | awk '{print $2}')"
        echo "Bundle: $bundle"
        dpkg-query -W busybox-static dropbear-bin grub-efi-arm64-bin xorriso gcc
        (cd "$artifacts"; sha256sum Image samsung.dtb initramfs.cpio.gz kernel.config)
        cat "$name.sha256"
    } > manifest.txt
)
install -m 0644 "$artifacts/kernel.config" "$publish/kernel.config"
for file in "$name" "$name.sha256" kernel.config manifest.txt; do
    mv -f "$publish/$file" "$output/$file"
done
echo "Built $output/$name ($bundle)"
