#!/usr/bin/env bash
# Run the probe as a native client on an isolated, virtual Wayland output.
set -euo pipefail
if [[ ${1:-} == --client ]]; then
    shift
    probe=$1
    target=$2
    unset DISPLAY  # Cage can also advertise a private Xwayland display.
    [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]
    matched=false
    for fd in /proc/$PPID/fd/*; do
        dev=$(readlink "$fd") || continue
        case $dev in
            /dev/input/*) echo "Unexpected physical input: $dev" >&2; exit 1 ;;
            /dev/dri/*)
                echo "Compositor DRM descriptor: $dev"
                if [[ $target != software && $fd -ef $target ]]; then matched=true; fi
                ;;
        esac
    done
    if [[ $target != software && $matched != true ]]; then
        echo "Compositor did not retain the requested render node" >&2
        exit 1
    fi
    "$probe" wayland "$target"
    touch "$XDG_RUNTIME_DIR/client-passed"
    exit 0
fi

if [[ $# != 2 || ! -x $1 ]]; then
    echo "Usage: $0 /path/to/probe-debian-gpu /dev/dri/renderDNNN|software" >&2
    exit 2
fi
probe=$(realpath "$1")
target=$2
runtime=$(mktemp -d)
trap 'rm -rf "$runtime"' EXIT
if [[ $target == software ]]; then
    renderer=(WLR_RENDERER=pixman LIBGL_ALWAYS_SOFTWARE=1)
else
    target=$(realpath -e "$target")
    [[ -c $target && ${target##*/} == renderD* ]] || exit 2
    renderer=(WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE="$target")
fi
env -i PATH=/usr/bin:/bin HOME="$HOME" XDG_RUNTIME_DIR="$runtime" \
    WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 "${renderer[@]}" \
    timeout -k 2s 45s cage -- "$(realpath "$0")" --client "$probe" "$target"
[[ -e $runtime/client-passed ]] || { echo 'Wayland client did not finish' >&2; exit 1; }
echo "PASS: private Wayland output ($target)"
