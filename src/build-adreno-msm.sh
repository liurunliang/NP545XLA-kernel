#!/usr/bin/env bash
# Backport two A680 fixes in a private Linux build, leaving the USB baseline intact.
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
mkdir -p "$(dirname "$out")"
work=$(mktemp -d)
stage=$(mktemp -d "$(dirname "$out")/.adreno-msm.XXXXXXXX")
trap 'rm -rf "$work" "$stage"' EXIT
release=$(cat "$obj/include/config/kernel.release")
[[ $release == 7.0.0 ]]
cmp "$artifacts/Image" "$obj/arch/arm64/boot/Image"
cmp "$artifacts/kernel.config" "$obj/.config"
module=lib/modules/$release/kernel/drivers/gpu/drm/msm/msm.ko
tar -xzOf "$artifacts/display-modules.tar.gz" "$module" > "$work/original.ko"
cmp "$work/original.ko" "$obj/drivers/gpu/drm/msm/msm.ko"

# Share read-only upstream files. Make the three patched sources and the
# complete output directory private, including Kbuild's generated headers.
mkdir "$work/linux" "$work/obj" "$work/artifacts"
cp -as "$src/." "$work/linux/"
adreno=drivers/gpu/drm/msm/adreno
for name in a6xx_catalog.c a6xx_gpu.c adreno_gpu.c; do
    rm "$work/linux/$adreno/$name"
    cp "$src/$adreno/$name" "$work/linux/$adreno/$name"
done
(cd "$work/linux/$adreno"; sha256sum --check <<'HASHES'
3f7d10139a5e53e082c40b60828162f1971f0d491b02aecc9c09f60f69083d91  a6xx_catalog.c
2bce0cf4b40ea68d17b4efebb93cdfd450aa17b7e43e3a28b6c34373a949ddf2  a6xx_gpu.c
c3f298bd4ca5fa5771a1d58d5384c78967b833006f752fa766cd84165447383b  adreno_gpu.c
HASHES
)
for patch in linux-7.0-adreno-gbif.patch linux-7.0-adreno-a680-gmem.patch; do
    patch --batch --fuzz=0 -d "$work/linux" -p1 < "$repo/patches/$patch"
done
cp -a --reflink=auto "$obj/." "$work/obj/"
cp "$artifacts"/{Image,kernel.config} "$work/artifacts/"
bash "$repo/src/build-diag-display-modules.sh" "$work/linux" "$work/obj" "$work/artifacts"
tar -xzOf "$work/artifacts/display-modules.tar.gz" "$module" > "$stage/msm.ko"
if cmp -s "$stage/msm.ko" "$work/original.ko"; then
    echo "The trial module is identical to the original" >&2
    exit 1
fi
# Same already-installed dependency set, userspace OF aliases and imported symbols.
for key in vermagic depends alias; do
    diff -u <(modinfo -F "$key" "$work/original.ko" | sort) <(modinfo -F "$key" "$stage/msm.ko" | sort)
done
diff -u <(nm -u "$work/original.ko" | sort) <(nm -u "$stage/msm.ko" | sort)
cmp "$work/original.ko" "$obj/drivers/gpu/drm/msm/msm.ko"
(cd "$stage"; sha256sum msm.ko > SHA256SUMS)
readelf -n "$stage/msm.ko" | grep 'Build ID:' > "$stage/build-id.txt"
mv -nT "$stage" "$out"
[[ ! -e $stage ]]
cat "$out/SHA256SUMS" "$out/build-id.txt"
