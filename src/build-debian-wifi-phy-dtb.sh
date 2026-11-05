#!/usr/bin/env bash
# Build a separate Samsung PCIe0 trial, with explicit PHY supplies.
set -euo pipefail
port0_x1=false
if [[ ${1:-} == --port0-x1 ]]; then
    port0_x1=true
    shift
fi
if [[ $# != 2 || ! -f $1 || -e $2 || -L $2 ]]; then
    echo "Usage: $0 [--port0-x1] SAMSUNG-PCIE0-TRIAL.dtb NEW-PHY-TRIAL.dtb" >&2
    exit 2
fi
base=$1
out=$2
phy=/soc@0/phy@1c06000
pmics=/soc@0/rsc@18200000
[[ $(fdtget "$base" / compatible) == 'samsung,np545xla qcom,sc8180x' &&
   $(fdtget "$base" /soc@0/ufshc@1d84000 status) == disabled &&
   $(fdtget "$base" /soc@0/pcie@1c00000 status) == okay &&
   $(fdtget "$base" /soc@0/pcie@1c18000 status) == disabled &&
   $(fdtget "$base" "$phy" compatible) == qcom,sc8180x-qmp-pcie-phy &&
   $(fdtget "$base" "$phy" status) == okay ]] || {
    echo 'Expected Samsung Debian PCIe0 trial DT with UFS disabled' >&2
    exit 1
}
trial=$(mktemp "$(dirname "$out")/.pcie0-phy.XXXXXXXX")
trap 'rm -f "$trial"' EXIT
cp "$base" "$trial"

# The Samsung PEP0.PEMC PCI0 D0 record votes for L5E at 880000 uV and
# L3C at 1200000 uV. Upstream SC8180x boards use that ordering on QMP.
attach_supply() {
    local prop=$1 bank=$2 id=$3 ldo=$4 uv=$5 node phandle
    node="$pmics/$bank/$ldo"
    [[ $(fdtget "$base" "$pmics/$bank" qcom,pmic-id) == "$id" &&
       $(fdtget -t u "$base" "$node" regulator-min-microvolt) == "$uv" &&
       $(fdtget -t u "$base" "$node" regulator-max-microvolt) == "$uv" ]] || return 1
    phandle=$(fdtget -t x "$base" "$node" phandle)
    [[ $phandle =~ ^[0-9a-f]+$ && $phandle != 0 && $phandle != ffffffff ]]
    fdtput -t x "$trial" "$phy" "$prop" "$phandle"
    [[ $(fdtget -t x "$trial" "$phy" "$prop") == "$phandle" ]]
}
attach_supply vdda-phy-supply regulators-2 e ldo5 880000
attach_supply vdda-pll-supply regulators-1 c ldo3 1200000
if $port0_x1; then
    controller=/soc@0/pcie@1c00000
    [[ $(fdtget -t u "$base" "$controller" num-lanes) == 2 &&
       $(fdtget -t x "$base" "$phy" reg) == '0 1c06000 0 1000' ]]
    # The stock driver cannot operate this layout. Use a single compatible
    # so systems with only the older module will leave this PHY unclaimed.
    fdtput -t s "$trial" "$phy" compatible qcom,sc8180x-pcie0-qmp-gen3x1-phy
    fdtput -t u "$trial" "$controller" num-lanes 1
    [[ $(fdtget "$trial" "$phy" compatible) == qcom,sc8180x-pcie0-qmp-gen3x1-phy &&
       $(fdtget -t u "$trial" "$controller" num-lanes) == 1 ]]
fi
chmod 0644 "$trial"
mv "$trial" "$out"
echo "Built $out"
