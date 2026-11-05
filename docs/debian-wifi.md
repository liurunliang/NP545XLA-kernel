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
