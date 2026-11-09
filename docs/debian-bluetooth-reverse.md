# NP545XLA 蓝牙固件与原厂初始化对照

2026-11-09。蓝牙尚未通过 Linux 验收：第一条版本查询仍超时，尚未取得有效 ROM 版本、完成两轮扫描或证明冷启动可用。本记录区分固件文件的静态分析、Windows 已运行驱动的身份核对，以及 Debian 真机诊断。

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
