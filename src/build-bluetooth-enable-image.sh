#!/usr/bin/env bash
# Build a separate Bluetooth test Image retaining the accepted lid fix.
set -euo pipefail
export LC_ALL=C PATH="/usr/sbin:$PATH"
if [[ $# != 4 || -e $4 || -L $4 ]]; then
    echo "Usage: $0 LINUX_SOURCE KERNEL_BUILD DIAG_ARTIFACTS NEW_OUTPUT_DIR" >&2
    exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
src=$(realpath "$1")
obj=$(realpath "$2")
artifacts=$(realpath "$3")
out=$(realpath -m "$4")
unit=drivers/pinctrl/qcom/pinctrl-msm.c
fix="$repo/patches/linux-7.0-np545xla-lid-edge.patch"
btfix="$repo/patches/linux-7.0-np545xla-bt-enable.patch"
marker='NP545XLA lid GPIO50: alternating PDC edges'
release=$(cat "$obj/include/config/kernel.release")
[[ $release == 7.0.0 ]]
(cd "$src"; echo "50fc4a43e1154ba2d064642dcf62c446fe92c48a7ebac9693671fe0f29095d2a  $unit" | sha256sum --check)
(cd "$artifacts"; sha256sum --check <<'BASE'
c02f5fa0fc7c82ecbba1a717caad561ecce165993148d6ae17bb8ab708960388  Image
ddb1ef05da86c3f9d98983299a61b924e0670eca788f4fc551a1e3a877edada0  kernel.config
BASE
)
cmp "$artifacts/Image" "$obj/arch/arm64/boot/Image"
cmp "$artifacts/kernel.config" "$obj/.config"
[[ $(readlink -f "$obj/source") == "$src" ]]
mkdir -p "$(dirname "$out")"
work=$(mktemp -d)
stage=$(mktemp -d "$(dirname "$out")/.lid-edge.XXXXXXXX")
trap 'rm -rf "$work" "$stage"' EXIT
base="$work/baseline.sha256"
sha256sum "$src/$unit" "$obj"/{arch/arm64/boot/Image,.config,Module.symvers,vmlinux.symvers,drivers/pinctrl/qcom/pinctrl-msm.o} > "$base"
mkdir -p "$work/source/$(dirname "$unit")" "$work/obj"
cp "$src/$unit" "$work/source/$unit"
patch --batch --fuzz=0 -p1 -d "$work/source" < "$fix"
patch --batch --fuzz=0 -p1 -d "$work/source" < "$btfix"
cp -a --reflink=auto "$obj/." "$work/obj/"

# Retain Kbuild's exact compiler paths so its .cmd dependency records remain
# usable. The mount namespace is private to this unprivileged child. Give it
# a read-only source tree with one patched file and a separate writable obj.
header="$obj/include/generated"
export KBUILD_BUILD_USER=$(sed -n 's/^#define LINUX_COMPILE_BY[[:space:]]*"\(.*\)"/\1/p' "$header/compile.h")
export KBUILD_BUILD_HOST=$(sed -n 's/^#define LINUX_COMPILE_HOST[[:space:]]*"\(.*\)"/\1/p' "$header/compile.h")
export KBUILD_BUILD_VERSION=$(cat "$obj/.version")
export KBUILD_BUILD_TIMESTAMP=$(sed -nE 's/^#define UTS_VERSION "#[0-9]+.* ((Sun|Mon|Tue|Wed|Thu|Fri|Sat) .*)"$/\1/p' "$header/utsversion.h")
[[ -n $KBUILD_BUILD_USER && -n $KBUILD_BUILD_HOST && -n $KBUILD_BUILD_TIMESTAMP ]]
unshare --user --map-root-user --mount --propagation private bash -euc '
    src=$1 obj=$2 private=$3 unit=$4 jobs=$5
    mount --bind "$src" "$src"
    mount -o remount,bind,ro "$src"
    mount --bind "$private/source/$unit" "$src/$unit"
    mount -o remount,bind,ro "$src/$unit"
    mount --bind "$private/obj" "$obj"
    make -C "$src" O="$obj" ARCH=arm64 -j"$jobs" Image
' bash "$src" "$obj" "$work" "$unit" "${JOBS:-$(getconf _NPROCESSORS_ONLN)}"

trial="$work/obj"
cmp "$obj/.config" "$trial/.config"
cmp "$header/utsrelease.h" "$trial/include/generated/utsrelease.h"
cmp "$header/utsversion.h" "$trial/include/generated/utsversion.h"
cmp "$obj/vmlinux.symvers" "$trial/vmlinux.symvers"
sha256sum --check "$base"
install -m 0644 "$trial/arch/arm64/boot/Image" "$stage/Image"
grep -aFq "$marker" "$stage/Image"
grep -aFq "NP545XLA Bluetooth GPIO170: APSS ownership enabled" "$stage/Image"
if cmp -s "$stage/Image" "$artifacts/Image"; then
    echo 'Trial Image matches the baseline' >&2; exit 1
fi
module="lib/modules/$release/kernel/drivers/gpu/drm/msm/msm.ko"
tar -xzOf "$artifacts/display-modules.tar.gz" "$module" > "$work/display.ko"
vermagic=$(modinfo -F vermagic "$work/display.ko")
[[ $vermagic == "$release "* ]]
grep -aFq "$vermagic" "$trial/vmlinux"
(cd "$stage"; sha256sum Image > SHA256SUMS)
{
    echo "Kernel release: $release"
    echo "GPIO170 ownership opt-in only; original GENI and Bluetooth drivers retained."
    echo "Runtime activation marker: $marker"
    echo "Module vermagic: $vermagic"
    grep MODVERSIONS "$trial/.config"
    echo "Baseline and candidate vmlinux.symvers are byte-identical."
    echo "Baseline and candidate .config, utsrelease.h and utsversion.h are byte-identical."
    echo "Patch, baseline and candidate SHA256:"
    sha256sum "$fix" "$btfix" "$artifacts"/{Image,kernel.config} "$obj/vmlinux.symvers" "$obj/Module.symvers"
    cat "$stage/SHA256SUMS"
} > "$stage/build-info.txt"
mv -nT "$stage" "$out"
[[ ! -e $stage ]]
cat "$out/build-info.txt"
