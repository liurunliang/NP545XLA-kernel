#!/usr/bin/env bash
# Build the optional backlight package for the verified 7.0 USB kernel ABI.
set -euo pipefail
export PATH="/usr/sbin:/sbin:$PATH" LC_ALL=C
if [[ $# != 3 || $(dpkg --print-architecture) != arm64 ]]; then
    echo "Usage (Debian arm64): $0 KERNEL_BUILD DIAG_ARTIFACTS OUTPUT_DIR" >&2
    exit 2
fi
obj=$(realpath "$1")
artifacts=$(realpath "$2")
mkdir -p "$3"
out=$(realpath "$3")
release=$(cat "$obj/include/config/kernel.release")
[[ $release == 7.0.0 ]]
cmp "$artifacts/Image" "$obj/arch/arm64/boot/Image"
cmp "$artifacts/kernel.config" "$obj/.config"
src=$(cd "$(dirname "$0")/debian-backlight" && pwd)
work=$(mktemp -d)
publish=$(mktemp -d "$out/.backlight.XXXXXXXX")
trap 'rm -rf "$work" "$publish"' EXIT
cp "$src/np545_sleep_backlight.c" "$work/"
printf 'obj-m := np545_sleep_backlight.o\n' > "$work/Kbuild"
make -C "$obj" M="$work" ARCH=arm64 W=1 modules
module=$work/np545_sleep_backlight.ko
[[ $(modinfo -F vermagic "$module") == "$(modinfo -F vermagic "$obj/drivers/phy/qualcomm/phy-qcom-edp.ko")" ]]
[[ -z $(modinfo -F alias "$module") ]]

name=np545xla-sleep-backlight
version=$release-1
pkg=$work/package
mkdir -p "$pkg/DEBIAN"
install -Dm644 "$module" "$pkg/usr/lib/modules/$release/extra/np545_sleep_backlight.ko"
install -Dm644 "$src/$name.service" "$pkg/usr/lib/systemd/system/$name.service"
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: $name
Version: $version
Section: kernel
Priority: optional
Architecture: arm64
Depends: kmod
Maintainer: NP545XLA Linux contributors <root@localhost>
Description: Opt-in sleep backlight quirk for the Samsung NP545XLA lid-edge trial
 Saves and restores the dedicated panel PWM during system suspend.
CONTROL
# Never leave an active trial driver behind on package removal. If a
# brightness restore is pending, modprobe -r fails and preserves the package.
cat > "$pkg/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
if [ "$1" = remove ] && [ -d /sys/module/np545_sleep_backlight ]; then
    if [ -d /run/systemd/system ] && systemctl is-active --quiet np545xla-sleep-backlight.service; then
        systemctl stop np545xla-sleep-backlight.service
    fi
    if [ -d /sys/module/np545_sleep_backlight ]; then modprobe -r np545_sleep_backlight; fi
fi
PRERM
chmod 755 "$pkg/DEBIAN/prerm"
for hook in postinst postrm; do
    printf '#!/bin/sh\nset -e\nif [ -d /lib/modules/%s ]; then depmod -a %s; fi\n' "$release" "$release" > "$pkg/DEBIAN/$hook"
    chmod 755 "$pkg/DEBIAN/$hook"
done
deb=${name}_${version}_arm64.deb
dpkg-deb --build --root-owner-group "$pkg" "$publish/$deb"
(cd "$publish"; sha256sum "$deb" > backlight.sha256)
mv "$publish/$deb" "$publish/backlight.sha256" "$out/"
