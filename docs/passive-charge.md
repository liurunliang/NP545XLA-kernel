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
`output/passive-charge-20261112/`。实现提交为 `9686bc6`。

### 真机安装及首次重启请求

真机 `--check` 和 `--install` 均已通过，发布后的 EFI SHA-256 为
`a9133f5d3b1646f5a2dba6fd5a611154f1184bc46abd0985173f3d2518d4e12c`。
只读重新挂载确认新启动器、原始备份和新服务文件一致；安装前后原控制
进程 PID 385、状态进程 PID 1745 及各自 invocation 均未改变，零重启。
新只读采样服务在普通 Latest 下保持 inactive。安装后电池 32%、实际
+1,072 mA，确认安装本身没有中断充电。

候选包及回退安装器位于真机 `/var/tmp/np545-passive-charge-20261112/`。
随后 `--arm` 成功并经重新挂载确认标记为 1。真机已启动测试项，boot ID
`f4a71602-6457-413f-bc18-2256fe8ec427`，十个控制/状态服务全部 runtime
masked、inactive、PID 0，本次启动时间戳为 0。用户确认桌面正常，输入表约
12 V / 0.6 A。启动约 453 秒时电池 36%、1900 mAh、实际电流 0，BQ 充电目标
0、PD 合约 12 V / 3 A；这证明当时没有充电，不能仅由输入功率判断电池电流。

首次测试发现新日志单元的 `StandardOutput=append:` 比 `LogsDirectory=`
创建目录更早打开文件，产生 `209/STDOUT`，因此开机早期时间序列缺失。
建立目录后恢复采样：BOOTTIME 589.54 至 1233.49 秒的 129 个样本均为零电流，
容量保持 1900 mAh；不能据此确定早期何时停充，更不能直接断言看门狗是原因。

修复改为在服务进程启动后打开日志，目录 0700、文件 0600。
`src/test-passive-charge-logger.py` 在 ARM64 真实 systemd 中验证目录预先不存在
的情况：旧单元复现退出 209，修复单元成功创建目录和文件。测试替身是 printf，
不代表硬件测试。修复已部署并核对候选包清单一致，原单元和清单保存在
`logger-v1-backup/`；EFI、内核、设备树和充电控制均未改动。修复后的单元
SHA-256 为 `e604eb0bac4e4c156a14326f00ad8f18437ae227c6b82c5f7dd3eb726557b340`。
第二轮已重启补齐早期曲线，结果如下；拔插恢复及返回 Latest 仍待验证。

本轮同时按用户要求将 Wi-Fi 配置固定为 `10.86.112.113/23`，网关
`10.86.112.1`，DNS `10.86.104.21` 和 `175.24.120.87`，SSH 使用 2223。
仅修改 NetworkManager 原连接的 IPv4 字段；新 SSH、网关和域名解析验证通过。
有线适配器 `00:e0:4f:71:1a:c1` 设置为始终关闭，原有线配置保留。
网络原配置备份在 `/var/lib/np545xla-network-backups/20261112-wifi-static/`，
验证成功后自动回滚定时器已取消。在第二次独立测试启动后，静态地址、网关、DNS 及有线关闭配置均已读回验证；
未设置路由器 DHCP 预留。
原始记录位于 `output/passive-charge-20261112/` 和 `output/wifi-static-20261112/`。

### 修复后的开机曲线与持续观察结果

第二次独立启动 boot ID 为 `1c497fd5-7ffa-46af-b5e2-9f92f4b5006b`。
十个服务仍全部被屏蔽且从未运行；采样服务从 BOOTTIME 16.80 秒启动，
无错误、零重启，第一个有效电池样本位于 22.24 秒。EFI 回读一致，一次性
标记已消费为 0，下次普通重启将选择原 Latest。

22.24 秒电池实际电流 +2586 mA、容量 1926 mAh，30 秒时 BQ 目标为
3776 mA。158.32 秒最后一个正电流样本为 +241 mA，163.36 秒首次为 0；
177 秒读到 BQ 目标为 0。容量增至 2032 mAh 后暂未继续增加。停充前后
PD 合约均为 12 V / 3 A，BQ 电压目标 8760 mV、看门狗配置约 175 秒不变。

上述电流目标归零、其他已读取配置保持不变的现象，与
[TI BQ25710 数据手册 §9.3.10.1](https://www.ti.com/lit/ds/symlink/bq25710.pdf)
描述的看门狗超时相符。这仍是原因推断：未记录固件最后写入时间，也未读取
会清除状态的寄存器。本轮未禁用看门狗或写入充电目标。
持续观察已完成：从 22.24 至 646.09 秒，
共 125 个有效样本，跨度 623.85 秒；其中 28 个正电流、97 个零电流、
0 个负电流。首次归零后没有恢复，容量保持 2032 mAh。**当前配置下，
不运行 Linux 控制不能持续充电**；这不排除后续找到更小的系统侧维护方案。
已提示用户拔下充电器，等待现场确认后检查放电，再提示接回。
拔插恢复及返回原 Latest 的验收尚未完成。

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
