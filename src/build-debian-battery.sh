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
powerlib=usr/lib/np545xla-power
install -Dm755 "$here/probe-debian-charge.py" "$pkg/$powerlib/np545_charge_observe.py"
ln -s "../lib/np545xla-power/np545_charge_observe.py" "$pkg/usr/bin/np545xla-charge-observe"
install -Dm644 "$here/debian-battery/np545-charge-observe.service" "$pkg/usr/lib/systemd/system/np545-charge-observe.service"
mkdir -p "$pkg/DEBIAN"
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: np545xla-battery-ro
Version: $release-5
Architecture: arm64
Maintainer: NP545XLA Linux contributors <root@localhost>
Depends: kmod, python3
Description: Read-only smart battery telemetry for the optional Samsung USB boot
CONTROL
for name in postinst postrm; do
    printf '#!/bin/sh\nset -e\nif [ -d /lib/modules/%s ]; then depmod -a %s; fi\n' "$release" "$release" > "$pkg/DEBIAN/$name"
    chmod +x "$pkg/DEBIAN/$name"
done
dpkg-deb --root-owner-group --build "$pkg" "$out/np545xla-battery-ro_${release}-5_arm64.deb"

# The writer is an independent package with no enablement in the default target.
trial=$stage/trial
install -Dm755 "$here/debian-battery/keepcharge.py" "$trial/$powerlib/keepcharge.py"
install -Dm644 "$here/debian-battery/np545-charge-keepalive.service" "$trial/usr/lib/systemd/system/np545-charge-keepalive.service"
mkdir -p "$trial/DEBIAN"
cat > "$trial/DEBIAN/control" <<CONTROL
Package: np545xla-charge-keepalive
Version: $release-2
Architecture: arm64
Maintainer: NP545XLA Linux contributors <root@localhost>
Depends: np545xla-battery-ro (= $release-5)
Description: Current refresh for the optional Samsung active charge trial
CONTROL
dpkg-deb --root-owner-group --build "$trial" "$out/np545xla-charge-keepalive_${release}-2_arm64.deb"

hotplug=$stage/hotplug
install -Dm755 "$here/debian-battery/hotplug.py" "$hotplug/$powerlib/hotplug.py"
install -Dm644 "$here/debian-battery/np545-pd-hotplug.service" "$hotplug/usr/lib/systemd/system/np545-pd-hotplug.service"
mkdir -p "$hotplug/DEBIAN"
cat > "$hotplug/DEBIAN/control" <<CONTROL
Package: np545xla-pd-hotplug
Version: $release-6
Architecture: arm64
Maintainer: NP545XLA Linux contributors <root@localhost>
Depends: np545xla-charge-keepalive (= $release-2)
Description: Samsung IC10 USB-C sink reconnect trial
CONTROL
dpkg-deb --root-owner-group --build "$hotplug" "$out/np545xla-pd-hotplug_${release}-6_arm64.deb"

trace=$stage/trace
install -Dm755 "$here/debian-battery/ic10_irq.py" "$trace/$powerlib/ic10_irq.py"
install -Dm644 "$here/debian-battery/np545-ic10-irq.service" "$trace/usr/lib/systemd/system/np545-ic10-irq.service"
mkdir -p "$trace/DEBIAN"
cat > "$trace/DEBIAN/control" <<CONTROL
Package: np545xla-ic10-irq
Version: $release-6
Architecture: arm64
Maintainer: NP545XLA Linux contributors <root@localhost>
Depends: np545xla-pd-hotplug (= $release-6), python3-libgpiod (>= 2)
Description: Read-only IC10 GPIO edge and PD state trace for the Samsung trial
CONTROL
dpkg-deb --root-owner-group --build "$trace" "$out/np545xla-ic10-irq_${release}-6_arm64.deb"

ack=$stage/ack
install -Dm755 "$here/debian-battery/irq_ack.py" "$ack/$powerlib/irq_ack.py"
install -Dm644 "$here/debian-battery/np545-irq-ack.service" "$ack/usr/lib/systemd/system/np545-irq-ack.service"
mkdir -p "$ack/DEBIAN"
cat > "$ack/DEBIAN/control" <<CONTROL
Package: np545xla-irq-ack
Version: $release-5
Architecture: arm64
Maintainer: NP545XLA Linux contributors <root@localhost>
Depends: np545xla-ic10-irq (= $release-6)
Description: Dedicated IC10 S2MM005 interrupt acknowledgment trial
CONTROL
dpkg-deb --root-owner-group --build "$ack" "$out/np545xla-irq-ack_${release}-5_arm64.deb"

gpio=$stage/gpio
install -Dm755 "$here/debian-battery/gpio_charge.py" "$gpio/$powerlib/gpio_charge.py"
install -Dm644 "$here/debian-battery/charge_startup.py" "$gpio/$powerlib/charge_startup.py"
install -Dm644 "$here/debian-battery/np545-gpiocharge.service" "$gpio/usr/lib/systemd/system/np545-gpiocharge.service"
mkdir -p "$gpio/DEBIAN"
cat > "$gpio/DEBIAN/control" <<CONTROL
Package: np545xla-gpiocharge
Version: $release-3
Architecture: arm64
Maintainer: NP545XLA Linux contributors <root@localhost>
Depends: np545xla-irq-ack (= $release-5)
Description: Interrupt-driven IC10 hotplug and battery charging trial
CONTROL
dpkg-deb --root-owner-group --build "$gpio" "$out/np545xla-gpiocharge_${release}-3_arm64.deb"
