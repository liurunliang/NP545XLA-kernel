# Debian U 盘上的 QCA6390 蓝牙测试项

三星从 GRUB 的 **Debian 13 - QCA6390 Bluetooth test (Samsung)** 进入独立测试项。默认入口为 **Debian 13 - Latest (Samsung)**。两者使用同一个已验证的 7.0.0 内核、USB 根分区和 GPIO101 续充服务。测试项单独使用带蓝牙节点的设备树，`np545.bluetooth=1` 才会加载私有模块目录里的上游蓝牙驱动。测试时从 Debian 的 BlueZ 软件包单独解包工具。

## 接线与供电

Windows 的蓝牙子系统 ID 为 `CLSC8180`。三星的 Hastings UART 驱动 INF 匹配这个 ID，初始速率为 115,200，工作速率为 3,200,000。Debian 的 `firmware-atheros` 提供了同名的 `qca/htbtfw20.tlv` 和 `qca/htnv20.bin`。三星 ACPI 里的 `UR18` 对应 `0x00c8c000`，即 Linux 的 `uart13`。测试使用 GPIO43–46 的串口引脚，通过上游 QCA6390 电源驱动控制 GPIO170。Wi‑Fi 继续使用原有 PCIe 路径和使能线。[Windows 硬件记录](dump/NP545XLA-hw-dump/hw-enum.txt#L2051) · [三星 BTH0 资源](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L96861) · [上游 QCA6390 驱动](https://github.com/torvalds/linux/blob/v7.0/drivers/bluetooth/hci_qca.c) · [RB5 的 QCA6390 接线](https://github.com/torvalds/linux/blob/v7.0/arch/arm64/boot/dts/qcom/qrb5165-rb5.dts)

最终试验使用三星 WBRX 列出的 S5A、S6C 和 S7C。S5A、S6C 沿用当前系统已有的电压设置，S7C 选择满足固件 950 mV 请求的最低硬件档位 952 mV。测试项让这条共享电源保持开启，避免蓝牙关断影响 PCIe 无线网卡。[三星 WBRX 电源请求](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L51384) · [测试设备树](../dts/sc8180xp-np545xla-bluetooth.dtso)

## 重建和安装

在之前构建 USB 内核的 Debian arm64 环境中，以已安装且校验过的 Latest 菜单为基础构建。安装器会核对 USB 根分区 UUID、ESP、原菜单和载荷，先备份原 EFI，再加入内容寻址的蓝牙 DTB 和新菜单。

```sh
k=/var/tmp/np545xla-diag
bash src/build-bluetooth-drivers.sh "$k/linux-7.0" "$k/obj" "$k/artifacts" output/bluetooth
bash src/build-bluetooth-boot.sh output/latest/boot output/bluetooth/boot
# 在目标三星上，从复制好的包、boot 目录和原 USB 镜像清单所在目录执行
sudo dpkg -i ./np545xla-bluetooth_7.0.0-1_arm64.deb
sudo bash install-daily-boot.sh --bluetooth boot manifest.txt
```

## 2026-11-06 真机结果

设备树中的串口绑定到了上游 `hci_uart_qca`。第一次冷启动生成 `hci0`，驱动发送读取芯片版本指令 `0xfc00` 后返回 `-110`（超时）。分别测试 3.2 Mbaud 和 115,200，以及固件维持供电和真实 RPMh 供电，均未读出 QCA 产品、SoC、ROM 或补丁版本。尚未进入蓝牙固件下载阶段。

临时版本探针独占同一串口做了对照。打开硬件流控时 CTS 持续未就绪，放开流控后收到了刚发出的版本指令原字节。硬件环回寄存器为零。显式 RTS 唤醒、高通 IBS 唤醒以及释放蓝牙使能后，都没有得到有效的 HCI 版本应答。探针随后卸载，串口交还上游驱动。这些观测将故障定位在固件下载之前的串口握手，尚不能判定具体是哪条信号或上电时序导致。

最终配置在正常关机、机器重新上电后进入测试项（启动 ID `06ce4ec0-3ddb-4ed6-9fd9-9d4153a8243c`）。`hci0` 位于 `c8c000.serial`，绑定 `hci_uart_qca`。从开机第 21.48 秒到第 28.68 秒，四次 `0xfc00` 版本读取全部超时。标准 HCI Read Local Version 同样没有得到回复。内核 Bluetooth Management 的 Read Index List 返回 0 个控制器，两次针对索引 0 的 Start Discovery 均返回 `0x11`（Invalid Index）。两轮均止于启动扫描，未取得 `[Signage] Samsung QMR Series` 的广播或查询结果。

同次启动通过 `wlp1s0` 关联 5 GHz 接入点，向无线网关发送的 3 个 ICMP 报文全部收到回复。将 HTTPS 连接绑定到这张网卡下载 Debian trixie 的 `InRelease`，收到 140,421 字节，SHA-256 为 `0584fba32e13e0ab8285fb16c27adea1ec03a73669c18702821094fd6ca86675`，与启用蓝牙前的对照文件逐字节一致。传输期间无线接口 RX 增加 158,292 字节、TX 增加 8,342 字节。

本次 USB 安装的 EFI SHA-256 为 `eec0245f39ec48702754a9aeda31d02b5e1d683858b48c4a8d4517e506600a0c`，蓝牙 DTB 为 `7e651c79753eaceda84b9cc3833163ea58511cc2c9f7b5553714984189e7d040`。八个一次性启动标记回读都为零。工作区的 `output/bluetooth/verified/` 保存了这次冷启动、管理接口和串口采样记录。

普通重启后已回到默认 Latest（启动 ID `774c19fe-f6b9-48aa-9954-8eee8814112d`），同一 U 盘上的 `/dev/sda3` 正常挂载，LightDM 活动，`wlp1s0` 已联网，蓝牙测试服务为 inactive。
