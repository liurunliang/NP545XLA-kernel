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

## GPIO170 单变量冷启动对照（2026-11-06）

分别从正常关机进入原蓝牙项和下拉版，各一次。两次使用同一 U 盘、内核、QCA6390 驱动和临时只读采样器。对已编译的设备树排序反编译后，唯一的差异是 `bt-enable-state` 中的 `bias-disable` 改为 `bias-pull-down`。GRUB 菜单中只有蓝牙项引用的 DTB 摘要发生变化。GPIO46 的配置、3,200,000 波特率、Wi-Fi 路径和默认 Latest 均沿用原设置。

采样器在 QCA6390 供电与 UART 驱动加载前启动。每 200 µs 读取一次 TLMM 的 GPIO170 控制寄存器、输出锁存和输入位，以及 GPIO43（CTS）的输入位，持续 35 秒。被动 HCI 监听记录索引 0 的首个版本请求 `00 fc 01 19`。下表均为开机后的单调时钟秒数，HCI 时间取主机收到监视记录时的时间。

| 真机记录 | 原版（禁用偏置） | 下拉版 |
|---|---:|---:|
| 启动 ID | `c835ee5f-7389-4974-b8e1-ae02e2e7914c` | `dd6839c0-9bf1-4163-b5aa-2fc9a0079dcd` |
| GPIO170 输出锁存首次 0 → 1 | 19.868092 s | 19.579240 s |
| 首个 `0xfc00` / 距置位 | 20.352668 s / 484.58 ms | 20.060339 s / 481.10 ms |
| 首次超时 | 22.375822 s | 22.083588 s |
| GPIO170 输入位，置位前 → 置位后 | 0 → 0 | 0 → 0 |
| GPIO43 输入位，置位前 → 置位后 | 1 → 1 | 1 → 1 |

两组在驱动接管前均读到 GPIO170 的下拉配置。原版接管后清除了下拉，下拉版则在置位前后都保有下拉，输出使能均为 1。两组各采到 175,002 次，无记录溢出，最大相邻采样间隔分别为 365 和 344 µs。窗口内均未采到 GPIO43 变低；CTS 为低有效。GPIO170 置位前后的数字输入读数与输出锁存是独立观测，未测量焊盘的模拟电压。

首个指令在两组中均未收到有效 HCI 版本事件，驱动均返回 `-110`。此次下拉配置不足以恢复版本握手。新 DTB SHA-256 为 `cbefd7885609f98d4a8bf508b11151999c6e15085d0e4b9da37b5e6f0cc7bbdc`。两组的电平、命令时间线、内核日志、差异及临时采样器源码保存在工作区的 `output/bluetooth/gpio170-pulldown/`。

试验结束后八个一次性启动标记均为零；三星正常重启进入默认 Latest（启动 ID `64c3a79d-9983-444f-ae8a-6e66b5b412d3`），仍从同一 U 盘运行，LightDM 活动，临时采样模块和服务已移除。

## GPIO46 的 RX 下降沿唤醒（2026-11-06）

在 GPIO170 已下拉的测试项上，UART13 的主中断仍为 GIC SPI 585（高电平触发），第二个中断指定 TLMM GPIO46（下降沿触发）。RX 工作时保持 `qup13` 和上拉；GENI 关闭串口资源时，只有 RX 切为 GPIO 输入并下拉。两种树解析后的供电引用、GPIO170 配置、3,200,000 波特率及 Wi-Fi 路径均相同。蓝牙项的 GRUB 菜单差异仅为 DTB 摘要。[三星 UR18 资源](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L69913) · [测试设备树](../dts/sc8180xp-np545xla-bluetooth.dtso) · [上游 GENI 资源切换](https://github.com/torvalds/linux/blob/v7.0/drivers/soc/qcom/qcom-geni-se.c#L597-L645)

基线和新版分别从正常关机进入测试项，新版另做一次相同的冷启动。三次都在驱动初始化前开启只读采样，在 35 秒内按 50 µs 周期读取 GPIO46、GPIO43、GPIO170 的 TLMM 状态，并以同一单调时钟记录被动 HCI 监听结果。各次均未溢出，最大采样间隔分别为 131、137、225 µs；采样可以观察数字电平变化，但不能还原 3.2 Mbaud 的串口字节。

| 真机结果 | 基线（仅 GPIO170 下拉） | 加 GPIO46 唤醒 | 同一新版复测 |
|---|---:|---:|---:|
| 启动 ID | `6faf95d8-1c03-4628-b3bf-8d4b1e98c0a9` | `f15832fd-5f86-42e7-ba49-ac99e0c616be` | `9b25f0b1-2b3a-4a12-8bff-12d38ac23bf5` |
| GPIO170 首次置位至首条请求前采到的 RX 电平变化数 | 0 | 5 | 7 |
| 首条请求时，GPIO46 / GPIO43 输入 | 低 / 高 | 高 / 低 | 高 / 低 |
| 首条 `0xfc00`，开机后秒数 | 19.676377 | 20.768836 | 20.156392 |
| 首次命令超时，开机后秒数 | 21.699635 | 22.782415 | 22.173680 |
| 首轮握手后读到的累计专用唤醒 IRQ 数（含重试） | 无专用 IRQ | 4 | 3 |

两次新版启动均注册了 `c8c000.serial:wakeup`（Linux IRQ 167、硬件 GPIO46），电源管理的 wakeup 状态为 enabled。首条请求时 GPIO46 已恢复为 UART 功能和上拉，GPIO43 保持 UART 功能，数字输入为低（CTS 有效）。两次 GPIO46 在 35 秒窗口内均采到 22 次电平变化，其中包括休眠引脚状态切换，不能把变化数当成收到的字节数。

复测中，IRQ 计数从 0 首次增到 1 被定位在开机后 22.171606–22.173909 s，与首条请求超时处于同一窗口。第一次版本请求后，两次新版都记录了 H4 帧重组错误 `-84`，均没有可由 HCI 层确认的版本事件，最终为 `-110`。结论是专用唤醒 IRQ 有活动，两次新版都出现 RX 活动和有效 CTS，芯片版本仍未读出。此处验证的是冷启动和串口运行时电源管理，整机合盖唤醒未做测试。

新版 DTB SHA-256 为 `d24e97db822d43d3460a0eb5f25ae3ea3b51ebe7ab64d5303ea2e224b4de33fa`。原始采样、IRQ 计数、HCI 日志、设备树和 GRUB 差异在工作区 `output/bluetooth/gpio46-rx-wake/`。

八个一次性标记均已清零。三星普通重启进入默认 Latest（启动 ID `31c676f5-22fa-492e-ace1-d6fcdbf21aca`），同一 Debian U 盘、LightDM 和 Wi-Fi 正常，蓝牙测试服务 inactive，临时观测器已移除。
