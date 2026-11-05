#!/usr/bin/env bash
# Boot the deliverable twice from USB. Neither guest gets a writable disk.
set -euo pipefail
export LC_ALL=C
umask 077

usage() {
    echo "Usage: $0 --image FILE --identity SSH_KEY --output NEW_DIR [--port 22222]" >&2
    echo "Optional environment: QEMU_ACCEL=hvf|tcg, QEMU_TIMEOUT=180, QEMU_FIRMWARE_DIR=DIR" >&2
}

die() { echo "Error: $*" >&2; exit 1; }
image=
identity=
output=
port=22222
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --image|--identity|--output|--port)
            (($# >= 2)) || { usage; exit 2; }
            case "$1" in
                --image) image=$2 ;;
                --identity) identity=$2 ;;
                --output) output=$2 ;;
                --port) port=$2 ;;
            esac
            shift 2 ;;
        *) usage; exit 2 ;;
    esac
done
[[ -f "$image" && -r "$image" ]] || die "choose a readable image file"
[[ -f "$identity" && -r "$identity" ]] || die "choose the SSH identity matching the embedded public key"
[[ -n "$output" && ! -e "$output" ]] || die "choose a new results directory"
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) || die "invalid host port"
timeout=${QEMU_TIMEOUT:-180}
[[ "$timeout" =~ ^[1-9][0-9]{0,4}$ ]] || die "invalid QEMU_TIMEOUT in seconds"
accel=${QEMU_ACCEL:-hvf}
case "$accel" in
    hvf) cpu=host ;;
    tcg) cpu=max ;;
    *) die "choose hvf or tcg" ;;
esac
qemu=$(command -v qemu-system-aarch64) || die "qemu-system-aarch64 is required"
firmware=${QEMU_FIRMWARE_DIR:-"$(dirname "$(dirname "$qemu")")/share/qemu"}
[[ -r "$firmware/edk2-aarch64-code.fd" && -r "$firmware/edk2-arm-vars.fd" ]] ||
    die "set QEMU_FIRMWARE_DIR to the directory containing the AArch64 code and ARM variable images"
mkdir -p "$(dirname "$output")"
mkdir "$output" || die "cannot create results directory"
scratch=$(mktemp -d)
pid=
stop_vm() {
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        pid=
    fi
}
cleanup() { stop_vm; rm -rf "$scratch"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_vm() {
    local mode=$1
    local vars="$scratch/$mode.fd"
    local code="$firmware/edk2-aarch64-code.fd"
    local -a network
    if [[ "$mode" == online ]]; then
        network=(-netdev "user,id=wired,restrict=on,hostfwd=tcp:127.0.0.1:$port-:2222" -device virtio-net-pci,netdev=wired)
    else
        network=(-nic none)
    fi
    serial="$output/$mode.serial.log"
    cp "$firmware/edk2-arm-vars.fd" "$vars"
    "$qemu" -nodefaults -machine virt,acpi=on,gic-version=3 -accel "$accel" -cpu "$cpu" \
        -m 1024 -smp 2 -display none -monitor none -serial "file:$serial" -no-reboot \
        -smbios type=1,manufacturer=QEMU,product=NP545XLA-DIAG-QEMU \
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=${code//,/,,}" \
        -drive "if=pflash,format=raw,unit=1,file=${vars//,/,,}" \
        -drive "if=none,id=stick,format=raw,readonly=on,file=${image//,/,,}" \
        -device qemu-xhci,id=xhci -device usb-storage,bus=xhci.0,drive=stick,removable=on,bootindex=1 \
        "${network[@]}" >"$output/$mode.qemu.log" 2>&1 &
    pid=$!
    deadline=$((SECONDS + timeout))
}

await_serial() {
    local marker=$1
    until grep -aFq "$marker" "$serial" 2>/dev/null; do
        if grep -aFq 'GRUB STOP:' "$serial" 2>/dev/null; then
            die "GRUB stopped before '$marker' (see $serial)"
        fi
        kill -0 "$pid" 2>/dev/null || die "QEMU exited before '$marker' (see $output)"
        ((SECONDS < deadline)) || die "timed out waiting for '$marker' in $serial"
        sleep 1
    done
}

check_acpi_handoff() {
    # Inspect the trace in order, after the guest has reached userspace.
    awk '
        BEGIN {
            phase = 1
            marker[1] = "GRUB ACPI: media "
            marker[2] = "GRUB ACPI: loading Linux"
            marker[3] = "GRUB ACPI: Linux accepted"
            marker[4] = "GRUB ACPI: initrd registered"
            marker[5] = "GRUB ACPI: before EFI boot"
            marker[6] = "NP545XLA DIAG"
        }
        phase <= 6 && index($0, marker[phase]) { phase++ }
        END {
            if (phase <= 6) {
                print "Missing or out-of-order marker: " marker[phase] > "/dev/stderr"
                exit 1
            }
        }
    ' "$serial" || die "default ACPI handoff check failed in $serial"
}

start_vm offline
for marker in "NP545XLA DIAG" "Entry: acpi" "Firmware: ACPI" "Network: no matching NIC" "USB storage: whole devices sda(" "Disk mounts: none"; do
    await_serial "$marker"
done
check_acpi_handoff
stop_vm
echo "Default ACPI handoff and offline console passed."

start_vm online
for marker in "Firmware: ACPI" "Host key: SHA256:" "SSH: ssh -p 2222 root@"; do
    await_serial "$marker"
done
check_acpi_handoff
fingerprint=$(sed -nE 's/.*Host key: (SHA256:[A-Za-z0-9+\/]+).*/\1/p' "$serial" | tail -n 1)
[[ -n "$fingerprint" ]] || die "missing Ed25519 fingerprint in $serial"
known_hosts="$output/known_hosts"
until ssh-keyscan -T 3 -p "$port" -t ed25519 127.0.0.1 >"$known_hosts" 2>/dev/null && [[ -s "$known_hosts" ]]; do
    ((SECONDS < deadline)) || die "no SSH host key on loopback port $port"
    sleep 1
done
received=$(ssh-keygen -E sha256 -lf "$known_hosts" | awk '{print $2}')
[[ "$received" == "$fingerprint" ]] || die "SSH key differs from the fingerprint on the guest console"
ssh_opts=(-F /dev/null -p "$port" -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes
          -o PreferredAuthentications=publickey -o HostKeyAlgorithms=ssh-ed25519 -o StrictHostKeyChecking=yes
          -o "UserKnownHostsFile=\"$known_hosts\"" -o GlobalKnownHostsFile=/dev/null)
report="$output/report.txt"
ssh "${ssh_opts[@]}" -i "$identity" root@127.0.0.1 \
    'test "$(id -u)" = 0 && test "$(uname -m)" = aarch64 && grep -Fq "Linux version" /run/diagnostics/boot-dmesg.txt && cat /run/diagnostics/report.txt' >"$report"
grep -Fq "Firmware: ACPI" "$report" && grep -Fq "Disk mounts: none" "$report" ||
    die "the report lacks the ACPI or disk-mount confirmation"
grep -Fxq 'Native display modules: not requested' "$report" ||
    die "the default ACPI entry attempted to load the Samsung display modules"

ssh-keygen -q -t ed25519 -N '' -f "$scratch/unrelated-key"
if ssh "${ssh_opts[@]}" -o IdentityAgent=none -i "$scratch/unrelated-key" root@127.0.0.1 true \
        >"$output/rejected-key.log" 2>&1; then
    die "the guest accepted an unrelated SSH key"
fi
grep -Fq "Permission denied" "$output/rejected-key.log" || die "unrelated-key test failed before authentication"
stop_vm
echo "Online DHCP, SSH fingerprint, authorized key, rejected key and RAM diagnostics passed. Results in $output"
