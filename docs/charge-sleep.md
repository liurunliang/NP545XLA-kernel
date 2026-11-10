# 充电服务睡眠交接候选

2026-11-10：本阶段实现睡眠前确认停充、释放 GPIO/I2C，唤醒后重新检查并启动充电。已通过 ARM64 包内 95 项测试和真实 systemd 管理器上的六组模拟顺序测试；真机睡眠验收尚未完成。此前完整充电循环的实测见 [charge-startup.md](charge-startup.md)，不能替代本候选的睡眠验证。

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
