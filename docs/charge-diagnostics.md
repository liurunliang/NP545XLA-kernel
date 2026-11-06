# NP545XLA 的 USB-C 和充电芯片只读对照

现有 **Battery read-only test (Samsung)** 菜单项可以一起观察两路 USB-C PD、电池请求和 BQ25710 设置。运行 `sudo np545xla-charge-observe` 取一个样本，或用 `sudo journalctl -b -t np545-charge -o cat` 读取自启动以来的时间线。采样包括同次启动的 ID、启动时钟和每行读取耗时。每次读取后间隔两秒。日用和摄像头菜单不启动这个采样服务。

## 社区先例

- 普通版三星 Galaxy Book Go（NP340XLA）实测的 BQ25710 和智能电池位于同一总线的 0x09、0x0b。其 `gbgo-charge` 服务每 60 秒读取电池请求的电流、电压、温度和满充状态，经限幅后更新充电芯片。周期刷新针对芯片的充电看门狗。普通版服务使用该机型自己的总线和充电限制。[社区实现](https://github.com/xbill9/linux-arm-adventures/blob/34f76f5cbbe3a78f29b1768180fc323378cf5140/galaxy-book-go/scripts/gbgo-charge)
- Galaxy Book4 Edge（NP750XQA）的实现先处理端口：检测插线、接通 S2MM006 的输入开关、核实供电档位，再根据电池请求维持 ISL9241 的设定。该项目在真机上区分了插线检测、供电协商与实际到达充电器的电力。它使用另一套 PD 控制器和充电芯片，寄存器地址及策略只适用于原机。[社区程序](https://github.com/ciscobugger/book4-edge-linux/blob/1ff984a82f55570ae0473a80811db1b4b760616e/userspace/charging/book4-pd-charge) · [实测与寄存器说明](https://github.com/ciscobugger/book4-edge-linux/blob/1ff984a82f55570ae0473a80811db1b4b760616e/reports/ec/07-pdic-s2mm006.md)
- 在 ChromiumOS EC 中，共用充电任务负责处理电池请求、整机限制和电源状态，BQ25710 驱动只实现将目标转换成芯片寄存器值。这说明在另一类设备中，持续维护充电可以完全由嵌入式控制器承担，并非一定由桌面 Linux 进程负责。[ChromiumOS 充电任务](https://chromium.googlesource.com/chromiumos/platform/ec/+/refs/heads/main/common/charge_state.c) · [BQ25710 芯片驱动](https://chromium.googlesource.com/chromiumos/platform/ec/+/refs/heads/main/driver/charger/bq25710.c)
- NP545XLA 自身的三星 EmuEC.sys 包含选择 PDO、接通或断开 Consumer Switch、设置 BQ25710 输入限流和检查充电电流的代码字符串。其 ACPI EMEC 为 IC10 和 IC19 各列出 0x33，为 IC20 列出 0x09 和 0x0b。这些是定位实际信号的依据，不能用来证明本轮 Linux 执行了 Windows 的动作。[三星驱动包](https://github.com/tordona/woa-device-drivers/releases/tag/samsung-np545xla-drivers) · [本机 ACPI](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L93774)

## 读取边界

- S2MM005 读取状态 0x0020、收到的电源能力 0x0260 和发出的请求 0x0240。只在两次状态相同、已连接、角色为用电端且处于 Sink_Ready 时解释固定 PDO 请求。源能力和请求缓冲在拔线后可能保留旧值；请求电压是协议值，不能替代电压表。[三星寄存器与状态定义](https://github.com/LineageOS/android_kernel_samsung_universal9810/blob/lineage-17.1/include/linux/ccic/s2mm005.h) · [三星 PD 消息实现](https://github.com/LineageOS/android_kernel_samsung_universal9810/blob/lineage-17.1/drivers/ccic/s2mm005_pd.c)
- BQ25710 必须读到厂商 0x0040、器件 0x0089 后才采集设置。记录看门狗时限、充电禁止位、充电电流和电压设定、输入限流和 ADC 配置。芯片状态寄存器 0x20 的部分故障位是读后清除，采样器跳过该寄存器；不启动 ADC，不改写任何控制字段。持续电压转换未开启时，ADC 原始值不能代表当前 VBUS。[TI BQ25710 手册，第 9.3、9.6 节](https://www.ti.com/lit/ds/symlink/bq25710.pdf)
- 电池请求电流和电压来自智能电池自己的 0x14、0x15；它们与 BQ25710 同号寄存器的目标值、以及电池实际电流分别记录。此只读入口只启动采样服务。带电启动后的主动续充使用另一个独立入口。[BQ25710 续充试验](bq25710-keepalive.md)

## 重建与安装

在已验证的 ARM64 构建环境运行：

```sh
work=/var/tmp/np545xla-diag
src/build-debian-battery.sh "$work/obj" "$work/artifacts" output/charge
src/build-charge-boot.sh output/battery/boot output/charge/boot
```

在三星 USB Debian 上安装生成的软件包，执行 `sudo systemctl daemon-reload` 后运行 `sudo bash install-daily-boot.sh --battery-diag boot manifest.txt`。安装器核对当前电池菜单指纹，并将升级前的 EFI 备份到 `EFI/BOOT/BOOTAA64.EFI.pre-battery-diag`。新增两个空的 PD 总线描述，不绑定控制策略驱动；既有电池入口的名称和默认日用选择保持原样。

## NP545XLA 真机对照（2026-11-06）

操作者确认同一充电器接在原端口并保持开盖。使用原电池菜单正常重启，启动 ID 为 `0373768f-fb6f-42e2-b61e-d9d6f9248837`。本轮从启动时钟 18.15 秒开始记录，共 254 个样本。响应热插的是 IC10；IC19 通常返回地址无应答，唯一一次完整读数显示未连接，没有足够数据判断第二个端口。各行的 PD 电压和电流表示固定供电档位及请求值。

| 阶段（北京时间） | S2MM005，IC10 | BQ25710 | 电池 |
|---|---|---|---|
| 带电启动至 15:29:00 | Sink_Ready，第 3 档，12 V / 3 A | 身份 0040:0089，看门狗 175 秒，电流设定 3,776 mA | 有效样本的实际电流中位数 +1.179 A，容量 4,883→4,929 mAh |
| 15:29:00→15:29:04 | 同一就绪状态和请求，未观察到降档 | 启动时钟 162.47 秒仍为 3,776 mA，164.51 秒设定为 0；充电禁止位始终未置位，电压及输入限流设置未变 | 93%，仍请求 4,256 mA 和 8,860 mV。实测电流从 +1,107 mA 经 +46 mA 降到 0，容量保持 4,929 mAh |
| 15:31:41 起，拔线约 30 秒 | 观测到脱离（状态 0），间或无应答。此时缓冲内仍有旧请求，不将其当作有效供电档位 | 电流设定为 0 | 电池转为放电 |
| 15:32:15–15:35:10，插回原端口 | 87 个样本均为 Sink_Ready，第 1 档，5 V / 3 A。电源仍公布 12 V / 3 A 档位 | 电流设定持续为 0，无新的非零目标 | 电池仍请求 5,320 mA，实测电流中位数 −847 mA，容量 4,921→4,879 mAh |

**带电启动后停充。** 芯片只清除了电流目标，USB-C 就绪状态和电池非零请求在边界两侧保持一致。这次是在 93% 发生，与此前 88% 的结果相对照，更符合 TI 描述的主机长时间没有刷新电流或电压设定、看门狗到期清零的行为。看门狗从最后一次有效写入计时；启动时钟从 Linux 启动计时。最后一次固件写入时刻和芯片的内部超时事件不能直接从本轮读取。匹配本机的三星 EmuEC.sys 还有一条在特定条件下检查寄存器 0x14 并设置 3,776 mA 的分支，和启动后实际读到的数值相符。

**运行中插回电源。** 控制器重新检测到线缆并发出了新的 5 V 请求，而带电启动曾选择 12 V；充电器没有恢复非零电流目标。两者都是实测差异。协商就绪只说明协议状态。本轮没有确认从 USB-C 到整机的输入开关已闭合，也无法凭旧 ADC 数据断定实际 VBUS，因而不能把电池承担系统负载的原因唯一归于 5 V 档位或某只开关。

未经写入的测量保存在构建机的 `output/charge/samples-final.jsonl`。与测试前的 EFI 相比，只有已有电池项使用的 DT 路径及诊断服务启动参数发生变化。旧电池 DT 和启动器备份均保留。

采样后，两项一次性标记均为 0，正常重启进入原默认桌面，启动 ID 为 `9126bdda-b4cb-43aa-9bde-5b9310740460`。LightDM 活动，Adreno 的 separate_gpu_kms=N，测试服务未运行，设备使用同一个 USB 根分区。记录见 `output/charge/return.txt` 和 `daily-confirmed.txt`。
