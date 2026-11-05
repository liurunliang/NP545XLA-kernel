#!/usr/bin/env bash
# Install the tested files on the USB root, outside /lib/firmware.
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
if [[ $# != 2 || $EUID != 0 ]]; then
    echo "Usage on the Samsung: sudo $0 DEBIAN_FIRMWARE_DIR qcdxkmsuc8180.mbn" >&2
    exit 2
fi
tr '\0' '\n' </proc/device-tree/compatible | grep -Fxq samsung,np545xla
rootdev=$(findmnt -no SOURCE /)
disk=$(lsblk -ndo PKNAME "$rootdev")
[[ $(findmnt -no FSTYPE /) == ext4 && -n $disk && $(lsblk -ndo TRAN "/dev/$disk") == usb ]]
base=/var/lib/np545xla-adreno
install -d -m 0755 "$base"
stage=$(mktemp -d "$base/.firmware.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
board=qcom/sc8180x/SAMSUNG/NP545XLA
install -Dm 0644 "$1/qcom/a630_sqe.fw" "$stage/qcom/a630_sqe.fw"
install -m 0644 "$1/qcom/a640_gmu.bin" "$stage/qcom/a640_gmu.bin"
install -Dm 0644 "$2" "$stage/$board/qcdxkmsuc8180.mbn"
# The Qualcomm package for QCOM043A REV_0913, and Debian's A680.1 pair.
cat > "$stage/SHA256SUMS" <<'HASHES'
1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c  qcom/a630_sqe.fw
3ff0c02708bbe78641db887fa62f3a7f9337934d0c2ce0b961ef7c43172591d2  qcom/a640_gmu.bin
faaeac2c537e70053bf05b7ff6a7fb3462331c970dc55a7d2aa9fb5c4e8cc939  qcom/sc8180x/SAMSUNG/NP545XLA/qcdxkmsuc8180.mbn
HASHES
(cd "$stage"; sha256sum -c SHA256SUMS)
chmod 0755 "$stage"
exec 3<"$stage/SHA256SUMS"
mv -nT "$stage" "$base/firmware"
# Also cover a retry or two concurrent installs. Leave a different bundle intact.
(cd "$base/firmware"; sha256sum -c - <&3)
echo "Adreno trial firmware ready in $base/firmware"
