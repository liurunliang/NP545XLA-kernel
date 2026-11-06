#!/usr/bin/env bash
# Private modules so the daily entry continues using its original module tree.
set -euo pipefail
export LC_ALL=C PATH="/usr/sbin:/sbin:$PATH"
[[ $# == 4 && $(dpkg --print-architecture) == arm64 ]] || {
    echo "Usage: $0 LINUX_SOURCE KERNEL_BUILD DIAG_ARTIFACTS OUTPUT_DIR" >&2; exit 2; }
src=$(realpath "$1"); obj=$(realpath "$2"); artifacts=$(realpath "$3")
mkdir -p "$4"; out=$(realpath "$4")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
release=$(cat "$obj/include/config/kernel.release")
[[ $release == 7.0.0 ]]
cmp "$artifacts/kernel.config" "$obj/.config"
cmp "$artifacts/Image" "$obj/arch/arm64/boot/Image"
modules=(net/bluetooth/bluetooth.ko drivers/bluetooth/{hci_uart,btqca,btbcm}.ko
         drivers/power/sequencing/pwrseq-qcom-wcn.ko net/rfkill/rfkill.ko
         crypto/{ecdh_generic,ecc,cmac,aes,ccm,ctr,sha256}.ko)
make -C "$src" O="$obj" ARCH=arm64 -j"${JOBS:-$(nproc)}" "${modules[@]}"
pkg=$work/pkg; root=$pkg/usr/lib/np545xla-bluetooth; tree=$root/lib/modules/$release
for m in "${modules[@]}"; do install -Dm644 "$obj/$m" "$tree/kernel/$m"; done
cp "$obj/modules.builtin" "$obj/modules.builtin.modinfo" "$tree/"
printf 'kernel/%s\n' "${modules[@]}" > "$tree/modules.order"
depmod -b "$root" -e -F "$obj/System.map" "$release" 2>"$work/depmod.log"
if [[ -s $work/depmod.log ]]; then cat "$work/depmod.log" >&2; exit 1; fi
for m in pwrseq_qcom_wcn hci_uart ecdh_generic cmac; do
    modprobe -d "$root" -S "$release" --show-depends "$m"
done
install -Dm644 "$here/debian-bluetooth.service" "$pkg/usr/lib/systemd/system/np545-bluetooth.service"
mkdir "$pkg/DEBIAN"
cat > "$pkg/DEBIAN/control" <<EOF
Package: np545xla-bluetooth
Version: $release-1
Architecture: arm64
Depends: kmod, firmware-atheros
Maintainer: NP545XLA Linux contributors <root@localhost>
Description: Isolated QCA6390 UART Bluetooth modules for the Samsung USB trial
EOF
dpkg-deb --root-owner-group --build "$pkg" "$work/bluetooth.deb"
install -m644 "$work/bluetooth.deb" "$out/np545xla-bluetooth_${release}-1_arm64.deb"
