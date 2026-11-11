#!/usr/bin/env bash
# Append an opt-in PM-debug entry to the current, physically captured USB menu.
set -euo pipefail
export LC_ALL=C PATH="/usr/sbin:/sbin:$PATH"
[[ $# == 3 && ! -e $3 && ! -L $3 ]] || {
    echo "Usage: $0 CURRENT_EFI PM_DEBUG_KERNEL_DIR NEW_OUTPUT_DIR" >&2; exit 2
}
here=$(cd "$(dirname "$0")" && pwd)
efi=$(realpath "$1") kernel=$(realpath "$2") out=$(realpath -m "$3")
echo "7ad52e7e7a2797a1c10f592378e3ebf8438d64f3501ebe486139a66ff11a46fa  $efi" | sha256sum --strict -c -
(cd "$kernel"; sha256sum --strict -c SHA256SUMS)
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.sleep-debug-boot.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
cp "$efi" "$stage/original.EFI"
cp "$kernel/Image" "$stage/Image"
python3 "$here/read-grub-menu.py" "$efi" > "$stage/base-menu"
python3 - "$stage" <<'PY'
import hashlib, json, re, sys
from pathlib import Path
w = Path(sys.argv[1])
base = (w/'base-menu').read_text()
image = hashlib.sha256((w/'Image').read_bytes()).hexdigest()
assert image == 'ffba40697b5364f0e48693e7b0f71bee10eec1284a4d6086664fb940a9188179'
assert 'sleep-debug' not in base and 'np545_pmdebug_once' not in base
def extract(pattern):
    matches = re.findall(pattern + r'.*?^\}', base, re.M | re.S)
    assert len(matches) == 1, pattern
    return matches[0]
boot = extract(r'^function bt_enable_boot \{')
prepare = extract(r'^function bt_enable_prepare \{')
entry = extract(r"^menuentry '[^\n]*' --id latest-media \{")
old = '163b71d2e6ae7deb2e0500de71d2b4639f1da80c68edb81a3477d1551e64735b'
addition = '\n\n'.join((boot, prepare, entry))
assert addition.count(old) == 3
addition = addition.replace('bt_enable_boot', 'pm_debug_boot').replace('bt_enable_prepare', 'pm_debug_prepare')
addition = addition.replace(f'/boot/np545xla-bluetooth-enable/Image-{old}', f'/boot/np545xla-sleep-debug/Image-{image}')
addition = addition.replace(f'/boot/bluetooth-enable-{old}.sum', f'/boot/sleep-debug-{image}.sum')
addition = addition.replace("Latest (Samsung)' --id latest-media", "Sleep debug - manual stages (Samsung)' --id sleep-debug")
addition = addition.replace('set diag_entry=Debian-latest-media', 'set diag_entry=Debian-sleep-debug')
addition = addition.replace(' loglevel=3 ', ' loglevel=6 np545.pmdebug=1 ')
assert old not in addition and addition.count('np545.pmdebug=1') == 1
once = '''
if search --no-floppy --file --set=pmdebug_esp /boot/np545-pmdebug.env; then
    set pmdebug_env="(${pmdebug_esp})/boot/np545-pmdebug.env"
    load_env --file "$pmdebug_env" np545_pmdebug_once
    if [ "$np545_pmdebug_once" = 1 ]; then
        set np545_pmdebug_once=0
        if save_env --file "$pmdebug_env" np545_pmdebug_once; then set default=sleep-debug; fi
    fi
fi
'''
trial = base + '\n' + addition + '\n' + once
assert trial[:len(base)] == base
(w/'trial-menu').write_text(trial)
path = f'/boot/np545xla-sleep-debug/Image-{image}'
(w/'Image.sum').write_text(f'{image}  {path}\n')
(w/'metadata.json').write_text(json.dumps({
    'base_efi': hashlib.sha256((w/'original.EFI').read_bytes()).hexdigest(),
    'image': image, 'image_path': path,
    'checksum_path': f'/boot/sleep-debug-{image}.sum',
    'dt_path': '/boot/daily-media-2661562ea2c05e2548a1cbb74cf0c70996d0aa31c9d9ce03c94225f9c51a1a25.dtb',
    'default_preserved': True, 'automatic_pm_test': False
}, indent=2) + '\n')
PY
bash "$here/build-daily-efi.sh" --config-ext4-once "$stage/trial-menu" "$stage/trial.EFI"
python3 "$here/read-grub-menu.py" "$stage/trial.EFI" | cmp - "$stage/trial-menu"
cp "$here/read-grub-menu.py" "$here/install-sleep-debug-boot.sh" "$stage/"
# The reflashed root omits grub-common and libdevmapper. Keep the two stock
# Debian tools and that library inside the package, without installing packages.
mkdir "$stage/tools" "$stage/tool-libs"
cp "$(command -v grub-file)" "$(command -v grub-editenv)" "$stage/tools/"
dm=$(ldd "$(command -v grub-file)" | awk '$1=="libdevmapper.so.1.02.1" {print $3}')
[[ -f $dm ]]
cp "$dm" "$stage/tool-libs/libdevmapper.so.1.02.1"
dpkg-query -W -f='${binary:Package} ${Version}\n' grub-common libdevmapper1.02.1 > "$stage/tool-versions.txt"
(cd "$stage"; sha256sum original.EFI Image Image.sum base-menu trial-menu trial.EFI metadata.json read-grub-menu.py install-sleep-debug-boot.sh tools/grub-file tools/grub-editenv tool-libs/libdevmapper.so.1.02.1 tool-versions.txt > SHA256SUMS)
mv -nT "$stage" "$out"
[[ ! -e $stage ]]
cat "$out/SHA256SUMS"
