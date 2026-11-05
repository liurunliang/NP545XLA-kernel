# NP545XLA Kernel

> **Hardware status, 2026-11-05.** The diagnostic USB boots Linux 7.0 on the NP545XLA-KA1TT using the Samsung device tree. Wired SSH over an RTL8153 adapter works. The internal screen can go dark after the boot messages. The Ubuntu live image is still in development. [Build instructions and hardware results](docs/usb-linux-diag.md)

Custom Linux kernel + boot ISO for the Samsung Galaxy Book Go 5G (SC8180XP).

The stock Ubuntu kernel doesn't include sc8180x-specific drivers (GCC, interconnect, SMMU power domains) — they're either missing entirely or loaded as modules that can't probe because their dependencies form a circular chain. This kernel builds everything critical as built-in (`=y`) so the hardware actually initializes.

## Quick Start

```bash
git clone https://github.com/potassium-os/NP545XLA-kernel.git
cd NP545XLA-kernel

# Shallow clone the kernel source (v7.0)
git clone --depth 1 --branch v7.0 https://github.com/torvalds/linux.git linux

# Build everything: kernel + DTBs + modules
docker build --platform linux/arm64 -t np545xla-kernel-build .
docker run --platform linux/arm64 --rm --privileged -v "$PWD":/work -v /dev:/dev np545xla-kernel-build /work/src/build.sh all
```

## Build Targets

| Target | What it builds |
|--------|---------------|
| `kernel` | `Image.gz` → `output/vmlinuz-np545xla` |
| `dtbs` | Device tree blobs → `output/dtbs/` |
| `modules` | Loadable modules → `output/modules/` |
| `debs` | Debian packages → `output/linux-*.deb` (DISABLED — no apt repo yet) |
| `iso` | Boot ISO → `build/np545xla-boot.iso` |
| `all` | Everything above (kernel + DTBs + modules + ISO) |
| `clean` | Clean build artifacts |

## Build the Boot ISO

Requires `-v /dev:/dev` for loop device access inside the container:

```bash
docker run --platform linux/arm64 --rm --privileged -v "$PWD":/work -v /dev:/dev np545xla-kernel-build /work/src/build.sh iso
```

With Ubuntu initrd fallback:

```bash
docker run --platform linux/arm64 --rm --privileged -v "$PWD":/work -v /dev:/dev np545xla-kernel-build /work/src/build-iso.sh /work/src/ubuntu-26.04-desktop-arm64.iso
```

## Configuration

`configs/np545xla_defconfig` — everything critical for SC8180X boot is built-in:

- **Clocks:** `gcc-sc8180x`, `gpucc-sc8180x`, `dispcc-sc8180x`
- **Interconnect:** `qnoc-sc8180x`
- **Power domains:** `rpmhpd`, `rpmh-regulator`
- **IOMMU:** `arm-smmu`, `arm-smmu-qcom`
- **UFS:** `ufs-qcom`
- **USB:** `dwc3-qcom`, `xhci-hcd`
- **Serial:** `qcom_geni_serial`, `serial_msm`
- **Pinctrl:** `pinctrl-sc8180x`
- **PHY:** `phy-qcom-qmp-ufs`, `phy-qcom-qmp-usb`

WiFi (ath11k) and remoteproc are modules — they need firmware after rootfs mounts.

## Device Tree

`dts/sc8180xp-samsung-np545xla.dts` — board DTS includes UART12 debug console, UFS, USB, PMIC regulators, GPIO keys.

## GRUB Config

`src/grub.cfg` — 13 boot entries: standard, serial variants (ttyMSM0/ttyS0/ttyAMA0), initrd debug shells (`break=top`, `break=premount`), nomodeset, IOMMU bypass, ACPI fallback.

## GitHub Actions

Pushes to `main` build and upload artifacts (vmlinuz, DTBs, modules).

An apt repository workflow is scaffolded in `.github/workflows/publish-apt.yml` (commented out until we have a booting kernel + GPG key). When enabled it publishes signed `.deb` packages to GitHub Pages.

## Repository Layout

```
├── Dockerfile
├── configs/np545xla_defconfig
├── dts/
│   ├── sc8180xp-samsung-np545xla.dts
│   ├── Makefile
│   └── QUESTIONS.md
├── src/
│   ├── build.sh
│   ├── build-iso.sh
│   └── grub.cfg
├── .github/workflows/
│   ├── build.yml
│   └── publish-apt.yml       ← DISABLED
├── linux/                    ← gitignored
└── output/                   ← gitignored
```

## License

GPL-2.0