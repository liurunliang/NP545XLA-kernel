#!/usr/bin/env bash
# Fetch the two A680 microcode files from authenticated Debian metadata.
# Keep them outside the kernel firmware search path until the board trial.
set -euo pipefail
export LC_ALL=C
if [[ $# != 1 || -e $1 || -L $1 ]]; then
    echo "Usage (Debian): $0 NEW_OUTPUT_DIRECTORY" >&2
    exit 2
fi
out=$(realpath -m "$1")
parent=$(dirname "$out")
mkdir -p "$parent"
work=$(mktemp -d)
stage=$(mktemp -d "$parent/.adreno-fw.XXXXXXXX")
trap 'rm -rf "$work" "$stage"' EXIT
cd "$work"
mkdir -p lists/partial
echo 'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian trixie-backports non-free-firmware' > backports.list
opts=(-o "Dir::Etc::sourcelist=$work/backports.list" -o Dir::Etc::sourceparts=-
      -o "Dir::State::Lists=$work/lists" -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=)
apt-get "${opts[@]}" update --error-on=any
name=firmware-qcom-soc
version=$(apt-cache "${opts[@]}" madison "$name" | awk -F'|' 'NR==1 {gsub(/ /,"",$2); print $2}')
[[ -n $version ]]
apt-get "${opts[@]}" download "$name=$version"
debs=("$name"_*.deb)
[[ ${#debs[@]} == 1 && $(dpkg-deb -f "${debs[0]}" Package) == "$name" &&
   $(dpkg-deb -f "${debs[0]}" Version) == "$version" ]]
expected=$(apt-cache "${opts[@]}" show "$name=$version" | awk '/^SHA256:/ {print $2; exit}')
[[ $expected =~ ^[0-9a-f]{64}$ ]]
printf '%s  %s\n' "$expected" "${debs[0]}" | sha256sum -c -
dpkg-deb -x "${debs[0]}" extracted
mkdir "$stage/qcom"
for file in a630_sqe.fw a640_gmu.bin; do
    src="extracted/usr/lib/firmware/qcom/$file"
    [[ -s $src && ! -L $src ]]
    install -m 0644 "$src" "$stage/qcom/$file"
done
cp extracted/usr/share/doc/firmware-qcom-soc/copyright "$stage/debian-copyright"
printf 'Source: Debian trixie-backports/non-free-firmware\nPackage: %s\nVersion: %s\nDeb SHA256: %s\n' \
    "$name" "$version" "$expected" > "$stage/source.txt"
(cd "$stage"; sha256sum qcom/* > SHA256SUMS)
mv -T --no-clobber "$stage" "$out"
[[ ! -e $stage ]]
cat "$out/source.txt" "$out/SHA256SUMS"
