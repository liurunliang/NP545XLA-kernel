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
