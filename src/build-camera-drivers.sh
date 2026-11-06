#!/usr/bin/env bash
# Package the UVC module closure privately for the optional camera boot.
set -euo pipefail
export PATH="/usr/sbin:/sbin:$PATH" LC_ALL=C
[[ $# == 4 && $(dpkg --print-architecture) == arm64 ]] || {
    echo "Usage: $0 LINUX_SOURCE KERNEL_BUILD DIAG_ARTIFACTS OUTPUT_DIR" >&2; exit 2; }
src=$(realpath "$1")
obj=$(realpath "$2")
artifacts=$(realpath "$3")
mkdir -p "$4"
out=$(realpath "$4")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
release=$(cat "$obj/include/config/kernel.release")
[[ $release == 7.0.0 ]]
cmp "$artifacts/kernel.config" "$obj/.config"
cmp "$artifacts/Image" "$obj/arch/arm64/boot/Image"
modules=(drivers/media/{usb/uvc/uvcvideo,common/uvc,mc/mc,v4l2-core/videodev}.ko
         drivers/media/common/videobuf2/{videobuf2-common,videobuf2-memops,videobuf2-v4l2,videobuf2-vmalloc}.ko)
make -C "$src" O="$obj" ARCH=arm64 -j"${JOBS:-$(nproc)}" "${modules[@]}"
pkg=$work/pkg
root=$pkg/usr/lib/np545xla-camera
tree=$root/lib/modules/$release
for mod in "${modules[@]}"; do
    install -D -m644 "$obj/$mod" "$tree/kernel/$mod"
done
cp "$obj/modules.builtin" "$obj/modules.builtin.modinfo" "$tree/"
printf 'kernel/%s\n' "${modules[@]}" > "$tree/modules.order"
depmod -b "$root" -e -F "$obj/System.map" "$release" 2>"$work/depmod.log"
if [[ -s $work/depmod.log ]]; then cat "$work/depmod.log" >&2; exit 1; fi
modprobe -d "$root" -S "$release" --show-depends uvcvideo
cmp "$artifacts/kernel.config" "$obj/.config"
install -Dm644 "$here/debian-camera.service" "$pkg/usr/lib/systemd/system/np545xla-camera.service"
install -Dm755 "$here/probe-debian-camera.py" "$pkg/usr/bin/np545xla-camera-test"
mkdir -p "$pkg/DEBIAN"
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: np545xla-camera
Version: $release-3
Architecture: arm64
Maintainer: NP545XLA Linux contributors <root@localhost>
Depends: kmod, v4l-utils, python3-gi, gir1.2-gstreamer-1.0, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good
Description: Opt-in UVC driver and 720p capture test for the Samsung Debian USB
CONTROL
dpkg-deb --root-owner-group --build "$pkg" "$work/camera.deb"
install -m644 "$work/camera.deb" "$out/np545xla-camera_${release}-3_arm64.deb"
