# Debian USB 上的 QCA639x 无线网卡

三星的 Windows 硬件清单记录了 QCA639x，PCI 标识为 `17cb:1101`、子系统为 `17cb:0108`。Linux v7.0 的 `ath11k_pci` 能匹配这个标识。设备树中的 `wifi@18800000` 则描述 SC8180x 集成的 WCN3990，两者使用不同的总线和驱动。[Windows 硬件清单](dump/NP545XLA-hw-dump/hw-enum.txt) · [Linux ath11k 支持列表](https://wireless.docs.kernel.org/en/latest/en/users/drivers/ath11k.html)

2026-11-05，NP545XLA 在 USB Debian 的单通道设备树上冷启动，PCIe0 建立 Gen2 ×1 链路，`ath11k_pci` 启动 QCA6390 hw2.0 固件，`wlp1s0` 扫描到 45 个无线接入点。采集时 SSH 使用 USB 有线网卡，无线接口处于 `disconnected`。仍待验证的项目包括关联并认证到指定接入点、通过无线 DHCP 获取地址、传输数据，以及拔掉网线后继续使用网络。

## PCIe 端口依据

检查三星 DSDT 的 `PRP0` 至 `PRP3`、`PCI0` 至 `PCI3` 下的 `_STA`，以及 `QPPX._RST`。这份固件将端口 0、3 标为可用，将 1、2 标为关闭。复位辅助方法只在端口 0 的特定板型分支脉冲 `WLEN`，端口 3 控制 SDX55，端口 2 分支为空。早期板级 DTS 据以选择 PCIe2 的 `PNID=2` 在反编译表中只有定义。可选的无线设备树片段因此启用 PCIe0 和它的 QMP PHY，停用 PCIe2、对应 PHY 以及 WCN3990 节点。[三星 DSDT](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl) · [无线设备树片段](../dts/sc8180xp-np545xla-wifi.dtso)

首次试验沿用固件留给 WLAN 的引脚和外部供电状态。片段不指定 `PERST`、`WL_EN` 或新的稳压器电压。ACPI 的 `GWLE` 描述 GIO0 引脚 169，脉冲条件还涉及板型与 ID；本次冷启动沿用这套引脚配置，端口成功枚举。

## 建立和安装

在同一个 Debian ARM64 构建机使用生成当前 USB 内核的源码、编译树和诊断产物。脚本核对 Image 和内核配置，执行内核符号、模块依赖、无线 PCI 别名检查，并验证片段能应用到三星设备树。

```sh
work=/var/tmp/np545xla-diag
src/build-debian-wifi.sh --port0-x1 "$work/linux-7.0" "$work/obj" "$work/artifacts" output/daily/wifi-v3
(cd output/daily/wifi-v3 && sha256sum -c wifi.sha256)
```

包中包括 QMP PCIe PHY、MHI、QRTR-MHI、ath11k、mac80211 及其运行时加密模块，以及触控板试验使用的 `hid_multitouch`。它保留原 USB 镜像里的内核和显示驱动。在笔记本 Debian 上使用有线连接安装本地包和辅助工具：

```sh
sudo apt install ./np545xla-wifi-modules_7.0.0-3_arm64.deb iw rfkill
sudo update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream
```

包依赖 `firmware-atheros` 和 `wireless-regdb`。Debian 包为 QCA6390 hw2.0 提供 `amss.bin`、`m3.bin`、`board-2.bin`。监管数据库提供两套签名，由 alternatives 同时切换数据库及其签名。这个自编内核信任 Linux 主线内置的监管数据库公钥。[Debian 固件清单](https://packages.debian.org/trixie/all/firmware-atheros/filelist)

模块包 `7.0.0-2` 补充了 `sha256.ko`。Debian 的上游监管数据库签名使用 SHA-256；cfg80211 会在加载数据库时调用 PKCS#7 验证，按签名中的算法名请求 `sha256`。这个内核的底层 SHA-256 库已内建，向 Crypto API 注册算法的驱动则按模块构建。升级已经运行的系统后，执行 `sudo iw reg reload` 可让 cfg80211 重新读取签名。[Linux 7.0 监管数据库验证](https://github.com/torvalds/linux/blob/v7.0/net/wireless/reg.c) · [PKCS#7 摘要选择](https://github.com/torvalds/linux/blob/v7.0/crypto/asymmetric_keys/pkcs7_verify.c) · [SHA-256 算法注册](https://github.com/torvalds/linux/blob/v7.0/crypto/sha256.c)

用正式 Image 和同一份 Debian `wireless-regdb 2026.05.30-1~deb13u1` 启动两次离线 QEMU。两次均载入了 sforshee 与 wens 的 X.509 证书。旧包导致 cfg80211 报告数据库签名无效，测试设置国家规则后仍显示 `country 00`；新包自动载入 `sha256` 并正确读出测试规则 `country DE: DFS-ETSI`。两次测试均未使用射频硬件。

在构建机上从已关闭内置 UFS 的 Debian 设备树生成独立的单通道 DTB，交给 USB 的独立 GRUB 入口。以部署中使用的日用 DT 为基础可保留该版本的输入设备配置。已经启用 PCIe0 的供电试验版 DTB 可以直接从下面的第二条命令开始。

```sh
fdtoverlay -i debian-base.dtb -o debian-wifi.dtb output/daily/wifi-v3/sc8180xp-np545xla-wifi.dtbo
src/build-debian-wifi-phy-dtb.sh --port0-x1 debian-wifi.dtb daily-pcie0-x1.dtb
fdtget daily-pcie0-x1.dtb /soc@0/ufshc@1d84000 status   # disabled
fdtget daily-pcie0-x1.dtb /soc@0/pcie@1c00000 num-lanes  # 1
```

## 前两次 PCIe0 冷启动

2026-11-05 从日常入口启动后，`1c06000.phy` 已绑定到 QMP 驱动，PCIe0 的供应设备均已就绪。启动日志在 20.499792 秒记录 `phy initialization timed-out`，PCIe0 随即返回 `-ETIMEDOUT`，系统没有枚举到无线 PCI 设备。Linux v7.0 在此处已启动本地 SerDes/PCS，等待 PHY 状态就绪超时；PCIe 接口尚未开始链路训练。运行中的 regulator summary 显示该 PHY 的两个电源消费者均指向 dummy regulator。[QMP 初始化及超时条件](https://github.com/torvalds/linux/blob/v7.0/drivers/phy/qualcomm/phy-qcom-qmp-pcie.c)

在同次启动的 195.404497 秒，通过 `drivers_probe` 只重探了 PCIe0。最后取到的日志是主桥地址范围，随后有线 SSH 失去响应。后续使用独立入口冷启动，不复用这次在线重探操作。

第二个试验 DT 只将 PCIe0 PHY 的 `vdda-phy` 接至 LDO5_E（0.88 V）、`vdda-pll` 接至 LDO3_C（1.20 V）。三星 PEP 的 PCI0 D0 供电记录和上游 SC8180x 板级 PHY 定义支持这个对应关系。第二次实机冷启动时运行中的 DT 已提供这两个属性，regulator summary 已列出两个 PHY 消费者。沿用双通道布局时，启动后 18.989 秒仍报告 PHY 初始化超时，PCIe0 主桥返回 `-110`，无线接口未出现。原始记录保存在本地 `output/daily/v3/cold-result.txt`。

```sh
src/build-debian-wifi-phy-dtb.sh daily.dtb daily-wifi-phy-supplies.dtb
```

## 端口 0 的单通道 PHY 布局依据

三星 Windows 清单中，设备 `ACPI\QCOM04A2\0` 使用 Qualcomm PCIe Platform Extension Plugin 1.0.1600.0，日期为 2021-07-17。Qualcomm 8180 CLS 200.0.62.0 参考包中，`qcppx8180.inf` 的硬件 ID、版本和日期全部吻合。以下偏移来自这个参考包里的原厂 ARM64 驱动，三星本机安装的 SYS 尚未取出做哈希比对。CAB 的 SHA-256 为 `5ffa71ad40056fb1dda96382ec5fc30f75536a98bf15ae37de596943464c6682`，解包后的 SYS 为 `198faec8195a142e8efb7f2f2fd4b24e9eeb584293cf8f86f2bb65e390c5c2d2`。[三星驱动记录](dump/NP545XLA-hw-dump/qualcomm-drivers.txt#L273-L277) · [参考包中的 Qualcomm 原厂文件](https://github.com/WOA-Project/Qualcomm-Reference-Drivers/blob/master/8180_CLS/200.0.62.0/qcppx8180.cab)

在 `qcppx8180.sys` 文件偏移 `0xc140`、`0xc150`，表项指向两套初始化记录（文件偏移 `0xd710`、`0x14050`）。两套都先切换 GCC 的 `0x6b000` 和 `0x6c01c`，对应 SC8180x 的 PCIe **端口 0** 控制器及 PHY 复位。两套的 PHY 电源控制均写 `0x6840`。同一张指针表随后执行 `0x6800 ← 0`、`0x6844 ← 3`，并在 `0x6814` 等待掩码 `0x40` 清零。这里是相对于端口的偏移，PHY 本身从 `0x6000` 开始。本机物理状态地址由此为 `0x01c06814`。上游 v7.0 用于 SC8180x 的双通道布局轮询 `0x01c06a14`，其第二条 RX 通道从单通道布局的 PCS 基址开始。[SC8180x GCC 复位映射](https://github.com/torvalds/linux/blob/v7.0/drivers/clk/qcom/gcc-sc8180x.c#L4516-L4523) · [Linux 单、双通道布局](https://github.com/torvalds/linux/blob/v7.0/drivers/phy/qualcomm/phy-qcom-qmp-pcie.c#L3416-L3434)

试验模块沿用上游 SC8180x 的模拟参数，只改用已有的 v4 单通道布局（TX `+0x200`、RX `+0x400`、PCS `+0x800`、PCS_MISC `+0xc00`）。原厂两套表的端口布局相同，部分调校有差异，包括两套都将 SSC_EN_CENTER 写为 0，Linux 对应值为 1。本次实机成功建链时使用 Linux 的现有模拟参数。三星 DSDT 要求 AUX 19.2 MHz、REFGEN 100 MHz，与上游端口的 assigned clocks 一致。同代厂商 GCC 和 Linux 均未给 PCI0 PIPE gate 注册父时钟，Linux 本次读取的 PIPE 报告值为 0，随后控制器完成 Gen2 ×1 链路训练。[三星 PEP](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L51954-L52046) · [Qualcomm SDMShrike GCC](https://android.googlesource.com/kernel/msm/+/6ef255005ceaae118d35fba8585de7ba1d4d5efb/drivers/clk/qcom/gcc-sdmshrike.c#2744) · [上游 7.0 DTS](https://github.com/torvalds/linux/blob/v7.0/arch/arm64/boot/dts/qcom/sc8180x.dtsi#L1799-L1821)

`7.0.0-3` 在原有 21 个模块之外增加了 `np545_pcie0_qmp.ko`，原有模块已与 `7.0.0-2` 逐文件核对 SHA-256。新增模块只匹配专用 compatible，加载前核对三星机型和 `phy@1c06000` 的地址与长度。相对第二轮，第三轮 DT 仅改动 PCIe0 的 `num-lanes=1` 和 PHY compatible。有线环境下启动旧入口即可使用原驱动回退。在同版 ARM64 UEFI QEMU 中也已验证两个平台驱动可以同时注册。[试验补丁](../patches/linux-7.0-sc8180x-pcie0-x1.patch)

## 单通道冷启动实测

| 层级 | 三星实机观测 |
| --- | --- |
| PHY | 18.134 秒读到 `PHY+0x814 status=0xa6`，掩码 `0x40` 已清零，`power_on=0`。时钟框架报告 AUX 19.2 MHz、REFGEN 100 MHz。两个 RPMh 电源消费者均已启用，报告值分别为 880000 µV 和 1200000 µV。 |
| PCIe | 18.599 秒报告 `PCIe Gen.2 x1 link up`（5.0 GT/s）。`0000:01:00.0` 枚举为 `17cb:1101`、子系统 `17cb:0108`，与 Windows 记录一致。 |
| 固件和无线接口 | `ath11k_pci` 识别 `qca6390 hw2.0`，获得 32 个 MSI 向量。MHI 上电成功，固件回报版本 `0x10121492`、构建时间 `2021-11-04 11:23`。19.364 秒时无线接口从 `wlan0` 更名为 `wlp1s0`。 |
| 无线扫描 | NetworkManager 列出 45 个可见接入点。记录时 `wlp1s0` 为 `disconnected`，USB 有线网络和 XFCE/X11 会话在线。 |

以上数据来自本地 `output/daily/wifi-v3/cold-boot.txt`、`cold-dmesg.txt` 和 `radio.txt`。RPMh 电压是软件供电投票值。冷启动后可经有线 SSH 复查 PHY、PCI 设备和射频扫描结果。[RPMh 查询实现](https://github.com/torvalds/linux/blob/v7.0/drivers/regulator/qcom-rpmh-regulator.c#L249-L261)

```sh
sudo dmesg | grep -Ei 'PCIe0 x1|CCF rate|supply vdda|link up|qca6390|fw_version'
cat /sys/bus/pci/devices/0000:01:00.0/uevent
iw dev wlp1s0 link
nmcli -t -f BSSID device wifi list ifname wlp1s0 --rescan yes | sort -u | wc -l
```
