#!/usr/bin/env bash
# Append a one-shot passive experiment, using exactly the accepted kernel and DT.
set -euo pipefail
export LC_ALL=C PATH="/usr/sbin:/sbin:$PATH"
[[ $# == 2 && ! -e $2 && ! -L $2 ]] || {
    echo "Usage: $0 CAPTURED_CURRENT_EFI NEW_OUTPUT_DIR" >&2; exit 2
}
here=$(cd "$(dirname "$0")" && pwd)
efi=$(realpath "$1") out=$(realpath -m "$2")
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.passive-charge-boot.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
cp "$efi" "$stage/original.EFI"
python3 "$here/read-grub-menu.py" "$efi" > "$stage/base-menu"
python3 "$here/passive-charge-menu.py" "$stage"
bash "$here/build-daily-efi.sh" --config-ext4-once "$stage/trial-menu" "$stage/trial.EFI"
python3 "$here/read-grub-menu.py" "$stage/trial.EFI" | cmp - "$stage/trial-menu"
cp "$here/read-grub-menu.py" "$here/install-passive-charge-boot.sh" "$stage/"
cp "$here/debian-battery/np545-passive-battery-sample.service" "$stage/"
mkdir "$stage/tools" "$stage/tool-libs"
cp "$(command -v grub-file)" "$(command -v grub-editenv)" "$stage/tools/"
dm=$(ldd "$(command -v grub-file)" | awk '$1=="libdevmapper.so.1.02.1" {print $3}')
[[ -f $dm ]]
cp "$dm" "$stage/tool-libs/libdevmapper.so.1.02.1"
dpkg-query -W -f='${binary:Package} ${Version}\n' grub-common libdevmapper1.02.1 systemd > "$stage/tool-versions.txt"
(cd "$stage"; sha256sum original.EFI base-menu trial-menu trial.EFI metadata.json read-grub-menu.py install-passive-charge-boot.sh np545-passive-battery-sample.service tools/grub-file tools/grub-editenv tool-libs/libdevmapper.so.1.02.1 tool-versions.txt > SHA256SUMS)
mv -nT "$stage" "$out"
[[ ! -e $stage ]]
cat "$out/SHA256SUMS"
