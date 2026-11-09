# NP545XLA 蓝牙固件与原厂初始化对照

2026-11-09。最新进展：GPIO170 控制权对照已两次读出有效 ROM 版本，完整固件加载及可用 hci0 已验证；冷启动自动修复和同一目标连续两轮发现仍未完成。下文按阶段保留静态分析及真机证据，早期失败结论以末节的控制权对照更新。

## 设备路径已核对到实际绑定

Windows 本轮报告中，`BTH0` 的依赖提供者包含 `ACPI\QCOM0418\12`；后者的 BIOS 名为 `\_SB.UR18`，设备为 COM4，PnP 分配内存 `0x00C8C000–0x00C8FFFF`、主 IRQ 617。当前 Windows DSDT 与已有参考表的蓝牙、UART 资源正文一致。

Linux 测试启动 `5c5444d7-3870-47d9-a7fe-c4d1f3e4a33d` 的 sysfs / 运行中设备树重新回读结果：

| 层级 | 实际值 |
|---|---|
| 平台设备 | `/sys/devices/platform/soc@0/cc0000.geniqup/c8c000.serial` |
| UART 驱动 | `qcom_geni_serial` |
| DT 节点 | `/soc@0/geniqup@cc0000/serial@c8c000` |
| 内存范围 | 起始 `0x00C8C000`，长度 `0x4000` |
| 主中断 | GIC SPI 585，即包含前 32 个 GIC 中断后的编号 617 |
| RX 唤醒 | GPIO46、下降沿 |
| 蓝牙子设备 | `serial0-0`，实际绑定 `hci_uart_qca` |
| 蓝牙 compatible | `qcom,qca6390-bt` |
| 当前测试 DT 的 max-speed | 3000000；本轮初始查询为 115200 |

真机启动日志把 `c8c000.serial` 注册为 `ttyHS1`，再注册 serdev 控制器 `serial0`。同次启动的 `ttyHS0` 对应另一条 `0x00A90000` 串口。现有测试通过设备树和 serdev 绑定，没有手工向 `ttyHS0` 发送命令。Windows 的 UR18、Linux 的 uart13、ttyHS1 和 serial0 是不同编号体系，不能直接按后缀数字配对。

[三星 UR18 / BTH0 资源](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L69913)、[测试设备树](../dts/sc8180xp-np545xla-bluetooth.dtso)、[上游 SC8180x UART13 定义](https://github.com/torvalds/linux/blob/v7.0/arch/arm64/boot/dts/qcom/sc8180x.dtsi#L1569)互相吻合。这个结论排除了当前配置选错 UART 地址的疑点，但尚未证明板上电气路由、蓝牙使能和全部供电状态正确。

## 已拆出的固件与 NVM

原厂文件来自已缓存并核验摘要的 NP545XLA 驱动包，其 `qcbtfmuart_hst8180.sys` 与本机 Windows 当前 SYS 文件一致。原厂 TLV / NVM 本身尚未在 Windows 本机做摘要回读，不能仅凭同一驱动包证明它就是本轮 Windows 实际下载的内容。Debian 文件则直接从本轮真机 `/lib/firmware/qca/` 取回。

| 文件 / 字段 | 原厂包 | Debian 真机 |
|---|---|---|
| `htbtfw20.tlv` 大小 | 207208 字节 | 210704 字节 |
| SHA-256 | `f359f3ff8d6d7a1e18bd0ad14554e0357ddfe42647de195763736ac0a19defcf` | `3fbe07f93d170b1483c1c7f71bdfd6c98862281bfc10898b8cd537b700f688ec` |
| TLV 产品 / ROM 字段 | `0x10` / `0x0200` | `0x10` / `0x0200` |
| TLV patch version | `0x380d` | `0x3ac0` |
| 内嵌版本字符串 | `BTFM.HST.2.0.0-00928-QCACHROMZ-1.411415.4` | `BTFM.HST.2.0.0-00943-QCACHROM-1` |
| `htnv20.bin` 大小 / 标签数 | 5825 字节 / 51 | 5857 字节 / 53 |
| NVM SHA-256 | `33bd520b5ebcf8b58a0e743fc1a18ece49d4d01df87ce397c096b3fa33e6c94f` | `a4c0cbafc102998805679a2947aa82dd3b0abf1a1c0b372f1630b8ea327e2e8a` |

使用[上游 btqca 的 TLV 结构](https://github.com/torvalds/linux/blob/v7.0/drivers/bluetooth/btqca.h)解析，四个文件的外层长度均与实际文件一致。新增的离线工具 [inspect-qca-firmware.py](../src/inspect-qca-firmware.py)检查长度、标签边界与重复 ID，并按标签 ID 对比；不修改文件、不向设备加载内容，也不声称验证了签名或校验算法。四个实物文件通过解析，另检查了七种损坏结构的拒绝行为。

```sh
python3 src/inspect-qca-firmware.py OEM/htbtfw20.tlv --compare DEBIAN/htbtfw20.tlv
python3 src/inspect-qca-firmware.py OEM/htnv20.bin --compare DEBIAN/htnv20.bin
```

41 个共同 NVM 标签完全相同，10 个不同：27、28、36、37、38、44、64、83、154、178；Debian 另有 54、157。HCI 传输标签 17 的六字节在两侧都是 `15 11 22 00 2e 00`。上游把标签 27 作为深睡眠配置处理；两文件该标签的偏移 1、5、8 不同。其他未知标签没有仅凭字节差异猜测含义。[上游处理位置](https://github.com/torvalds/linux/blob/v7.0/drivers/bluetooth/btqca.c#L319)

Linux QCA6390 本来就选择 `htbtfw%02x.tlv` 和 `htnv%02x.bin`。固件字符串内另出现 `PF=QCA6690`，但同系列 Linux 固件也有该字符串，不能据此更换板子的 compatible。上述静态 patch 版本也不能直接等同于 Windows radio API 返回的 LMP subversion。

## 指令级分析的边界

原厂 TLV 的文件偏移 `0x28` 开始可解析为 ARM Thumb 指令。文件 `0x24` 的字值为 `0x222cc`；按 `0x28 → 0x222cc` 建立候选映射后，初始函数读取的绝对字符串指针 `0x5406a` 正好指向文件偏移 `0x31dc6` 的版本字符串。Debian 文件使用同一候选映射，其指针对应 `0x54e1e → 0x32b7a`。这是代码内部交叉引用支持的静态映射，未在芯片上读取执行 PC。

入口包含大量初始化调用，并向低地址的函数表写入 Thumb 函数指针。例如文件 `0x446` 的短函数将 `0x22695` 写入 `0x21d90`，将 `0x226b3` 写入 `0x21dc4`。文件 `0x3e4` 的跳板还把包外地址 `0x100d7f63` 装入返回 PC。因而现有 TLV 是依赖包外代码的下载补丁，无法单独还原芯片上电 ROM 的全部行为；没有取得完整 ROM 镜像。

保留了有边界的入口、函数表安装及跳板反汇编。没有把数据池的线性反汇编当成可执行路径，也没有把这些指令当成真机执行轨迹。

## 原厂驱动中的首条查询和等待

以下 VA 仅适用于已核验的 `qcbtfmuart_hst8180.sys`，SHA-256 为 `b9d07c02b42e8bb1e0816a6325de41e76d9be9b72c6eaeed1e40dc2194b389be`。Windows SYS 为 ARM64，芯片下载补丁为 Thumb，分析时分开处理。

| 代码位置 | 静态证据 |
|---|---|
| `0x140004c60` | 版本请求函数构造 opcode `0xfc00`、单字节参数 `0x19`，与上游查询相同 |
| `0x14001f328` | 带 `FdoDevFirmwareInitialize` 字符串的初始化函数，先设置串口速率、读取通信状态 |
| `0x14001f418–0x14001f434` | 读取 `0x140020588` 的有符号常量 `-2000000`，通过 IAT `0x14005d310` 调用 `KeDelayExecutionThread` |
| `0x14001fa78` | 初始化函数调用上述版本请求函数，失败后另有重试路径 |

IAT 名称已核对为 `ntoskrnl.exe!KeDelayExecutionThread`；按 Microsoft 定义，负数为相对等待，单位为 100 ns，因此该常量代表 200 ms。[Microsoft 接口定义](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-kedelayexecutionthread)

这提供了一个可检验的时序差异，不证明本机本轮 Windows 经过了所有静态分支。原厂的完整重试、串口清队列及 GPIO 流程尚未全部复现到 Linux。

## 200 ms 单变量真机对照

独立诊断参数 `qca_initial_settle` 默认关闭，只在 NP545XLA QCA6390 的单次初始速率版本探测中增加 200 ms 等待。保留 RTS 探测关闭、现有 115200 查询、原 UART 驱动和自动省电。构建核验原源码、配置、符号表、Image 和原 hci_uart 模块未变；新模块 SHA-256 为 `4031a4529e93b059bcb07000418f1a6b5f6c2f57a640a990bfab4ef777189b98`。

正常重启进入测试启动 `5c5444d7-3870-47d9-a7fe-c4d1f3e4a33d` 后，同次启动按原等待 / 增加等待 / 原等待执行 A/B/A：

| 组别 | 查询开始（开机后） | 接收数据 | 结果 |
|---|---|---|---|
| 原等待 | 151.271899 s | `00 40 fc 01 19` | `-110` |
| 额外 200 ms | 156.659521 s | `00 40 fc 01 19` | `-110` |
| 恢复原等待 | 161.667916 s | `00 40 fc 01 19` | `-110` |

中间组的等待从 156.456074 到 156.659494 s，实测 203.420 ms。三组均只发送 `01 00 fc 01 19`，没有 FC48、有效版本或固件下载。单独加这段等待未恢复握手。初版分组脚本因为匹配了标记末尾不存在的空格而在首组取证后退出；修正了记录匹配，在同次启动重做完整 A/B/A，首版原始日志仍保留。该脚本错误没有改变固件或 GPIO 设置。

原厂 / Debian 文件、摘要、离线解析、反汇编及本轮真机记录保存在忽略目录 `output/bluetooth/reverse/`。这些文件支持后续继续检查原厂串口寄存器、GPIO170 和 WBRX 电源过程；目前没有足够证据将问题归因于固件版本或某一个引脚。

## 恢复日用入口

删除本轮 `73-settle-probe.conf`，保留此前独立测试模块配置；USB EFI 摘要未变，八个单次启动标记均为 0。正常重启回到 Latest，启动 ID 为 `238765e7-63d6-4654-ab35-dae753b8a85b`，命令行没有 `np545.bluetooth=1`，没有加载 `hci_uart`。LightDM 和 `np545-gpiocharge.service` 分别检查均为 active。绑定 `wlp1s0` 下载 Debian Release 得到 138612 字节，SHA-256 为 `ed56aac47e7911e65ee63aae8d67e29f20e023f840e49f8ed037043a33de138a`。

## GENI 上游流控修复对照（2026-11-09）

UART 地址正确不代表 GENI 初始化正确。核对当前内核源码（SHA-256 `16111293677a5a2975f2b1942bbf914af8e955b64fef2f5b0a6bca79a5bf1a8c`）后，发现两个可复用的流控修复未包含：

- [RTS 流控修复 `0b1837c04d23`](https://github.com/torvalds/linux/commit/0b1837c04d2335ec50b9a55b0282dcde7bc12439)：增加 `manual_flow`，启用硬件流控时避免 `set_mctrl()` 强行把 RTS 置为不接收。
- [AUTOCTS v2 提案](https://lkml.iu.edu/2610.2/17019.html)：启用硬件 CTS 时设置 `UPSTAT_AUTOCTS`，避免串口核心同时使用软件 CTS 停发。作者报告 Motorola Moto G10 / WCN3950 的蓝牙初始化曾卡住，并提交了真机验证。这是已查阅的提交提案，不在此声称其已被当前内核合入。

2024 年的 [DMA RX 取消修复](https://lkml.iu.edu/2410.1/02807.html)已包含：当前 `qcom_geni_serial_stop_rx_dma()` 等待 `RX_EOT`，失败后重置 RX DMA 状态机。此前 FIFO 也未读到有效版本，不能仅根据相同的 `0xfc00` 超时报错归因于这项旧 DMA 缺陷。

### 本次真机证据及限制

沿用此前独立 DMA / FIFO 模块的隔离方式，临时模块只允许绑定 NP545XLA 的 `0x00c8c000` UART，不注册控制台。两项修复分别由默认关闭的参数控制；记录流控、软件队列和 DMA 回调，最多 64 条状态日志。原 UART 源码、HCI 源码、配置、符号表、Image 和原 HCI 模块的摘要在构建前后相同。模块 SHA-256 为 `4c3ac815f1d8cceedd3c120577874f9e8d514c3d3193c09d825e9680c7bd340c`。构建仅出现裁剪控制台注册后的两个未使用函数警告。

正常重启进入独立测试项，启动 ID 为 `d9b502db-f61f-4159-b08f-407043b2b4d3`，不是冷启动。回读完整日志发现，**内置驱动在 19.716633 s 的首次查询就已报告 CTS=0**，不是换绑临时模块才出现。因此本次不能直接复现此前 CTS=1、收到 `00 40 fc 01 19` 的条件。

| 条件 | 实际观察 | 版本结果 |
|---|---|---|
| 启动时原内置驱动 | CTS=0，无接收数据 | `-110` |
| 临时模块，两项关闭 | 状态 `0x1`，未记录 DMA 发送回调，CTS=0 | `-110` |
| 仅 RTS 修复 | 相关流控调用的 RFR 保持 0，CTS 仍为 0 | `-110` |
| 仅 AUTOCTS 修复 | 状态变为 `0x9`；出现 `start_tx_dma`、队列 5 字节，未观察到 DMA 发送完成或接收 | `-110` |
| 两项同时开启 | 初始化发生约 30 s 的等待；147.959738 s 才开始查询，158.183050 s 超时 | `-110`，组内采集流程提前结束 |
| 最后恢复基线组 | 未执行 | 无结果 |

这证明诊断开关改变了对应的驱动行为，没有证明五个命令字节已从物理引脚发出，也没有证明这两项修复能解决本机故障。后续复核发现这里的 `hw_stopped` 实际读取了 TTY 字段，并不是串口核心的 `uart_port->hw_stopped`，不能据此排除串口核心停发。没有获得有效芯片版本、下载固件或进行扫描。

组合组的准备等待超过原脚本固定的 6 s 取证窗口，结果标记检查失败；自动清理的 45 s 等待也不足，临时 UART 模块曾保留。待 HCI 模块实际退出后，另行卸载临时 UART 模块、清空 `driver_override`、重新绑定内置 `qcom_geni_serial`，均已回读确认。没有将该脚本记录为完成的五组 A/B/A；后续若继续该方式，应按实际查询结束事件等待，并先统一初始 CTS 状态。

### 恢复与后续判断

本轮没有新增永久服务覆盖、替换已安装内核或修改日用设备树。USB EFI 摘要仍为 `d86e7ec81e18cebd1feba385cd5494d790f2bb1540330f1c39c0f9773cd96fea`，八个单次启动标记均为 0。随后正常进入 Latest，启动 ID 为 `7a8a8292-698d-4140-90a9-2e12ee04ca0d`；没有蓝牙测试命令行，也没有加载临时 UART 模块或 `hci_uart`。LightDM、GPIO101 续充服务分别检查为 active。经 Wi-Fi 下载仍为 138612 字节、摘要 `ed56aac47e7911e65ee63aae8d67e29f20e023f840e49f8ed037043a33de138a`。

原始日志、源文件、上游补丁、生成脚本、构建结果、失败组和恢复证据保存在忽略目录 `output/bluetooth/geni-flow/`。下一步应优先保持原驱动从开机起的绑定，记录 GENI 控制器与 GPIO / 电源的初始化交接，确认 CTS 为何在不同启动中不同。当前仍不能在上游控制器驱动、本机引脚配置和蓝牙电源状态之间确定根因；也没有证据将已下载到磁盘的蓝牙 TLV 当成已执行过的故障来源。

## GPIO170 控制权定位与首次有效版本（2026-11-09）

本轮已读到有效芯片版本、完成通用固件加载，并使 hci0 进入可用状态。直接阻断此前握手的一项缺口是 GPIO170 的 eGPIO 控制权。冷启动自动修复以及原定同一标牌连续两轮发现，尚未在本节所述试验中通过。

### 原驱动启动观测与原厂对照

第一次内置 GENI 观测启动为 `6bee9bfe-1fed-4696-9104-02be0cc719bb`，没有运行中换绑 UART。GPIO43 输入为高、GENI 报告 CTS=0，两者一致；GPIO170 控制寄存器为 `0x0a01`，使能时 IO 从 0 变成 2，仅输出锁存变化，输入回读仍为低。GENI 主 / 从固件寄存器均为 `0x20b`，loopback 为 0，IO macro 为 `0x31c`。

SC8180x 引脚表没有 eGPIO 元数据。GPIO170 的控制寄存器 bit11 已置位，bit12 未置位；上游通用 pinctrl-msm 使用前者判断 eGPIO 能力、后者取得 APSS 控制权。没有取得控制权时，APSS TLMM 配置会被忽略。[上游说明](https://lkml.rescloud.iu.edu/2202.1/03850.html)；[SM8250 补齐同类能力的提交](https://git.zx2c4.com/linux-rng/commit/drivers/pinctrl?id=b39e9199fbe1df6c8c510c52c24b5db35020e705)。SM8250 的引脚范围不等于 SC8180x 的已验证范围。

缓存的三星 `qcgpio8180.inf_arm64_0465d80aa7d1a73e/qcgpio.sys`，SHA-256 `e0b4d6fa5d13fe8a2b007564fbed7765279e127dffc2db488017b0072f2631cb`，也包含相同操作。在 VA `0x140002320` 的代码段中，按引脚编号左移 12 位并加 tile 偏移定位寄存器；`0x140002450` 测试 `0x800`，`0x140002454–0x140002460` 在具备能力时合入 `0x1000` 后写回。最初的线性反汇编在无法解码的字节处中断，改为执行节内逐个对齐的 ARM64 指令读取后才找到此段；没有把所有解码数据都当作真实执行路径。该 GPIO SYS 只核对了驱动包身份，未核对本轮 Windows 实际加载文件的摘要，也没有取得 Windows 寄存器执行轨迹。

同时修正观测字段：此前流控日志读取的是 `tty->hw_stopped`，不是串口核心使用的 `uart_port->hw_stopped`。旧日志不能证明串口核心未停发。后续镜像分别记录 `uart_port->hw_stopped` 和 `tty->flow.stopped`。

### 同次启动的控制权 A/B 对照

启动 ID `eaae97d6-e49b-4392-bd22-0fd5adadb3c3`，Image SHA-256 `072e7a5f5d26fc0d85c0d4529fa6c104d4682671b0cc436c1d9fcf8e9389c48d`。GENI 从开机起保持原绑定，RTS 和 AUTOCTS 修复开关都为关闭。

临时控制只在显式测试启动、三星机型及 SC8180x TLMM 上出现；由原 GPIO 驱动的锁保护，只允许 GPIO170 已是 GPIO 输出低时改 bit12，写 0 恢复捕获的原位值。其他控制位和引脚不改。每组卸载 HCI 客户端后再切换，并用同一个单次 115200 查询模块测试。

| 条件 | 查询时间（开机后） | 结果 |
|---|---|---|
| 启动基线，`0x0a01` | 20.070029 s | CTS=1，收到异常五字节，`-110` |
| 取得控制权，`0x1a01` | 137.548868 s | CTS=1，21 字节有效回复，返回 0 |
| 恢复原控制位，`0x0a01` | 138.728528 s | CTS=0，无有效回复，`-110` |
| 再次取得控制权，`0x1a01` | 141.004949 s | CTS=1，相同有效回复，返回 0 |

两次有效回复均为 `04 0e 12 01 00 fc 00 19 0c 10 00 00 00 2b 0d 00 02 00 02 0a 40`，上游解析 Product `0x10`、SoC `0x400a0200`、ROM `0x0200`、ROM 阶段 patch `0x0d2b`。取得控制权时，使能后的 IO 为 3，输入和输出都为高；恢复原位值时只到 2。35 秒引脚采样为 699997 次、最大间隔 115621 ns、无溢出。173.173615 s 恢复 `0x0a01`，然后才进入完整初始化试验。

初版分组脚本使用系统默认模块索引卸载私有 HCI 模块，提前退出，未更改控制位。修正为按实际已加载模块卸载后，完整对照才执行。原退出记录与后续证据均保留。

### 固件加载、真实地址与扫描边界

重新取得 GPIO170 控制权，并关闭 `qca_initial_version_only` 后，保留现有 3.0M 速率，上游流程成功读取版本，加载 Debian 的 `htbtfw20.tlv` 和 `htnv20.bin`；226.072112 s 报告 `QCA setup on UART is completed`。没有启用 GENI 流控修复，也没有替换为原厂 TLV。

此时管理接口把 hci0 列为 unconfigured，缺少 `public-address`，实际地址是通用 NVM 的占位值 `00:00:00:00:5A:AD`。使用前一轮 Windows radio API 回传的本机真实地址，经 BlueZ 标准 Set Public Address 配置；它触发异步重新初始化，不能仅在命令完成后的固定 3 秒就判断失败。随后 hci0 为 UP RUNNING，HCI/LMP 5.2、Qualcomm 29、LMP subversion `0x3abf`，收发错误计数为 0。[上游占位地址处理](https://lkml.rescloud.iu.edu/2404.0/03287.html)；[BlueZ 配置接口](https://bluez.readthedocs.io/en/latest/mgmt-api/#set-public-address-command)。实际地址保存在本机产物，不写死到通用设备树源码。

扫描已收到周边设备的真实 HCI / MGMT 发现事件，第二个长窗口发现了 Windows 报告中另一台同名标牌（地址末尾 `4D:73`）。但先前目标（末尾 `2C:5F`）没有连续两轮出现，不能记录为原定扫描验收通过。用户补充现场有多台标牌且距离较远，漏扫本身不能据此归因为蓝牙故障。

首次 `btmgmt --timeout ... find` 没有打开管理通道、没有发出发现命令，已清理等待进程；直接管理接口随后发出了真实 inquiry，但自然结束后的 Stop Discovery 返回 Rejected，脚本退出并保留原始事件。随后 HCI 查询的两个记录窗口分别约 2.38 秒和 25.63 秒，第一轮没有新的 Inquiry 命令，不能算作独立完整的 25.6 秒扫描。第二轮抓到了新的 Inquiry 及成功完成事件。这些不足都没有用缓存设备列表补齐。

两次并行 Wi-Fi 下载均得到 138612 字节和 SHA-256 `ed56aac47e7911e65ee63aae8d67e29f20e023f840e49f8ed037043a33de138a`。续充服务在 GPIO 对照之前（开机约 60 秒）已因没有等到原口 12 V 而退出，不能称本轮续充服务复核通过；用户已确认原口重新接电，后续启动继续复核，充电代码未修改。

内置 GENI 首次观测、原厂 GPIO 分析及控制权对照原件分别保存在忽略目录 `output/bluetooth/geni-native/`、`output/bluetooth/owner/`。本节证明运行中修正控制权可恢复握手与完整初始化；冷启动自动配置仍是下一项验收。
