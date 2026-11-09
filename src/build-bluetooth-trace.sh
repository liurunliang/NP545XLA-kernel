#!/usr/bin/env bash
# Build one opt-in diagnostic module without changing the accepted build tree.
set -euo pipefail
export LC_ALL=C PATH="/usr/sbin:/sbin:$PATH"
[[ ( $# == 4 || ( $# == 5 && $5 == --initial-version-probe ) ) &&
   ! -e $4 && ! -L $4 && $(dpkg --print-architecture) == arm64 ]] || {
    echo "Usage: $0 LINUX_SOURCE KERNEL_BUILD DIAG_ARTIFACTS NEW_OUTPUT_DIR [--initial-version-probe]" >&2; exit 2; }
probe=${5:-}
repo=$(cd "$(dirname "$0")/.." && pwd)
src=$(realpath "$1"); obj=$(realpath "$2"); artifacts=$(realpath "$3")
out=$(realpath -m "$4")
unit=drivers/bluetooth/hci_qca.c
module=drivers/bluetooth/hci_uart.ko
fix="$repo/patches/linux-7.0-qca6390-startup-trace.patch"
[[ $(cat "$obj/include/config/kernel.release") == 7.0.0 ]]
[[ $(readlink -f "$obj/source") == "$src" ]]
cmp "$artifacts/kernel.config" "$obj/.config"
cmp "$artifacts/Image" "$obj/arch/arm64/boot/Image"
(cd "$src"; echo "2874b18365317774d93979395c469f7a26961fb3aabc0282775d319878e3bd34  $unit" | sha256sum --check)
mkdir -p "$(dirname "$out")"
work=$(mktemp -d)
stage=$(mktemp -d "$(dirname "$out")/.bluetooth-trace.XXXXXXXX")
trap 'rm -rf "$work" "$stage"' EXIT
sha256sum "$src/$unit" "$obj/$module" "$obj"/{.config,Module.symvers,arch/arm64/boot/Image} > "$work/baseline.sha256"
mkdir -p "$work/source/$(dirname "$unit")" "$work/obj"
cp "$src/$unit" "$work/source/$unit"
patch --batch --fuzz=0 -p1 -d "$work/source" < "$fix"
if [[ -n $probe ]]; then
    probe_fix="$repo/patches/linux-7.0-qca6390-initial-version-probe.patch"
    patch --batch --fuzz=0 -p1 -d "$work/source" < "$probe_fix"
fi
cp -a --reflink=auto "$obj/." "$work/obj/"

# Reuse the private mount-namespace build used by the lid trial. The original
# source and objects keep their paths for Kbuild, but are never modified.
unshare --user --map-root-user --mount --propagation private bash -euc '
    src=$1 obj=$2 private=$3 unit=$4 module=$5 jobs=$6
    mount --bind "$src" "$src"
    mount -o remount,bind,ro "$src"
    mount --bind "$private/source/$unit" "$src/$unit"
    mount -o remount,bind,ro "$src/$unit"
    mount --bind "$private/obj" "$obj"
    # Single-module modpost does not import symbols from the other Bluetooth
    # modules. Use the same dependency targets as the existing private build.
    make -C "$src" O="$obj" ARCH=arm64 -j"$jobs" "$module" \
        net/bluetooth/bluetooth.ko drivers/bluetooth/{btqca,btbcm}.ko \
        drivers/power/sequencing/pwrseq-qcom-wcn.ko net/rfkill/rfkill.ko \
        crypto/{ecdh_generic,ecc,cmac,aes,ccm,ctr,sha256}.ko
' bash "$src" "$obj" "$work" "$unit" "$module" "${JOBS:-$(getconf _NPROCESSORS_ONLN)}"

cmp "$obj/.config" "$work/obj/.config"
cmp "$obj/include/generated/utsrelease.h" "$work/obj/include/generated/utsrelease.h"
[[ $(modinfo -F vermagic "$obj/$module") == "$(modinfo -F vermagic "$work/obj/$module")" ]]
sha256sum --check "$work/baseline.sha256"
install -m644 "$work/obj/$module" "$stage/hci_uart.ko"
modinfo -p "$stage/hci_uart.ko" | grep -F 'qca_startup_trace:'
grep -aqF 'QCA_STARTUP' "$stage/hci_uart.ko"
if [[ -n $probe ]]; then
    modinfo -p "$stage/hci_uart.ko" | grep -F 'qca_initial_version_only:'
    modinfo -p "$stage/hci_uart.ko" | grep -F 'qca_initial_rts_wake:'
fi
if cmp -s "$stage/hci_uart.ko" "$obj/$module"; then
    echo 'Trace module unexpectedly matches the original' >&2; exit 1
fi
{
    echo "Kernel release: 7.0.0"
    echo "Module vermagic: $(modinfo -F vermagic "$stage/hci_uart.ko")"
    echo 'Activation: private hci_uart module with qca_startup_trace=1'
    echo 'Scope: first 64 UART chunks until version discovery; at most 64 bytes per chunk'
    echo 'TX_DEQUEUE records the driver queue, not physical pin transmission.'
    echo 'serdev_reported is not a measurement of the wire baud rate.'
    echo 'Baseline source, Image, module, configuration and symbols verified unchanged.'
    if [[ -n $probe ]]; then
        echo 'Additional parameter: qca_initial_version_only=1 on NP545XLA QCA6390 only'
        echo 'One initial-rate version query; no FC48, firmware download or scan initialization.'
        echo 'Optional qca_initial_rts_wake=1 adds one 5 ms RTS deassert/assert timing probe.'
        echo 'Returns an initialization error even after a successful diagnostic query.'
        sha256sum "$probe_fix"
    fi
    sha256sum "$fix" "$artifacts/kernel.config" "$obj/$module"
} > "$stage/build-info.txt"
(cd "$stage"; sha256sum hci_uart.ko build-info.txt > SHA256SUMS)
mv -nT "$stage" "$out"; [[ ! -e $stage ]]
cat "$out/build-info.txt"
