#!/usr/bin/env bash
# Build the native eDP stack against the unmodified diagnostic Image and config.
set -euo pipefail
export LC_ALL=C
export PATH="/usr/sbin:$PATH"

if [[ $# != 3 ]]; then
    echo "Usage: $0 SRC_TREE BUILD_DIR OUTPUT_DIR (after build-diag-kernel.sh)" >&2
    exit 2
fi
source_tree=$(realpath "$1")
build_dir=$(realpath "$2")
artifacts=$(realpath "$3")
release=$(cat "$build_dir/include/config/kernel.release")
if [[ $release != 7.0.0 ]]; then
    echo "Expected the diagnostic Linux 7.0.0 build; found $release" >&2
    exit 1
fi

verify_kernel() {
    cmp "$build_dir/.config" "$artifacts/kernel.config"
    cmp "$build_dir/arch/arm64/boot/Image" "$artifacts/Image"
}
verify_kernel

# These three entry points and their link-time dependencies are pinned to the
# v7.0 diagnostic config. Pass them together so MODPOST checks all imports.
modules=(
    drivers/phy/qualcomm/phy-qcom-edp.ko
    drivers/gpu/drm/panel/panel-edp.ko
    drivers/gpu/drm/msm/msm.ko
    drivers/gpu/drm/clients/drm_client_lib.ko
    drivers/gpu/drm/display/drm_display_helper.ko
    drivers/gpu/drm/display/drm_dp_aux_bus.ko
    drivers/gpu/drm/drm_exec.ko
    drivers/gpu/drm/drm_gpuvm.ko
    drivers/gpu/drm/scheduler/gpu-sched.ko
    drivers/media/cec/core/cec.ko
    drivers/soc/qcom/llcc-qcom.ko
    drivers/soc/qcom/mdt_loader.ko
    drivers/soc/qcom/ocmem.ko
    drivers/soc/qcom/ubwc_config.ko
)
make -C "$source_tree" O="$build_dir" ARCH=arm64 KBUILD_MODPOST_WARN= \
    -j"${JOBS:-$(getconf _NPROCESSORS_ONLN)}" "${modules[@]}"
verify_kernel

stage=$(mktemp -d "$artifacts/.display-modules.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
modpath="lib/modules/$release"
moddir="$stage/$modpath"
for module in "${modules[@]}"; do
    install -D -m 644 "$build_dir/$module" "$moddir/kernel/$module"
done
printf '%s\n' "${modules[@]}" > "$moddir/modules.order"
cp "$build_dir/modules.builtin" "$build_dir/modules.builtin.modinfo" "$moddir/"
depmod -b "$stage" -e -F "$build_dir/System.map" "$release" 2>"$stage/depmod.log" || {
    cat "$stage/depmod.log" >&2
    exit 1
}
if [[ -s "$stage/depmod.log" ]]; then
    cat "$stage/depmod.log" >&2
    exit 1
fi

# Check all roots and ensure the archive only contains their resolved closure.
for entry in phy_qcom_edp panel_edp msm; do
    modprobe -d "$stage" -S "$release" --show-depends "$entry"
done > "$stage/loads"
sed -n 's|^insmod .*/kernel/||p' "$stage/loads" | sed 's/[[:space:]]*$//' | sort -u > "$stage/closure"
diff -u <(sort "$moddir/modules.order") "$stage/closure"

# The initramfs uses BusyBox modprobe. Include its two text indexes and the
# uncompressed modules, without host build links or kmod's binary caches.
tar --sort=name --mtime=@0 --numeric-owner --owner=0 --group=0 -C "$stage" \
    -czf "$stage/display-modules.tar.gz" "$modpath/kernel" "$modpath/modules.dep" "$modpath/modules.alias"
mv -f "$stage/display-modules.tar.gz" "$artifacts/display-modules.tar.gz"
