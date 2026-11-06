#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PATH="/usr/sbin:/sbin:$PATH"
if [[ $# != 3 || $(dpkg --print-architecture) != arm64 ]]; then
    echo "Usage: $0 KERNEL_BUILD DIAG_ARTIFACTS OUTPUT_DIR" >&2; exit 2
fi
obj=$(realpath "$1")
artifacts=$(realpath "$2")
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$3"
out=$(realpath "$3")
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
release=$(cat "$obj/include/config/kernel.release")
[[ $release == 7.0.0 ]]
cmp "$artifacts/kernel.config" "$obj/.config"
cmp "$artifacts/Image" "$obj/arch/arm64/boot/Image"
cp "$here/debian-battery/np545_battery.c" "$stage/"
echo 'obj-m := np545_battery.o' > "$stage/Kbuild"
make -C "$obj" M="$stage" ARCH=arm64 W=1 modules
# Verify the module's only SMBus transfer function is the read-word helper.
[[ $(nm -u "$stage/np545_battery.ko" | awk '$NF ~ /^i2c_(smbus|transfer|master)/ {print $NF}') == i2c_smbus_read_word_data ]]
pkg=$stage/pkg
install -Dm644 "$stage/np545_battery.ko" "$pkg/usr/lib/modules/$release/extra/np545_battery.ko"
install -Dm755 "$here/probe-debian-battery.py" "$pkg/usr/bin/np545xla-battery-sample"
install -Dm644 "$here/debian-battery/np545-battery-sample.service" "$pkg/usr/lib/systemd/system/np545-battery-sample.service"
install -Dm755 "$here/debian-battery/sleep-sample" "$pkg/usr/lib/systemd/system-sleep/np545-battery-sample"
install -Dm755 "$here/probe-debian-charge.py" "$pkg/usr/bin/np545xla-charge-observe"
install -Dm644 "$here/debian-battery/np545-charge-observe.service" "$pkg/usr/lib/systemd/system/np545-charge-observe.service"
mkdir -p "$pkg/DEBIAN"
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: np545xla-battery-ro
Version: $release-3
Architecture: arm64
Maintainer: NP545XLA Linux contributors <root@localhost>
Depends: kmod, python3
Description: Read-only smart battery telemetry for the optional Samsung USB boot
CONTROL
for name in postinst postrm; do
    printf '#!/bin/sh\nset -e\nif [ -d /lib/modules/%s ]; then depmod -a %s; fi\n' "$release" "$release" > "$pkg/DEBIAN/$name"
    chmod +x "$pkg/DEBIAN/$name"
done
dpkg-deb --root-owner-group --build "$pkg" "$out/np545xla-battery-ro_${release}-3_arm64.deb"
