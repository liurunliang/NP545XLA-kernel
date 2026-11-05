#!/usr/bin/env bash
# Create a separate Debian DTB for the Samsung SSTP0001 touchpad.
set -euo pipefail
if [[ $# != 2 || ! -f $1 || -e $2 || -L $2 ]]; then
    echo "Usage: $0 DEBIAN-SAMSUNG.dtb NEW-PROBE.dtb" >&2
    exit 2
fi
base=$1
output=$2
qup=/soc@0/geniqup@8c0000
touchbus="$qup/i2c@880000"
ec="$qup/i2c@884000/touchpad@62"
ufs=/soc@0/ufshc@1d84000
[[ $(fdtget -t s "$base" / compatible) == 'samsung,np545xla qcom,sc8180x' &&
   $(fdtget -t s "$base" "$ufs" status) == disabled &&
   $(fdtget -t s "$base" "$touchbus" compatible) == qcom,geni-i2c &&
   $(fdtget -t s "$base" "$touchbus" status) == okay &&
   $(fdtget -t x "$base" "$ec" reg) == 62 ]] || {
    echo "Expected Samsung Debian DTB with internal UFS disabled and the original I2C nodes" >&2
    exit 1
}
tlmm=/soc@0/pinctrl@3100000
ldo=/soc@0/rsc@18200000/regulators-1/ldo11
[[ $(fdtget -t s "$base" /soc@0/rsc@18200000/regulators-1 qcom,pmic-id) == c &&
   $(fdtget -t s "$base" "$tlmm" compatible) == qcom,sc8180x-tlmm ]] || exit 1
if fdtget "$base" "$touchbus/touchpad@40" reg >/dev/null 2>&1; then
    echo 'Touchpad node already exists' >&2; exit 1
fi
tmp=$(mktemp -d "$(dirname "$output")/.touchpad.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
stage="$tmp/board.dtb"
# GIO0 virtual pin 448 / 64 = index 7: GSI 590, SPI 558, PDC 78 -> GPIO104.
# Independent check: lid pin 320 -> GSI 564 -> SPI 532 -> PDC 52 -> GPIO50.
cat > "$tmp/touchpad.dts" <<EOF
/dts-v1/;
/plugin/;
/ {
    fragment@0 {
        target-path = "$tlmm";
        __overlay__ {
            touchpad_irq: sstp0001-irq-state {
                pins = "gpio104";
                function = "gpio";
                bias-pull-up;
                input-enable;
            };
        };
    };
    fragment@1 {
        target-path = "$touchbus";
        __overlay__ {
            #address-cells = <1>;
            #size-cells = <0>;
            touchpad@40 {
                compatible = "hid-over-i2c";
                reg = <0x40>;
                hid-descr-addr = <0x0e>;
                pinctrl-names = "default";
                pinctrl-0 = <&touchpad_irq>;
                wakeup-source;
            };
        };
    };
};
EOF
dtc -@ -I dts -O dtb -o "$tmp/touchpad.dtbo" "$tmp/touchpad.dts"
fdtoverlay -i "$base" -o "$stage" "$tmp/touchpad.dtbo"
tp="$touchbus/touchpad@40"
fdtput -t x "$stage" "$tp" interrupts-extended "$(fdtget -t x "$base" "$tlmm" phandle)" 68 8
# Samsung's PEP votes for LDO11_C at 3300000 uV in TCPD D0.
fdtput -t x "$stage" "$tp" vdd-supply "$(fdtget -t x "$base" "$ldo" phandle)"
# The original board asks Linux to claim reserved GPIO0/1, so GENI cannot
# bind. Preserve the firmware mux for this trial, keeping all reservations.
fdtput -d "$stage" "$touchbus" pinctrl-0 pinctrl-names
# Windows identifies the device at 0x62 as the EC, without a HID-I2C CID.
fdtput -t s "$stage" "$ec" status disabled
mv "$stage" "$output"
