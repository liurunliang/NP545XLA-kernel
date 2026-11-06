# NP545XLA 的 USB-C 和充电芯片只读对照

现有 **Battery read-only test (Samsung)** 菜单项可以一起观察两路 USB-C PD、电池请求和 BQ25710 设置。运行 `sudo np545xla-charge-observe` 取一个样本，或用 `sudo journalctl -b -t np545-charge -o cat` 读取自启动以来的时间线。采样包括同次启动的 ID、启动时钟和每行读取耗时。每次读取后间隔两秒。日用和摄像头菜单不启动这个采样服务。

## 社区先例

- 普通版三星 Galaxy Book Go（NP340XLA）实测的 BQ25710 和智能电池位于同一总线的 0x09、0x0b。其 `gbgo-charge` 服务每 60 秒读取电池请求的电流、电压、温度和满充状态，经限幅后更新充电芯片。周期刷新针对芯片的充电看门狗。普通版服务使用该机型自己的总线和充电限制。[社区实现](https://github.com/xbill9/linux-arm-adventures/blob/34f76f5cbbe3a78f29b1768180fc323378cf5140/galaxy-book-go/scripts/gbgo-charge)
- Galaxy Book4 Edge（NP750XQA）的实现先处理端口：检测插线、接通 S2MM006 的输入开关、核实供电档位，再根据电池请求维持 ISL9241 的设定。该项目在真机上区分了插线检测、供电协商与实际到达充电器的电力。它使用另一套 PD 控制器和充电芯片，寄存器地址及策略只适用于原机。[社区程序](https://github.com/ciscobugger/book4-edge-linux/blob/1ff984a82f55570ae0473a80811db1b4b760616e/userspace/charging/book4-pd-charge) · [实测与寄存器说明](https://github.com/ciscobugger/book4-edge-linux/blob/1ff984a82f55570ae0473a80811db1b4b760616e/reports/ec/07-pdic-s2mm006.md)
- NP545XLA 自身的三星 EmuEC.sys 包含选择 PDO、接通或断开 Consumer Switch、设置 BQ25710 输入限流和检查充电电流的代码字符串。其 ACPI EMEC 为 IC10 和 IC19 各列出 0x33，为 IC20 列出 0x09 和 0x0b。这些是定位实际信号的依据，不能用来证明本轮 Linux 执行了 Windows 的动作。[三星驱动包](https://github.com/tordona/woa-device-drivers/releases/tag/samsung-np545xla-drivers) · [本机 ACPI](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L93774)

## 读取边界

- S2MM005 读取状态 0x0020、收到的电源能力 0x0260 和发出的请求 0x0240。只在两次状态相同、已连接、角色为用电端且处于 Sink_Ready 时解释固定 PDO 请求。源能力和请求缓冲在拔线后可能保留旧值；请求电压是协议值，不能替代电压表。[三星寄存器与状态定义](https://github.com/LineageOS/android_kernel_samsung_universal9810/blob/lineage-17.1/include/linux/ccic/s2mm005.h) · [三星 PD 消息实现](https://github.com/LineageOS/android_kernel_samsung_universal9810/blob/lineage-17.1/drivers/ccic/s2mm005_pd.c)
- BQ25710 必须读到厂商 0x0040、器件 0x0089 后才采集设置。记录看门狗时限、充电禁止位、充电电流和电压设定、输入限流和 ADC 配置。芯片状态寄存器 0x20 的部分故障位是读后清除，采样器跳过该寄存器；不启动 ADC，不改写任何控制字段。持续电压转换未开启时，ADC 原始值不能代表当前 VBUS。[TI BQ25710 手册，第 9.3、9.6 节](https://www.ti.com/lit/ds/symlink/bq25710.pdf)
- 电池请求电流和电压来自智能电池自己的 0x14、0x15；它们与 BQ25710 同号寄存器的目标值、以及电池实际电流分别记录。没有充电器写入服务。

## 重建与安装

在已验证的 ARM64 构建环境运行：

```sh
work=/var/tmp/np545xla-diag
src/build-debian-battery.sh "$work/obj" "$work/artifacts" output/charge
src/build-charge-boot.sh output/battery/boot output/charge/boot
```

在三星 USB Debian 上安装生成的软件包，执行 `sudo systemctl daemon-reload` 后运行 `sudo bash install-daily-boot.sh --battery-diag boot manifest.txt`。安装器核对当前电池菜单指纹，并将升级前的 EFI 备份到 `EFI/BOOT/BOOTAA64.EFI.pre-battery-diag`。新增两个空的 PD 总线描述，不绑定控制策略驱动；既有电池入口的名称和默认日用选择保持原样。
