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
name=np545xla-sleep-backlight
version=$release-2
deb=${name}_${version}_arm64.deb
# A build must never replace the accepted -1 manifest or an existing -2.
exec {out_fd}<"$out"
flock "$out_fd"
if [[ -e $out/$deb || -e $out/backlight.sha256 ]]; then
    echo "Package or manifest already exists in $out; use a new output directory" >&2
    exit 1
fi
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
grep -aFq 'board lid handler active' "$module"
nm "$module" | grep -w 'dev_attr_disarm' > /dev/null

pkg=$work/package
mkdir -p "$pkg/DEBIAN"
install -Dm644 "$module" "$pkg/usr/lib/modules/$release/extra/np545_sleep_backlight.ko"
install -Dm644 "$src/$name.service" "$pkg/usr/lib/systemd/system/$name.service"
install -Dm755 "$src/stop" "$pkg/usr/libexec/$name/stop"
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: $name
Version: $version
Section: kernel
Priority: optional
Architecture: arm64
Depends: kmod
Maintainer: NP545XLA Linux contributors <root@localhost>
Description: Opt-in lid and sleep backlight driver for the Samsung NP545XLA
 Blanks the dedicated panel PWM on lid closure and across system suspend.
CONTROL
# Refuse to replace an in-memory driver with a different module on disk.
# The incoming preinst also protects upgrades from -1, whose prerm only
# handles removal. Neither hook changes the enabled or running policy.
cat > "$work/stopped-check" <<'CHECK'
if [ -d /sys/module/np545_sleep_backlight ]; then
    echo 'Stop np545xla-sleep-backlight.service and verify the module unloaded before replacing it.' >&2
    exit 1
fi
if [ -d /run/systemd/system ]; then
    state=$(systemctl show -p ActiveState --value np545xla-sleep-backlight.service)
    case "$state" in
        inactive|failed) ;;
        *) echo "Stop np545xla-sleep-backlight.service before replacing it (state $state)." >&2; exit 1 ;;
    esac
fi
CHECK
cat > "$pkg/DEBIAN/preinst" <<'PREINST'
#!/bin/sh
set -eu
case "$1" in install|upgrade) ;; *) exit 0 ;; esac
PREINST
cat "$work/stopped-check" >> "$pkg/DEBIAN/preinst"
cat > "$pkg/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -eu
case "$1" in
remove)
    if [ -d /run/systemd/system ] && systemctl is-active --quiet np545xla-sleep-backlight.service; then
        systemctl stop np545xla-sleep-backlight.service
    fi
    if [ -d /sys/module/np545_sleep_backlight ]; then
        /usr/libexec/np545xla-sleep-backlight/stop
    fi
    ;;
upgrade|failed-upgrade) ;;
*) exit 0 ;;
esac
PRERM
cat "$work/stopped-check" >> "$pkg/DEBIAN/prerm"
chmod 755 "$pkg/DEBIAN"/{preinst,prerm}
for hook in postinst postrm; do
    printf '#!/bin/sh\nset -e\nif [ -d /lib/modules/%s ]; then depmod -a %s; fi\n' "$release" "$release" > "$pkg/DEBIAN/$hook"
    echo 'if [ -d /run/systemd/system ]; then systemctl daemon-reload; fi' >> "$pkg/DEBIAN/$hook"
    chmod 755 "$pkg/DEBIAN/$hook"
done
dpkg-deb --build --root-owner-group "$pkg" "$publish/$deb"
(cd "$publish"; sha256sum "$deb" > backlight.sha256)
mv "$publish/$deb" "$publish/backlight.sha256" "$out/"
