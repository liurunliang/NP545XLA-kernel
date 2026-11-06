# NP545XLA 电池只读测试

在现有 Debian U 盘的 GRUB 中选择 **Debian 13 - Battery read-only test (Samsung)**。菜单沿用 Lid edge 的内核、盖子中断和背光，默认项仍为 Adreno 日用桌面。测试设备树单独启用三星固件的 IC20 总线（100 kHz，GPIO181/182），只在地址 0x0b 描述电池。[三星 IC20 引脚](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L74500) · [三星电池地址](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L93780)

驱动只调用 SMBus Read Word 从电池取值。构建时核验编译后的模块引用的总线传输函数。充电芯片地址 0x09 没有设备节点。电量、电压、有符号电流、充放电状态和电池当前单位下的剩余与满充容量通过 Linux power_supply 提供。0 电流且电池自行报告充满时显示 Full，其余 0 电流显示 Not charging。电流的正负反映电池方向；外接适配器是否在线需与现场操作核对。上游 SBS 驱动的部分容量读取路径会切换计量模式，本测试只读取现行单位。[上游驱动](https://github.com/torvalds/linux/blob/v7.0/drivers/power/supply/sbs-battery.c)

在此基础上，电池菜单可升级为同时采集 USB-C 协商及充电器只读设置的版本。[充电诊断和社区实现对照](charge-diagnostics.md)

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
sudo apt-get install --no-install-recommends ./np545xla-battery-ro_7.0.0-3_arm64.deb
sudo systemctl daemon-reload
sudo bash install-daily-boot.sh --battery boot manifest.txt
```

安装时核对当前启动器及原有文件，保存旧启动器为同一 EFI 分区的 `EFI/BOOT/BOOTAA64.EFI.pre-battery`，最后发布追加菜单项的启动器。测试项可手选；如使用一次性选择，GRUB 在交给该项前清除 `boot/np545-battery.env` 中的 `np545_battery_once` 请求。

## 真机识别

首次测试启动 ID 为 `494106f2-9f3e-44ad-8ed8-647088899396`。三星从同一 USB 根分区启动，IC20 枚举为 I²C 适配器 5，电池位于 `5-000b`。只读查询取得 SBS SpecificationInfo `0x31`、8,639 mV 和 100%。电池报告原生 mAh 模式，满充容量 5,321 mAh，设计容量 5,320 mAh，设计电压 7.72 V。安装时 EFI 上原有载荷全部读回验证；电池项使用的设备树 SHA-256 为 `66cdb57e1483c0e11b4f583030068126ba8f081c6f1b035a1a5b4f8f5f84b9d0`，启动器为 `d17d3a0050743ece0c50dc6da40f2ba36dc0649058804f896d2e8c56c3d12465`。

11 月 6 日开盖测试中，操作者确认拔掉独立充电线，USB 根盘及有线网络继续工作。拔电前 12 个样本的电流中位数为 −10 mA，剩余容量一直为 5,321 mAh（100%）。北京时间 14:07:12 首次出现 −862 mA，14:07:22 报告 99%；14:20:46 测得 −954 mA、5,076 mAh（95%）。此前 13 分钟的放电样本电流中位数约为 −917 mA。

操作者在北京时间 14:29 确认把同一条充电线重新接回原端口。14:29:27–14:31:52 的 15 次独立取样中，电流始终为负（−1,013 至 −917 mA，中位数 −942 mA），剩余容量从 4,932 降至 4,893 mAh，百分比从 93% 降至 92%。同一启动的五秒后台记录与此一致。本轮热插没有观察到电池净充电；这些电池侧读数本身不能判断 USB-C 是否达成供电协商。测试没有访问充电器、改写电池模式或请求任何充电电压、电流。

### 合盖耗电

拔掉充电线、保留启动 U 盘、集线器和 USB 有线网卡，现场合盖并在约 15 分钟后只开盖唤醒。以下为同步挂起钩子的实机样本（北京时间）：

| 时点 | 盖子 | 电量 | 剩余容量 | 电压 | 电池瞬时电流 |
|---|---|---:|---:|---:|---:|
| 14:40:14.189，挂起前 | 关 | 89% | 4,755 mAh | 8.195 V | −866 mA |
| 14:56:04.047，恢复后 | 开 | 87% | 4,628 mAh | 8.200 V | −643 mA |

同一启动的成功睡眠计数从 0 到 1，失败计数保持为 0。两条样本相隔 949.858 秒，其中实际 `s2idle` 为 **946.577 秒（15 分 46.6 秒）**，另有 3.281 秒处于清醒状态。原生容量差为 **127 mAh**，乘以前后平均电压 8.1975 V，估算消耗 **1.041 Wh**。用整个采样窗口作分母，平均约 **3.946 W**。这是本机带上述 USB 外设的一次短时测量，电流列是挂起前、恢复后的瞬时值。

构建机的 `output/battery/` 下保留 `samples.jsonl`（本次启动的采样及 pre/post）、`sleep-result.json`、`replug-first-150s.jsonl`、`lid-kernel.txt` 和 `operator-events.txt`。

### 接电状态下重启

待机测试之后，操作者再次确认充电线接回。第二次单次启动前电流为 −1,007 mA，容量为 4,580 mAh。保持这条线连接，正常重启到同一只读测试项（启动 ID `5f7d2646-febe-4a7b-9cc4-97db636a2568`）。Linux 电池接口报告 Charging 和正电流。北京时间 15:00:07–15:01:40 的 10 个样本均为正，范围 **+1.902 至 +2.159 A**，中位数 **+2.011 A**；剩余容量从 **4,628 升至 4,679 mAh**，显示从 87% 升至 88%。

完整五秒记录显示，新启动首次采样为 4,601 mAh（86%）。15:01:44 仍为 +1.894 A；15:01:49 起连续四个样本为 **0 mA / Not charging**，容量保持 4,681 mAh（88%）。本轮实测证实了净充电，也记录了充电随后停止；未查明停止原因。完整记录在 `output/battery/acboot-samples.jsonl`。两次启动均使用同一电池驱动、没有写充电配置。

完成测量后，只读挂载 U 盘 EFI 分区确认电池和摄像头的单次标记均为 0。正常重启自动进入原默认 Adreno 桌面（启动 ID `38206231-c810-4ff8-b8e1-e3128324b860`），USB 根分区 UUID 一致，内屏已连接、LightDM 活动、`separate_gpu_kms=N`；电池试验模块和采样服务均未启用。原始检查在 `output/battery/daily-verified.txt`。
