# NP545XLA 带电启动后的 BQ25710 续充试验

在 Debian U 盘上选择 **BQ25710 charge keepalive test (Samsung)**。开机前把同一充电器接到已经验证的 IC10 对应端口。原 Adreno 日用项是默认入口，原 Battery read-only test 项可用于对照。

普通版 Galaxy Book Go 的服务定期写入电池请求的充电电压、电流。本机固件已经设好 8,760 mV，TI 手册说明写电流或电压任一寄存器即可刷新看门狗，因此本试验只写 IC20 总线、地址 0x09 的 ChargeCurrent（0x14）。看门狗沿用 175 秒，服务每 45 秒刷新，按 64 mA 向下取整，上限取电池请求与 1,024 mA 中的较低者。协议状态由 IC10 只读采样。[普通版实现](https://github.com/xbill9/linux-arm-adventures/blob/34f76f5cbbe3a78f29b1768180fc323378cf5140/galaxy-book-go/scripts/gbgo-charge) · [TI 手册 §9.3.10.1、§9.6.3–4](https://www.ti.com/lit/ds/symlink/bq25710.pdf)

服务只在专用启动项的前 90 秒内接手，要求 IC10 已就绪且请求 12 V / 3 A，芯片身份、两项输入限流、固件电压和初始电流 3,776 mA 均匹配，还要求电池有正电流。接手后约每两秒核对一次。电池温度须在 5–40 °C，电压须在 6–8.76 V，电池须继续请求足够的电压和电流。遇到充满、告警、掉线、数据读取失败或芯片自行停充，服务退出，已接手时会尝试将电流设为零并读回。正常关机和待机前也执行此步骤。每次启动只允许一次接手；若进程被强制终止，芯片仍有原来的看门狗。恢复热插后的 12 V 协商是单独的工作。

## 重建和使用

在先前验证的 ARM64 Debian 构建机上，从此仓库运行：

```sh
work=/var/tmp/np545xla-diag
src/build-debian-battery.sh "$work/obj" "$work/artifacts" output/keepcharge
src/build-keepcharge-boot.sh output/charge/boot output/keepcharge/boot
python3 src/test-charge-keepalive.py
```

在三星的 U 盘 Debian 上安装生成的 `np545xla-battery-ro` 和 `np545xla-charge-keepalive` 两个包，执行 `sudo systemctl daemon-reload`，再执行 `sudo bash install-daily-boot.sh --battery-keepalive boot manifest.txt`。安装器核对原菜单摘要，保留 `EFI/BOOT/BOOTAA64.EFI.pre-battery-keepalive`，并复用原电池项的 DT。手选测试项只对本次开机生效。

```sh
# 每次写入、即时读回，以及当时的电池状态
sudo journalctl -b -t np545-keepcharge -o cat
# 独立只读观测，包括 PD、芯片设定、实际电流和剩余容量
sudo journalctl -b -t np545-charge -o cat
```

验收时间从首次成功刷新开始计算。比较 175 秒以前和以后多个同一启动的样本，检查电池实际电流持续为正、剩余容量（mAh）继续增长。退出测试用正常重启回到默认桌面。

## NP545XLA 真机结果（2026-11-06）

充电器在重启前接好，使用原 IC10 端口、现有 Debian U 盘，保持开盖。测试启动 ID 为 `cbd2dd08-6f31-4d66-9f52-72ee78c1636a`。在 Linux 启动后 20.229 秒，服务确认固件电流设定为 3,776 mA、电池实际正在充电，并首次设为 1,024 mA、读回一致。以下时刻以该次刷新为零点，电流为电池电量计报告的实际值。

| 接手后（秒） | 实际电流（mA） | 剩余容量（mAh） | 电量 |
| ---: | ---: | ---: | ---: |
| 1.05 | +1,071 | 4,949 | 93% |
| 175.95 | +931 | 4,998 | 94% |
| 350.46 | +818 | 5,040 | 95% |
| 399.25 | +790 | 5,051 | 95% |

独立采样器在上述区间获得 197 条记录，相邻采样间隔最大 2.07 秒。所有记录均为正电流；175 秒后的 111 条记录为 +790 至 +931 mA，中位数 +855 mA，容量从 4,998 增到 5,051 mAh。全部 197 条均读回 1,024 mA 的充电设定、175 秒看门狗和 12 V / 3 A 的协议请求。服务成功刷新 9 次，间隔约 46–47 秒。对应的只读对照在开机第 164.51 秒已清零。[先前的只读结果](charge-diagnostics.md)

手动结束服务时，启动时钟 423.074 秒，服务读回 0 mA。重启前独立采样器再次读回芯片设定 0 mA，电量计也读到实际电流 0 mA。三个一次性菜单标记均已清零。完整记录位于构建机 `output/keepcharge/samples.jsonl` 和 `output/keepcharge/refresh.jsonl`。本次覆盖原端口带电启动的 93%–95% 区间；热插协商和充满终止留待分别验证。

正常重启后，三星进入原默认 Adreno 日用项，启动 ID 为 `3dc8fb2e-0c39-4f65-bd4b-72a47628aa9b`。USB 根分区 UUID 与测试前一致，LightDM 已启动，Adreno 的 `separate_gpu_kms=N`，续充服务和两个采样服务均为 inactive。核对记录在 `output/keepcharge/daily-confirmed.txt`。
