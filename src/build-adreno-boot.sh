#!/usr/bin/env bash
# Build the optional USB EFI + versioned initramfs supplement in Debian.
set -euo pipefail
export LC_ALL=C
if [[ $# != 4 || -e $4 || -L $4 ]]; then
    echo "Usage: $0 debian-image-manifest.txt DEBIAN_FIRMWARE_DIR qcdxkmsuc8180.mbn NEW_OUTPUT_DIR" >&2
    exit 2
fi
src=$(cd "$(dirname "$0")" && pwd)
manifest=$(realpath "$1")
debian=$(realpath "$2")
zap=$(realpath "$3")
out=$(realpath -m "$4")
mkdir -p "$(dirname "$out")"
work=$(mktemp -d)
stage=$(mktemp -d "$(dirname "$out")/.adreno-boot.XXXXXXXX")
trap 'rm -rf "$work" "$stage"' EXIT
fw="$work/var/lib/np545xla-adreno/firmware"
board=qcom/sc8180x/SAMSUNG/NP545XLA
mkdir -p "$fw/$board"
install -m 0644 "$debian/qcom/a630_sqe.fw" "$debian/qcom/a640_gmu.bin" "$fw/qcom/"
install -m 0644 "$zap" "$fw/$board/qcdxkmsuc8180.mbn"
cat > "$stage/firmware.sha256" <<'HASHES'
1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c  qcom/a630_sqe.fw
3ff0c02708bbe78641db887fa62f3a7f9337934d0c2ce0b961ef7c43172591d2  qcom/a640_gmu.bin
faaeac2c537e70053bf05b7ff6a7fb3462331c970dc55a7d2aa9fb5c4e8cc939  qcom/sc8180x/SAMSUNG/NP545XLA/qcdxkmsuc8180.mbn
HASHES
(cd "$fw"; sha256sum -c "$stage/firmware.sha256")
install -m 0644 "$stage/firmware.sha256" "$fw/SHA256SUMS"
install -m 0755 "$src/debian-init" "$work/debian-init-adreno"
(
    cd "$work"
    # No root entry and no original PID 1. Only extra paths are unpacked.
    find . -mindepth 1 -exec touch -d @0 -- {} +
    find . -mindepth 1 -print0 | sort -z | cpio --null --quiet --reproducible -o -H newc --owner=0:0
) | gzip -n > "$stage/adreno.cpio.gz"
bash "$src/build-daily-efi.sh" --adreno-overlay "$stage/adreno.cpio.gz" "$manifest" "$stage/BOOTAA64.EFI"
(cd "$stage"; sha256sum BOOTAA64.EFI adreno.cpio.gz firmware.sha256 > SHA256SUMS)
mv -nT "$stage" "$out"
[[ ! -e $stage ]]
cat "$out/SHA256SUMS"
