# NP545XLA 电池只读测试

在现有 Debian U 盘的 GRUB 中选择 **Debian 13 - Battery read-only test (Samsung)**。菜单沿用 Lid edge 的内核、盖子中断和背光，默认项仍为 Adreno 日用桌面。测试设备树单独启用三星固件的 IC20 总线（100 kHz，GPIO181/182），只在地址 0x0b 描述电池。[三星 IC20 引脚](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L74500) · [三星电池地址](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L93780)

驱动只调用 SMBus Read Word 从电池取值。构建时核验编译后的模块引用的总线传输函数。充电芯片地址 0x09 没有设备节点。电量、电压、有符号电流、充放电状态和电池当前单位下的剩余与满充容量通过 Linux power_supply 提供。0 电流且电池自行报告充满时显示 Full，其余 0 电流显示 Not charging。电流的正负反映电池方向；外接适配器是否在线需与现场操作核对。上游 SBS 驱动的部分容量读取路径会切换计量模式，本测试只读取现行单位。[上游驱动](https://github.com/torvalds/linux/blob/v7.0/drivers/power/supply/sbs-battery.c)

## 取样和测量

```sh
sudo np545xla-battery-sample
sudo journalctl -b -t np545-battery -o cat --no-pager
# 完成开合盖后，计算有效窗口的能耗和平均功率
sudo journalctl -b -t np545-battery -o cat --no-pager | np545xla-battery-sample --summarize-sleep
```

测试入口每五秒记录一条。电流和电压单位为 µA、µV；charge_now 为 µAh，energy_now 为 µWh，取电池原生单位。另在实际挂起前和恢复后各取一次，并记录盖子开关、成功睡眠计数、包含和排除睡眠时间的两种时钟。测量时保留启动 U 盘及集线器，只插拔单独的电源。每次插拔后观察多条稳定读数；满充时如电流为零，可先放电再重新接电。

合盖耗电使用纯电池供电的 pre/post 容量差。睡眠时间取两端 CLOCK_BOOTTIME 差减 CLOCK_MONOTONIC 差；同步检查内核睡眠成功计数、失败计数和盖子事件。若原生读数为电量，瓦时估算采用电量差乘前后平均电压，报告为近似值。容量变化小于电量计分辨率时应延长窗口。

## 重建

在原 ARM64 Debian 构建环境执行：

```sh
work=/var/tmp/np545xla-diag
src/build-debian-battery.sh "$work/obj" "$work/artifacts" output/battery
src/build-battery-boot.sh output/debian-final/manifest.txt output/camera/boot \
    output/daily/lid-edge/boot-esp output/battery/boot
```

将软件包、生成的 boot 目录、原 manifest.txt 和新版 install-daily-boot.sh 放到三星 USB Debian，执行：

```sh
sudo apt-get install --no-install-recommends ./np545xla-battery-ro_7.0.0-2_arm64.deb
sudo systemctl daemon-reload
sudo bash install-daily-boot.sh --battery boot manifest.txt
```

安装时核对当前启动器及原有文件，保存旧启动器为同一 EFI 分区的 `EFI/BOOT/BOOTAA64.EFI.pre-battery`，最后发布追加菜单项的启动器。测试项可手选；如使用一次性选择，GRUB 在交给该项前清除 `boot/np545-battery.env` 中的 `np545_battery_once` 请求。

## 真机识别

首次测试启动 ID 为 `494106f2-9f3e-44ad-8ed8-647088899396`。三星从同一 USB 根分区启动，IC20 枚举为 I²C 适配器 5，电池位于 `5-000b`。只读查询取得 SBS SpecificationInfo `0x31`、8,639 mV 和 100%。电池报告原生 mAh 模式，满充容量 5,321 mAh，设计容量 5,320 mAh，设计电压 7.72 V。安装时 EFI 上原有载荷全部读回验证；电池项使用的设备树 SHA-256 为 `66cdb57e1483c0e11b4f583030068126ba8f081c6f1b035a1a5b4f8f5f84b9d0`，启动器为 `d17d3a0050743ece0c50dc6da40f2ba36dc0649058804f896d2e8c56c3d12465`。

11 月 6 日开盖测试中，操作者确认拔掉独立充电线，USB 根盘及有线网络继续工作。拔电前 12 个样本的电流中位数为 −10 mA，剩余容量一直为 5,321 mAh（100%）。北京时间 14:07:12 首次出现 −862 mA，14:07:22 报告 99%；14:20:46 测得 −954 mA、5,076 mAh（95%）。此前 13 分钟的放电样本电流中位数约为 −917 mA。
