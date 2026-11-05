# Samsung Galaxy Book Go 5G (NP545XLA) — Linux on SC8180XP

## The Situation

- **SoC:** Qualcomm Snapdragon 8cx Gen 2 (SC8180XP)
- **Diagnostic USB, 2026-11-05.** A real NP545XLA-KA1TT booted Linux 7.0 with the Samsung device tree. Wired SSH over the RTL8153 and enumeration of the internal UFS were verified. See the [diagnostic image and display results](usb-linux-diag.md).
- **Ubuntu live image, 2026-05-23.** The initramfs stopped at "Unable to find a medium containing a live system". The sections below describe that earlier image.
- **Target:** Ubuntu 26.04 LTS (kernel 6.14 base)

SC8180XP is the **only** 8cx generation without mainline kernel support:
- SC8180X (Gen 1) — supported since 6.5
- SC8180XP (Gen 2) — **not supported**
- SC8280XP (Gen 3) — supported since 6.0
- X1E80100 (Gen 4) — supported since 6.8

The 'P' variant difference from SC8180X: "no integrated modem" (Konrad Dybcio, linux-arm-msm mailing list, 2025-06-25). Everything else is board/variant design differences.

SC8180XP was explicitly excluded from the Qualcomm/Lenovo/Arm/Linaro aarch64-laptops collaboration that brought up the other 8cx generations.

---

## Serial Console

### Debug Port: `\_SB.UARD`

The DBG2 ACPI table declares `\_SB.UARD` as the debug serial port:

| Property | Value |
|----------|-------|
| ACPI device | `\_SB.UARD` |
| UART base | `0xA90000` |
| DT node | `uart12` (QUP1 SE10) |
| GIC SPI | 389 |
| ACPI status | Active (`_STA = 0x0B`) |
| Kernel driver | `qcom_geni` |

### 3.5mm Combo Jack

The 3.5mm headphone jack is a **TRRS 4-conductor** combo port that dual-purposes as headphone out and UART debug. The EC switches modes based on impedance on the mic line.

**How to force UART mode:** Put a **150KΩ resistor** between the mic and ground contacts on a TRRS plug (CTIA pinout). This tells the EC to switch from audio to UART.

**Pinout once in UART mode (CTIA TRRS):**

| Pin | Audio function | UART function |
|-----|----------------|---------------|
| Tip | Left speaker | TX (from laptop) |
| Ring 1 | Right speaker | RX (to laptop) |
| Ring 2 | Ground | Ground |
| Sleeve | Mic | Mode detect (150KΩ to GND) |

### ⚠️ Voltage: 1.8V — DO NOT use 3.3V/5V adapters directly

Qualcomm TLMM GPIO runs at **1.8V logic**. Standard USB-TTL adapters are 3.3V or 5V — connecting one directly **will fry the UART pin**.

**Safe options:**
1. **1.8V USB serial adapter** — some CP2102-based adapters support 1.8V, or FTDI FT232H with VCCIO set to 1.8V
2. **Level shifter** between a 3.3V adapter and the laptop (1.8V↔3.3V bidirectional, e.g. TXS0108E or BSS138-based shifter)
3. **Resistor divider** on the RX line (laptop TX → adapter RX) — but the TX direction (adapter TX → laptop RX) still needs to be 1.8V-safe. Most 3.3V adapters idle TX high at 3.3V, which can damage the pin over time.

**Safest cheap option:** get a USB serial adapter that explicitly supports 1.8V mode.

### USB-C Debug Port: Qualcomm EUD (Embedded USB Debug)

The DBG2 table declares **4 additional debug devices** on the USB controllers:

| # | PortType | Subtype | ACPI | Address |
|---|----------|---------|------|----------|
| 1 | 0x8003 (USB vendor) | 0x5143 ('QC') | `\_SB.URS0` | 0x0A600000 |
| 2 | 0x8003 (USB vendor) | 0x5143 ('QC') | `\_SB.URS1` | 0x0A800000 |
| 3 | 0x8003 (USB vendor) | 0x5143 ('QC') | `\_SB.URS0` | 0x0A600000 |
| 4 | 0x8003 (USB vendor) | 0x5143 ('QC') | `\_SB.URS1` | 0x0A800000 |

`PortSubtype 0x5143` = ASCII "QC" — this is **Qualcomm EUD** (Embedded USB Debug), **not** standard USB2 DbC.

#### What is EUD?

EUD is a debug interface built into almost every Qualcomm SoC since ~2018. When enabled, it presents a **7-port USB hub** on the USB-C port, with one port populated by the "EUD control interface". With the right USB commands, additional devices appear:

- **SWD** — Serial Wire Debug (JTAG-lite). Full CPU debug: breakpoints, register inspection, single-step. Via OpenOCD + GDB.
- **COM** — Bidirectional UART serial console. No 3.5mm hackery needed, no voltage worries.
- **TRACE** — Real-time MMIO trace peripheral.

Source: Casey Connolly (Linaro), "The hidden JTAG in your Qualcomm/Snapdragon device's USB port" (June 2025). Qualcomm open-sourced the host-side library: [github.com/quic/eud](https://github.com/quic/eud). Rebased OpenOCD with EUD support: [github.com/linux-msm/openocd](https://github.com/linux-msm/openocd).

#### What it entails

1. **EUD must be enabled on the device side** — write to specific MMIO registers to activate the EUD hardware and start a USB gadget. On dev boards this is trivial; on production devices it depends on fuses and OEM debug policy.
2. **Plug a regular USB-C cable** from the laptop to your dev machine.
3. **The laptop appears as a 7-port USB hub** with the EUD control interface.
4. **Run OpenOCD** with the EUD config — it discovers the SWD port and connects.
5. For the **COM (UART) peripheral**, it should expose a serial console. This hasn't been integrated into OpenOCD yet, but the hardware support exists.

#### The catch: production device enablement

- Our DSDT has **zero EUD references** — no ACPI device, which is typical for production Windows laptops. EUD lives outside ACPI.
- The DT binding (`qcom,eud`) only lists `sc7280` as compatible. SC8180XP isn't supported yet — we'd need to figure out the EUD base address and mode manager register for this SoC.
- Whether EUD is **fuse-disabled** on this Samsung is unknown. The Linaro blog notes that some production devices (e.g. OnePlus 6) have EUD working despite fuses suggesting otherwise — it may depend on whether Samsung shipped with a loose debug policy.
- EUD can be re-enabled with a **cryptographically signed debug policy** from the OEM. We don't have Samsung's signing key.
- On a production device, EUD's JTAG/SWD **cannot access EL2** (hypervisor) — registers read as zero. EL0/EL1 debug works fine.

#### How to test if EUD works on our device

1. Boot Linux on the laptop (even the half-working ACPI boot)
2. Write to the EUD enable register (address unknown for SC8180XP — need to find from SoC TRM or by comparing with sc7180/sm8150 base addresses)
3. Start a USB gadget (e.g. `g_serial` or configfs)
4. Plug USB-C to another machine and check if a 7-port hub appears
5. If it does — EUD is active, and you can use OpenOCD + the EUD library for SWD debug and COM serial

#### Realistic assessment

| Factor | Outlook |
|--------|----------|
| EUD hardware present on SC8180XP? | Almost certainly yes — present on all QCOM SoCs since ~2018 |
| Fuse-disabled on this Samsung? | Unknown — could go either way |
| Debug policy available? | No — would need Samsung's OEM signing key |
| DT/driver support for SC8180XP EUD? | None — would need to add `qcom,sc8180xp-eud` compatible and find the register base |
| Worth trying? | **Yes** — cost is zero (just a USB-C cable), and if it works it's the best debug path by far |

If EUD works, it's strictly superior to the 3.5mm UART: no voltage concerns, no resistor hack, no adapter purchase, and you get SWD debug on top of serial. But the 3.5mm UART is the **guaranteed** path — EUD is the bonus.

### Kernel Cmdline for Serial

```
efi=novamap clk_ignore_unused earlycon=qcom_geni,0xA90000 console=ttyMSM0,115200n8 initcall_debug loglevel=8
```

- `earlycon=qcom_geni,0xA90000` — gets output from the very first moment the kernel can drive the UART
- `console=ttyMSM0,115200n8` — may need to be `ttyMSM12` depending on QUP SE index assignment

---

## Known Boot Quirks (from linux-surface Pro X — same SoC)

Source: https://github.com/linux-surface/surface-pro-x/wiki/Basic-Setup

### Kernel command line parameters

| Parameter | Required? | Why |
|-----------|-----------|-----|
| `efi=novamap` | **YES** — both ACPI and DT | Prevents lockups during early boot |
| `clk_ignore_unused` | YES — DT boot only | Prevents disabling "unused" clocks at late init, which causes lockups |

### NVMe in ACPI mode

Broken by mainline commit `8fd4391ee717` ("arm64: PCI: Exclude ACPI consumer resources from host bridge windows"). Needs reverting for ACPI NVMe access. DT mode should work without this revert if the DT describes the PCIe controller correctly.

**Implication:** ACPI boot is a dead end. DT is the path forward.

**Note:** This device uses UFS, not NVMe. The NVMe commit revert is irrelevant here.

### Black screen on GPU handoff

Known issue when kernel switches from simplefb to GPU-based framebuffer. Wait 20 seconds or force-reboot. This is a display bring-up sequencing issue.

### Initramfs module requirements

If booting from USB, these modules must be in the initramfs (not all distros include them by default on ARM64):

- `phy-qcom-qmp`
- `phy-qcom-snps-femto-v2`
- `dwc3-qcom`
- `uas`
- `usb_storage`

---

## ACPI Boot Status Across SC8180XP Devices

Reported on Dell Inspiron 14 3420, Lenovo IdeaPad 5G 14Q8X05:

- ✅ Basic framebuffer
- ✅ USB
- ❌ Keyboard/trackpad (I2C bus not enumerated)
- ❌ PCIe devices (NVMe, WiFi) — even with drivers loaded
- ❌ WiFi, GPU, touch, audio — all dead

Root cause: missing device tree. ACPI alone doesn't properly enumerate the I2C and PCIe buses on this SoC.

---

## Current Boot Status (2026-05-23)

**Boot media:** Custom ISO with GRUB, custom kernel v7.0, DT boot via `devicetree` command
**Boot log screenshots:** `docs/000925C1-*.jpeg` (early boot), `docs/BB702B01-*.jpeg` (final state)
**Kernel cmdline:** `efi=novamap clk_ignore_unused` (plus console/loglevel params)

### What's Working ✅

| Subsystem | Status | Details |
|-----------|--------|---------|
| Kernel boot | ✅ | Custom v7.0 kernel loads, `/init` runs, initramfs executes |
| Framebuffer | ✅ | efifb at 1920×1080×32, console renders on screen |
| SMMU (apps) | ✅ | `arm-smmu 15000000` probes as SMMUv2, stage-1, 79 register groups, 106 context banks |
| QUP IOMMU | ✅ | geniqup at 8c000/ac000/cc000 join iommu groups 0–2 |
| UFS IOMMU | ✅ | `1d84000.ufshc` added to iommu group 3 |
| USB storage driver | ✅ | `usb-storage` interface driver registered |
| Networking stack | ✅ | PF_INET6, PF_PACKET, SRv6, IOAM all registered |
| arch-timer-mmio | ✅ | Running at 19.2MHz |
| Clocksource | ✅ | `arch_mmio_counter` registered |
| GPIO keys | ✅ | lid switch (gpio50), power key (pmic) |
| UART12 pinctrl | ✅ | gpio83/84, qup12 function |

### What's Broken ❌

#### 1. Deferred Probe Cascade — THE BLOCKER

The second SMMU (`2ca00000`) fails to probe, creating a dependency chain that kills everything downstream:

```
arm-smmu 2ca00000.iommu: deferred probe timeout, ignoring dependency
arm-smmu 2ca00000.iommu: probe with driver arm-smmu failed with error -110 (ETIMEDOUT)
```

**Dependency chain (all stuck waiting on regulators from RSC):**

| Device | Waiting on |
|--------|------------|
| `18200000.rsc` | `/psci/power-domain-cpu-cluster` |
| `88e8000.phy` | `rsc@18200000/regulators-2/ldo5` |
| `88ed000.phy` | `rsc@18200000/regulators-2/ldo5` |
| `1d87000.phy-wrapper` | `rsc@18200000/regulators-1/ldo3` |
| `a6f8800.usb` | unknown |
| `a8f8800.usb` | unknown |
| `18321000.interconnect` | `rsc@18200000/clock-controller` |

**Root cause:** The RSC (Resource State Coordinator) at `18200000` can't probe because it's waiting on a PSCI power domain (`/psci/power-domain-cpu-cluster`). Without the RSC, no regulators are provided. Without regulators, PHYs, USB, and interconnect all stay deferred. Without USB, no input devices or storage are discovered.

#### 2. No Live Medium Found

```
Unable to find a medium containing a live system
Attempt interactive netboot from a URL?
yes no (default yes)
```

The initramfs (casper) gives up because USB and UFS are both blocked by the deferred probe chain — no storage device ever appears.

#### 3. Keyboard Not Working

Both onboard and USB keyboards are dead, consistent with the USB controllers being stuck in deferred probe.

#### 4. efivarfs Mount Failure

```
mount: mounting efivarfs on /sys/firmware/efi/efivars failed: No such device
```

Minor — efivarfs not available in this boot configuration. Not the root cause of anything.

### Analysis: The PSCI → RSC → Regulator Chain

The fundamental problem is that the RPMH RSC driver can't get the PSCI CPU cluster power domain. This means:

1. The `psci` node in the DT may be incomplete — it needs to expose power domains
2. Or the RSC node is missing a required `power-domains` property that references the PSCI power domain provider
3. Or the kernel is missing the `CONFIG_QCOM_RPMH` / `CONFIG_QCOM_RPMH_RSC` config options
4. Or the PSCI firmware on this device doesn't expose the CPU cluster power domain

**Key reference:** The working Surface Pro X DT (same SoC) should show how `apps_rsc` and the PSCI power domains are wired up. Diffing our DTS against the SPX DT is the fastest path to a fix.

### DTS Status

The board DTS is at `NP545XLA-kernel/dts/sc8180xp-samsung-np545xla.dts`. It includes `sc8180x.dtsi` + `sc8180x-pmics.dtsi` and defines:
- chosen + stdout-path (UART12)
- GPIO keys (lid, power)
- Reserved memory regions
- PMIC regulators under `&apps_rsc` (copied from Lenovo Flex 5G)
- QUP wrappers enabled
- UART12 with pinctrl
- UFS + UFS PHY with regulators
- Both USB controllers (primary + secondary) with PHY regulators
- TLMM pinctrl (UART12 + lid)

**What's likely missing or wrong:**
- The `&apps_rsc` regulator blocks reference supplies from `vph_pwr` and other rails, but the RSC itself may not be probing (it's the `18200000.rsc` that's deferred)
- The PSCI node may need `power-domains` or `domain-idle-states` properties to expose CPU cluster power domains
- The interconnect provider at `18321000` can't probe without the RSC clock controller

### Next Steps

1. **Diff our DTS against the Surface Pro X DT** — see how they wire `apps_rsc`, PSCI power domains, and the RSC
2. **Check kernel config** — verify `CONFIG_QCOM_RPMH`, `CONFIG_QCOM_RPMH_RSC`, `CONFIG_QCOM_PSCI_POWER_DOMAIN` are enabled
3. **Check if `psci` node in `sc8180x.dtsi` exposes power domains** — if not, we need to add them
4. **Try `init=/bin/sh`** — if the kernel can at least give a shell, we can inspect `/sys` to see what's probing and what's not
5. **Get serial console working** — still the highest-value debug investment; the 3.5mm combo jack + 1.8V adapter path

---

## The Real Project: Building a Device Tree

No one has contributed a DTS for the Samsung Galaxy Book Go 5G to mainline. The `aarch64-laptops/build` project doesn't list it. No existing ACPI dumps found for this specific device.

### Reference DTs

- `sc8180x.dtsi` — in mainline since 6.5, covers Gen 1 SoC. This is 90% of what's needed.
- `sc8180x-primus.dts` — Gen 1 reference board DTS
- `sc8180x-lenovo-flex-5g.dts` — Gen 1 laptop board DTS
- linux-surface Pro X DT — `https://github.com/linux-surface/surface-pro-x` — working SC8180XP DT
- Konrad Dybcio: "You should be able to do most of the bringup work with sc8180x.dtsi"
- Anton Bambura (jenneron on GitHub) has reportedly poked at SC8180XP specifically

### DTS Structure

```
sc8180x.dtsi (mainline — has CPUs, clocks, pinctrl, I2C/SPI, PCIe, UFS, USB, SMMU, remoteprocs, SPMI)
  └── sc8180xp-samsung-galaxy-book-go5g.dts (YOUR NEW FILE)
        ├── Board-specific I2C devices (from ACPI dump)
        ├── GPIO keys (power button, etc.)
        ├── Panel/display definition
        ├── Touchscreen (I2C addr + interrupt)
        ├── Keyboard (I2C addr + interrupt)
        ├── Touchpad (I2C addr + interrupt)
        ├── WiFi (ath11k PCI address)
        ├── Regulator fixes if needed
        └── Fixed clocks if ACPI provides them
```

### GPIO Pin Numbering (critical gotcha)

The DSDT uses **two different GPIO pin numbering schemes** on `\_SB.GIO0` (QCOM040D = TLMM):

1. **GpioIo OperationRegion** (direct read/write): uses **physical TLMM pin numbers** (0–176). Example: pin 50 = LID switch, pin 166 = camera enable.

2. **GpioInt in _CRS/_AEI** (interrupt source): uses a **Qualcomm-specific namespace** where pins >190 are NOT physical TLMM pins. The Windows "System Manager GPIO" driver translates these internally. The mapping is opaque without either booting Linux with ACPI (read `/sys/kernel/debug/gpio`) or reverse-engineering the Windows GPIO driver.

**Pins ≤189** (within ACPI ngpios=190) are likely 1:1 with physical TLMM pins.
**Pins >189** (keyboard 640, touchscreen 448, ADSP 256) require translation — cannot be decoded from DSDT alone.

---

## Mining Hardware Info from Windows 11

This is how the aarch64-laptops and linux-surface people built their DTs. Windows has all the hardware enumeration — you just need to extract it.

### 1. ACPI Tables (THE BIG ONE)

The DSDT and SSDTs contain: I2C bus definitions, PCIe root complex layout, GPIO pin mappings, clock/regulator references, device _HID/_CID strings.

```powershell
# As Administrator in PowerShell:

# Download acpidump + iasl from https://www.acpica.org/downloads (Windows binary)
# Then dump everything:
acpidump.exe -b          # dumps all tables to binary files
iasl.exe -d DSDT.dat    # disassemble DSDT to ASL source
iasl.exe -d SSDT*.dat   # disassemble all SSDTs
```

The disassembled ASL source is the Rosetta Stone. Every I2C device, its address, its interrupt, its power resource — it's all in there.

### 2. Device Manager (cross-reference)

- View → Resources by Connection → shows interrupts and memory ranges
- Right-click device → Properties → Details → Hardware IDs → gives ACPI path (e.g. `ACPI\QCOM0818`)
- Map ACPI paths to DSDT nodes → map to DTS compatible strings

### 3. PCI Device Enumeration

```powershell
wmic path win32_pnpentity get name,deviceid /format:list
```

Or use MSINFO32 → Components.

### 4. GPIO / Pin Controller

The pinmux is the hardest part. Sources:
- DSDT `_CRS` (Current Resource Settings) for each device
- Windows `devcon` or `pnputil` for enumeration
- SoC TRM (Technical Reference Manual) for fixed pin assignments
- SC8180XP should use `qcom,sc8180xp-tlmm` (may be identical to `qcom,sc8180x-tlmm`)

### 5. Firmware Files

```
# Pull firmware blobs from Windows:
C:\Windows\System32\drivers\   # .sys files may contain embedded firmware
C:\Windows\INF\                 # .inf files reference firmware paths

# Or from the EFI partition:
mountvol S: /s
# Browse S:\EFI\ for Qualcomm .mbn firmware files
```

WiFi/BT firmware (ath11k), ADSP firmware, etc. The linux-surface project packages these for the Surface Pro X — may be reusable.

### 6. UFS Storage

```powershell
Get-Disk | Select-Number,FriendlyName,SerialNumber,Size,PartitionStyle
Get-PhysicalDisk | Format-List
```

Should use same `qcom,sc8180x-ufshc` as Gen 1.

---

## Key Resources

| Resource | URL |
|----------|-----|
| aarch64-laptops build project | https://github.com/aarch64-laptops/build |
| aarch64-laptops IRC | #aarch64-laptops on OFTC (bridged to Matrix) |
| linux-surface Pro X | https://github.com/linux-surface/surface-pro-x |
| linux-surface kernel (spx/ branches) | https://github.com/linux-surface/kernel |
| linux-surface aarch64 configs | https://github.com/qzed/aarch64-kernel-configs |
| linux-surface aarch64 firmware | https://github.com/linux-surface/aarch64-firmware |
| linux-surface aarch64 packages | https://github.com/linux-surface/aarch64-packages |
| Qualcomm mainline status | https://linux-msm.github.io/mainline-status/ |
| Kernel bugzilla SC8180XP | https://bugzilla.kernel.org/show_bug.cgi?id=218512 |
| LKML thread (Feb 2024) | https://lkml.org/lkml/2024/2/22/182 |
| Konrad Dybcio response (Jun 2025) | https://www.spinics.net/lists/linux-arm-msm/msg240437.html |
| Dell Inspiron 3420 SC8180XP report | https://www.spinics.net/linux/fedora/fedora-arm/msg14628.html |
| ACPI dump (IdeaPad 5G) | https://github.com/aarch64-laptops/build/files/14700163/ACPI.zip |
| NVMe-breaking commit | https://github.com/torvalds/linux/commit/8fd4391ee717 |

---

## Quick-Start Path

1. ~~**Dump ACPI from Windows**~~ — ✅ Done, see `acpi-analysis.md`
2. ~~**Build the DTS**~~ — ✅ Done, see `NP545XLA-kernel/dts/sc8180xp-samsung-np545xla.dts`
3. ~~**Custom kernel + ISO**~~ — ✅ Done, kernel v7.0, boots to initramfs
4. **Fix the PSCI → RSC → regulator chain** — the deferred probe cascade is the current blocker (see Current Boot Status above)
5. **Diff our DTS against Surface Pro X DT** — fastest path to understanding what's missing in the PSCI/RSC wiring
6. **Get serial console working** — 3.5mm combo jack, 1.8V adapter, 150KΩ resistor — still the highest-value debug investment
7. **Try `init=/bin/sh`** — if the kernel can give a shell without storage, we can inspect `/sys` live
8. **Iterate** — fix DT, rebuild, boot, repeat
