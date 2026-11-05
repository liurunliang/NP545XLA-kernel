#!/usr/bin/env bash
# Remove the obsolete GPIO power-key from an existing Samsung daily DTB.
set -euo pipefail
export LC_ALL=C
if [[ $# != 2 || ! -f $1 || -e $2 || -L $2 ]]; then
    echo "Usage: $0 CURRENT-DAILY.dtb NEW-LID.dtb" >&2
    exit 2
fi
base=$1
out=$2
lid=/gpio-keys/lid-switch
power=/gpio-keys/power-key
native=/soc@0/spmi@c440000/pmic@0/pon@800/pwrkey
tlmm=/soc@0/pinctrl@3100000
keyboard=/soc@0/geniqup@ac0000/i2c@a80000/keyboard@5
touchpad=/soc@0/geniqup@8c0000/i2c@880000/touchpad@40

[[ $(fdtget "$base" / compatible) == 'samsung,np545xla qcom,sc8180x' &&
   $(fdtget "$base" /soc@0/ufshc@1d84000 status) == disabled &&
   $(fdtget "$base" "$keyboard" compatible) == samsung,np545xla-eckb &&
   $(fdtget "$base" "$touchpad" compatible) == hid-over-i2c &&
   $(fdtget "$base" /soc@0/pcie@1c00000 status) == okay &&
   $(fdtget "$base" /soc@0/phy@1c06000 compatible) == qcom,sc8180x-pcie0-qmp-gen3x1-phy ]] ||
    { echo 'Expected the Samsung daily DT with USB root, EC keyboard, touchpad and PCIe0 Wi-Fi' >&2; exit 1; }

pin_controller=$(fdtget -t u "$base" "$tlmm" phandle)
power_key=$(fdtget -t u "$base" "$native" phandle)
[[ $(fdtget "$base" /gpio-keys compatible) == gpio-keys &&
   $(fdtget -t u "$base" "$lid" gpios) == "$pin_controller 50 1" &&
   $(fdtget -t u "$base" "$lid" linux,input-type) == 5 &&
   $(fdtget -t u "$base" "$lid" linux,code) == 0 &&
   $(fdtget "$base" "$native" compatible) == qcom,pm8941-pwrkey &&
   $(fdtget -d okay "$base" "$native" status) == okay &&
   $(fdtget -t u "$base" "$native" linux,code) == 116 &&
   $(fdtget -t u "$base" "$power" gpios) == "$power_key 0 1" &&
   $(fdtget -t u "$base" "$power" linux,code) == 116 &&
   $(fdtget -l "$base" "$power") == '' &&
   $(fdtget -p "$base" "$power" | sort) == $'gpios\nlinux,code\nwakeup-source' ]] ||
    { echo 'Expected the GPIO50 lid, the native power key and its obsolete GPIO reference' >&2; exit 1; }
fdtget "$base" "$lid" wakeup-source >/dev/null

work=$(mktemp -d "$(dirname "$out")/.lid.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$base" "$work/lid.dtb"
fdtput -r "$work/lid.dtb" "$power"
# Independently apply the explicit source deletion and compare the complete trees.
dtc -q -I dtb -O dts "$base" > "$work/expected.dts"
echo '/ { gpio-keys { /delete-node/ power-key; }; };' >> "$work/expected.dts"
dtc -q -s -I dts -O dts "$work/expected.dts" > "$work/expected.sorted"
dtc -q -s -I dtb -O dts "$work/lid.dtb" > "$work/actual.sorted"
cmp "$work/expected.sorted" "$work/actual.sorted"
chmod 0644 "$work/lid.dtb"
mv -n "$work/lid.dtb" "$out"
[[ ! -e $work/lid.dtb ]]
echo "Built $out"
