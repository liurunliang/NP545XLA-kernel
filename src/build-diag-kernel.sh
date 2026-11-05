#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 ]]; then
    echo "Usage: $0 SRC_TREE BUILD_DIR OUTPUT_DIR" >&2
    exit 2
fi

repo=$(cd "$(dirname "$0")/.." && pwd)
source_tree=$(cd "$1" && pwd)
mkdir -p "$2" "$3"
build_dir=$(cd "$2" && pwd)
output_dir=$(cd "$3" && pwd)
commit=028ef9c96e96197026887c0f092424679298aae8
tar_sha=bb7f6d80b387c757b7d14bb93028fcb90f793c5c0d367736ee815a100b3891f0
fragment="$repo/configs/diag-v7.0.config"
board=sc8180xp-samsung-np545xla

if [[ -e "$source_tree/.git" ]]; then
    [[ $(git -C "$source_tree" rev-parse HEAD) == "$commit" ]] || {
        echo "Expected upstream Linux v7.0 at $commit" >&2
        exit 1
    }
elif [[ ! -f "$source_tree/.np545xla-source-sha256" ]] ||
     [[ $(awk 'NR == 1 { print $1 }' "$source_tree/.np545xla-source-sha256") != "$tar_sha" ]] ||
     [[ $(make -s --no-print-directory -C "$source_tree" kernelversion) != 7.0.0 ]]; then
    echo 'Expected a verified upstream linux-7.0.tar.xz source tree' >&2
    exit 1
fi

kmake=(make -C "$source_tree" O="$build_dir" ARCH=arm64)
if [[ -n ${CROSS_COMPILE:-} ]]; then
    kmake+=("CROSS_COMPILE=$CROSS_COMPILE")
fi
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN)}

cd "$build_dir"
"${kmake[@]}" defconfig
ARCH=arm64 "$source_tree/scripts/kconfig/merge_config.sh" -m -O "$build_dir" \
    "$build_dir/.config" "$fragment"
"${kmake[@]}" olddefconfig
while IFS= read -r setting; do
    if ! grep -Fxq "$setting" "$build_dir/.config"; then
        echo "Missing required built-in after olddefconfig: $setting" >&2
        exit 1
    fi
done < <(grep '^CONFIG_.*=y$' "$fragment")

# Compile the out-of-tree board against precisely the headers used by Image.
# Keep the kernel checkout untouched and skip all unrelated DTBs and modules.
"${CPP_FOR_DTS:-cpp}" -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
    -I "$source_tree/include" -I "$source_tree/arch/arm64/boot/dts/qcom" \
    "$repo/dts/$board.dts" -o "$build_dir/$board.dts.prep"
dtc -I dts -O dtb -o "$build_dir/$board.dtb" "$build_dir/$board.dts.prep"
"${kmake[@]}" -j"$jobs" Image
install -m 0644 "$build_dir/arch/arm64/boot/Image" "$output_dir/Image"
install -m 0644 "$build_dir/$board.dtb" "$output_dir/samsung.dtb"
install -m 0644 "$build_dir/.config" "$output_dir/kernel.config"
