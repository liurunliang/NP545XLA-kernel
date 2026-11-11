# 充电服务睡眠交接候选

2026-11-10：本阶段实现睡眠前确认停充、释放 GPIO/I2C，唤醒后重新检查并启动充电。已通过 ARM64 包内 95 项测试、真实 systemd 管理器上的六组模拟顺序测试，以及原端口满电接电状态下的一次真机睡眠/恢复。随后充电中睡眠试验，用户报告无法唤醒并强制重启；该轮未通过，原因尚未确定，本候选不满足设为默认的验收条件。睡眠期间接入状态变化尚待验收。此前完整充电循环的实测见 [charge-startup.md](charge-startup.md)，不能替代本候选新增分支的睡眠验证。

## 交接流程

使用单独的 `np545-charge-sleep.service`，运行 `gpio_charge.py --startup --sleep`。它与原充电、IRQ 诊断服务互斥。普通入口不启用睡眠协议。新包安装不会启用或启动任何服务。

`np545-charge-sleep-guard.service` 通过 `RequiredBy=sleep.target` 加入必需依赖，同时设置 `Before=sleep.target`。主服务启动前检查这两个实际依赖，避免漏装守卫仍开始充电。准备失败时必需依赖失败，睡眠动作不能继续；不能将它改为可失败的 `Wants`。顺序规则参考 [systemd.unit](https://www.freedesktop.org/software/systemd/man/261/systemd.unit.html)。

1. 守卫核对当前 boot ID、主进程 PID、systemd invocation，写入带随机 token 的本次请求，向 systemd 主进程发送 SIGUSR1。
2. 主进程唤醒原阻塞等待，在已有退出路径写零并读回。只有 PD、consumer、BQ 和电池检查均通过才保留已有外部输入。普通停止和故障继续原来的清理策略。
3. 再次核对芯片身份、目标为零和电池状态，关闭全部 GPIO/I2C 资源后发布确认。守卫等待主进程成功退出，并独立重新读回芯片身份、零电流和相同电压，才准许睡眠。
4. 睡眠结束或已准许的睡眠动作取消后，守卫退出阶段消费一次确认，启动新进程。新进程重新读取实时 PD/BQ/电池，不复用睡前充电目标。恢复失败不自动重试；未成功准备的请求也不能触发恢复。

请求与确认位于 root 专有的 `/run/np545-charge-sleep/`，绑定当前启动和进程身份；确认只消费一次。主进程的睡眠模式发生错误时返回失败，即便已经收到停止信号，也不会伪装成成功停机。

本阶段睡眠期间充电目标为零，没有用户态循环继续刷新看门狗。原电流上限 1024 mA、温度范围 5–40°C、已知电压配置和 175 秒看门狗保持原约束。睡眠期间持续充电、其他端口/适配器、更高充电电流不在本阶段范围。

## 构建与试验安装

使用原 `src/build-debian-battery.sh`。本候选更新包如下：

| 包 | 候选版本 | 回退版本 |
| --- | --- | --- |
| np545xla-pd-hotplug | 7.0.0-10 | 7.0.0-9 |
| np545xla-ic10-irq | 7.0.0-10 | 7.0.0-9 |
| np545xla-irq-ack | 7.0.0-9 | 7.0.0-8 |
| np545xla-gpiocharge | 7.0.0-7 | 7.0.0-6 |
| np545xla-charge-sleep | 7.0.0-1 | 移除 |

`np545xla-battery-ro 7.0.0-5` 和 `np545xla-charge-keepalive 7.0.0-3` 不变，不必替换同版现场文件。新控制包保持精确版本依赖，四个旧控制包需一起升级或回退。

真机试验要求原 IC10 充电器、USB 根系统、`np545.gpiocharge=1 np545.battery=1` 启动参数和匹配板型。先保存版本、源码、日志、unit 和临时覆盖，备齐上一版完整循环的回退包，再停止原服务并安装五个候选包。执行 `systemctl daemon-reload` 后：

```sh
systemctl enable --runtime np545-charge-sleep-guard.service
systemctl start np545-charge-sleep.service
```

守卫仅本次启动启用，不改变默认 EFI 或持久启动策略。原 `90-full-cycle-trial.conf` 可保留用于同次启动回退，但旧服务必须 inactive。开启睡眠前，核对新服务已 ready、只有一个控制进程、目标电流及实时电池状态符合当前场景。

回退时先确认当前没有进行睡眠交接，停止守卫和候选服务，禁用运行时守卫，移除新 sleep 包并同时安装四个回退包；重新加载 systemd 后，在保留的原 `--startup` 覆盖下启动 `np545-gpiocharge.service`。不能只停新主进程却留下必需守卫，否则后续睡眠会被拒绝。专用回退脚本还应核对 boot ID、USB 根 UUID 和当前包版本。

## 验证证据与待验收项

源码归档 SHA256：`8beed4a336082c82aa55df87e1df6cac5d4fe9a0f78b37cf45852c4236fb553a`。证据保存在 `output/charge-sleep-20261110/`，其中 `arm64/output/packages/` 包含七个构建产物和 SHA256；现场只更新上述五个包。

ARM64 上解包后逐一比较包内代码和源码，再直接测试包内模块：keepalive 15、startup 28、cycle 16、GPIO 5、IRQ 5、sleep 26，共 95 项通过。新增覆盖故障停充、输入保留、未插电预置清零、5 V 满电转 12 V 再充后的睡眠配置、资源释放后确认、跨启动/过期/错误 token 拒绝及恢复失败不重试。

`test-systemd-order.py` 使用构建机的真实 systemd 和 `sleep.target`，但替换硬件访问和最终睡眠动作，不调用内核睡眠。六组通过：守卫缺失拒绝主服务、正常准备及恢复、主进程准备失败、独立读回失败、睡眠动作失败后恢复、恢复进程失败且不重试。`systemd-analyze verify` 通过。前两次运行修正的是测试断言和日志记录器字段冲突，候选代码没有因此改动。

真机按单一变量依次验证：

1. 满电接电：确认准备零电流、资源释放与实际内核睡眠顺序；保持睡眠数分钟后唤醒，新 PID 重新进入满电等待，核对输入和实际容量。
2. 正在充电：睡前实际正电流；准备将目标清零；唤醒后重新核验并恢复，连续采样证明实际正电流和容量增长。
3. 睡眠期间拔线/插线：每轮只改变一个接入状态，唤醒后正确进入未插电等待或重新协商。不能将内核早醒、单纯熄屏或 SSH 不通当成真实睡眠证据。

每轮保存 boot ID、主进程 invocation、带单调时钟的服务与内核日志、suspend 计数和睡前后独立电池样本。观察期间不主动远程连接，待用户唤醒后采集。

## 真机部署基线

2026-11-10 在原 Linux 启动 `999a1194-882f-4503-8804-b88c5fd77aaa`、USB 根 UUID `aeb13805-ba45-4385-8a98-067b839ca579` 上部署。安装前 PID 1562 的上一版仍正常满电等待；现场所有电源 Python 文件与回退包逐一匹配。备份、五个候选包、四个回退包和带启动/版本检查的脚本保存在 `/var/tmp/np545-charge-sleep-999a1194/`。

实现提交 `00ef764`，包和说明提交 `b24610e`。安装后现场八个电源模块与包内代码相符，真机 `systemd-analyze verify` 通过，运行时启用守卫。新进程 PID 28831、invocation `69da00cf56334acd9207f4394810ef68` 于启动时钟 7266.634 秒进入满电等待；原服务停止时关闭其拥有的输入，新服务重新核验并恢复输入。7301.602 秒独立读取为 12 V / 3 A、0 mA / 8760 mV，电池 100%、实际电流 0、容量 5282 mAh。原服务 inactive，新服务 active、零重启，守卫成为 `sleep.target` 的必需依赖。部署用临时睡眠阻止已解除，内核睡眠成功/失败计数均为 0。

本段只确认部署与睡前基线，不代表真机睡眠验收。现场证据为 `preflight-before.json`、`deploy.txt`、`device-backup.tar.gz`、`full-before-sleep.json` 和 `delivery-manifest.json`，同时归档到主仓库忽略的 `output/charge-sleep-20261110/`。

## 满电接电睡眠与恢复实测

用户从 Linux 桌面手动睡眠，保持原充电器、IC10、U 盘和网线连接。内核 `PM: suspend entry (s2idle)` / `PM: suspend exit` 成对出现，成功计数 0 → 1，失败计数仍为 0。电池 sleep hook 的 boottime 与 monotonic 差值确认实际睡眠 **492.537 秒**（约 8 分 13 秒）；用户回复、五分钟观察窗口和实际睡眠起止分别记录，未把计时窗口当成实际睡眠长度。观察期间没有远程连接三星。

启动时钟 7412.356 秒，PID 28831 记录零目标并保留已验证的 12 V 输入。7412.402 秒 GPIO 显示 UNCLAIMED，随后 7412.403 秒发布本次确认；守卫独立读回通过后于 7412.479 秒准许睡眠。电池 pre hook 为 7412.790 秒。原进程成功退出，没有在睡眠期间继续运行充电循环。

post hook 为 7909.058 秒。守卫启动新 PID 29456、invocation `870a8fc7f84e4eaf89d81331661f968a`，7910.419 秒确认恢复；新进程首先读到输入已经有效且 consumer=1，无需重新打开受电开关，7910.498 秒进入满电等待。守卫成功退出，确认文件被消费，只留下新进程 running 记录；没有恢复重试。现场代码仍与候选包完全一致。

睡前/睡后 hook 及 7936.728 秒独立读取均为 100%、5282 mAh、实际电流 0；末次读回仍是 12 V / 3 A、BQ 0 mA / 8760 mV、175 秒看门狗与原输入限流。上述证据确认睡前停充、睡眠成功和唤醒后的满电等待，睡前后读数不等于对睡眠期间每个瞬间的连续测量。

内核另有 USB PHY 未进入 L2、xHCI 恢复重初始化及 USB 网卡重新枚举日志；网络随后恢复，充电服务和内核 suspend 计数无失败。本轮不将充电交接通过扩大为所有设备的睡眠恢复均无告警。

证据为 `full-after-sleep.json`、`full-after-dmesg.txt`、`full-sleep-summary.json` 和 `full-sleep-user-confirmation.json`。汇总已断言确认顺序、单次恢复、输入继承、容量不变及代码匹配。随后用户确认拔出充电器，准备未满电时的充电睡眠测试。

## 充电中睡眠试验未通过

拔线后的只读观察持续 811.822 秒，28 个样本全部为负电流，容量 5282 → 5037 mAh，显示到达 95% 后观察进程自动退出并解除临时睡眠阻止。电池满电标志在 96% / 5088 mAh 时清除，重新请求 5320 mA / 8860 mV；该请求不替代服务的 1024 mA 上限。PID 29456 全程未退出或重启。

用户后来插回原端口时电量已到 86%，不能将先前结束观察的 95% 当作实际接入电量。启动时钟 10590.070 秒出现接入边沿，10591.310 秒首次读回 1024 mA，继续保留 8760 mV。随后独立观察 63.822 秒、13 个样本全部为正电流，范围 +1071～+1073 mA，容量增长 19 mAh。正式睡前快照显示 87%、4575 mAh、实际 +1071 mA，仍是 PID 29456；候选代码哈希匹配，旧服务未运行，临时睡眠阻止已解除，既有睡眠成功/失败计数为 1/0。

用户确认进入睡眠后，观察窗口内未远程连接。提示唤醒后，用户报告“没醒来我强制重启了”，随后确认已回到 Linux 桌面。**本轮结果为用户报告的唤醒失败及强制重启，不计为充电恢复通过。** 截至本段记录，旧地址可以收到网络回应，但 2223 端口 SSH 等待服务端版本信息超时，尚未取得新的 boot ID、睡眠日志或重启后的充电状态。

镜像构建脚本默认配置 `Storage=volatile` 和 `ReadKMsg=no`，前一轮也需要通过 `dmesg` 补取内核记录。强制重启可能使本次关键过程丢失；还需在连接恢复后检查上一启动 journal 与 pstore。当前证据不能确认本次是否完成睡前零电流确认、是否进入内核睡眠、是否已恢复但显示未亮，亦不能确定故障由充电服务还是其他设备恢复路径造成。下一次复测前需补充能跨重启保留的定向证据，不能仅重复同一流程。

已保存 `charging-after-replug.json`、`charging-before-watch.jsonl`、`charging-before-summary.json`、`charging-before-sleep.json` 和 `charging-sleep-user-confirmation.json`；`delivery-manifest.json` 明确标记本轮失败及不可设为默认。重启后状态与故障归因仍待补充。

## 重刷后的基线（2026-11-11）

用户重刷系统并恢复 SSH 后，主机密钥已变化；新公钥与用户本机已有的 SSH 信任记录一致，使用独立 known_hosts 连接，保留旧记录。新启动 ID 为 `60bc8efe-29b4-497c-8de2-5060bd11873d`，仍为 Debian 13、内核 7.0.0、原 Image `163b71d2…64735b` 及 USB 根 UUID `aeb13805-ba45-4385-8a98-067b839ca579`。命令行带 `np545.chargestartup=1`，GPIO46 的系统唤醒仍 disabled。

新系统安装的是充满等待阶段的版本：gpiocharge 7.0.0-6、pd-hotplug / ic10-irq 7.0.0-9、irq-ack 7.0.0-8、keepalive 7.0.0-3。七个现场电源模块与上一版回退基线逐一匹配；sleep 候选包和两个候选 unit 均不存在。`sleep.target` 已被屏蔽。journal 配置为 `Storage=persistent`、`SystemMaxUse=64M`、`ReadKMsg=yes`，与失败试验时的内存日志不同。当前仅存在新启动日志，旧试验备份目录和 pstore 均为空或不存在，不能从新系统补回失败一轮的过程。

本次只读检查发现电源公布的是 5 V / 3 A、9 V / 3 A、15 V / 3 A、20 V / 4.7 A，缺少既有策略要求的固定 12 V / 3 A。服务在启动时钟 23.833 秒以 `source does not offer fixed 12 V / 3 A` 退出。独立读数为 PD 15 V / 3 A、BQ 0 mA / 8760 mV、输入限流 `0x2e00`，电池 97%、5145 mAh、实际电流 0。用户随后确认换过充电器或连接方式。本次调查没有放宽档位检查、写充电寄存器、安装睡眠候选或解除睡眠屏蔽。当前电源条件不匹配可以解释本次服务拒绝接管，不能用于归因前一天的唤醒失败。

新基线、主机验证及 journal 状态证据保存在 `output/charge-sleep-reflash-20261111/`。继续充电或睡眠试验前，须先确认输入条件并重新建立现场基线。

### 换回原电源并恢复已验证服务

用户确认换回上轮电源后，只读确认原固定 12 V / 3 A PDO 再次出现，当前为 5 V / 3 A、BQ 0 mA / 8760 mV、已知复位输入限流 `0x4100`。服务仍保持此前不支持电源时的失败状态。重新核对启动 ID、USB UUID、板型、启动参数、七个模块哈希和睡眠屏蔽后，仅重新启动现有 `np545-gpiocharge.service`，没有更新包或重新安装睡眠候选。

新进程 PID 5525、invocation `8d28f6d404944e29ba3c26167b619715` 于启动时钟 1692.676 秒请求 12 V，1693.686 秒首次读回 1024 mA。6 秒后的独立读取为实际 +924 mA；两项输入限流均为 `0x3c00`，电压目标仍为 8760 mV。之后连续独立观察 **182.052 秒、35 个样本全部为正**，实际电流 +520～+649 mA，容量 5130 → 5160 mAh（增加 30 mAh），显示 97% → 98%。服务始终同一 PID、零重启；截至最终快照共 7 次刷新，间隔 45.146～45.637 秒，超过 175 秒看门狗周期后仍在充电。

最终独立读数为 98%、5164 mAh、实际 +509 mA；充电代码仍匹配上一版基线。睡眠候选依然未安装，睡眠目标仍 masked，成功/失败计数均为 0。本轮确认新系统已恢复已验证的充电路径，不构成对前一天睡眠失败的修复或复测。

另外只读记录了当前输入设备及唤醒权限：USB 鼠标自身 wakeup enabled，但其 hub、root hub 和 xHCI 路径为 disabled；`gpio-keys` 的 wakeup enabled。已询问用户上次尝试的具体唤醒方式及屏幕表现，以区分未收到唤醒事件和恢复卡住。当前配置不能倒推失败一轮的实际唤醒事件，尚未据此归因或修改权限。

证据为 `original-adapter-preflight.json`、`service-recovery.jsonl`、`restored-charge-watch.jsonl`、`service-recovery-summary.json`、`restored-final.json` 和 `wakeup-input-baseline.json`。

### 清醒时开合盖对照通过

用户补充：失败一轮中，电源键、键盘、鼠标、触控板及合盖后重新开盖均试过，屏幕始终完全不亮。因此不能仅以当前 USB hub 未启用 wakeup 解释该次故障。

2026-11-11 在同一新启动中，以 `systemd-inhibit --what=handle-lid-switch:sleep:idle --mode=block` 运行 180 秒只读观察，同时保留五个 sleep/suspend 目标的持久屏蔽。用户合盖再开盖后明确确认“正常亮起并显示画面”。记录为：

- GPIO50 为 high → low → high，IRQ 计数 0 → 1 → 2，`SW_LID` 为 0 → 1 → 0；关闭持续 6.024605 秒。
- 内核记录合盖 PWM duty 256 → 0，开盖恢复至 256；与用户视觉确认一致。
- 睡眠成功/失败计数保持 0/0，boottime 与 monotonic 差值未增加；本轮没有进入睡眠。
- 充电服务仍为 PID 5525、零重启；末次读数为 100%、5282 mAh、实际 0 mA、BQ 目标 0 mA / 8760 mV、PD 12 V / 3 A。

观察程序正常结束，临时 inhibitor 已解除，持久睡眠屏蔽仍保留。这验证当前清醒状态下的盖子输入和画面恢复，不能证明睡眠中的唤醒 IRQ 或设备恢复路径正常，也不能补回前一轮丢失的日志。证据为 `wake-failure-user-details.json`、`lid-awake.jsonl`、`lid-awake-after.json`、`lid-awake-summary.json` 和 `lid-observer-cleanup.txt`。

### 独立 PM 调试内核与后续步骤

当前内核没有 `/sys/power/pm_test`。为分离进程冻结、设备回调及真正睡眠阶段，新增 `src/build-sleep-debug-image.sh`，在私有构建目录中保留已验证的 GPIO50 交替边沿和 GPIO170 蓝牙补丁，只增加 `CONFIG_PM_DEBUG=y` 与其依赖 `CONFIG_PM_SLEEP_DEBUG=y`。未启用自动启动睡眠测试、PM_ADVANCED_DEBUG 或 DPM_WATCHDOG。原源码、构建输出和已验证 Image 均经哈希确认未被改写。

候选 Image SHA256 为 `ffba40697b5364f0e48693e7b0f71bee10eec1284a4d6086664fb940a9188179`；版本仍为 7.0.0，utsrelease/utsversion 与基线相同。14,951 个现有内核导出记录保留，增加 `pm_debug_messages_should_print`。由于 `CONFIG_MODVERSIONS=n`，导出表和 vermagic 检查不构成完整 ABI 证明，仍须在真机验证既有模块加载。

`src/test-sleep-debug-qemu.py` 使用静态 ARM64 BusyBox 和最小 initramfs，在 QEMU 11/HVF 中实际启动此 Image，依次设置 `pm_test=freezer`、`pm_test=devices` 并写入 `state=freeze`。两阶段均等待约 5 秒后成功返回，最终恢复 `pm_test=none` 并关机，宿主退出码为 0。它验证通用 PM 测试接口及虚拟设备回调，不代表三星硬件已通过。测试机制参考内核的 [Basic PM Debugging](https://docs.kernel.org/power/basic-pm-debugging.html)。

`src/build-sleep-debug-boot.sh` 以真机只读取回的 EFI `7ad52e7e…11a46fa` 为基线，完整保留原菜单，在末尾添加 `sleep-debug` 项。它复用当前设备树、initramfs、原充电服务及其他启动参数，只切换 Image、增加诊断标记并提高日志级别。`np545_pmdebug_once` 在 GRUB 成功写回 0 后才选择一次诊断启动；下次普通启动仍为原 Latest。菜单通过 `grub-script-check`，嵌入 EFI 后再次读取并与源菜单比较。启动诊断项不会自动执行 PM 测试。

安装工具 `src/install-sleep-debug-boot.sh` 有四个明确操作：

- `--check`：核对机型、USB 根和 ESP 身份、包哈希、原 Image/EFI、设备树、五个睡眠屏蔽和全部一次性标记；仅只读挂载 ESP。
- `--install`：保存原 EFI 备份，安装独立 Image 和未激活的菜单项，保持默认 Latest。
- `--arm`：在所有其他标记为 0 时，仅将诊断项标记设为 1，不重启。
- `--rollback`：清除本次标记并恢复原 EFI；不删除独立 Image，以便保留证据。

写入操作均在 USB 分区身份校验与锁保护后进行，完成后以只读重新挂载核对。诊断包自带 Debian ARM64 的 `grub-file`、`grub-editenv` 和缺失的 libdevmapper，仅在包内运行，不安装系统软件。没有任何操作解除睡眠屏蔽、修改充电策略或自动发起睡眠。

后续真机验证按以下顺序进行，每一步保存证据后才继续：

1. 一次性启动诊断内核，验证桌面、USB 根、模块加载、SSH、充电基线和 `pm_test` 接口；此时仍禁止桌面自动睡眠。
2. 正常停止充电控制进程，独立确认电流目标为 0、输入与电池状态，保存并同步日志；不能在旧充电服务运行时直接绕过守卫写 `state`。
3. 先执行 `freezer`，验证自动返回和输入状态；通过后再准备 `devices`，记录设备回调与恢复。`devices` 仍可能因真实驱动故障卡住，并非无风险测试。
4. 分阶段测试通过后，再决定完整 s2idle 的单变量对照和睡眠候选复测；不会把 QEMU 通过或清醒时开盖亮屏算作修复。

诊断构建、QEMU 日志、当前 EFI 备份和安装包位于 `output/sleep-debug-20261111/`。最终 `arm64/boot-v3/` 已暂存至真机 `/var/tmp/np545-sleep-debug-20261111/boot-v3/`，`--check` 实际退出码为 0，证据为 `device-preflight-v3.txt`；新系统缺少工具及工具不支持 `--version` 的两次预检均在写入前退出，修正后才通过。所有旧的一次性标记为 0，ESP 已卸载，未安装或激活诊断入口。物理诊断内核启动、三星设备阶段测试和本轮安装/回退写入均尚未验收。

### 诊断内核一次性真机启动通过

用户确认可以安装并重启后，在原启动 `60bc8efe…1873d` 保存满电基线：PD 12 V / 3 A、BQ 0 mA / 8760 mV、100%、5282 mAh、实际 0 mA，原服务 PID 5525。随后运行最终包的 `--install` 和 `--arm`，两次均返回 0，并通过只读重新挂载核对 EFI、独立 Image、原版备份及标记。旧 EFI 保存为 USB ESP 上的 `/EFI/BOOT/BOOTAA64.EFI.pre-pmdebug-7ad52e7e7a2797a1`。同步 journal 和文件系统后正常重启，没有执行睡眠。

新启动 ID 为 `cebcfca3-61f6-4fba-977a-b458e316fbc1`。旧地址 SSH 超时后，用户确认 Linux 桌面画面正常，并提供新 IP `10.86.97.82`；使用原主机密钥严格验证后恢复连接。实际 `BOOT_IMAGE` 指向 `ffba4069…88179` 诊断 Image，文件哈希匹配，`np545.pmdebug=1` 存在，`pm_test` 显示 `[none] core processors platform devices freezer`。

显卡 msm、EC 键盘、只读电池、背光、PCIe PHY、ath11k Wi-Fi、蓝牙 hci_uart 和 UVC 模块均加载。LightDM/Xorg/Xfce 运行，内屏 eDP connected，hci0 和 video0/video1 存在，相关服务 active、零重启、没有失败 unit。未发现模块格式或未知符号错误。原基线已有的两项 SPMI probe 告警及 cpufreq ICC 延迟探测仍存在，不能将本次启动描述为没有内核告警；本轮也没有重做相机采集、蓝牙扫描和 Wi-Fi 联网验收。

七个充电 Python 文件与重启前逐一匹配。新服务 PID 384 于启动时钟 17.127 秒进入满电等待，零重启。本次固件启动后的输入为 5 V / 3 A、BQ 0 mA / 8400 mV，服务按既有满电策略保留输入和零目标，没有主动恢复睡前的 12 V / 8760 mV。184.590 秒独立读数为 100%、5282 mAh、实际 0 mA；启动初期存在小幅负电流，不能说从启动开始每一瞬间都是零电流。本轮确认满电等待正常，不构成新内核下未满电充电恢复或完整充电循环的验收。

只读回查真实 ESP：诊断 EFI 与包一致，原 EFI 备份完整，全部十个一次性标记为 0，包括 `np545_pmdebug_once=0`。原 Latest 默认项保留，下次普通重启仍走原内核。五个睡眠目标仍持久 masked，GPIO46 系统唤醒 disabled，睡眠成功/失败计数 0/0，`pm_test=none`。**诊断启动已通过，真机 freezer/devices 及完整 s2idle 尚未执行，原唤醒故障尚未判定或修复。**

证据：`before-install.json`、`install.txt`、`arm.txt`、`reboot-request.json`、`reconnect.jsonl`、`after-boot-probe.json`、`after-boot-inventory.json`、`after-boot-esp.json`、`deployment-summary.json`、`boot-summary.json`。
