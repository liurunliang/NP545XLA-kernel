# NP545XLA 的 USB-C 热插 12 V 测试项

Debian U 盘新增 **USB-C hotplug 12 V test (Samsung)**。使用已经验证的 IC10 充电口、一只 12 V / 3 A 充电器，集线器仅连接 U 盘和网络。带电开机后先读取原适配器的固定供电档位、BQ 的适配器输入状态和端口的受电开关。只有在本次启动观察到真实脱离状态及电池放电后，才对重新插入的电源执行恢复。

## 本机依据和控制范围

- 三星 NP545XLA 的 EmuEC.sys 在 RVA `0xda98` 的函数向 S2MM005 的 0x0010 发送选择 PDO 和改变接收端状态的两条命令。RVA `0xe44c` 的分支为新选择使用状态 19（Select_Capability）。适配程序从实时的 Source_Capabilities 中寻找与本次带电启动一致的固定 12 V / 3 A 档位，再从发出的请求和 Sink_Ready 回读确认结果。三星公开的 S2MM005 驱动也使用这一对命令。[本机三星驱动包](https://github.com/tordona/woa-device-drivers/releases/tag/samsung-np545xla-drivers) · [三星 S2MM005 实现](https://github.com/LineageOS/android_kernel_samsung_universal9810/blob/lineage-17.1/drivers/ccic/s2mm005_pd.c)
- 同一二进制的 RVA `0xc690` 查询供电和受电开关，RVA `0xca30` 设置开关，RVA `0xce88` 和 `0xe914` 处理短路与湿度状态。测试只操作原端口，核对稳定用电角色、干燥和短路状态。如果已协商 12 V 且输入路径仍关闭，只尝试接通受电方向一次，并核对开关和 BQ 的 AC_STAT。已发现充电芯片由其他路径供电时退出。
- BQ25710 在拔线后可能恢复输入电流寄存器的复位值 0x4100。恢复期间只允许将它降低到本机带电启动已测得的 0x3c00，并读回输入限流。随后沿用 8,760 mV 的原电压，按电池自身请求、温度和状态限幅，充电电流上限 1,024 mA，保留 175 秒看门狗。首次给电池恢复电流后限时检查实际电流是否转正。读取 ChargerStatus 会确认部分故障位，因此发现任何故障即停止本次尝试。[TI 手册 §9.6.2、§9.6.6](https://www.ti.com/lit/ds/symlink/bq25710.pdf)

## 构建和取证

```sh
work=/var/tmp/np545xla-diag
src/build-debian-battery.sh "$work/obj" "$work/artifacts" output/hotplug
src/build-keepcharge-boot.sh --hotplug output/keepcharge/boot output/hotplug/boot
python3 src/test-charge-keepalive.py
```

在当前三星 USB Debian 上安装生成的三个包，再运行 `sudo systemctl daemon-reload` 和 `sudo bash install-daily-boot.sh --battery-hotplug boot manifest.txt`。安装器复用原 DT，核对前一版 EFI 并保留 `EFI/BOOT/BOOTAA64.EFI.pre-battery-hotplug`。新增项沿用只读采样器，独立选择自己的写入服务。

```sh
sudo journalctl -b -t np545-hotplug -o cat
sudo journalctl -b -t np545-charge -o cat
```

测试查看同一启动中原口脱离、实际放电、重新接入、12 V / 3 A 就绪、芯片输入有效、恢复刷新，以及从恢复刷新计时超过 175 秒后的电池电流和剩余容量。

## 真机起始条件（2026-11-06）

启动 ID `7130ccda-6c19-4c99-b15b-53869f258ee6` 使用新的独立入口。开机第 19.597 秒看到原端口第 3 档 12 V / 3 A，受电开关为 1，BQ 的适配器输入有效；电池为 96%、5,096 mAh，实际电流 +790 mA。保持接线到第 275 秒时，充电设定已由看门狗清零，电池实际为 0 mA、5,123 mAh，协议仍在 12 V。起始阶段只记录状态，热插后的续充单独计时。

## 原口拔插和恢复结果

操作者确认只有原充电器供电，集线器没有另接电源。三星保持开盖，U 盘和网线全程连接。从读到原口已经脱离到重新接入间隔 58.99 秒，均在同一启动内。拔线期间电池实际电流为 −941 至 −832 mA，剩余容量从 5,123 降至 5,109 mAh。

| 重插阶段 | 当时的真机观测 |
| --- | --- |
| 重新接入 | 启动时钟 1,394.460 秒，IC10 先报告第 1 档 5 V / 3 A；充电器也公布了第 3 档固定 12 V / 3 A。 |
| 请求并确认 12 V | 1,394.471 秒发出选档命令，1,395.487 秒读回第 3 档 12 V / 3 A、Sink_Ready。从首次读到 5 V 计时为 1.027 秒。 |
| 接通充电芯片输入 | 12 V 就绪时，受电开关仍为 0，BQ 的 AC_STAT 也为 0。服务接通受电开关并核对回读，随后 AC_STAT 为 1，BQ 首次回读充电设定 1,024 mA。 |

下表从首次恢复电流设定（启动时钟 1,395.701 秒）计时。该时刻电量计仍报告 −835 mA，随后第一次独立采样就已转正。

| 恢复后经过时间 | 电池实际电流 | 剩余容量 | 电量 |
| --- | ---: | ---: | ---: |
| 1.25 秒 | +1,055 mA | 5,109 mAh | 96% |
| 176.05 秒 | +627 mA | 5,145 mAh | 97% |
| 277.70 秒 | +574 mA | 5,162 mAh | 97% |

137 条独立采样中，电池实际电流全部为正，最大采样间隔 2.06 秒以内。超过 175 秒后共有 51 条记录，电流范围 +574 至 +627 mA，中位数 +599 mA；该窗口中容量继续增长了 17 mAh。137 条采样全部报告 12 V / 3 A 协商档位、1,024 mA 充电设定和 175 秒看门狗。服务共成功刷新 7 次。此结果覆盖这台机器原口、原充电器的一次实体拔插。原始记录在构建机的 `output/hotplug/events.jsonl` 与 `output/hotplug/samples.jsonl`。

正常停止服务后，读回充电设定为 0 mA，测试开启的受电开关也已关闭。重启前再次独立读取 BQ 的充电设定，确认是 0 mA；四个一次性启动标记均为 0。

正常重启回原默认 Adreno 日用项，启动 ID 为 `a406ddd0-54da-4650-90ca-7ae3bda1a063`。同一个 U 盘根分区正常挂载，LightDM 活动、Adreno `separate_gpu_kms=N`；热插、续充和两个采样服务全部为 inactive。核对记录见 `output/hotplug/return.txt` 和 `output/hotplug/daily-confirmed.txt`。

## IC10 中断线独立观测项

**IC10 GPIO IRQ trace (Samsung)** 继承上面的热插项及其只读 PD 和电池采样器，增加 `np545.ic10irq=1` 和一个输入边沿记录器。`np545-pd-hotplug` 本身仍负责原有热插处理和约 45 秒的续充刷新。记录器只读取 IC10 的既有状态、源能力和请求寄存器，避开中断状态及清中断命令。GPIO 边沿订阅会在 Linux 一侧注册下降沿 IRQ；只订阅处于 GPIO 输入功能且未被占用的线，使用原有偏置，记录结束时释放。

EMEC 的六个 GpioInt 按资源顺序为 704、26、41、768、81、42。通过本机 GIO0 的中断资源表、DT 中 PDC 的范围和 SC8180x 引脚映射表，704 / 64 = 11 → GSI 588 → SPI 556 → PDC 76 → GPIO101；768 / 64 = 12 → GSI 599 → SPI 567 → PDC 87 → GPIO119。其余四条为直接编号。本机三星 EmuEC.sys 在 RVA `0x7ab8` 分两组注册中断；组内第一项的回调 `0x7d70` 经 `0x8ae8` 和 `0x1cfe8` 进入 PD 处理函数 `0xfec0`。这是定位 GPIO101 的固件依据，实际边沿另行对照。[板上 DSDT](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L93774) · [Qualcomm 虚拟引脚说明](https://marc.info/?l=devicetree&m=178272904036845&w=3) · [Linux v7.0 SC8180x 引脚表](https://github.com/torvalds/linux/blob/v7.0/drivers/pinctrl/qcom/pinctrl-sc8180x.c) · [三星驱动包](https://github.com/tordona/woa-device-drivers/releases/tag/samsung-np545xla-drivers)

在 ARM64 构建机运行 `src/build-debian-battery.sh "$work/obj" "$work/artifacts" output/ic10irq` 和 `src/build-keepcharge-boot.sh --ic10irq output/hotplug/boot output/ic10irq/boot`。U 盘已安装上一版热插包时，仅需安装新增的 `np545xla-ic10-irq` 及其 Debian 依赖 `python3-libgpiod`，然后运行 `sudo systemctl daemon-reload` 和 `sudo bash install-daily-boot.sh --battery-ic10irq boot manifest.txt`。通过 `sudo journalctl -b -t np545-ic10-irq -o cat` 查看内核边沿时间、线电平、IRQ 计数及 IC10 状态，使用同一启动的 BOOTTIME 对齐 `np545-hotplug` 和 `np545-charge` 记录。
