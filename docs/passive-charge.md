# 不启动 Linux 充电控制的独立测试

目标是区分固件/硬件在进入 Linux 后保留的充电能力，与现有 Linux
控制服务负责的续充和接入恢复。当前默认 Latest 和充电包保持原样，
新增菜单项 `Firmware charging, no Linux control (Samsung)`，ID 为
`passive-charge`。这是对照实验，不代表固件自主充电已经通过验收。

## 启动隔离与回退

候选基于 2026-11-12 从真机 USB EFI 只读捕获的启动器，SHA-256 为
`0fb029e284fbc612e41cfcab8b45fd8da37dda4a01f35951b6a1258adda94d29`。
完整旧菜单作为原样前缀保留。测试项复用 Latest 的 Image `163b71d2…64735b`、
设备树 `2661562e…a1a25`、initramfs、USB 根、Wi-Fi、蓝牙和桌面参数。
没有重编内核或修改既有睡眠屏蔽。

测试项移除 `np545.gpiocharge=1`、`np545.chargestartup=1` 和原控制/采样
服务的 `systemd.wants` 参数，并添加 `np545.chargepassive=1`。通过本次
启动的 `systemd.mask=` 屏蔽以下服务，即使持久配置或其他依赖请求也不能启动：

* `np545-gpiocharge`、`np545-charge-keepalive`、`np545-pd-hotplug`；
* `np545-ic10-irq`、`np545-irq-ack`；
* `np545-charge-sleep`、`np545-charge-sleep-guard`；
* `np545-charge-observe`、`np545-power-supply`、`np545-battery-sample`。

只读 SBS 驱动仍由原设备树和模块自动加载。新服务
`np545-passive-battery-sample.service` 仅在本测试参数存在时运行原有只读
`np545xla-battery-sample --watch`，每五秒将带 boot ID、BOOTTIME 的读数追加至
`/var/log/np545-passive-charge/battery.jsonl`，目录权限 0700。它不打开 BQ/PD
控制接口；记录落盘，避免原先 volatile journal 在重启后丢失证据。
外接电源状态桥依赖活动控制进程，因此测试中也被屏蔽；以实际电池电流和
容量变化判断充电，不以桌面外接电源图标作为验收依据。

`src/install-passive-charge-boot.sh` 提供四个模式：

* `--check`：核对板型、内核、USB 根和 ESP UUID、载荷哈希、旧一次性标记、
  空间以及新服务文件。只读挂载 ESP，不改变运行中的充电。
* `--install`：保存原 EFI，发布追加菜单和未启用的只读采样服务；新一次性标记为 0，默认仍为 Latest。
* `--arm`：仅将 `np545_passive_once` 设为 1。GRUB 在交给测试项之前持久化清零；下次普通重启回到 Latest。
* `--rollback`：清零标记并恢复捕获的原 EFI。原始备份文件为
  `EFI/BOOT/BOOTAA64.EFI.pre-passive-0fb029e284fbc612`。

所有写入均核对临时文件，完成后卸载并只读重新挂载回读。安装器不会停止
当前充电服务、直接写充电寄存器或自动重启。不要用停止现有服务来代替
本次对照，因为它的退出清理本身会停充；重启测试仍包含原方案正常关机
清理及固件重新初始化，不能称作完全断电冷启动。

## 验证进度

`src/test-passive-charge-boot.py` 已在 ARM64 构建机调用真实 systemd 生成器，
验证正常 Latest、不带控制的测试项、以及测试项额外请求控制服务三种情况。
测试项的十个屏蔽均实际生成为 `/dev/null` 链接，旧 Latest 未增加屏蔽。
交付 EFI 的内嵌菜单读回与输入一致，原 Latest 菜单未改变。

`src/test-passive-charge-menu-qemu.py` 已通过真实 GRUB 的两次 QEMU 启动：
首次选择 `Debian-passive-charge` 并将 FAT 环境文件标记清零，第二次选择
`Debian-latest-media`。该测试盘以探针函数替代内核准备和交接，只验菜单、
参数与一次性回退，不代表 Linux 或真机充电验收。测试程序最初假设环境文件
没有额外注释；适配 GRUB 的警告注释后重测通过，交付启动器未因此修改。

构建、原 EFI、systemd 生成器输出与 QEMU 记录位于
`output/passive-charge-20261112/`。真机安装、启动和充电实验结果待补充。

## 真机实验顺序

1. 保持已验证的原充电器、原端口、USB 根和 Wi-Fi，进入一次性测试项。
   确认新 boot ID、实际 cmdline、十个 runtime mask、控制服务本次从未启动，
   只读采样从开机开始记录。不要手工启动充电控制。
2. 连续观察至少十分钟，覆盖当前已知约 175 秒看门狗时间的多个周期。
   分别记录充电电流、容量增量，以及是否和何时停止；短时正电流不算持续通过。
3. 提示用户只拔出充电器，确认实际转为放电后再提示接回原端口；观察是否
   无控制介入地恢复正电流和容量增长。一次只安排一个物理动作。
4. 完成后回到原 Latest，确认控制服务与实际充电恢复。持续充电和热插恢复
   分别判定；本轮不扩展到睡眠、满电再充、其他适配器或其他端口。
