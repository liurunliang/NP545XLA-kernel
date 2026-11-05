#!/usr/bin/env bash
# Build on Debian arm64 as root, in a native Linux filesystem.
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
usage() {
    echo "Usage: $0 --work-dir DIR [--prepare-only | --public-key FILE --uuid UUID --modules FILE --kernel-build DIR --firmware-deb FILE --output EXT4_FILE]" >&2
}
work= key= uuid= modules= kernel_build= firmware= output= prepare=no
while (($#)); do
    case "$1" in
        --prepare-only) prepare=yes; shift ;;
        --work-dir|--public-key|--uuid|--modules|--kernel-build|--firmware-deb|--output)
            (($# >= 2)) || { usage; exit 2; }
            case $1 in
                --work-dir) work=$2 ;; --public-key) key=$2 ;; --uuid) uuid=$2 ;;
                --modules) modules=$2 ;; --kernel-build) kernel_build=$2 ;;
                --firmware-deb) firmware=$2 ;; --output) output=$2 ;;
            esac
            shift 2 ;;
        *) usage; exit 2 ;;
    esac
done
[[ -n $work ]] || { usage; exit 2; }
if (( EUID != 0 )) || [[ $(dpkg --print-architecture) != arm64 ]]; then
    echo "Run in a native Debian arm64 guest as root." >&2; exit 1
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$work"
work=$(realpath "$work")
exec 9>"$work/.rootfs.lock"
flock 9
stage=$(mktemp -d "$work/rootfs.XXXXXXXX")
image_tmp=
trap 'rm -rf "$stage"; if [[ -n $image_tmp ]]; then rm -f "$image_tmp"; fi' EXIT

# A reusable base contains no login key, host keys or machine identity.
# Bump the cache revision when changing packages, archive sources or hooks.
base="$work/debian-trixie-arm64-base-v2.tar"
packages=apt,ca-certificates,curl,dbus,systemd-sysv,systemd-resolved,systemd-timesyncd,udev,kmod,openssh-server,sudo,iproute2,iputils-ping,login,passwd,util-linux,e2fsprogs
if [[ ! -s $base ]]; then
    mmdebstrap --mode=root --variant=minbase --architectures=arm64 --include="$packages" \
        --aptopt='Acquire::Retries "3"' \
        --customize-hook='rm -f "$1"/etc/ssh/ssh_host_* "$1"/var/lib/dbus/machine-id "$1"/var/lib/systemd/random-seed; printf "uninitialized\n" > "$1"/etc/machine-id' \
        trixie "$stage/base.tar" \
        'deb https://deb.debian.org/debian trixie main' \
        'deb https://deb.debian.org/debian trixie-updates main' \
        'deb https://deb.debian.org/debian-security trixie-security main'
    mv "$stage/base.tar" "$base"
fi
if [[ $prepare == yes ]]; then
    echo "Prepared $base"
    exit
fi
[[ -r $key && -r $modules && -d $kernel_build && -r $firmware && -n $output ]] || { usage; exit 2; }
[[ $uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || {
    echo "Expected an ext4 filesystem UUID." >&2; exit 1
}
key=$(realpath "$key")
modules=$(realpath "$modules")
kernel_build=$(realpath "$kernel_build")
firmware=$(realpath "$firmware")
mkdir -p "$(dirname "$output")"
# Build an ordinary file: this script must never receive a device target.
if [[ -e $output && ! -f $output || -L $output ]]; then
    echo "Expected an ordinary output image file: $output" >&2; exit 1
fi
root="$stage/tree"
mkdir -p "$root" "$stage/modules"
tar --xattrs -xf "$base" -C "$root"
tar -xzf "$modules" -C "$stage/modules"
modroot="$stage/modules/lib/modules/7.0.0"
[[ -s "$modroot/modules.dep" && -s "$modroot/modules.alias" ]] || {
    echo "Expected display modules from build-diag-display-modules.sh (Linux 7.0.0)" >&2; exit 1
}
artifacts=$(dirname "$modules")
cmp "$kernel_build/arch/arm64/boot/Image" "$artifacts/Image"
cmp "$kernel_build/.config" "$artifacts/kernel.config"
# The recovery archive carries just the loadable closure. Populate kmod's
# indices for that closure plus the built-ins from this exact kernel build.
cp "$kernel_build/modules.builtin" "$kernel_build/modules.builtin.modinfo" "$modroot/"
cut -d: -f1 "$modroot/modules.dep" | sort > "$modroot/modules.order"
(cd "$modroot" && find kernel -type f -name '*.ko' | sort) | diff "$modroot/modules.order" -
install -d "$root/usr/lib/modules"
cp -a "$modroot" "$root/usr/lib/modules/"
depmod -b "$root" -e -F "$kernel_build/System.map" 7.0.0 2>"$stage/depmod.log"
if [[ -s $stage/depmod.log ]]; then cat "$stage/depmod.log" >&2; exit 1; fi
for module in phy_qcom_edp panel_edp msm; do
    [[ $(modinfo -b "$root" -k 7.0.0 -F vermagic "$module") == 7.0.0\ * ]] || {
        echo "Wrong kernel module: $module" >&2; exit 1
    }
done
echo "925755a9b0891c7dc39bbb73d28ab8f7193d37303b5022e8bc9d458b9b4aaa4e  $firmware" | sha256sum --check --status
cp "$firmware" "$root/tmp/np545xla-firmware.deb"
chroot "$root" dpkg --install /tmp/np545xla-firmware.deb
rm -f "$root/tmp/np545xla-firmware.deb"
install -d "$root/usr/share/doc/np545xla-debian"
chroot "$root" dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' \
    > "$root/usr/share/doc/np545xla-debian/packages.tsv"

chroot "$root" useradd --create-home --shell /bin/bash --groups sudo liurunliang
ssh_dir="$root/home/liurunliang/.ssh"
install -d -m 0700 "$ssh_dir"
# A single bare public key only. Discard its comment and reject key options.
awk 'NF {
    if (++count > 1 || $1 !~ /^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa)$/ || NF < 2) exit 1
    print $1, $2
} END {if (count != 1) exit 1}' "$key" > "$ssh_dir/authorized_keys"
ssh-keygen -lf "$ssh_dir/authorized_keys" >/dev/null
chmod 0600 "$ssh_dir/authorized_keys"
chroot "$root" chown -R liurunliang:liurunliang /home/liurunliang/.ssh
printf 'liurunliang ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$root/etc/sudoers.d/90-np545xla"
chmod 0440 "$root/etc/sudoers.d/90-np545xla"
chroot "$root" visudo -c >/dev/null

install -d "$root/etc/ssh/sshd_config.d" "$root/etc/systemd/system/ssh.service.d"
cat > "$root/etc/ssh/sshd_config.d/10-np545xla.conf" <<'CONF'
Port 2223
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
AllowUsers liurunliang
CONF
printf '[Unit]\nRequires=np545xla-ssh-hostkeys.service\nAfter=np545xla-ssh-hostkeys.service\n' \
    > "$root/etc/systemd/system/ssh.service.d/hostkeys.conf"
# No generated server secret or machine identifier is shipped on the USB.
test -z "$(find "$root/etc/ssh" -maxdepth 1 -name 'ssh_host_*' -print -quit)"
printf 'uninitialized\n' > "$root/etc/machine-id"
ln -sfn /etc/machine-id "$root/var/lib/dbus/machine-id"
printf 'np545xla-debian\n' > "$root/etc/hostname"
cat > "$root/etc/hosts" <<'HOSTS'
127.0.0.1 localhost
127.0.1.1 np545xla-debian
::1 localhost ip6-localhost ip6-loopback
HOSTS
printf 'UUID=%s / ext4 defaults,errors=remount-ro 0 1\n' "$uuid" > "$root/etc/fstab"
install -d "$root/etc/systemd/system-generators"
ln -sfn /dev/null "$root/etc/systemd/system-generators/systemd-gpt-auto-generator"

install -d "$root/etc/systemd/network" "$root/etc/modprobe.d" "$root/etc/systemd/journald.conf.d"
cat > "$root/etc/systemd/network/20-np545xla-wired.network" <<'NETWORK'
[Match]
Driver=r8152 cdc_ether virtio_net

[Link]
RequiredForOnline=no

[Network]
DHCP=ipv4
IPv6AcceptRA=yes

[DHCPv4]
ClientIdentifier=mac
NETWORK
ln -sfn ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
cat > "$root/etc/modprobe.d/np545xla-display.conf" <<'MODPROBE'
# udev may resolve the OF aliases before the display service runs.
softdep msm pre: phy_qcom_edp panel_edp
options msm separate_gpu_kms=1
MODPROBE
# Bound userspace logs in RAM. The keyboard can produce thousands of identical
# kernel messages per second; dmesg still exposes the kernel's own ring buffer.
printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=32M\nReadKMsg=no\n' > "$root/etc/systemd/journald.conf.d/90-np545xla.conf"
# The hardware can start at 1970. timesyncd uses this file's mtime as the
# initial floor and maintains it on persistent storage on later boots.
chroot "$root" install -d -o systemd-timesync -g systemd-timesync /var/lib/systemd/timesync
chroot "$root" install -m 0644 -o systemd-timesync -g systemd-timesync /dev/null /var/lib/systemd/timesync/clock
# Keep regular system/security updates available, including Realtek firmware.
cat > "$root/etc/apt/sources.list" <<'SOURCES'
deb https://deb.debian.org/debian trixie main non-free-firmware
deb https://deb.debian.org/debian trixie-updates main non-free-firmware
deb https://deb.debian.org/debian-security trixie-security main non-free-firmware
SOURCES
install -Dm 0755 "$repo/src/debian-rootfs/login-status" "$root/usr/local/sbin/np545xla-login-status"
install -m 0644 "$repo"/src/debian-rootfs/*.service "$root/etc/systemd/system/"
systemctl --root="$root" mask --quiet ssh.socket
systemctl --root="$root" enable --quiet systemd-networkd.service systemd-resolved.service systemd-timesyncd.service ssh.service \
    np545xla-ssh-hostkeys.service np545xla-display.service np545xla-login-status.service getty@tty1.service
systemctl --root="$root" disable --quiet systemd-networkd-wait-online.service

image_tmp=$(mktemp "$(dirname "$output")/.np545xla-ext4.XXXXXXXX")
truncate -s 12G "$image_tmp"
mke2fs -q -F -t ext4 -L NP545_DEBIAN -U "$uuid" -m 1 -d "$root" "$image_tmp"
e2fsck -fn "$image_tmp"
[[ $(blkid -s UUID -o value "$image_tmp") == "${uuid,,}" ]]
chmod 0644 "$image_tmp"
mv -f "$image_tmp" "$output"
image_tmp=
echo "Built $output ($uuid)"
