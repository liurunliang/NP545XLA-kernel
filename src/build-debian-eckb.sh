#!/usr/bin/env bash
# Build the board's keyboard add-on against the existing USB kernel ABI.
set -euo pipefail
export PATH="/usr/sbin:/sbin:$PATH" LC_ALL=C
if [[ $# != 4 || $(dpkg --print-architecture) != arm64 ]]; then
    echo "Usage (Debian arm64): $0 SRC_TREE KERNEL_BUILD DIAG_ARTIFACTS OUTPUT_DIR" >&2
    exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
src=$(realpath "$1")
obj=$(realpath "$2")
artifacts=$(realpath "$3")
mkdir -p "$4"
out=$(realpath "$4")
release=$(cat "$obj/include/config/kernel.release")
[[ $release == 7.0.0 ]]
cmp "$artifacts/Image" "$obj/arch/arm64/boot/Image"
cmp "$artifacts/kernel.config" "$obj/.config"

stage=$(mktemp -d)
publish=$(mktemp -d "$out/.eckb.XXXXXXXX")
trap 'rm -rf "$stage" "$publish"' EXIT
ext=$stage/i2c-hid
mkdir "$ext"
cp "$src/drivers/hid/hid-ids.h" "$stage/"
cp "$src/drivers/hid/i2c-hid/"{i2c-hid-core.c,i2c-hid-dmi-quirks.c,i2c-hid-of.c,i2c-hid.h} "$ext/"
cd "$ext"
sha256sum -c <<'HASHES'
668f42b4120f9a6c93885f5fce917e9f9c5d3fd058a8da856b13b8445ed4bfd1  i2c-hid-core.c
3ecd7b2240edc309876c8f22b127fe147033da901bde8f5ce544b53da215ba25  i2c-hid-dmi-quirks.c
234ff8be5d64db33f8f7dcc0c1a00ddbba8075d9d35ca1f76702b107ab826fbe  i2c-hid-of.c
b9de73a3b29e0874c6c810df7ce2eabfc53f3fdbd12fb02c8c96229ef272f5cb  i2c-hid.h
HASHES
patch --batch --fuzz=0 -p1 < "$repo/patches/linux-7.0-np545xla-eckb.patch"
cat > Kbuild <<'KBUILD'
obj-m := np545_eckb.o
np545_eckb-y := i2c-hid-core.o i2c-hid-of.o
np545_eckb-$(CONFIG_DMI) += i2c-hid-dmi-quirks.o

ccflags-y += -Di2c_hid_core_probe=np545_eckb_probe
ccflags-y += -Di2c_hid_core_remove=np545_eckb_remove
ccflags-y += -Di2c_hid_core_shutdown=np545_eckb_shutdown
ccflags-y += -Di2c_hid_core_pm=np545_eckb_pm
ccflags-y += -Di2c_hid_get_dmi_i2c_hid_desc_override=np545_eckb_dmi_descriptor
ccflags-y += -Di2c_hid_get_dmi_hid_report_desc_override=np545_eckb_dmi_report
ccflags-y += -Di2c_hid_get_dmi_quirks=np545_eckb_dmi_quirks
KBUILD
make -C "$obj" M="$ext" ARCH=arm64 KBUILD_MODPOST_WARN= modules
module="$ext/np545_eckb.ko"
[[ $(modinfo -F vermagic "$module") == "$(modinfo -F vermagic "$obj/drivers/phy/qualcomm/phy-qcom-edp.ko")" ]]
modinfo -F alias "$module" | grep -Fq 'Csamsung,np545xla-eckb'
if modinfo -F alias "$module" | grep -Fq hid-over-i2c; then
    echo 'Unexpected generic HID autoload alias' >&2
    exit 1
fi

pkg=$stage/pkg
name=np545xla-eckb
version=$release-1
mkdir -p "$pkg/DEBIAN"
install -D -m 644 "$module" "$pkg/usr/lib/modules/$release/extra/np545_eckb.ko"
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: $name
Version: $version
Section: kernel
Priority: optional
Architecture: arm64
Depends: kmod
Maintainer: NP545XLA Linux contributors <root@localhost>
Description: Samsung NP545XLA built-in keyboard driver for Linux $release
 Reads the ECKB HID descriptor directly on the NP545XLA daily USB kernel.
CONTROL
for hook in postinst postrm; do
    printf '#!/bin/sh\nset -e\nif [ -d /lib/modules/%s ]; then depmod -a %s; fi\n' "$release" "$release" > "$pkg/DEBIAN/$hook"
    chmod 755 "$pkg/DEBIAN/$hook"
done
deb=${name}_${version}_arm64.deb
dpkg-deb --build --root-owner-group "$pkg" "$publish/$deb"
(cd "$publish"; sha256sum "$deb" > eckb.sha256)
mv "$publish/$deb" "$publish/eckb.sha256" "$out/"
echo "Built $out/$deb"
