#!/bin/bash
# Usage: build-diag-initramfs.sh PUBLIC_KEY OUTPUT_DIR (Debian arm64)
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [[ $# != 2 || ! -r "$1" ]]; then
    echo "Usage: $0 PUBLIC_KEY OUTPUT_DIR" >&2
    exit 2
fi
if [[ $(dpkg --print-architecture) != arm64 ]] || ! dpkg-query -W -f='${db:Status-Status}' busybox-static | grep -qx installed; then
    echo "Build in Debian arm64 with busybox-static installed." >&2
    exit 1
fi

public_key=$(realpath "$1")
source_dir=$(cd "$(dirname "$0")/diag-initramfs" && pwd)
mkdir -p "$2"
output_dir=$(realpath "$2")
work=$(mktemp -d)
output_tmp=$(mktemp "$output_dir/.initramfs.XXXXXX")
trap 'rm -rf "$work"; rm -f "$output_tmp"' EXIT
root=$work/root
mkdir -p "$root"/{bin,dev,proc,sys,run,tmp,etc,root/.ssh}
chmod 1777 "$root/tmp"
chmod 700 "$root/root" "$root/root/.ssh"

# Accept just one bare, supported OpenSSH public key. Strip its comment.
awk '
    NF {
        if (++count > 1 || $1 !~ /^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa)$/ || NF < 2) exit 1
        print $1, $2
    }
    END {if (count != 1) exit 1}
' "$public_key" > "$root/root/.ssh/authorized_keys" || { echo "Expected one public key." >&2; exit 1; }
ssh-keygen -lf "$root/root/.ssh/authorized_keys" >/dev/null
chmod 600 "$root/root/.ssh/authorized_keys"
printf 'root:x:0:0:Diagnostic shell:/root:/bin/sh\n' > "$root/etc/passwd"
printf 'root:*:19000:0:99999:7:::\n' > "$root/etc/shadow"
chmod 600 "$root/etc/shadow"
printf 'root:x:0:\n' > "$root/etc/group"
printf '/bin/sh\n' > "$root/etc/shells"

busybox_path=$(command -v busybox)
cp -L "$busybox_path" "$root/bin/busybox"
"$busybox_path" --list > "$work/applets"
for applet in sh ash mount cat hostname dmesg mkdir grep awk tr cut readlink sleep head tail modprobe wc \
    ip ifconfig udhcpc kill sed mv cp cmp ls sort date basename rm; do
    if ! grep -Fxq "$applet" "$work/applets"; then
        echo "Required busybox applet is missing: $applet" >&2
        exit 1
    fi
done
while IFS= read -r applet; do
    [[ $applet == busybox ]] || ln -s busybox "$root/bin/$applet"
done < "$work/applets"

# The kernel build supplies the module dependency closure and BusyBox indexes.
# Accept older standalone invocations without an explicit archive for baseline boots.
if [[ -n ${DIAG_DISPLAY_MODULES:-} ]]; then
    tar -xzf "$DIAG_DISPLAY_MODULES" -C "$root"
    [[ -s "$root/lib/modules/7.0.0/modules.dep" && -s "$root/lib/modules/7.0.0/modules.alias" ]] ||
        { echo "Display module archive lacks its Linux 7.0.0 indexes." >&2; exit 1; }
fi

# ldd resolves the interpreter and the complete dependency tree of each
# distribution binary. Keep their guest paths even on a merged-/usr builder.
for program in dropbear dropbearkey; do
    exe=$(command -v "$program")
    cp -L "$exe" "$root/bin/$program"
    ldd "$exe" > "$work/ldd"
    if grep -q 'not found' "$work/ldd"; then
        cat "$work/ldd" >&2
        exit 1
    fi
    while IFS= read -r lib; do
        install -D -m 755 "$lib" "$root$lib"
    done < <(awk '{for (i=1;i<=NF;i++) if ($i ~ /^\//) print $i}' "$work/ldd" | sort -u)
done

firmware_dir=${RTL_FIRMWARE_DIR:-/usr/lib/firmware/rtl_nic}
shopt -s nullglob
patches=("$firmware_dir"/rtl8153[a-c]-*.fw{,.xz,.zst})
if (( ${#patches[@]} )); then
    mkdir -p "$root/lib/firmware/rtl_nic"
    notice=${RTL_FIRMWARE_COPYRIGHT:-"$firmware_dir/../../../share/doc/firmware-realtek/copyright"}
    if [[ ! -r "$notice" ]]; then
        echo "Set RTL_FIRMWARE_COPYRIGHT to the packaged firmware-realtek copyright file." >&2
        exit 1
    fi
    install -D -m 644 "$notice" "$root/usr/share/doc/firmware-realtek/copyright"
    for patch in "${patches[@]}"; do
        name=${patch##*/}
        case $name in
            *.zst) zstd -dc "$patch" > "$root/lib/firmware/rtl_nic/${name%.zst}" ;;
            *.xz)  xz -dc "$patch" > "$root/lib/firmware/rtl_nic/${name%.xz}" ;;
            *)     cp -L "$patch" "$root/lib/firmware/rtl_nic/$name" ;;
        esac
    done
else
    echo "Warning: RTL8153 firmware patches absent; supply firmware-realtek or RTL_FIRMWARE_DIR." >&2
fi

install -m 755 "$source_dir/init" "$root/init"
install -m 755 "$source_dir/dhcp" "$root/bin/diag-dhcp"
install -m 755 "$source_dir/report" "$root/bin/diag-report"
(cd "$root"; find . -print0 | LC_ALL=C sort -z | cpio --null -o --format=newc --owner=0:0 --quiet) \
    | gzip -n > "$output_tmp"
chmod 644 "$output_tmp"
mv -f "$output_tmp" "$output_dir/initramfs.cpio.gz"
echo "Built $output_dir/initramfs.cpio.gz"
