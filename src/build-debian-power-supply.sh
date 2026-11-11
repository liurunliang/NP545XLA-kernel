#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PATH="/usr/sbin:/sbin:$PATH"
if [[ $# != 2 || $(dpkg --print-architecture) != arm64 ]]; then
    echo "Usage: $0 KERNEL_BUILD OUTPUT_DIR" >&2
    exit 2
fi
obj=$(realpath "$1")
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$2"
out=$(realpath "$2")
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
release=$(cat "$obj/include/config/kernel.release")
[[ $release == 7.0.0 ]]
cp "$here"/debian-battery/np545_power_supply.{c,h} "$stage/"
echo 'obj-m := np545_power_supply.o' > "$stage/Kbuild"
make -C "$obj" M="$stage" ARCH=arm64 W=1 modules
# There must be no bus-transfer, GPIO, regmap or PD control imports.
nm -u "$stage/np545_power_supply.ko" > "$out/undefined-symbols.txt"
if grep -E '(i2c_|gpiod_|regmap_|typec_|tcpm_)' "$out/undefined-symbols.txt"; then exit 1; fi
cp "$stage/np545_power_supply.ko" "$out/"
pkg=$stage/pkg
install -Dm644 "$stage/np545_power_supply.ko" "$pkg/usr/lib/modules/$release/extra/np545_power_supply.ko"
install -Dm755 "$here/debian-battery/power_supply_report.py" "$pkg/usr/lib/np545xla-power/power_supply_report.py"
install -Dm644 "$here/debian-battery/np545-power-supply.service" "$pkg/usr/lib/systemd/system/np545-power-supply.service"
mkdir -p "$pkg/DEBIAN"
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: np545xla-power-supply
Version: $release-2
Architecture: arm64
Maintainer: NP545XLA Linux contributors <root@localhost>
Depends: kmod, python3, systemd, np545xla-gpiocharge (= $release-6), np545xla-battery-ro (= $release-5)
Description: Read-only standard external power status for the validated IC10 charger
CONTROL
for hook in postinst postrm; do
    printf '#!/bin/sh\nset -e\nif [ -d /lib/modules/%s ]; then depmod -a %s; fi\nsystemctl daemon-reload || true\n' "$release" "$release" > "$pkg/DEBIAN/$hook"
    chmod +x "$pkg/DEBIAN/$hook"
done
cat > "$pkg/DEBIAN/prerm" <<'HOOK'
#!/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = deconfigure ]; then
    systemctl disable --now np545-power-supply.service || true
fi
HOOK
chmod +x "$pkg/DEBIAN/prerm"
dpkg-deb --root-owner-group --build "$pkg" "$out/np545xla-power-supply_${release}-2_arm64.deb"
sha256sum "$out/np545_power_supply.ko" "$out/np545xla-power-supply_${release}-2_arm64.deb" > "$out/SHA256SUMS"
