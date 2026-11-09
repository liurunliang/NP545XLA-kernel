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


## 启动串口字节观测（2026-11-09）

复用现有私有模块与独立启动项，在 `hci_qca` 增加默认关闭的 `qca_startup_trace` 参数。它记录发送队列出队、H4 解析前的原始接收字节、切速前后的软件速率值。每次初始化最多记录 64 段，每段最多 64 字节；读到版本后、下载固件前停止，初始化最终失败时也停止。[构建脚本](../src/build-bluetooth-trace.sh)使用现有 lid 构建的私有挂载空间方法，保持原始源码、内核 Image、原模块、配置和符号文件不变。观测位置参考[上游 GENI 跟踪实现](https://github.com/torvalds/linux/commit/6e5bd7cc3a2f304a66d294011647d82074421979)。

```sh
bash src/build-bluetooth-trace.sh /var/tmp/np545xla-diag/linux-7.0 \
    /var/tmp/np545xla-diag/obj /var/tmp/np545xla-diag/artifacts NEW_OUTPUT_DIR
```

日志模块 SHA-256 为 `7213637eab43248b27ebd42513304d90e3710c274e41efdfec7b92f83b1423d1`，原模块为 `2f8c4ee61682cdb0954e5481396a0827875020ce54753741003ac127ff83ec00`。目标机复制整个私有模块目录到 `/usr/lib/np545xla-bluetooth-startup-trace`，只在副本替换 `hci_uart.ko`；服务的独立 drop-in 指向副本并传入参数。服务仍受 `np545.bluetooth=1` 限制。原模块目录保留。构建及安装取证在 `output/bluetooth/startup-trace/`。

3.2M 项在正常关机后自行开机，启动 ID 为 `dddb26d4-0892-460e-8925-e2f9cb26eba4`。用户确认没有再次按键，因此本次不能证明机器持续关机 10 秒的冷启动条件。GPIO170、GPIO46、供电配置与原测试项一致，日志参数实际读回为 `Y`。四轮初始化均失败，第一轮为：

| 开机后时间 | 观测 |
|---|---|
| 20.165040 s | 115200 下出队切速命令 `01 48 fc 01 11` |
| 20.167029 s | 收到 `00 40 8a 01 11`，随后 H4 返回 `-84` |
| 20.484041 s | 切速调用返回，软件报告 3200000 |
| 20.484090 s | 出队版本请求 `01 00 fc 01 19` |
| 20.484216 s | 收到 `00 00`，随后 H4 返回 `-84` |
| 22.496103 s | 版本读取失败 `-110` |

第三轮在 115200 下收到的五个字节与切速命令逐字节相同。其余三轮均为上述部分字节不同的五字节串；四轮切至 3.2M 后均只收到 `00 00`。这些是串口交给 HCI 驱动的字节，尚不能证明它们来自蓝牙芯片，也不能证明是硬件环回。`TX_DEQUEUE` 只表示驱动出队，`serdev_reported` 是软件返回值，都不是焊盘上的测量。

失败后短暂唤醒 UART13，只读检查非破坏性寄存器，再恢复原 `power/control=auto`。环回寄存器为零，IO 路由值为 `0x31c`，收发数据位均为 8、配置无校验。QUP 版本为 `0x10030000`，串口时钟框架报告 102.4 MHz，收发分频均为 1，符合该版本 32 倍采样下的 3.2M 配置。此快照采自初始化结束后，未覆盖切速瞬间，也没有示波器波形。

同次启动通过 `wlp1s0` 下载 Debian trixie Release 文件，内容与测试前逐字节相同，SHA-256 为 `ed56aac47e7911e65ee63aae8d67e29f20e023f840e49f8ed037043a33de138a`；传输期间 RX 增加 186264 字节、TX 增加 8328 字节。蓝牙管理接口仍报告零个控制器，尚不能执行目标设备扫描。


## 初始速率查询与冷启动取证（2026-11-09）

参考 RB5 等上游 QCA6390 设备默认的 3.0M 工作速率，只将测试设备树的 `max-speed` 从 3200000 改为 3000000；GPIO170 下拉、GPIO46 唤醒、共享供电和 Wi-Fi 路径都不变。排序后的 DTB 差异只有这一项，菜单差异只有蓝牙 DTB 摘要。测试 DTB 为 `1fed2cfb015e92fe3b3a2cd00707c85174b3384c302800a12ad005dd811e9b1d`；仓库默认蓝牙 overlay 仍为 3.2M。

第一次普通重启（`3f9a8a34-ded4-45d6-a902-b75aa6ebb66e`）未观察到 RX，版本读取超时，重试间隔较长。此后两次用户手动关机再开机，联网后实际读到的入口都是 Latest（`7c06c87d-944f-43ef-8625-dde0715554f7`、`277791c3-35fa-4717-84c1-faffbbaee47b`），缺少 `np545.bluetooth=1`。这两次不能计入蓝牙冷启动结果。旧 journal 只存内存，pstore 为空，无法据此确定中途是否启动过测试项或再次重启。

为避免日志继续丢失，临时增加有容量限制的持久 journal，以及按启动 ID 保存启动参数和前 180 秒内核日志的记录器。记录器滤掉已有的键盘 `incomplete report` 噪声，保存观察数据，不改硬件配置。临时设置、安装脚本和原始数据保存在 `output/bluetooth/startup-trace/`。

再次普通重启确认进入 3.0M 测试项（`859f7e7e-1774-45b1-b143-57f91305256e`）。20.066739 s 出队 `01 48 fc 01 0e`，20.068725 s 收到 `00 40 8a 01 0e`；切速后 20.382729 s 出队版本请求，20.383579 s 收到 `00 00`，22.397797 s 超时。后续三轮相同。说明异常可以在 115200 的切速命令阶段出现，不能只归因于 3.0M 与 3.2M 的选择。此次为普通重启，未冒充冷启动。

### 复用上游函数的低速单次诊断

给日志模块增加默认关闭、限定 NP545XLA QCA6390 的 `qca_initial_version_only` 参数。使能时保留上游电源和串口初始化，随后在 115200 直接调用上游 `qca_read_soc_version()`，不发送 `0xfc48` 切速命令。查询后关断蓝牙电源序列，不下载固件，也不继续控制器初始化；即使版本查询成功，仍以 `-ECANCELED` 结束诊断，不能把它当作可扫描的修复驱动。

```sh
bash src/build-bluetooth-trace.sh /var/tmp/np545xla-diag/linux-7.0 \
    /var/tmp/np545xla-diag/obj /var/tmp/np545xla-diag/artifacts NEW_OUTPUT_DIR \
    --initial-version-probe
```

这项构建先应用日志补丁，再应用 `linux-7.0-qca6390-initial-version-probe.patch`。整理后的脚本重新构建，模块与已部署产物逐字节一致，SHA-256 为 `d4b9354d32628a37941eb33970753bf870dec6054b6c21e48bdbff371fd12774`；原始内核、构建配置、符号和模块仍通过不变校验。

在同一测试启动中卸载并重新加载此诊断模块，使用上游电源序列重新启用蓝牙，得到：

| 开机后时间 | 低速单次查询 |
|---|---|
| 284.053843 s | 115200 查询开始，`serdev_device_get_cts()` 返回 1，即 CTS 有效 |
| 284.053987 s | 出队 `01 00 fc 01 19`，未先发送切速命令 |
| 284.055975 s | 收到 `00 40 fc 01 19`，随后 H4 报 `-84` |
| 286.081262 s | 版本读取 `-110`，CTS 仍有效 |

这些字节依然不能归因于芯片回显、板上短接或 DMA 中的某一种原因；尚无有效的版本事件。此项是运行中重新初始化的诊断，冷启动复测仍待完成。查询前后各通过 `wlp1s0` 下载同一个 Debian Release，内容相同，SHA-256 仍为 `ed56aac47e7911e65ee63aae8d67e29f20e023f840e49f8ed037043a33de138a`；包含两次下载的窗口内，Wi-Fi RX 增加 349142 字节、TX 增加 16653 字节。

### 避开自动重启的菜单交接

`np545_bluetooth_once=0` 继续使用默认 Latest；`=1` 沿用原来的单次蓝牙启动。新增 `=2` 仅用于准备冷启动：GRUB 将标记保存为 1，并停在显示出来的菜单，不加载 Linux。用户在菜单处手动关机、等待 10 秒后开机，下一次 GRUB 再消费 1，单次启动蓝牙项。这避免在已重新启动的 Linux 中强制断电，也避免测试标记在准备关机时提前被消耗。保存标记失败时不进入等待状态。

已安装菜单 SHA-256 为 `d86e7ec81e18cebd1feba385cd5494d790f2bb1540330f1c39c0f9773cd96fea`，回读与候选逐字节一致；菜单语法检查通过，新增逻辑之外的菜单、内核和 DTB 保持原样。源码构建可逐字节重现此 EFI。此时独立测试服务的 `72-initial-version.conf` 指向私有诊断副本，仍受 `np545.bluetooth=1` 限制。随后已完成菜单处关机的真机交接，结果见下节。

结束诊断时删除临时 `72-initial-version.conf` 可恢复字节日志模块；再移除 `70-startup-trace.conf` 可恢复原私有驱动。删除临时 boot-record 服务、`71-boot-record.conf` 和 `99-np545-bluetooth-investigation.conf` 后重新加载服务、重启 journald，可恢复原记录方式。保留已取回的记录和原始模块目录；清零单次标记后默认仍为 Latest。


## 已确认的菜单关机冷启动与 UART 对照（2026-11-09）

用户确认在 GRUB 菜单手动关机、熄灭约 10 秒后再开机。随后实际读到启动 ID `0d8ebe70-5bb7-4913-98c1-771609bb56b2`，命令行含 `np545.bluetooth=1`，两个诊断参数均为 `Y`。这次进入了预定的测试项；启动历史没有记录到中间的另一次 Linux 用户空间启动。

第一条低速查询在 20.213973 s 开始，CTS 逻辑值为 1。20.214217 s 出队 `01 00 fc 01 19`，20.216437 s 收到 `00 40 fc 01 19`，随后 H4 重组失败，22.241974 s 返回 `-110`，CTS 仍为 1。没有切速命令、有效芯片版本或固件下载；管理接口仍返回 0 个可用控制器。因此未进行两次标牌扫描，蓝牙验收仍未通过。

### 同次启动的 DMA / FIFO 比较

从同一 7.0.0 上游 `qcom_geni_serial.c` 构建临时独立模块，仅允许绑定 NP545XLA 的 `c8c000.serial`，不注册控制台。分别使用原 DMA 路径和上游已有 FIFO 收发操作，执行相同的 115200 单次版本查询，然后卸载临时模块、清除 `driver_override`、恢复内置 `qcom_geni_serial`。没有替换启动内核或安装临时 UART 模块到开机路径。

| 同次启动中的运行中查询 | DMA 模式寄存器 | 收到的数据 | 结果 |
|---|---:|---|---|
| 临时模块 DMA | 1 | 未记录到 RX | `-110` |
| 临时模块 FIFO | 0 | `00 40 fc 01 19` | `-110` |
| 恢复原内置 DMA | 1 | `00 40 fc 01 19` | `-110` |

两种模式记录的环回值均为 0，IO 路由值为 `0x31c`。初始速率时钟为 7,372,800 Hz、分频 2、32 倍采样。FIFO 也能复现异常，因此不能仅用 DMA 数据损坏解释；临时 DMA 那次无 RX 也保留在记录中。临时模块 SHA-256 为 `c8fe4991ae7aa61cc16bf99e0ba94bc4e9b3719336dfa1eeb36419b6f6961a21`，原源码、配置、符号表和 Image 的摘要均通过复核。

### GPIO43–46 的被动数字采样

只以 `O_RDONLY` / `PROT_READ` 读取 TLMM 状态，每次限时 0.5 秒，不写寄存器或请求 GPIO。引脚归属已核对上游 SC8180x 定义及真机 DT：GPIO43–46 位于 east tile `0x03500000`，GPIO170 位于 south tile。第一次采到 518802 个样本；随后加入 `dmb osh`，正序、逆序各再采一次，分别为 214048、214001 个样本，三次均无记录溢出。

三次都能按 115200 / 8N1 从 GPIO45 解码出 `01 00 fc 01 19`，五个停止位均有效。各次 GPIO45 有 18 次变化，GPIO46 有 17 次变化；第一组的 17 次 RX 变化与 TX 落在同一条记录，带屏障的正、逆序采样中，同方向边沿的最近记录时刻相差不超过 2344 ns。GPIO43 保持低，GPIO44 由高变低。查询前 RX 为低，不能把异常接收数据当成芯片版本回复。

这里只证明数字输入状态近乎同步，不能判定物理短接、芯片回显或模拟电压。采样顺序包含数次 MMIO 读取，并非同时采样；未变化且间隔不超过 4000 ns 的样本未逐条保存，不能把边沿附近约 1 µs 的间隔当成整个窗口的最大间隔。`CLOCK_MONOTONIC` 与 printk 时间也不能直接相减；后两次使用内核标记估计了约 15.4 ms 的时基差。原始数据及离线解码脚本已保留。

### 原厂配置和当前边界

核验了已缓存的 [NP545XLA 原厂驱动包](https://github.com/tordona/woa-device-drivers/releases/tag/samsung-np545xla-drivers)，压缩包 SHA-256 与发布页一致，为 `ec290dd56fc2844f48707751d769f6b425a8fa1cd7fdb56e5f3e4b4390900478`。匹配 `CLSC8180` 的蓝牙 INF 指定初始 115200、工作 3200000、`RadioGPIOControled=1` 和 `ExplicitRtsWakeup=1`。静态分析还能找到有条件的 RTS 清除 / 置位和各 5 ms 等待；这不是本机 Windows 运行时分支的证据，尚未据此修改 Linux 时序。

用户确认这台机器曾在 Windows 下实际扫描或连接成功，并要求进入 Windows 对照。下一阶段需核对这台机器当前的硬件 ID、UART 资源和驱动状态，再做实际扫描。历史可用不等于本轮 Windows 验收已通过。

本轮最后仍绑定原内置 UART，临时传输模块已卸载。经 `wlp1s0` 完成 138612 字节 HTTPS 下载，SHA-256 为 `ed56aac47e7911e65ee63aae8d67e29f20e023f840e49f8ed037043a33de138a`。LightDM、GPIO101 续充服务活动；ESP 回读仍为已验证的冷启动菜单，八个一次性标记均为 0，默认 Latest 保留。Windows 交接前保留私有低速诊断副本，便于随后做 Windows 到 Linux 的对照。

原始证据位于 `output/bluetooth/startup-trace/after-cold/`、`ordered-samples/`、`after-cold-final/`、`fifo-compare/`、`oem-uart/`；其中包括源码、构建记录、完整内核片段、采样和菜单回读。上述 UART 变体和数字采样均为运行中实验，不冒充另一轮冷启动。


## Windows 对照采集

`docs/dump/NP545XLA-BluetoothBaseline.ps1` 使用 Windows 自带 PnP、CIM、PnPUtil、注册表读取和公开蓝牙 API，读取当前机器的硬件 ID、UART 资源、实际服务与驱动文件摘要、设备参数、DSDT 及近期蓝牙日志。默认尝试两次 12.8 秒 BR/EDR inquiry，间隔 3 秒；`-SkipInquiry` 可只取静态信息。它不配对设备、不改驱动或注册表，也不切换蓝牙开关。没有 `-UploadUri` 时，所有报告只保存在 Windows 本机 `%LOCALAPPDATA%\NP545-Bluetooth\`。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\NP545XLA-BluetoothBaseline.ps1
```

该 API 不发现仅支持 BLE 的设备；搜索结果同时记录记忆 / 配对状态和原始 last-seen 时间，不能把缓存中存在设备当成两次现场扫描成功。Windows 返回的 LMP / HCI 运行时版本也不等同于 Linux 在下载固件前请求的 `0xfc00` ROM 版本。[Windows inquiry API](https://learn.microsoft.com/en-us/windows/win32/api/bluetoothapis/nf-bluetoothapis-bluetoothfindfirstdevice) · [射频信息结构](https://learn.microsoft.com/en-us/windows/win32/api/bluetoothapis/ns-bluetoothapis-bluetooth_radio_info)

PowerShell 语法解析、嵌入 C# 编译及 64 位原生结构大小检查均已通过。随后在 Windows 真机执行，结果见下节。为交接 Windows，已在仍为 `0d8ebe70` 的 Debian 中校验 USB 和 EFI，将蓝牙单次标记从 0 设为 2，并发送正常重启；GRUB 应保存为 1 后停在菜单。用户可在菜单处关机并移除 Debian U 盘，再启动原 Windows。下一次插回 USB 开机会单次运行现有蓝牙诊断，此后默认仍是 Latest。该交接没有设置固件 BootNext；当前内核的 EFI 变量不可用。


## Windows 原厂驱动实测与重启回 Linux（2026-11-09）

用户确认已进入原 Windows，并授权通过临时局域网入口回传本轮硬件、驱动、ACPI 和蓝牙报告。采集运行于 Windows 11 ARM64，PowerShell `5.1.26100.9711`。未配对设备、替换驱动、修改注册表或固件启动项；回传完成后已关闭临时接收服务。原始报告、接收摘要和对照结果保存在忽略目录 `output/bluetooth/windows-baseline/`，不将机器私有报告纳入提交。

### 本机驱动、资源及版本

- 当前蓝牙传输设备为 `ACPI\VEN_QCOM&DEV_0471&SUBSYS_CLSC8180`，对应 `\_SB.BTH0`；UART 为 `ACPI\QCOM0418\12`，对应 `\_SB.UR18`，内存资源 `0x00C8C000–0x00C8FFFF`。二者及蓝牙 radio 的设备状态均为 OK、问题代码为 0。
- 正在运行的 `QcBluetooth` 为 `1.0.1560.0000`，`qcuart` 为 `1.0.1600.0000`。两份 SYS 文件的 SHA-256 分别为 `b9d07c02b42e8bb1e0816a6325de41e76d9be9b72c6eaeed1e40dc2194b389be`、`804aed0f9dd97473933d258f22f65b09aefa1613abfc58a21ad137106a0ed7df`，与前述原厂包逐字节一致。
- 本机蓝牙驱动类参数实际读到 `DefaultBaudRate=115200`、`BaudRate=3200000`、`ExplicitRtsWakeup=1`、`RadioGPIOControled=1`、`SWInBandSleepEnabled=1`。UART 的 Instance 18 配置为 `UartClass=2`、`EnableGsi=0`、`GpiiId=1`、`DeleteComPort=1`。注册表设定值不等同于测量过的电气时序或确认执行过某条驱动分支。
- 当前 DSDT 为 394195 字节、校验和有效，SHA-256 `6164c3d674c97c03914aa8fb67257cacc8893f4954a6b6690049f4e7f3efc6e9`。与现有同型号参考表只有 5 个字节不同：表校验和，以及 `SOSN` 常量内的 4 个字节。其他字节完全相同，包括蓝牙、UART 和 GPIO 资源描述；没有发现需改换串口或 GPIO 编号的差异。
- Windows radio API 成功返回 manufacturer `0x001d`、LMP subversion `0x380c`；PnP 属性另外报告 LMP / HCI version 均为 `0x0b`。这是 Windows 固件运行后的版本，不能当作 Linux 的下载前 `0xfc00` ROM 版本回复。

### 两轮标牌发现

第一次运行的两个 12.8 秒 inquiry 中，第一轮现场发现了目标标牌，第二轮没有返回该地址。因此没有将首次运行判为连续发现成功。随后保持标牌可发现，在同一次 Windows 启动中使用 `-InquiryOnly -InquiryTimeoutMultiplier 20` 复测，跳过重复硬件采集，每轮请求 25.6 秒 inquiry：

| 复测轮次 | 单调计时耗时 | 同一目标地址 | 本机记录的 last-seen |
|---|---:|---|---|
| 1 | 25.633 秒 | 找到 | 13:11:47.940 |
| 2 | 27.403 秒 | 找到 | 13:12:18.374 |

两轮的错误码均为 0，同一目标的 `Remembered` 和 `Authenticated` 均为 false，last-seen 分别落在各自的新扫描窗口内。第二轮还有另一台同名标牌，验收按地址交集核对，未仅凭名字合并。两轮连续发现通过；未做配对或音频传输验证。Windows 与 Mac 的墙钟存在偏差，上表只比较同一 Windows 内的时间，不跨机器计算延迟。

两份 ZIP 摘要分别为 `8927605094846af53e26dc9446dab95594c6809b08d65be848bcf658d41370f2` 和 `699c564218cf42a0e416daca88fb4066868949d313c85e5b71a69edab89e65fd`。首次采集访问服务注册表某个受保护子树时失败，未生成 `service-parameters.json`；关键蓝牙参数已从当前驱动类 `Parameters` 读出。采集器现将服务参数读取限定为三个 Qualcomm 服务，避免遍历 `BTHPORT` 配对密钥，并增加独立扫描模式、扫描时长参数和单调计时。新增扫描模式已在真机完成上述复测；收窄后的完整注册表采集路径仅完成语法检查，未再在 Windows 重跑。

### Windows 到 Linux 的对照

用户插回原 Debian U 盘，在 Windows 选择“重新启动”。进入的实际启动 ID 为 `742a1eb1-9cf9-4283-bed0-f7f0fcad1b85`，命令行含 `np545.bluetooth=1`，仍从原 USB 根分区启动，低速单次查询与日志参数均为 `Y`，测试 DT 的 `max-speed` 仍为 3000000。本次是 Windows 到 Linux 的正常重启，不能计作新的冷启动。

| 开机后时间 | 结果 |
|---|---|
| 19.724192 s | 115200 单次版本查询开始，CTS=1 |
| 19.724963 s | 发送 `01 00 fc 01 19` |
| 19.726952 s | 收到 `00 40 fc 01 19`，随后 H4 `-84` |
| 21.728269 s | 查询返回 `-110`，CTS 仍为 1 |

Windows 可正常通信和扫描，没有使本轮 Linux 低速握手恢复。未读到有效 ROM 版本，也未进入 Linux 标牌扫描。当前证据支持继续核对 Linux 与原厂的初始化、流控和引脚状态切换；还不能指定某一处时序为根因。

查询后经 `wlp1s0` 实际下载 138612 字节 Debian Release，摘要仍为 `ed56aac47e7911e65ee63aae8d67e29f20e023f840e49f8ed037043a33de138a`。仍使用内置 UART 驱动，临时 FIFO / DMA 模块未加载，LightDM 和 GPIO101 续充服务活动。回读 USB EFI 与原冷启动菜单一致，八个单次标记均为 0，默认 Latest 保留。记录在 `output/bluetooth/startup-trace/after-windows-complete/` 和对应启动历史目录。另保留首次取证因设备树路径写错而提前退出的 `after-windows/`；该错误不涉及硬件写入，随后在同次启动完成采集。

随后正常重启进入默认 Latest，实际启动 ID 为 `a6c85b80-7f0c-4941-95c3-63f232c36a69`，同一 USB 根分区，命令行不含 `np545.bluetooth=1`，蓝牙测试服务 inactive。LightDM 与 GPIO101 续充服务 active；该默认启动再次经 Wi-Fi 完成同一文件下载，大小和摘要与测试项一致。独立诊断副本及有容量限制的启动日志暂保留，供后续初始化对照；未改变默认入口。


## RTS 唤醒调用及寄存器对照（2026-11-09）

参考本机已核验的 Windows 原厂驱动，增加默认关闭的 `qca_initial_rts_wake`。它仅在 NP545XLA、QCA6390 和 `qca_initial_version_only=1` 同时满足时生效，在 115200 版本查询前撤销 / 恢复 RTS，各等待约 5 ms。使用上游 `hci_uart_set_flow_control()` 相同的 serdev 调用，并记录 RTS 返回码和原始 TIOCM 值；仍不下载固件、不进入扫描。原厂 `bt_hci_qca_wakeup_valkyrie` 分支有 CTS 条件，本实验强制执行一次脉冲，不能据此声称 Windows 在本机执行了该分支。

安装的是独立模块副本和临时 `73-rts-probe.conf`；未更换 Image、DTB 或 EFI。正常重启进入测试项，启动 ID `6587b5a8-1ce1-49c4-b150-aaf6b2c48693`，不计作冷启动。先按关闭 / 开启 / 关闭参数做 A/B/A，三次均发送 `01 00 fc 01 19`、收到 `00 40 fc 01 19`，最终 `-110`。GPIO44 数字输入均只采到一次下降沿，因此最初仅能确认调用发生，不能确认脉冲到达引脚。

进一步记录返回值，并用只读 MMIO 对照 UART 的 `SE_UART_MANUAL_RFR`、`SE_GENI_IOS` 和 GPIO43–46。读取 UART 寄存器的三组窗口统一临时将串口 `power/control` 设为 `on`，确认 runtime active；退出恢复 `auto`，实际回读 suspended。自动省电下的第一组仅采 GPIO，不读取可能已关时钟的 UART。每次采样限时 0.5 秒、无溢出；这些都是同次启动中的运行中诊断。

| 诊断条件 | RTS 调用 / TIOCM | 接收的五个字节 | 版本结果 |
|---|---|---|---|
| 自动省电，脉冲开启 | 两次返回 0；358 → 354 → 358 | `00 40 fc 01 19` | `-110` |
| 保持串口运行，脉冲关闭 | 不额外切换 | `00 40 fc 01 19` | `-110` |
| 保持串口运行，脉冲开启 | 两次返回 0；358 → 354 → 358 | `01 00 fc 01 19` | `-110` |
| 保持串口运行，再次关闭 | 不额外切换 | `01 00 fc 01 19` | `-110` |

保持运行时，脉冲组在 GPIO44 采到约 5.848 ms 的高电平窗口；同窗口 RFR 读值从 0 变为 `0x80000000`，再回到 0。GPIO43 仍为低。原始 TIOCM 非负、CTS 位保持有效，RTS 位实际切换，因此这次可以排除把 serdev 错误返回误当作 CTS 的解释。寄存器读回没有保留 READY / NOT_READY 命令位，不能把读值直接当成软件写值。数字输入不代表模拟电压测量。

此后接收数据与发送命令完全相同，也不是 HCI 事件；没有读出芯片版本。A/B/A 的后一个基线仍出现相同变化，不能将接收字节变化独归因于 RTS 脉冲。单独补这个时序和保持串口运行均未恢复握手。后续转向固件及原厂初始化代码的离线分析。

首版模块摘要 `4f3db155560efea2a722a97534c8d8bdc4578315e752ad2a6c28fee1da2f431a`；带返回值版 `f0c83fadf8dc2185d8a1b26bb7e58a2a24ac3e911dcc38699f6884869ea610e7`。两次构建都核验原源码、Image、配置、符号表和原模块不变。源码、构建、原始采样及分析保存在忽略目录 `output/bluetooth/rts-wake/`。

结束时撤销本轮 73 覆盖，恢复原 72 低速诊断配置；UART 仍绑定内置驱动，`driver_override` 为空。EFI 摘要仍为 `d86e7ec81e18cebd1feba385cd5494d790f2bb1540330f1c39c0f9773cd96fea`，八个单次标记均为 0。随后实际进入默认 Latest，启动 ID `05e6607c-82c9-4ab8-8758-fe53561fae24`，命令行没有蓝牙标记、hci_uart 未加载、测试服务 inactive，LightDM 和 GPIO101 续充服务 active。测试项和默认项分别经 `wlp1s0` 下载 138612 字节，摘要均为 `ed56aac47e7911e65ee63aae8d67e29f20e023f840e49f8ed037043a33de138a`。
