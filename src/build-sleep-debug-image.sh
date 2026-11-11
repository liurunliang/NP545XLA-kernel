#!/usr/bin/env bash
# Build an isolated PM-debug Image retaining the accepted lid and Bluetooth fixes.
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
work=$(mktemp -d "$(dirname "$out")/.pm-debug-work.XXXXXXXX")
stage=$(mktemp -d "$(dirname "$out")/.pm-debug-stage.XXXXXXXX")
trap 'rm -rf "$work" "$stage"' EXIT
base="$work/baseline.sha256"
sha256sum "$src/$unit" "$obj"/{arch/arm64/boot/Image,.config,Module.symvers,vmlinux.symvers,drivers/pinctrl/qcom/pinctrl-msm.o} > "$base"
mkdir -p "$work/source/$(dirname "$unit")" "$work/obj"
cp "$src/$unit" "$work/source/$unit"
patch --batch --fuzz=0 -p1 -d "$work/source" < "$fix"
patch --batch --fuzz=0 -p1 -d "$work/source" < "$btfix"
cp -a --reflink=auto "$obj/." "$work/obj/"
"$src/scripts/config" --file "$work/obj/.config" --enable PM_DEBUG \
    --disable PM_ADVANCED_DEBUG --disable PM_TEST_SUSPEND --disable DPM_WATCHDOG

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
    make -C "$src" O="$obj" ARCH=arm64 olddefconfig
    make -C "$src" O="$obj" ARCH=arm64 -j"$jobs" Image
' bash "$src" "$obj" "$work" "$unit" "${JOBS:-$(getconf _NPROCESSORS_ONLN)}"

trial="$work/obj"
# Only PM_DEBUG and its dependent PM_SLEEP_DEBUG may change semantically.
# New disabled symbols from Kconfig are equivalent to absent disabled symbols.
python3 - "$obj/.config" "$trial/.config" "$stage/config-delta.json" <<'PY_CONFIG'
import json, re, sys
from pathlib import Path
def config(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        if line.startswith('CONFIG_'):
            key, value = line.split('=', 1)
            result[key] = value
        elif (match := re.fullmatch(r'# (CONFIG_\w+) is not set', line)):
            result[match[1]] = 'n'
    return result
before, after = map(config, sys.argv[1:3])
delta = {k: [before.get(k, 'n'), after.get(k, 'n')]
         for k in sorted(before.keys() | after.keys())
         if before.get(k, 'n') != after.get(k, 'n')}
assert delta == {'CONFIG_PM_DEBUG': ['n', 'y'], 'CONFIG_PM_SLEEP_DEBUG': ['n', 'y']}, delta
Path(sys.argv[3]).write_text(json.dumps(delta, indent=2) + '\n')
PY_CONFIG
cmp "$header/utsrelease.h" "$trial/include/generated/utsrelease.h"
cmp "$header/utsversion.h" "$trial/include/generated/utsversion.h"
# Existing module-visible symbols must retain their full signatures. Any new
# exports are recorded for review; this does not claim physical module acceptance.
python3 - "$obj/vmlinux.symvers" "$trial/vmlinux.symvers" "$stage/symbol-delta.json" <<'PY_SYMBOLS'
import json, sys
from pathlib import Path
def symbols(path):
    rows = [line.split() for line in Path(path).read_text().splitlines()]
    return {row[1]: row for row in rows}
before, after = map(symbols, sys.argv[1:3])
missing = sorted(before.keys() - after.keys())
changed = sorted(k for k in before.keys() & after.keys() if before[k] != after[k])
assert not missing and not changed, {'missing': missing, 'changed': changed}
Path(sys.argv[3]).write_text(json.dumps({'existing_exports': len(before),
    'new_exports': {k: after[k] for k in sorted(after.keys() - before.keys())}}, indent=2) + '\n')
PY_SYMBOLS
sha256sum --check "$base"
install -m 0644 "$trial/arch/arm64/boot/Image" "$stage/Image"
install -m 0644 "$trial/.config" "$stage/kernel.config"
nm --defined-only "$trial/vmlinux" | awk '$3 ~ /^pm_(test_level|debug_messages_on|print_times)$/ { print }' > "$stage/debug-symbols.txt"
grep -Eq '[[:space:]]pm_test_level$' "$stage/debug-symbols.txt"
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
(cd "$stage"; sha256sum Image kernel.config config-delta.json symbol-delta.json debug-symbols.txt > SHA256SUMS)
{
    echo "Kernel release: $release"
    echo "PM_DEBUG and PM_SLEEP_DEBUG enabled; no automatic boot-time suspend test or panic watchdog."
    echo "Accepted GPIO50 and opt-in GPIO170 fixes retained. Original drivers retained."
    echo "Runtime activation marker: $marker"
    echo "Module vermagic: $vermagic"
    grep MODVERSIONS "$trial/.config"
    echo "All existing core export signatures retained; additions recorded in symbol-delta.json."
    echo "Only two PM debug options changed; utsrelease.h and utsversion.h are byte-identical."
    echo "Physical boot, driver loading and PM test-mode execution remain unverified."
    echo "Patch, baseline and candidate SHA256:"
    sha256sum "$fix" "$btfix" "$artifacts"/{Image,kernel.config} "$obj/vmlinux.symvers" "$obj/Module.symvers"
    cat "$stage/SHA256SUMS"
} > "$stage/build-info.txt"
mv -nT "$stage" "$out"
[[ ! -e $stage ]]
cat "$out/build-info.txt"
