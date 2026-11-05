#!/usr/bin/env bash
# Build add-on modules for the existing USB kernel, keeping its Image and display stack.
set -euo pipefail
export PATH="/usr/sbin:/sbin:$PATH" LC_ALL=C
if [[ $# != 4 || $(dpkg --print-architecture) != arm64 ]]; then
    echo "Usage (Debian arm64): $0 SRC_TREE BUILD_DIR DIAG_ARTIFACTS OUTPUT_DIR" >&2
    exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
src=$(realpath "$1")
obj=$(realpath "$2")
artifacts=$(realpath "$3")
mkdir -p "$4"
out=$(realpath "$4")
stage=$(mktemp -d)
publish=$(mktemp -d "$out/.wifi.XXXXXXXX")
trap 'rm -rf "$stage" "$publish"' EXIT
release=$(cat "$obj/include/config/kernel.release")
[[ $release == 7.0.0 ]]
verify_kernel() {
    cmp "$artifacts/Image" "$obj/arch/arm64/boot/Image"
    cmp "$artifacts/kernel.config" "$obj/.config"
}
verify_kernel
# QRTR-MHI and the crypto transforms are looked up at runtime; modinfo on
# ath11k_pci alone does not list them. hid-multitouch handles the input trial.
modules=(
    drivers/phy/qualcomm/phy-qcom-qmp-pcie.ko
    drivers/bus/mhi/host/mhi.ko
    drivers/net/wireless/ath/ath11k/ath11k_pci.ko
    drivers/net/wireless/ath/ath11k/ath11k.ko
    drivers/net/wireless/ath/ath.ko
    drivers/soc/qcom/qmi_helpers.ko
    net/qrtr/qrtr.ko net/qrtr/qrtr-mhi.ko
    net/rfkill/rfkill.ko net/wireless/cfg80211.ko net/mac80211/mac80211.ko
    lib/crypto/libarc4.ko crypto/michael_mic.ko
    crypto/aes.ko crypto/ccm.ko crypto/cmac.ko crypto/ctr.ko crypto/gcm.ko crypto/ghash-generic.ko
    drivers/hid/hid-multitouch.ko
)
make -C "$src" O="$obj" ARCH=arm64 KBUILD_MODPOST_WARN= -j"${JOBS:-$(nproc)}" "${modules[@]}"
verify_kernel
pkg="$stage/pkg"
check="$stage/check"
moddir="$pkg/usr/lib/modules/$release"
checkdir="$check/lib/modules/$release"
for module in "${modules[@]}"; do
    install -D -m 644 "$obj/$module" "$moddir/kernel/$module"
done
mkdir -p "$checkdir"
cp -al "$moddir/kernel" "$checkdir/"
printf 'kernel/%s\n' "${modules[@]}" > "$checkdir/modules.order"
cp "$obj/modules.builtin" "$obj/modules.builtin.modinfo" "$checkdir/"
depmod -b "$check" -e -F "$obj/System.map" "$release" 2>"$stage/depmod.log"
[[ ! -s "$stage/depmod.log" ]] || { cat "$stage/depmod.log" >&2; exit 1; }
for mod in phy_qcom_qmp_pcie qrtr_mhi ath11k_pci hid_multitouch; do
    modprobe -d "$check" -S "$release" --show-depends "$mod"
done
modprobe -d "$check" -S "$release" --resolve-alias 'pci:v000017CBd00001101sv000017CBsd00000108bc02sc80i00' |
    grep -Fxq ath11k_pci

name=np545xla-wifi-modules
version=$release-1
mkdir "$pkg/DEBIAN"
cat > "$pkg/DEBIAN/control" <<EOF
Package: $name
Version: $version
Architecture: arm64
Maintainer: NP545XLA Linux contributors <root@localhost>
Depends: kmod, firmware-atheros, wireless-regdb
Description: QCA639x PCIe wireless and HID modules for the NP545XLA USB kernel
 Supplements the board's Linux $release kernel and existing display modules.
EOF
for script in postinst postrm; do
    cat > "$pkg/DEBIAN/$script" <<EOF
#!/bin/sh
set -e
if [ -d /lib/modules/$release ]; then depmod -a $release; fi
EOF
    chmod 755 "$pkg/DEBIAN/$script"
done
deb=${name}_${version}_arm64.deb
dpkg-deb --build --root-owner-group "$pkg" "$publish/$deb"

overlay=sc8180xp-np545xla-wifi.dtbo
dtc -@ -I dts -O dtb -o "$publish/$overlay" "$repo/dts/${overlay%.*}.dtso"
fdtoverlay -i "$artifacts/samsung.dtb" -o "$stage/wifi.dtb" "$publish/$overlay"
[[ $(fdtget "$stage/wifi.dtb" /soc@0/pcie@1c00000 status) == okay ]]
[[ $(fdtget "$stage/wifi.dtb" /soc@0/pcie@1c18000 status) == disabled ]]
(cd "$publish"; sha256sum "$deb" "$overlay" > wifi.sha256)
for file in "$deb" "$overlay" wifi.sha256; do mv "$publish/$file" "$out/$file"; done
echo "Built $out/$deb and $out/$overlay"
