# Debian USB 上的 QCA639x 无线网卡

三星的 Windows 硬件清单记录了 QCA639x，PCI 标识为 `17cb:1101`、子系统为 `17cb:0108`。Linux v7.0 的 `ath11k_pci` 能匹配这个标识。设备树中的 `wifi@18800000` 则描述 SC8180x 集成的 WCN3990，两者使用不同的总线和驱动。[Windows 硬件清单](dump/NP545XLA-hw-dump/hw-enum.txt) · [Linux ath11k 支持列表](https://wireless.docs.kernel.org/en/latest/en/users/drivers/ath11k.html)

## PCIe 端口依据

检查三星 DSDT 的 `PRP0` 至 `PRP3`、`PCI0` 至 `PCI3` 下的 `_STA`，以及 `QPPX._RST`。这份固件将端口 0、3 标为可用，将 1、2 标为关闭。复位辅助方法只在端口 0 的特定板型分支脉冲 `WLEN`，端口 3 控制 SDX55，端口 2 分支为空。早期板级 DTS 据以选择 PCIe2 的 `PNID=2` 在反编译表中只有定义。可选的无线设备树片段因此启用 PCIe0 和它的 QMP PHY，停用 PCIe2、对应 PHY 以及 WCN3990 节点。[三星 DSDT](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl) · [无线设备树片段](../dts/sc8180xp-np545xla-wifi.dtso)

首次试验沿用固件留给 WLAN 的引脚和外部供电状态。片段不指定 `PERST`、`WL_EN` 或新的稳压器电压。ACPI 的 `GWLE` 描述 GIO0 引脚 169，脉冲条件还涉及板型与 ID；应保存端口实际枚举结果后再决定是否需要实现这个序列。

## 建立和安装

在同一个 Debian ARM64 构建机使用生成当前 USB 内核的源码、编译树和诊断产物。脚本核对 Image 和内核配置，执行内核符号、模块依赖、无线 PCI 别名检查，并验证片段能应用到三星设备树。

```sh
work=/var/tmp/np545xla-diag
src/build-debian-wifi.sh "$work/linux-7.0" "$work/obj" "$work/artifacts" output/daily/wifi
(cd output/daily/wifi && sha256sum -c wifi.sha256)
```

包中包括 QMP PCIe PHY、MHI、QRTR-MHI、ath11k、mac80211 及其运行时加密模块，以及触控板试验使用的 `hid_multitouch`。它保留原 USB 镜像里的内核和显示驱动。在笔记本 Debian 上使用有线连接安装本地包和辅助工具：

```sh
sudo apt install ./np545xla-wifi-modules_7.0.0-2_arm64.deb iw rfkill
sudo update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream
```

包依赖 `firmware-atheros` 和 `wireless-regdb`。Debian 包为 QCA6390 hw2.0 提供 `amss.bin`、`m3.bin`、`board-2.bin`。监管数据库提供两套签名，由 alternatives 同时切换数据库及其签名。这个自编内核信任 Linux 主线内置的监管数据库公钥。[Debian 固件清单](https://packages.debian.org/trixie/all/firmware-atheros/filelist)

模块包 `7.0.0-2` 补充了 `sha256.ko`。Debian 的上游监管数据库签名使用 SHA-256；cfg80211 会在加载数据库时调用 PKCS#7 验证，按签名中的算法名请求 `sha256`。这个内核的底层 SHA-256 库已内建，向 Crypto API 注册算法的驱动则按模块构建。升级已经运行的系统后，执行 `sudo iw reg reload` 可让 cfg80211 重新读取签名。[Linux 7.0 监管数据库验证](https://github.com/torvalds/linux/blob/v7.0/net/wireless/reg.c) · [PKCS#7 摘要选择](https://github.com/torvalds/linux/blob/v7.0/crypto/asymmetric_keys/pkcs7_verify.c) · [SHA-256 算法注册](https://github.com/torvalds/linux/blob/v7.0/crypto/sha256.c)

用正式 Image 和同一份 Debian `wireless-regdb 2026.05.30-1~deb13u1` 启动两次离线 QEMU。两次均载入了 sforshee 与 wens 的 X.509 证书。旧包导致 cfg80211 报告数据库签名无效，测试设置国家规则后仍显示 `country 00`；新包自动载入 `sha256` 并正确读出测试规则 `country DE: DFS-ETSI`。两次测试均未使用射频硬件。

在构建机上把片段应用到已有的 **Debian 专用 DTB**，另存后交给独立 GRUB 试验入口；保留基线入口和原诊断入口。以下文件名中的 `debian-base.dtb` 指从持久镜像取得、已禁用内置 UFS 的设备树。

```sh
fdtoverlay -i debian-base.dtb -o debian-wifi.dtb output/daily/wifi/sc8180xp-np545xla-wifi.dtbo
fdtget debian-wifi.dtb /soc@0/ufshc@1d84000 status    # disabled
fdtget debian-wifi.dtb /soc@0/pcie@1c00000 status     # okay
```

## 实机检查

从新入口冷启动后保留有线 SSH。先确认运行中 DT 的 PCIe0 已启用，再检查 PCI 枚举、驱动是否注册无线接口、扫描能否完成，最后单独验证认证和 DHCP。老入口使用原有 PCIe2 引脚设置。

```sh
tr -d '\0' </proc/device-tree/soc@0/pcie@1c00000/status
sudo modprobe phy_qcom_qmp_pcie
sudo modprobe qrtr_mhi
sudo modprobe ath11k_pci
grep -H '^PCI_ID=17CB:1101$' /sys/bus/pci/devices/*/uevent
sudo dmesg | grep -Ei 'pcie|ath11k|mhi|qrtr|regulatory'
iw dev
rfkill list
```

如果端口报告链路未建立，先记录控制器、PHY 和延迟探测情况；此时尚未到无线驱动加载固件的阶段。如果已枚举而固件启动失败，再检查驱动报告的 QMI 板号与 `board-2.bin` 匹配情况。这两个结果对应不同的排查路径。

## 第一次 PCIe0 实机启动

2026-11-05 从日常入口启动后，`1c06000.phy` 已绑定到 QMP 驱动，PCIe0 的供应设备均已就绪。启动日志在 20.499792 秒记录 `phy initialization timed-out`，PCIe0 随即返回 `-ETIMEDOUT`，系统没有枚举到无线 PCI 设备。Linux v7.0 在此处已启动本地 SerDes/PCS，等待 PHY 状态就绪超时；PCIe 接口尚未开始链路训练。运行中的 regulator summary 显示该 PHY 的两个电源消费者均指向 dummy regulator。[QMP 初始化及超时条件](https://github.com/torvalds/linux/blob/v7.0/drivers/phy/qualcomm/phy-qcom-qmp-pcie.c)

在同次启动的 195.404497 秒，通过 `drivers_probe` 只重探了 PCIe0。最后取到的日志是主桥地址范围，随后有线 SSH 失去响应。后续使用独立入口冷启动，不复用这次在线重探操作。

第二个试验 DT 只将 PCIe0 PHY 的 `vdda-phy` 接至 LDO5_E（0.88 V）、`vdda-pll` 接至 LDO3_C（1.20 V）。三星 PEP 的 PCI0 D0 供电记录和上游 SC8180x 板级 PHY 定义支持这个对应关系。这两路此前已有其他设备在用；是否能让 PHY 就绪仍待验证。构建时以上一次测试的 DT 为输入，输出到新文件，再核对两个消费者、PHY 状态和 PCI 枚举。

```sh
src/build-debian-wifi-phy-dtb.sh daily.dtb daily-wifi-phy-supplies.dtb
```

## 第三次试验使用端口 0 的单通道 PHY 布局

三星 Windows 清单中，设备 `ACPI\QCOM04A2\0` 使用 Qualcomm PCIe Platform Extension Plugin 1.0.1600.0，日期为 2021-07-17。Qualcomm 8180 CLS 200.0.62.0 参考包中，`qcppx8180.inf` 的硬件 ID、版本和日期全部吻合。以下偏移来自这个参考包里的原厂 ARM64 驱动，三星本机安装的 SYS 尚未取出做哈希比对。CAB 的 SHA-256 为 `5ffa71ad40056fb1dda96382ec5fc30f75536a98bf15ae37de596943464c6682`，解包后的 SYS 为 `198faec8195a142e8efb7f2f2fd4b24e9eeb584293cf8f86f2bb65e390c5c2d2`。[三星驱动记录](dump/NP545XLA-hw-dump/qualcomm-drivers.txt#L273-L277) · [参考包中的 Qualcomm 原厂文件](https://github.com/WOA-Project/Qualcomm-Reference-Drivers/blob/master/8180_CLS/200.0.62.0/qcppx8180.cab)

在 `qcppx8180.sys` 文件偏移 `0xc140`、`0xc150`，表项指向两套初始化记录（文件偏移 `0xd710`、`0x14050`）。两套都先切换 GCC 的 `0x6b000` 和 `0x6c01c`，对应 SC8180x 的 PCIe **端口 0** 控制器及 PHY 复位。两套的 PHY 电源控制均写 `0x6840`。同一张指针表随后执行 `0x6800 ← 0`、`0x6844 ← 3`，并在 `0x6814` 等待掩码 `0x40` 清零。这里是相对于端口的偏移，PHY 本身从 `0x6000` 开始。本机物理状态地址由此为 `0x01c06814`。上游 v7.0 用于 SC8180x 的双通道布局轮询 `0x01c06a14`，其第二条 RX 通道从单通道布局的 PCS 基址开始。[SC8180x GCC 复位映射](https://github.com/torvalds/linux/blob/v7.0/drivers/clk/qcom/gcc-sc8180x.c#L4516-L4523) · [Linux 单、双通道布局](https://github.com/torvalds/linux/blob/v7.0/drivers/phy/qualcomm/phy-qcom-qmp-pcie.c#L3416-L3434)

试验模块沿用上游 SC8180x 的模拟参数，只改用已有的 v4 单通道布局（TX `+0x200`、RX `+0x400`、PCS `+0x800`、PCS_MISC `+0xc00`）。原厂两套表的端口布局相同，部分调校有差异，包括两套都将 SSC_EN_CENTER 写为 0，Linux 对应值为 1。这一轮先检验布局。三星 DSDT 要求 AUX 19.2 MHz、REFGEN 100 MHz，与上游端口的 assigned clocks 一致。同代厂商 GCC 和 Linux 均未给 PCI0 PIPE gate 注册父时钟，Linux 读取的 PIPE 频率可能为 0，电气信号仍需另行验证。[三星 PEP](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L51954-L52046) · [Qualcomm SDMShrike GCC](https://android.googlesource.com/kernel/msm/+/6ef255005ceaae118d35fba8585de7ba1d4d5efb/drivers/clk/qcom/gcc-sdmshrike.c#2744) · [上游 7.0 DTS](https://github.com/torvalds/linux/blob/v7.0/arch/arm64/boot/dts/qcom/sc8180x.dtsi#L1799-L1821)

从上一轮含正确供电的日用 DT 构建独立产物：

```sh
work=/var/tmp/np545xla-diag
src/build-debian-wifi.sh --port0-x1 "$work/linux-7.0" "$work/obj" "$work/artifacts" output/daily/wifi-v3
src/build-debian-wifi-phy-dtb.sh --port0-x1 output/daily/v3/daily.dtb output/daily/wifi-v3/daily-pcie0-x1.dtb
```

`7.0.0-3` 包含与 `7.0.0-2` 逐文件 SHA-256 一致的 21 个原有模块，并加入 `np545_pcie0_qmp.ko` 外部试验模块。新模块只匹配试验 DT 的专用 compatible，加载前核对机型与 `phy@1c06000` 地址长度；正常启动后内核会对该外部模块记录 O 标记。软件包安装后，在 USB 的独立入口选择新 DT 并冷启动。旧入口仍选择原驱动，可以直接用于回退。新 DT 相对供电版只有 PCIe0 的 `num-lanes=1` 及其 PHY compatible 两处变更。下次启动从有线 SSH 收集：

```sh
sudo dmesg | grep -Ei 'PCIe0 x1|CCF rate|supply vdda|1c00000|ath11k|mhi'
grep -Hi '^PCI_ID=17CB:1101$' /sys/bus/pci/devices/*/uevent
iw dev
```

模块日志包含原驱动轮询的最后一个状态值（10 ms 超时，掩码 `0x40`）、CCF 报告的输入时钟、两个电源消费者启用状态和电压。RPMh 返回软件保存的供电投票；板上模拟电压需要仪器测量。正常冷启动即可获取这些指标，测试不使用运行时重新探测。[试验补丁](../patches/linux-7.0-sc8180x-pcie0-x1.patch) · [RPMh 查询实现](https://github.com/torvalds/linux/blob/v7.0/drivers/regulator/qcom-rpmh-regulator.c#L249-L261)

在相同的 Linux 7.0.0 上以 ARM64 UEFI QEMU 冷启动 USB 副本，实际安装 7.0.0-3 后同时加载两个模块。平台总线分别注册 `qcom-qmp-pcie-phy` 和 `np545-pcie0-qmp-phy`，单通道设备标识只解析到后者。端口 0 的电气链路及 QCA639x 仍需三星硬件验证。
