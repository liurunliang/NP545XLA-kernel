# NP545XLA 的 USB-C 和充电芯片只读对照

现有 **Battery read-only test (Samsung)** 菜单项可以一起观察两路 USB-C PD、电池请求和 BQ25710 设置。运行 `sudo np545xla-charge-observe` 取一个样本，或用 `sudo journalctl -b -t np545-charge -o cat` 读取自启动以来的时间线。采样包括同次启动的 ID、启动时钟和每行读取耗时。每次读取后间隔两秒。日用和摄像头菜单不启动这个采样服务。

## 社区先例

- 普通版三星 Galaxy Book Go（NP340XLA）实测的 BQ25710 和智能电池位于同一总线的 0x09、0x0b。其 `gbgo-charge` 服务每 60 秒读取电池请求的电流、电压、温度和满充状态，经限幅后更新充电芯片。周期刷新针对芯片的充电看门狗。普通版服务使用该机型自己的总线和充电限制。[社区实现](https://github.com/xbill9/linux-arm-adventures/blob/34f76f5cbbe3a78f29b1768180fc323378cf5140/galaxy-book-go/scripts/gbgo-charge)
- Galaxy Book4 Edge（NP750XQA）的实现先处理端口：检测插线、接通 S2MM006 的输入开关、核实供电档位，再根据电池请求维持 ISL9241 的设定。该项目在真机上区分了插线检测、供电协商与实际到达充电器的电力。它使用另一套 PD 控制器和充电芯片，寄存器地址及策略只适用于原机。[社区程序](https://github.com/ciscobugger/book4-edge-linux/blob/1ff984a82f55570ae0473a80811db1b4b760616e/userspace/charging/book4-pd-charge) · [实测与寄存器说明](https://github.com/ciscobugger/book4-edge-linux/blob/1ff984a82f55570ae0473a80811db1b4b760616e/reports/ec/07-pdic-s2mm006.md)
- 在 ChromiumOS EC 中，共用充电任务负责处理电池请求、整机限制和电源状态，BQ25710 驱动只实现将目标转换成芯片寄存器值。这说明在另一类设备中，持续维护充电可以完全由嵌入式控制器承担，并非一定由桌面 Linux 进程负责。[ChromiumOS 充电任务](https://chromium.googlesource.com/chromiumos/platform/ec/+/refs/heads/main/common/charge_state.c) · [BQ25710 芯片驱动](https://chromium.googlesource.com/chromiumos/platform/ec/+/refs/heads/main/driver/charger/bq25710.c)
- NP545XLA 自身的三星 EmuEC.sys 包含选择 PDO、接通或断开 Consumer Switch、设置 BQ25710 输入限流和检查充电电流的代码字符串。其 ACPI EMEC 为 IC10 和 IC19 各列出 0x33，为 IC20 列出 0x09 和 0x0b。这些是定位实际信号的依据，不能用来证明本轮 Linux 执行了 Windows 的动作。[三星驱动包](https://github.com/tordona/woa-device-drivers/releases/tag/samsung-np545xla-drivers) · [本机 ACPI](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L93774)

## 读取边界

- S2MM005 读取状态 0x0020、收到的电源能力 0x0260 和发出的请求 0x0240。只在两次状态相同、已连接、角色为用电端且处于 Sink_Ready 时解释固定 PDO 请求。源能力和请求缓冲在拔线后可能保留旧值；请求电压是协议值，不能替代电压表。[三星寄存器与状态定义](https://github.com/LineageOS/android_kernel_samsung_universal9810/blob/lineage-17.1/include/linux/ccic/s2mm005.h) · [三星 PD 消息实现](https://github.com/LineageOS/android_kernel_samsung_universal9810/blob/lineage-17.1/drivers/ccic/s2mm005_pd.c)
- BQ25710 必须读到厂商 0x0040、器件 0x0089 后才采集设置。记录看门狗时限、充电禁止位、充电电流和电压设定、输入限流和 ADC 配置。芯片状态寄存器 0x20 的部分故障位是读后清除，采样器跳过该寄存器；不启动 ADC，不改写任何控制字段。持续电压转换未开启时，ADC 原始值不能代表当前 VBUS。[TI BQ25710 手册，第 9.3、9.6 节](https://www.ti.com/lit/ds/symlink/bq25710.pdf)
- 电池请求电流和电压来自智能电池自己的 0x14、0x15；它们与 BQ25710 同号寄存器的目标值、以及电池实际电流分别记录。此只读入口只启动采样服务。带电启动后的主动续充使用另一个独立入口。[BQ25710 续充试验](bq25710-keepalive.md)

## 重建与安装

在已验证的 ARM64 构建环境运行：

```sh
work=/var/tmp/np545xla-diag
src/build-debian-battery.sh "$work/obj" "$work/artifacts" output/charge
src/build-charge-boot.sh output/battery/boot output/charge/boot
```

在三星 USB Debian 上安装生成的软件包，执行 `sudo systemctl daemon-reload` 后运行 `sudo bash install-daily-boot.sh --battery-diag boot manifest.txt`。安装器核对当前电池菜单指纹，并将升级前的 EFI 备份到 `EFI/BOOT/BOOTAA64.EFI.pre-battery-diag`。新增两个空的 PD 总线描述，不绑定控制策略驱动；既有电池入口的名称和默认日用选择保持原样。

## NP545XLA 真机对照（2026-11-06）

操作者确认同一充电器接在原端口并保持开盖。使用原电池菜单正常重启，启动 ID 为 `0373768f-fb6f-42e2-b61e-d9d6f9248837`。本轮从启动时钟 18.15 秒开始记录，共 254 个样本。响应热插的是 IC10；IC19 通常返回地址无应答，唯一一次完整读数显示未连接，没有足够数据判断第二个端口。各行的 PD 电压和电流表示固定供电档位及请求值。

| 阶段（北京时间） | S2MM005，IC10 | BQ25710 | 电池 |
|---|---|---|---|
| 带电启动至 15:29:00 | Sink_Ready，第 3 档，12 V / 3 A | 身份 0040:0089，看门狗 175 秒，电流设定 3,776 mA | 有效样本的实际电流中位数 +1.179 A，容量 4,883→4,929 mAh |
| 15:29:00→15:29:04 | 同一就绪状态和请求，未观察到降档 | 启动时钟 162.47 秒仍为 3,776 mA，164.51 秒设定为 0；充电禁止位始终未置位，电压及输入限流设置未变 | 93%，仍请求 4,256 mA 和 8,860 mV。实测电流从 +1,107 mA 经 +46 mA 降到 0，容量保持 4,929 mAh |
| 15:31:41 起，拔线约 30 秒 | 观测到脱离（状态 0），间或无应答。此时缓冲内仍有旧请求，不将其当作有效供电档位 | 电流设定为 0 | 电池转为放电 |
| 15:32:15–15:35:10，插回原端口 | 87 个样本均为 Sink_Ready，第 1 档，5 V / 3 A。电源仍公布 12 V / 3 A 档位 | 电流设定持续为 0，无新的非零目标 | 电池仍请求 5,320 mA，实测电流中位数 −847 mA，容量 4,921→4,879 mAh |

**带电启动后停充。** 芯片只清除了电流目标，USB-C 就绪状态和电池非零请求在边界两侧保持一致。这次是在 93% 发生，与此前 88% 的结果相对照，更符合 TI 描述的主机长时间没有刷新电流或电压设定、看门狗到期清零的行为。看门狗从最后一次有效写入计时；启动时钟从 Linux 启动计时。最后一次固件写入时刻和芯片的内部超时事件不能直接从本轮读取。匹配本机的三星 EmuEC.sys 还有一条在特定条件下检查寄存器 0x14 并设置 3,776 mA 的分支，和启动后实际读到的数值相符。

**运行中插回电源。** 控制器重新检测到线缆并发出了新的 5 V 请求，而带电启动曾选择 12 V；充电器没有恢复非零电流目标。两者都是实测差异。协商就绪只说明协议状态。本轮没有确认从 USB-C 到整机的输入开关已闭合，也无法凭旧 ADC 数据断定实际 VBUS，因而不能把电池承担系统负载的原因唯一归于 5 V 档位或某只开关。

未经写入的测量保存在构建机的 `output/charge/samples-final.jsonl`。与测试前的 EFI 相比，只有已有电池项使用的 DT 路径及诊断服务启动参数发生变化。旧电池 DT 和启动器备份均保留。

采样后，两项一次性标记均为 0，正常重启进入原默认桌面，启动 ID 为 `9126bdda-b4cb-43aa-9bde-5b9310740460`。LightDM 活动，Adreno 的 separate_gpu_kms=N，测试服务未运行，设备使用同一个 USB 根分区。记录见 `output/charge/return.txt` 和 `daily-confirmed.txt`。

## qcom_battmgr 固件接口核查（2026-11-09）

结论：所检查的两个 NP545XLA 原厂 ADSP 镜像缺少同平台参考固件中承载 PMIC GLINK 充电服务的加载段。直接加载 `qcom_battmgr`、增加设备树节点或安装 ADSP 模块，不能补出这个固件服务。现有证据支持继续以三星 EmuEC 对应的 I²C 硬件路径完善充电；若迁入内核，应接入 `power_supply` / Type-C 等标准子系统，而非把寄存器控制塞入 GLINK 客户端。

### 驱动需要什么

实际构建的 Linux 7.0 源码包含 `qcom,sc8180x-pmic-glink` 匹配，使用 SC8280XP 协议分支。`pmic_glink.c` 等待 RPMSG 通道 `PMIC_RTR_ADSP_APPS`，并通过 PDR 查询 `tms/servreg` 的 `msm/adsp/charger_pd`。SC8180X 的 `qcom_battmgr` 电池对象提供属性读取，驱动没有直接操作三星 S2MM005、BQ25710 的实现；持续充电依赖对端固件。内核 `qcom_pd_mapper` 中的域名是平台映射表，出现 `charger_pd` 映射本身不证明固件提供该服务。[上游驱动](https://github.com/torvalds/linux/blob/v7.0/drivers/power/supply/qcom_battmgr.c) · [GLINK 通道与 PDR 查询](https://github.com/torvalds/linux/blob/v7.0/drivers/soc/qcom/pmic_glink.c) · [PD 映射表](https://github.com/torvalds/linux/blob/v7.0/drivers/soc/qcom/qcom_pd_mapper.c)

### 原厂与参考固件的离线对照

三星输入来自 [NP545XLA 原厂导出包](https://github.com/tordona/woa-device-drivers/releases/tag/samsung-np545xla-drivers)。完整归档 SHA256 与发布值一致：`ec290dd56fc2844f48707751d769f6b425a8fa1cd7fdb56e5f3e4b4390900478`。分别检查其中 2021 与 2023 两个 ADSP 驱动目录；INF 均包含本机 `SUBSYS_C1A1144D`。

对照输入为 [SC8180X 参考驱动固定提交中的 ADSP CAB](https://github.com/WOA-Project/Qualcomm-Reference-Drivers/blob/81bbe7ab8925e6d045f719711feeb01ed15deb50/8180_CLS/200.0.64.0/qcsubsys_ext_adsp8180.cab)，版本 `08/13/2021,1.0.1610.0000`。下载文件的 Git blob SHA1 与该提交目录记录一致；CAB SHA256 为 `951e95cd474c0e22a52f724429c1a9a9ae24d63e9932266c43ecc8061cd02e90`。它的 INF 匹配参考板，未列出三星 `C1A1144D`；本轮仅离线分析，未加载到三星。

| 镜像 | 文件字节数 | ELF 程序头数 | `PMIC_RTR_ADSP_APPS` / 完整 `msm/adsp/charger_pd` |
| --- | ---: | ---: | --- |
| 三星 `06/21/2021,1.0.1530.0002` | 10,744,632 | 15 | 均未找到 |
| 三星 `03/13/2023,1.0.1530.0003` | 10,744,632 | 15 | 均未找到 |
| 高通参考 `08/13/2021,1.0.1610.0000` | 11,659,764 | 19 | 均找到 |

参考镜像具有三星两个镜像均未包含的四个 PT_LOAD 段，虚拟地址分别为 `0x60000000`、`0x600f2000`、`0x6019e000`、`0x6019f000`。其中第 9 段同时包含完整服务路径（文件偏移 `0x3fed4c`）、`BattMngrDevice_InitContext`（`0x40202d`）以及 PMIC 通道名（`0x40ec00`）；第 12 段也有电池管理函数信息。这是加载段与接口内容共同构成的证据，强于仅对字符串做阴性搜索。

三星镜像仍保留 `charger_process`、`battman_policy.c` 和 `charger_pd` 等公共线索。其中两处 `charger_pd` 位于并列 `sensor_pd`、`root_pd` 的域名表，不是完整服务注册路径。不能据此宣称充电域可以运行。

三个 ADSP 镜像 SHA256 分别为：

- 三星 2021：`a1cb626f9cdcd1e4130e30267d646609684e7bf34d8f8f8e9128f101cb0e0616`
- 三星 2023：`4ad21f21c7ee1962e492b1324f7562822e3c6e1d1d35895bb523f96b3c80ff14`
- 高通参考：`008847ec80d03f745d8db9302c21c801ce97cc7ccd1b48758d272f5414ba1f29`

### 三星 Windows 路径与 Linux 现场

原厂包带有 `qcpmicglink8180.sys`，二进制确含同名 PMIC 通道，但其 INF 匹配 `ACPI\QCOM049A`，本机 DSDT 没有这个 HID。相反，DSDT 的电池 `PMBM/QCOM0263` 依赖三星 `PM3P/SAM0606`；`PM3P.GBST` 从 `EMEC.CHGS` 读取状态，`EMEC/SAM0604` 列出 IC10、IC19、IC20 等 I²C 资源。Windows 枚举报告 `Samsung PMIC 3rd Party Driver` 和 `Samsung EmuEC Device` 为 OK。`SecPmic3p.sys` 同时包含 `GBST`、`PMCF` 方法标识。结合此前 EmuEC 的 PD 与 BQ25710 代码分析，不能将“Qualcomm Battery”设备名称或驱动包中存在 GLINK 文件等同于使用 GLINK 充电。[DSDT 电池依赖](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L603) · [EmuEC 资源](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L93743)

当前真机启动 `a20d1a8c-9281-4dc5-b0a6-00d344467797` 的只读采集确认：内核配置将 BATTMGR、PMIC GLINK、Q6V5 PAS、PD mapper、GLINK SMEM 设为模块，但 `modinfo` 查不到对应模块；`/lib/firmware` 未发现 ADSP 镜像。活动设备树的 `remoteproc@17300000` 为 `okay`，指向三星 `qcadsp8180.mbn`，没有 PMIC GLINK 节点；`remoteproc` 和 `rpmsg` 设备列表为空。因此当前未出现通道也有部署层原因，单独不能作为固件不支持的证据。

本轮未安装或启动 ADSP，未改写充电芯片，未验证任何 GLINK 请求回复。结论限定于已核验原厂包中的两版固件；其他未知版本或固件内部动态机制不在已验证范围。参考固件的存在不构成本机可用性证据。

可复核证据归档在 `output/charge-startup-20261109/qcom-battmgr/`：`live-platform.json`、`segment-comparison.json`、`adsp-comparison.json`、归档目录与哈希、解码后的 INF 和接口字符串位置。`inspect-firmware.py IMAGE...` 可重新读取 ELF 程序头并定位标识；`collect-live.py` 仅读取运行状态。原厂大归档继续复用 `output/gpu-firmware/NP545XLA.7z`，未向 Git 提交固件二进制。

## 睡眠充电前的硬件职责核查（2026-11-09）

当前证据支持由主机实施充电策略，尚不能确认本机存在可在主机睡眠后完整接管的硬件或固件。BQ25710 可以独立维持设定的恒流/恒压，但满充停充、再充和电池温度策略另有负责者。是否采用内核定期唤醒，应在核实电池包和原厂睡眠路径后决定。

### 已确认的边界

| 部件 | 已确认职责 | 不能据此推出的能力 |
| --- | --- | --- |
| S2MM005，IC10 / IC19，0x33 | USB-C/PD 协议状态、PDO 请求、Consumer Switch 控制；原端口已有 Linux 实测 | 不能由 PD 就绪推断电池正在充电，也未证明它能代管 IC20 的充电策略 |
| BQ25710，IC20，0x09 | 恒流/恒压、电源路径、输入限制、芯片故障保护、通信看门狗 | 没有自动读取 SBS 电池或独立执行整套电池充电策略的证据 |
| 智能电池 SDI 4432D53，IC20，0x0b | 真机读出身份、温度、状态、容量及请求电流/电压；观察到满充/终止充电标志 | 上报满充或过温与直接切断充电是不同能力；包内芯片、独立保护阈值及接线尚未识别 |
| Samsung EmuEC.sys | 原厂代码内存在电池型号匹配、温度检查、满充停充、再充和目标刷新；已定位 WDF 定时器与 D0 电源回调 | 静态代码不能证明 Windows 实际睡眠状态，或其他固件是否接管 |

TI 手册第 9.4.1.2 节明确将满充或不适宜充电时的终止交给 host：设置禁止位或把电流写为零。第 9.5.1 节说明 BQ25710 仅作 SMBus 从设备，不主动发起通信。第 9.3.10.8 节的 155°C 热关断针对芯片结温；引脚表没有专用电池 NTC/TS 输入，不能替代电池温度管理。第 9.3.10.1 节允许关闭看门狗，但这仅取消失联停充条件。[TI BQ25710 Rev. B](https://www.ti.com/lit/ds/symlink/bq25710.pdf)

### 原厂代码的可复核证据

本轮检查原厂包中 `emuec.inf_arm64_dcadbca96f4e5604/EmuEC.sys`，SHA256 为 `70de2be234da9d34125b4409f1272f8e74b2a7f1f1c651f9f09548823cb58bb9`。以下均为 RVA，镜像基址 `0x140000000`。函数名依据相邻日志字符串定位，再核对分支和调用；不只依据字符串存在作结论。

- `ChargerInit`（`0x144b0`）：TI 厂商分支给保存的 ChargeOption0 赋值 `0xe70e` / `0xe70c`，随后经 `0x17ac8` 写寄存器 `0x12`；两值的看门狗位均为 `11b`。对应标称 175 秒，手册容差范围为 140–210 秒，不能把 175 秒当作保证最短时间。
- `RefreshCharger`（`0x14ec8`）：活动充电分支累加计数，到 30 后重新写 `0x14`、`0x15`；另一分支检查电流被清零后的恢复。它由下述定时回调调用，名义刷新间隔约 30 秒，但定时器允许延迟，不应当作严格周期。
- `checkBattStatus`（`0x13318`）：检查缓存电池状态 bit 5 后，通过 `chargeSignal`（`0x13770`）派发停充。`SetChargerStop`（`0x14d60`）的 BQ25710 分支将 `0x14` 写为零。
- `checkBattTemp`（`0x13490`）：读取缓存温度，超出允许区间时进入上述停充派发；读数为 `0xffff` 的分支则请求重读并返回失败，该分支本身没有派发停充。`BattMaincharge`（`0x13bc8`）调用该检查；`battTrickleCharge`（`0x13a20`）包含温度恢复和容量阈值再充分支。以下补充具体控制流，不能把所有“检查失败”都理解为立即写零。
- `checkDeviceName`（`0x13070`）：从 `0x2b620` 的型号表选择 `0x2b650` 起的参数行，其电压字段进入 `SetChargerMain` 的处理路径。表中 `4432D53`、`4432W53`、`4432D50` 对应 8,760 mV，`4402D51` 对应 8,696 mV。真机现已读出 `4432D53`，与第一行相符；这仍不构成将现有 8,696 mV 设置抬高的理由，后续还存在策略调整与寄存器量化。

反汇编和提取表保存在本调查工作树 `output/hardware-boundary/`：`emuec.disasm.txt`、`emuec-xrefs.json`、`emuec-charging-excerpts.txt`、`emuec-battery-profiles.json`。这些是分析产物，未作为驱动代码提交。

### 原厂满充、再充和异常处理的进一步核查

以下是同一 EmuEC 样本的静态行为，不是新增真机测试，也不是已经批准的 Linux 参数。温度使用原厂的 `2731` 偏移折算，摄氏值取近似值。

| 场景 | 原厂控制流 | 对后续适配的含义 |
| --- | --- | --- |
| 运行中充满 | `checkBattStatus(0x13318)` 检查满充状态或软件容量上限，将状态置为 `0x20`、目标派发置零，调用停充；`mainBattCharCtrl(0x13c90)` 后续仍处理这个状态 | 停充后进入等待，管理任务继续运行；正常充满不应导致管理器退出 |
| 电量下降后再充 | `battTrickleCharge(0x13a20)` 先检查温度，再比较缓存 SOC。默认分支阈值为 96 或 97，取决于上下文 `+0x117`；容量上限模式改用 `+0xce9`。满足条件后重新进入充电，先派发预充目标，再由主充路径初始化 | 存在容量回差和恢复检查；SOC 经 `ModifyRSOC` 处理，模式字段含义尚未全部厘清，不能直接把 96/97 当作 Linux 阈值 |
| 温度不合适 | 主充检查允许原始值 `2731–3231`，约 0–50°C；越界置温度故障并停充。等待/故障恢复使用 `2781–3181`，约 5–45°C | 停充范围与恢复范围不同，有意避免阈值附近反复启停；保留当前 Linux 更保守的范围 |
| 温度改变充电目标 | `CheckBatteryTemp(0x15370)` 在主充状态 `0x11` 下执行高低温分档。高温分支约 41°C 进入、39°C 及以下退出；目标还取决于缓存单体数据和状态位，低温另有多档 | 原厂温控不仅是一个温度开关；需要区分停充、降流/降压、恢复，不能只复制型号表中的最高电压 |
| 电源或电池离线 | 主控制器发现 AC 或电池存在标志缺失后清状态，并派发停充 | PD/输入、电池存在状态必须共同约束目标 |
| 充电计数耗尽 | 主控制器递减计数，归零后进入 `0x80` 停充状态；不同路径写入 7,200、18,000、64,800 等初值 | 这些是执行次数计数；分支和调度可推迟递减，不能直接声称是严格的墙上时钟超时 |

**定时器频率不等于电池采样频率。** `SendBatteryMessage(0x17e38)` 先执行恢复、错误检查及 `RefreshCharger`，随后调用普通轮询，最后调用主充控制和温度分档。`GetBattData(0x12030)` 只是读取缓存，在该函数内没有 I²C 读取或采样时间检查。普通轮询 `BatteryPolling(0x12a40)` 每累计 7 次调用才读取一个选中项；初始化在 `0x12268` 写入掩码 `0x3e40`，选择 SOC、电压、循环次数、电池状态、电流和温度六项。因此常规路径名义上约 42 次定时回调完成一轮，并非每秒更新全部数据；初始化、恢复和调度延迟会改变实际时序。这是静态推导，尚无 Windows 总线时序实测。

通信失败也不能概括为“原厂立即停充”：普通读取失败会设置恢复标志和重试计数，暂时保留旧缓存；`CheckRecover(0x125b8)` 的重试耗尽路径才将温度、状态等缓存置为 `0xffff`，另有容量/设计字段使用回退值。温度检查遇到 `0xffff` 时请求恢复并返回失败，调用者跳过余下检查；该分支自身没有写零。由于刷新位于本轮普通采样及策略检查之前，**尚未证明整个驱动对持续通信故障具有怎样的停充上限**。后续 Linux 应明确新鲜采样、最大允许数据年龄、失败停充和恢复条件，而不是照搬这个缓存及重试实现。

进一步串联控制流后，可确认以下更具体的边界，仍不等于整机故障实测：

- `RefreshCharger` 在 `0x14f94–0x150bc` 按调用计数和 AC/电池存在标志刷新备份电流/电压；该分支不检查温度缓存是否为 `0xffff`、恢复掩码是否非零或采样年龄。另一分支在读回电流为零且主充状态仍为 `0x11` 时重写目标，也没有先验证新的温度读数。
- `mainBattCharCtrl` 在 `0x13e40` 递减充电计数，之后才进入状态/温度检查。状态为 `0xffff` 会从 `checkBattStatus` 返回失败；温度为 `0xffff` 会从 `checkBattTemp` 返回失败。两条失败路径都可能保留 `0x11` 主充状态。计数归零是另一个停充条件，但它不是“最后一次有效温度采样之后经过多久”的计时器。
- **第二个温度处理函数不会自动补上这一保护。** `SendBatteryMessage` 在 `0x181c4` 调用主控制器后，紧接着在 `0x181c8` 调用 `CheckBatteryTemp(0x15370)`，没有依据前者的检查结果跳过它。该函数仅以主充状态 `0x11` 为入口条件，没有过滤 `0xffff`；按无符号比较，失效值会满足高温分档条件。
- 一个可逐条核对的局部路径是：主充状态 `0x11`、温度 `0xffff`、分档 flags 初始为零，且四个缓存单体值均 ≤ 4099。`0x15444` 的比较进入高温分支，`0x15318` 返回真，随后 `0x15488` / `0x15494` 将备份目标写入 `0x14` / `0x15`。备份值是否非零取决于此前上下文。这里证明的是**无效温度值仍能到达目标写入路径**，不是证明这一上下文已在真机出现，也不是证明一定持续充电。

BQ25710 的看门狗只依据是否按时收到充电电流/电压寄存器写入；它不知道主机是否成功读取了电池温度。因此，当电池读取失效而充电器写入仍成功时，继续写目标可能维持看门狗，不能用“有 175 秒看门狗”代替主机的数据有效性检查。该结论来自芯片接口定义与上述静态路径，不涉及人为制造电池故障。[TI 手册 9.3.10.1 与 0x12 寄存器定义](https://www.ti.com/lit/ds/symlink/bq25710.pdf)

当前 Linux 候选代码没有沿用上述 OEM 缓存分档路径：[`np545_battery.c`](../src/debian-battery/np545_battery.c) 的温度属性直接读取 SBS，并对零值、`0xffff` 返回 `-ENODATA`；[`hotplug.py`](../src/debian-battery/hotplug.py) 的活动充电循环先取 `pack()`、执行 `pack_target()`，再刷新目标。接管后的读取异常会退出循环并进入停充清理；停充写入在通信故障时能否成功仍取决于链路。本轮只核对源码，没有做故障注入。后续内核方案必须让目标刷新、温度分档和睡眠恢复都服从同一份有效采样与停充决定。

本次摘录与前提保存在 `output/hardware-boundary/emuec-communication-boundary.json` 和 `emuec-communication-excerpts.txt`；没有据此修改真机策略或宣称已确定完整故障停充时限。

`CheckBatteryError(0x12db8)` 还轮换读取厂商命令 `0x00` / `0x90`，分别检查 `(word & 0x0f00) == 0x0900`、bit 1，并使用四次确认计数；日志将其关联到永久故障/不平衡。它表明原厂还使用包内厂商状态，不能证明这些故障已经由包内 FET 独立处理。TI 的 [bq3055 手册 A.1.1.6](https://www.ti.com/lit/ug/sluu440/sluu440.pdf) 有相似的状态字段和 FET 编码，但本机没有芯片身份读数，且 `0x90` 的含义没有由该手册确认，**不能据此认定电池包使用 bq3055**。本轮没有向电池发送这些厂商操作。

可复核产物：`output/hardware-boundary/emuec-policy-excerpts.txt` 与 `emuec-policy-boundary.json`，包含函数范围、默认轮询表、阈值原始值及未验证项。

### 原厂定时任务与电源回调

依据微软公开 [KMDF 1.17 函数表](https://github.com/microsoft/Windows-Driver-Frameworks/blob/main/src/publicinc/wdf/kmdf/1.17/wdffuncenum.h) 和 [回调结构定义](https://github.com/microsoft/Windows-Driver-Frameworks/blob/main/src/publicinc/wdf/kmdf/1.17/wdfdevice.h)，对间接调用进行解析，避免把控制流保护检查误认为实际驱动调用：

- `0x4f048` 注册 `EvtDeviceD0Entry=0x5dc0`、`EvtDeviceD0Exit=0x6180`、`EvtDeviceSelfManagedIoInit=0x6670`；SelfManagedIoSuspend/Restart 字段为零。
- `0x20c48` 创建三个 WDF timer。第一个回调为 `0x20e20`，Period 为 0，TolerableDelay 为 1,000 ms。`0x6898` 初次启动使用 `-300000000` 个 100 ns，即名义 30 秒；回调在 `0x20f58` 使用 `-10000000` 自行重启，即名义 1 秒。它接着调用 `SendBatteryMessage(0x17e38)`，后者调用 `RefreshCharger`。这是调用调度证据，不是每秒获得一份新电池采样的实测证据。[WDF_TIMER_CONFIG](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdftimer/ns-wdftimer-_wdf_timer_config)
- D0Exit 经 `0x61e8` 在 `0x6468–0x64bc` 对三个 timer 执行 `WdfTimerStop(..., TRUE)`，随后关闭 I/O target。已跟踪的普通路径未发现把 BQ 看门狗关闭或将充电移交给另一控制器的操作。存在条件性的电池切断命令分支，不能当作普通睡眠交接。
- `0x6828` 注册的电源通知 GUID 是 `GUID_CONSOLE_DISPLAY_STATE`，回调 `0x20410` 处理屏幕关闭、开启和变暗；它不是完整的系统睡眠通知。
- D0Entry/D0Exit 所调的 `0x507f0` / `0x509a8` 主要修改上下文字段。驱动另有 PoFx 注册和性能状态调用；这些调用本身不能证明充电交接。

**设备 D0 退出、Windows Modern Standby、屏幕关闭需要分别验证。** D0Exit 在多种设备电源/PnP 场景执行；代码中停止 timer 不能直接推出每次合盖都停止充电，也不能证明休眠或关机期间如何充电。[微软 D0Exit 定义](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdfdevice/nc-wdfdevice-evt_wdf_device_d0_exit)

新增分析产物为 `emuec-wdf-methods.json`、`emuec-import-xrefs.json`、`emuec-power-excerpts.txt`、`emuec-power-constants.json`，均位于 `output/hardware-boundary/`。

### 休眠、关机与厂商命令的边界

进一步按参数类型追踪了电源回调，避免把数值相同的不同枚举混用：

- D0Entry 在 `0x5e6c` 调用 `WdfDeviceGetSystemPowerAction`，`0x5e7c` 比较返回值 `3`，对应 `POWER_ACTION::PowerActionHibernate`。该分支设置恢复标志，跳过 `0x4faa0` 的 PoFx 注册，调用 `0x507f0` 更新上下文；已有 PoFx 句柄时再报告设备已上电。它描述恢复处理，不能证明休眠期间谁负责充电。WDF 对部分电源场景的返回值语义还存在版本差异，不能只凭这个比较反推实机睡眠类型。[系统电源动作 API](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdfdevice/nf-wdfdevice-wdfdevicegetsystempoweraction)
- D0Exit 在 `0x621c` 比较的却是回调传入的 `WDF_POWER_DEVICE_STATE`：`4` 为 `WdfPowerDeviceD3`，`5` 才是 `WdfPowerDeviceD3Final`。这里的 `4` **不是**另一个枚举中的 `PowerActionShutdown`。D3 分支只额外向 `0x509a8` 传入清理标志；停止三个 timer、关闭 I/O target 是后续共同路径。已跟踪路径未发现专门针对 S4/S5 修改 BQ 看门狗的分支，但这不能排除其他驱动或固件介入。[设备电源枚举](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdfdevice/ne-wdfdevice-_wdf_power_device_state) · [系统电源枚举](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/ne-wdm-power_action)

原先发现的 Ship Mode 已追到明确的厂商命令路径，不能把它当作普通关机动作：

1. 邮箱分派函数 `0x1c0f0` 从输入 byte 1 取命令，使用 `command - 0x80` 索引 `0x2b6a0` 的 128 项函数表。
2. 命令 `0xe8` 对应表项 `0x2b9e0`，调用 `0x16150`（日志为 `SetShipmode command`）；`0x16180` 将上下文 `+0xdb` 置为 `0xa5`。
3. D0Exit 只有检查到该标志，才在 `0x630c` 调用 `0x142d0`：先派发停充，再向电池请求 ManufacturerAccess `0x0010`，随后清除标志。这是驱动意图与请求路径；实际电池包是否接受并关断 FET、原厂软件何时发出该邮箱命令，均未验证。未执行该命令，也未穷举所有间接上下文写入。

同一邮箱表还明确了原厂**电池寿命延长选项是主机策略**：命令 `0xe3` 指向 `0x16090`；模式切换到 `1` 时，将 `+0xce8` / `+0xce9` 分别设为 `80` / `75`。`checkBattStatus` 在驱动缓存/修正后的 SOC ≥ 80 时派发停充，等待状态在 SOC ≤ 75 且温度等条件允许时启动再充。该路径没有把“80% 上限”作为自主阈值写入充电芯片的证据，不能据此假定主机停工后上限仍会执行。后续 Windows 采样应记录当前电池保护选项，不因高电量时未充电就判为异常。

S0 待机、S4 休眠、完整 S5 关机应分别取证。Windows 启用 Fast Startup 后，用户选择“关机”仍可能涉及保存内核休眠映像，不能直接当作完整 S5 样本。后续需要用实际系统电源事件区分，现有 Before/After 操作说明只覆盖手动 S0 待机。[Fast Startup 与休眠的区别](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/distinguishing-fast-startup-from-wake-from-hibernation)

本节仍是静态证据。新增可复核记录为 `output/hardware-boundary/emuec-lowpower-mailbox-boundary.json` 和 `emuec-lowpower-mailbox-excerpts.txt`；已重新核对原厂二进制 SHA256 及上述两个函数表项，没有对真机发送厂商命令或改变电源状态。

### ACPI 与原 Windows 睡眠能力记录

继续核查了仓库已有的原厂表和 Windows 枚举记录，未为此切换操作系统：

- `facp.dat` 长 276 字节，长度字段一致，校验和为零；Flags=`0x00300000`，即 Hardware Reduced 与 Low Power S0 Idle 均置位，ARM boot flags=`0x0001`，声明通过 SMC 使用 PSCI。文件 SHA256 为 `15b75401cc28fb1c8aba1337da155bec520b3df46d477fe40f72425dabc74be7`。
- `hw-enum.txt` 中 **2026-05-22 17:35:57 的历史 Windows 输出**列出 `Standby (S0 Low Power Idle) Network Connected`、Hibernate、Fast Startup 可用，S1/S2/S3 和 Hybrid Sleep 不可用。这是当时系统的运行输出，比仅靠 FADT 位更直接，但仍需重新读取当前 Windows 状态。
- DSDT 的 `_PTS` / `_WAK`（99478、99486 行）只执行调试输出及 LED 字段修改；该方法体没有充电寄存器访问或移交。未以此排除其他固件机制。
- `PEP0.LPMD` 返回 `LPCD`；其中 EMEC 的 component 0 具有 PSTATE 0/1，分别对 `/arc/client/rail_cx` 给出 `0x100` / `0` 的 NPA 资源投票。包内没有充电管理参数。这与 EmuEC 中 PoFx 性能状态调用相符，不能把电源轨投票等同于充电接管。
- EMEC 的 `EMOP(0x9c)` / `BMOP(0x9e)` 属于厂商自定义 OperationRegion。其存在不是物理独立 EC 的证明；电池状态经 PM3P/EMEC 传递也不等于固件持续控制充电。

因此优先验证的解释是：**原 Windows 使用 S0 待机，EmuEC 可能在其间保持 D0 并定期维护充电**。这是由已知电源模型和定时路径提出的假设，尚无该机待机中的执行轨迹支持。S0 待机允许受控的短时软件活动，不能套用“合盖后所有内核任务都停止”的前提。[微软 Modern Standby 模型](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/modern-standby)

补充支持线索：已识别的 170 处 WDF 函数表加载中没有 `WdfDeviceAssignS0IdleSettings`，充电 timer 的 TolerableDelay 为 1,000 ms，也不是 `TolerableDelayUnlimited`。微软将后者用于永不因该定时器唤醒处理器的配置。这些静态特征支持进一步追踪待机中的 timer 活动，但不构成所有间接路径或其他驱动行为的穷举证明。[WDF 空闲降电要求](https://learn.microsoft.com/en-us/windows-hardware/drivers/wdf/supporting-idle-power-down) · [No-Wake Timers](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/no-wake-timers)

证据摘录：`output/hardware-boundary/acpi-power-boundary.json`、`acpi-power-excerpts.txt`、`windows-archived-sleep-states.txt`。

### Linux 定时唤醒路径：RTC 硬件存在，维护后回睡仍需适配

2026-11-09 13:46–13:56 UTC，对同一启动 `a20d1a8c-9281-4dc5-b0a6-00d344467797` 完成只读检查：

- `/sys/power/mem_sleep` 仅有 `[s2idle]`，`/sys/class/rtc` 为空。PMIC RTC 平台设备已经创建，兼容串为 `qcom,pm8941-rtc`，但没有绑定驱动；`CONFIG_RTC_DRV_PM8XXX=m`，目标机没有对应模块文件。
- 活动节点 `/soc@0/spmi@c440000/pmic@0/rtc@6000` 没有被禁用，IRQ 描述为 `<0 0x61 1 0>`。它来自 `sc8180x-pmics.dtsi`；父 PMIC 的 DT 兼容串是 `qcom,pm8150`，不据此单独推断芯片实物型号。
- `CLOCK_REALTIME_ALARM`、`CLOCK_BOOTTIME_ALARM` 的只读 `clock_gettime` 调用均返回 `EINVAL`。`CONFIG_CHARGER_MANAGER`、`CONFIG_PM_AUTOSLEEP`、`CONFIG_PM_WAKELOCKS` 均未启用。

为区分“设备树有节点”和“硬件真实可访问”，新增一次性只读模块 [`np545_rtc_diag.c`](../src/debian-battery/np545_rtc_diag.c)。它限定本机兼容串、上述节点、SID 0、已绑定的 `pmic-spmi` 父设备，以及尚未绑定正式 RTC 驱动的状态；只通过现有 regmap 读取上游 RTC 驱动也读取的地址。计数读取沿用上游的低字节进位检查。它不注册 RTC、不申请中断、不写寄存器、不改变系统时间，也没有常驻任务。

| 13:55:19 UTC 真机读数 | 结果 | 已证明的范围 |
| --- | --- | --- |
| RTC 控制 `0x6046` | `0x80` | RTC enable 位已设置 |
| RTC 计数 `0x6048–0x604b` | 16,410,951 → 16,410,952，间隔 1,121 ms | 通过现有 SPMI/regmap 可读，计数正在推进 |
| 闹钟控制 `0x6146` / 目标 `0x6140–0x6143` | `0x00` / `0` | 此刻未启用闹钟；没有设置或触发过闹钟 |

模块以匹配的 Linux 7.0 构建树执行 `ARCH=arm64 W=1` 编译，无警告；未解析的 regmap 符号仅有 `regmap_read` / `regmap_bulk_read`。KO SHA256 为 `0d2ea58ffeaafc9974ee71de5cb5ebde0861e6e551a2f457f4d7e53a86488188`，vermagic 为 `7.0.0 SMP preempt mod_unload aarch64`。真机加载成功，随后已卸载；RTC class 仍为空，充电服务仍保留原先的 failed 状态。未进行睡眠、重启或充电参数修改。

正式 RTC 驱动不能只考虑“补一个模块”：当前 DT 没有 `allow-set-time`、NVMEM offset 或 `qcom,uefi-rtc-info`。上游 `rtc-pm8xxx` 在这种配置下以零 offset 解释计数；读到的约 1,641 万秒不是当前 Unix 时间。当前内核 `CONFIG_RTC_HCTOSYS_DEVICE="rtc0"`，RTC 核心在该设备注册时会执行 `do_settimeofday64`。因此**若按当前配置直接注册为 rtc0，会把原始计数当成日期设置系统时间**；正式验证前须先处理时间基准，或在隔离测试配置中避免自动设置系统时钟。本轮只读模块绕开了 RTC 注册路径。[RTC 核心](https://github.com/torvalds/linux/blob/v7.0/drivers/rtc/class.c) · [PM8xxx 驱动](https://github.com/torvalds/linux/blob/v7.0/drivers/rtc/rtc-pm8xxx.c)

上游驱动已有 RTC alarm 和 wake IRQ 支持，SPMI IRQ 的 `set_wake` 会传递到父中断；可优先复用这条路径。但**计数可读不证明有闹钟写权限、IRQ 能到达 Linux，或能从 s2idle 唤醒**。EFI RTC 也不能作为现成替代：当前没有成功绑定，且该版本 `rtc-efi.c` 明确清除 `RTC_FEATURE_ALARM`。`alarmtimer` 只选择同时具备 alarm 和 wakeup 能力的 RTC；仅创建内核定时器不能填补这一缺口。[alarmtimer 实现](https://github.com/torvalds/linux/blob/v7.0/kernel/time/alarmtimer.c)

另一个边界是“唤醒后自动回睡”。[Charger Manager 文档](https://www.kernel.org/doc/html/latest/power/charger-manager.html) 仍描述 `cm_suspend_again` / `charger_global_desc`；本轮核对的 v7.0 `.c` 和 `.h` 已没有这些接口。当前实现用 `ALARM_BOOTTIME` 安排唤醒，在 PM complete 阶段检查电池，缺 RTC 且充电时会拒绝 suspend；它没有提供文档所述的旧回睡函数。其充电控制还依赖 regulator 接口，不能直接接管现有 SBS + BQ25710 服务。[当前 Charger Manager 源码](https://github.com/torvalds/linux/blob/v7.0/drivers/power/supply/charger-manager.c)

`kernel/power/suspend.c::platform_suspend_again()` 明确排除 `PM_SUSPEND_TO_IDLE`。而 `s2idle_loop()` 执行时设备已完成 noirq suspend；GENI I²C 的 `suspend_noirq` 会将 adapter 标记为 suspended，并按状态关闭中断、时钟和 interconnect。因此不能直接在 s2idle 回调里照常访问电池/充电器。**定时唤醒、恢复总线并执行策略、区分用户唤醒并决定是否回睡，是三个需要分别验收的环节。** 全内核协调的要求保留，当前尚没有可以直接启用就完成这三步的实现。[s2idle 控制流](https://github.com/torvalds/linux/blob/v7.0/kernel/power/suspend.c) · [GENI I²C 电源回调](https://github.com/torvalds/linux/blob/v7.0/drivers/i2c/busses/i2c-qcom-geni.c)

下一步硬件验证顺序：先在清醒状态确认 RTC 时间处理及单次 alarm IRQ，再做受控 s2idle 唤醒；之后验证恢复后的 IC10/IC20 访问和充电目标刷新，最后才加入维护后回睡、开盖/按键退出及连续周期功耗检查。各步均不能以“模块编译成功”代替真机结果。

原始证据在 `output/hardware-boundary/live-rtc-readonly.txt`、`live-linux-wake-inventory.json`。源码副本及哈希在 `linux-power-sources/`、`linux-power-source-sha256.json`；其中 `charger-manager.c` 和 `kernel/power/suspend.c` 与直接下载的上游 v7.0 文件逐字节一致，对照记录在 `linux-power-upstream-comparison.json`。

### 真机电池身份与广播模式

SBS 标准允许电池作为 SMBus 主设备，周期性向充电器发送 `ChargingCurrent(0x14)` / `ChargingVoltage(0x15)`。`BatteryMode(0x03)` 的 bit 14 为 1 时禁止这些广播；bit 13 独立控制告警广播。bit 0 / bit 8 表示可选的包内充电控制器能力及使能，与一般电池保护不是同一个概念。[SBS 1.1，第 5.1.4、5.2、5.4 节](https://sbs-forum.org/specs/sbdat110.pdf)

2026-11-09 13:13:54 UTC，在启动 `a20d1a8c-9281-4dc5-b0a6-00d344467797` 中读取：

| SBS 字段 | 实测值 | 含义与边界 |
| --- | --- | --- |
| ManufacturerName / DeviceName / DeviceChemistry | `SDI` / `4432D53` / `LION` | 当前实物身份，不再依靠 FCC 照片或候选型号猜测 |
| BatteryMode `0x03` | `0x6000`，两次读数相同 | bit 14=1 禁止 I/V 广播；bit 13=1 禁止告警广播；bit 0=0 未声明可选内部充电控制器；不能据此判断没有保护 FET |
| SpecificationInfo / DesignVoltage | `0x0031` / 7,720 mV | 与现有 SBS 读取结果一致 |
| ChargingCurrent / ChargingVoltage | 6,916 mA / 8,860 mV | 电池请求值，不是批准的板级目标；不得直接代替现有电流、电压限制 |
| 温度 / BatteryStatus | 28.9°C / `0x00c0` | 该采样时已初始化、正在放电 |

两次模式采样间隔约 64.7 秒。SBS 对 ALARM_MODE 有 45–65 秒自动清除约定；两次读数不足以证明期间从未变化，亦未查明是谁设置该位，不能据此推断固件符合性或控制器存在与否。

本机电池与 BQ25710 位于同一 IC20，但**当前配置没有启用电池 I/V 广播**。BQ25710 的公开命令表未列出 SBS 的 `AlarmWarning(0x16)`，不能默认它实现完整 Smart Battery Charger 告警机制。此前主机未刷新时电流归零的实测，也未显示有其他控制者在持续有效刷新。直接开启广播可能绕过现有 1,024 mA 和较低电压策略，本轮没有修改 BatteryMode。

[三星 FCC 内部照片](https://fccid.io/m/d304a060e9280057b3c38009f4d3a005e3a703a308e13ba47123c5045a97ace7.pdf) 的送检样机电池标签可辨认为 AA-PBAN2HE、标称 7.72 V。照片不能识别包内保护芯片，也不能替代对当前真机电池型号的读取。

### 同款电池的社区实现

ChromiumOS EC 在固定提交 `08f5a1e6fc2c9467230444ac9b582dcf4d9f0068` 的 [`board/sasuke/battery.c`](https://chromium.googlesource.com/chromiumos/platform/ec/+/08f5a1e6fc2c9467230444ac9b582dcf4d9f0068/board/sasuke/battery.c) 中明确匹配 `SDI / 4432D53`。`sasuke` 对应 Samsung Galaxy Chromebook Go，可在 [ChromiumOS 设备表](https://new.chromium.org/chromium-os/developer-library/reference/development/developer-information-for-chrome-os-devices/) 核对。

该配置给出最大 8,760 mV、标称 7,720 mV、预充 200 mA，并通过 profile override 将请求电压减去 100 mV、将超过 4 A 的请求电流降低 10%。这些数值可与原厂驱动交叉核对，不能直接移植为 NP545XLA 参数。

更重要的是职责分工：该板有 NPCX EC，使用 RAA489000；[`ec.tasklist`](https://chromium.googlesource.com/chromiumos/platform/ec/+/08f5a1e6fc2c9467230444ac9b582dcf4d9f0068/board/sasuke/ec.tasklist) 明确启用 CHARGER 任务。[`charger_task`](https://chromium.googlesource.com/chromiumos/platform/ec/+/08f5a1e6fc2c9467230444ac9b582dcf4d9f0068/common/charge_state_v2.c) 读取电池、执行温度策略、设置电流/电压，并持续循环；插电时维持充电轮询。板级秒钩子还针对“满电且 AP 睡眠”降低 PD 输入电压。即主处理器睡眠时，EC 软件仍有工作要做。本机尚未确认等价的独立常驻控制者。

复用时还需注意该历史源码的两个细节：

- 电池表顶部关于温度字段不生效的注释与该提交的代码不一致。`board.h` 开启 `CONFIG_BATTERY_CHECK_CHARGE_TEMP_LIMITS`，实际函数按请求是否同时为零选择 start/charging 范围；应追踪执行路径，不能只抄注释或温度表。
- FET 配置给出 `cfet_mask=0xc000`、`cfet_off_val=0x2000`，与掩码及相邻位定义存在明显不一致。它是进一步查询包内状态的线索，不能当作本机已验证的保护解码器。本轮未发送 ManufacturerAccess 或 ship-mode 命令。

### 新发现：满充后服务退出，尚无自动再充闭环

本轮读取已有日志，发现同次启动中的充电服务早于诊断操作停止：

1. 启动约 1,377 秒时，目标电流 1,024 mA，实际 +262 mA，电池 8.675 V、29.1°C、97%，状态 `0x0080`。
2. 约 1,379 秒时，服务把充电电流写为零并读回确认，随后关闭 Consumer Switch。
3. 退出原因是 `pack status 0x40a0`，包含 `TERMINATE_CHARGE_ALARM`、`INITIALIZED`、`FULLY_CHARGED`。

这证明电池会发出明确的满充/终止信号，当前主机策略也确实执行停充。它没有证明电池保护 FET 自行切断，更不等于已验收完整满充/再充周期。`keepcharge.py::pack_target` 将该状态作为 `StopCharge`，服务退出后处于 failed；`charge_startup.py` 的启动满电等待没有覆盖运行中充满再回到等待的转换。该行为是日用整合前的明确缺口，不应把“能持续充电”和“整套充电管理完成”等同。

原始日志：`output/hardware-boundary/live-mode-repeat-and-charge-history.txt`。本轮保留现场，未重启充电服务。

### 只读诊断实现与验证

新增 `src/debian-battery/np545_battery_diag.c`，只在 `samsung,np545xla` 上找到指定 OF 节点、地址 `0x0b`、所有者 `np545-battery-ro` 后读取允许列表。它不注册新 I2C 驱动、不解绑现有驱动、不改变 client flags、不写寄存器。模块加载时采样一次，不创建后台任务；字符串由 `strings=1` 显式开启，使用标准 SBS 读取方式并检查长度。

已在现有 Linux 7.0 构建树中以 `ARCH=arm64 W=1` 编译通过，无警告。未解析符号中的 I2C 调用均为读取接口。模块 SHA256 为 `b2bb2f3234cae29c34bc117c0658e59a10b498a377bf2f1dae78bd96e76d146f`，vermagic 为 `7.0.0 SMP preempt mod_unload aarch64`。真机两次加载/卸载均完成，读数在 `live-battery-identity.txt` 与上述重复采样日志中。模块未加入启动配置或正式软件包。

独立外部模块构建方式：在临时目录复制该 C 文件，Kbuild 内容为 `obj-m := np545_battery_diag.o`，使用与目标内核严格匹配的构建目录执行 `make -C <kernel-build> M=<diagnostic-dir> ARCH=arm64 W=1 modules`。不能仅凭版本号相同就混用内核 ABI。

### 剩余核查顺序

1. **原厂真实睡眠行为**：补 Windows 运行时电源状态、定时活动和睡眠/恢复前后充电寄存器证据，区分屏幕关闭、Modern Standby、休眠和关机；继续核查 ACPI/固件路径。现有静态证据已定位普通 D0 回调，但还没有证明睡眠交接。
2. **独立保护与告警链**：查明 SDI 4432D53 包内控制器、保护条件及告警接收者。没有可信寄存器定义前不写 ManufacturerAccess，不以升温、过充或清除保护标志验证。
3. **补全主机策略边界**：把运行中充满、等待、再充、温度恢复、通信失败和 PD 断连列为后续状态机验收项；保持当前保守电压、电流。
4. **再定睡眠充电实现**：若证明外部控制者能完整负责，再研究睡眠期间委托；否则由内核承担温度/状态检查、停充/再充和看门狗刷新，另行验证可唤醒时钟及自动返回睡眠。`power_supply` 提供标准接口，不自动填补这些策略。当前已只读确认 PMIC RTC 走时，尚未验证 alarm IRQ、s2idle 唤醒和自动回睡；还需处理 RTC 时间基准和 GENI I²C 恢复顺序。

调查中临时加载并卸载了 SBS 和 RTC 的只读诊断模块，没有修改真机充电参数、电池模式、服务或启动项，没有重启。睡眠持续充电、完整满充/再充周期和电池独立异常保护仍未完成真机验收。

### 已准备的 Windows 验证入口

[`dump/NP545XLA-PowerBaseline.ps1`](dump/NP545XLA-PowerBaseline.ps1) 只采集当前电池遥测、系统/相关驱动信息、睡眠能力、电源设置，以及 After 阶段的系统电源事件和 powercfg 报告。还会保存 EmuEC 服务状态、映像路径、磁盘文件 SHA256，以及 WPR/Tracelog/Tracefmt 的命令查找结果。脚本不切换系统、不触发睡眠、不启用追踪、不改设置、不访问原始 I²C，也不进行网络上传。报告写入 `%LOCALAPPDATA%\NP545-Power\<timestamp>`。磁盘文件哈希不等于已加载内存映像的校验；工具未出现在命令查找结果中也不等于未安装。

Windows 的营销型号可能是 `Galaxy Book Go 5G`，脚本同时核对三星厂商和 `Win32_BaseBoard.Product` 中的 `NP545XLA` 板号。2026-11-10 实机返回 `NP545XLA-KA1TT`，但 `root\wmi` 的 `BatteryStatus`、`BatteryFullChargedCapacity` 均无实例。因此每次电池采样另存 `battery-first-system.json` / `battery-last-system.json`，使用 `CallNtPowerInformation(SystemBatteryState=5)` 的只读查询取得系统汇总状态、容量和功率。保留原始 DWORD `Rate` 及按 LONG 解释的 `SignedRate`，后者单位为 mW；这些仍是可能缓存的 Windows 遥测，不是原始 SBS 读取。原生结构校验为 32 字节，输入指针为空，不调用电源策略设置功能。[查询接口](https://learn.microsoft.com/en-us/windows/win32/api/powerbase/nf-powerbase-callntpowerinformation) · [状态结构与 Rate 符号](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_battery_state)

首轮仅验证**原端口插电的 S0 待机**。应由操作者安排切换 Windows，以免中断其他 Linux 工作；电池有充电空间、确认正在充电时，在管理员 PowerShell 执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\NP545XLA-PowerBaseline.ps1 -Phase Before
```

记录打印的 Reports 目录，保持同一充电器、端口及外设组合，手动从开始菜单选择“睡眠”，约 20 分钟后唤醒，立即执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\NP545XLA-PowerBaseline.ps1 -Phase After -TrialDirectory '<Reports 目录>'
```

判断必须同时查看：

1. 当前 `/a` 是否仍支持 S0 Low Power Idle；驱动版本是否与反汇编样本一致。
2. 睡眠报告是否记录目标时间段，Screen Off 与 Sleep/低功耗驻留是否成立；出现非零驻留并不等于整段持续深睡。
3. `before/battery-last-system.json` 与 `after/battery-first-system.json` 的容量、充放电状态；WMI 有实例时再对照 `battery-last.json` / `battery-first.json` 的容量和电压。还应核对期间是否重启、是否改变电源来源。两种来源都是 Windows 遥测，可能缓存，不能当作直接 SBS 寄存器读取。
4. **AC 会话的 SleepStudy 不记录能量变化**，因此不能用其中的 Charge 标记证明实际充电；需结合前后容量读数。即使容量增长，也只支持该测试区间的净充电，无法单独区分待机维护与唤醒附近的充电，更不能证明执行者身份。若需定位 EmuEC 活动，下一阶段再进行针对性 ETW/总线观测。[SleepStudy 限制](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/modern-standby-sleepstudy) · [powercfg 命令](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options)

脚本已用官方 PowerShell 7.4.6 便携版完成语法解析；新增映像路径处理检查了 5 种正常形式和 3 种拒绝形式，文档中的 5 段 PowerShell 命令也已通过解析。2026-11-10 又验证了原生 C# 编译、32 字节结构布局和负功率转换，并在 Windows 11 ARM64 build 26200 完成 Before / After 真机采集，二者 Errors 均为空。`complete.json` 只表示一次采集结束，仍须核对原始记录与事件覆盖范围。此前检查在 `output/hardware-boundary/power-collector-validation.txt`，本轮原始文件、采集器副本、摘要及分析在 `output/hardware-boundary/windows-validation-20261110/`。

### Windows 插电待机基线实测（2026-11-10）

本轮使用 `dcf8ac9` 的采集器，SHA256 为 `c3e35fd97aec6f8ef3011a1b583fccb43ed28832c7373d4097e5193fc2ec9bce`。用户在原端口插电，从开始菜单进入睡眠，随后按电源键唤醒。期间没有主动 SSH 查询、额外 WPP/WPR 追踪或充电参数修改。原定计时 20 分钟，实际从进入待机到用户唤醒约 **39 分 19 秒**；按真实事件时长记录，不计作恰好 20 分钟的测试。

| 核对项 | 本轮证据 |
| --- | --- |
| 驱动与电源 | EmuEC 为 Running，磁盘 SHA256 与反汇编样本一致；四段待机退出事件均报告 AC，电池未更换 |
| 是否重启 | 相关 Kernel-Power 事件的 BootId 均为 `27`，会话连续；CIM 的 LastBootUpTime 随校时变化，不能单独据此判为重启 |
| 实际待机时长 | 事件 `5924 / 5928 / 5961 / 6155` 的 DurationInUs 合计 `2359.265907 s`；使用校时事件修正首尾时间所得 `2359.245398 s`，相差约 21 ms |
| 待机边界容量 | 进入待机 `6129 mWh`（约 15%），唤醒 `23290 mWh`（约 57%），净增约 `17.2 Wh`；这是 Windows 驱动估计，约以 1% 容量为步进，不是独立电量计测量 |
| 采集边界容量 | Before 最后样本 `4903 mWh`（约 12%）；After 首个样本 `23290 mWh`。Before 到真正进入待机仍有清醒充电时间，因此不能把二者全部增量算作待机所得 |
| 最深低功耗驻留 | 四段退出事件的软件 / 硬件 DRIPS 均为 0，最后约 30 分钟的 SleepStudy Sleep 段也报告 `LowPowerStateTime=0`、`HwLowPowerStateTime=0` |
| 活动线索 | 最后长段中，Update Orchestrator / WU 分别活跃约 1020 s，ARC 的 cx 电源域约束约 676 s，`\\_SB.IC20` I²C 设备活跃约 45.6 s。活动可能重叠，不能相加为总时长，也不能仅凭设备活跃证明某条充电寄存器写入 |

**本轮确认 Windows 的待机区间内电池容量明显增长，但没有验证最深平台低功耗下的持续充电，更没有证明独立 EC / 固件接管。** Sleep 状态标签并不保证整段都在 DRIPS；本轮系统更新和平台约束持续存在。与原厂静态分析结合，只能说主机侧维护仍有机会执行，具体 EmuEC 定时器、SBS 读取和 BQ25710 刷新仍需针对性追踪。[Modern Standby 的状态与 DRIPS](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/modern-standby-states) · [SleepStudy 的活动与驻留指标](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/modern-standby-sleepstudy)

本轮另有三处数据边界：

- Windows 时间服务将墙钟回拨约 `8 h 2 min 9 s`，Kernel-General 事件 `5940` 保存了 OldTime / NewTime，随后还有两次毫秒级校正。原采集器按 Before 时间过滤，虽然没有报错，却漏掉了校时后的事件；已另行按日志顺序补采最近 500 条相关事件，保存为 `power-events-by-record.json`。BatteryReport 的跨校时 Duration 出现无符号下溢，不能用于算时长；SleepStudy 最后 Sleep 段与 Kernel-Power 的 SleepDuration 还存在 5 秒差异，保留两份原值，不使用虚假精度。
- After 首个样本为 `AcOnLine=1, Charging=0, Discharging=1, SignedRate=+26280 mW`，标志与正功率不一致；约 15 秒后恢复 `Charging=1, Discharging=0`，功率 `+24356 mW`。因此不以唤醒瞬间的单个状态位判断充电中断。最后容量还从 23290 增至 23699 mWh，但不把唤醒后的增长计入待机。
- AC 报告的 `EnergyDrain` / `Discharge` 汇总为 0，仍可见进入 / 退出容量字段增长；不能把汇总为 0 当作没有充入电量。待机容量差与首次 After 样本互相吻合，但仍属于同一 Windows 驱动遥测链。

采集器现为 Before 增加 System 日志序号游标，After 按 `EventRecordID` 获取电源、启动和校时事件，并在电池样本保存 `GetTickCount64` 运行时间。缺少旧版游标、日志重置或超过 2000 条上限时会记录错误，不静默宣告覆盖完整。新增逻辑通过语法和 C# 编译检查；尝试在真机验证新查询时 SSH 两次超时，尚未完成新版整轮复测，本轮结论来自已补齐的原始事件。没有修改系统时钟、更新策略或睡眠配置。

后续清醒充电的 WPP 小样本已完成，见下节。待机追踪前仍需确认系统校时及后台活动，再将驱动日志与待机驻留对齐。若平台仍无法进入 DRIPS，应继续定位 cx 约束及 IC20 活动；不能跳过这一边界，直接把本轮结果解释为硬件自治充电。

### 原厂 WPP 入口与后续运行时取证

上述 EmuEC 样本包含可定向启用的 WPP 日志。以下参数来自 ARM64 反汇编，已于 2026-11-10 在同哈希的 Windows 驱动上完成两分钟清醒充电实测：

| 项目 | 值与静态依据 |
| --- | --- |
| 启用用的 control GUID | `28f88fb3-c7ec-4a0c-bf04-aaaa2e4dc7e0`，位于 `0x2b400`；初始化入口 `0x52010` 将其放入控制块，`0x4f7f4` 调用动态解析的 `EtwRegisterClassicProvider` 注册 |
| 通用充电日志标志 | `0x21590` 将正文格式化后，以 flag index 10 调用 `0x210e8`；后者检查 `1 << (10 - 1)`，即 `0x200` |
| 首轮候选 level | `5`；覆盖已核对的 level 2 日志，但不覆盖所有 OEM 调用。例如 `SetChargerMain` 末尾 `0x14d34` 传入 `0x40`，并另受 recorder 状态条件限制 |
| 解码用的 message GUID / ID | `cb82acef-d6ce-3c92-28fd-52039420aa94` / `15`；GUID 位于 `0x2bc20`，不是启用 provider 所用的 GUID |
| 正文 | `0x2120c` 经 `WmiTraceMessage` 传入两个以 NUL 结尾的 ANSI 字符串：`EmuEC` 和已由 `_vsnprintf` 格式化的正文；正文最多 511 字节 |

定位记录保存在 `output/hardware-boundary/emuec-wpp-boundary.json`、`emuec-wpp-excerpts.txt` 和 `emuec-import-addresses.json`。本轮已经在缺少私有 PDB 时按已核对的格式解码实际 ETL。不能把 control GUID 当作 TMF 文件名，也不能因为通用工具暂时没有显示文本，就判断驱动没有执行。微软说明 TMF 按 message GUID 匹配，其内部格式可能随版本变化。[TMF 格式说明](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/trace-message-format-file)

#### 清醒充电 WPP 实测（2026-11-10）

**Windows 主机侧 EmuEC 确实持续监测电池，并约每 30 秒向充电器提交电流、电压写请求，返回状态均为成功。** 这次采集主动保持清醒，是解码和调用链的正对照，不是睡眠充电验证。

设备仍为 `NP545XLA-KA1TT`、Windows 11 ARM64 build 26200，EmuEC 服务 Running，磁盘映像 SHA256 为 `70de2be234da9d34125b4409f1272f8e74b2a7f1f1c651f9f09548823cb58bb9`。采集期间线程临时申请系统和显示器保持清醒，结束后恢复此前状态；没有修改电源方案、充电参数或驱动，也没有启停已有 WPR/OEM 会话。

| 观测 | 实测结果与范围 |
| --- | --- |
| 采集窗口 | UTC `03:31:40.032062` 至 `03:33:40.594703`，约 120.56 s；原始 ETL 15,138,816 字节 |
| Provider 启用 | `EnumerateTraceGuidsEx` 查询到 3 个注册实例；采集前均未启用，期间 LoggerId 58、level 5、MatchAnyKeyword `0x200`，结束后均恢复未启用 |
| 完整性 | 3,703 个事件，238,894 字节 payload；会话与离线消费者报告的事件 / 缓冲区丢失计数均为 0；ProcessTrace / CloseTrace 返回 0 |
| 主维护循环 | 119 条 `RefreshCharger::mainBattChg`，间隔中位数 1.00748 s，最大 1.06724 s；本轮状态始终为 `mainBattChg=0x11, setCharge=1, CHARGER_FLAG=9` |
| 新电池读取 | 17 条读取成功分支的 `BatteryPolling::cmd`，每约 7.06 s 轮换温度、SOC、电压、循环数、状态、电流；同一字段约 42.3–42.5 s 更新一次。大量 `GetBattData` 是缓存访问，未计入新读取 |
| 写请求 | 4 组 `0x14 / 0x15`，同一寄存器间隔约 30.23–30.35 s；8 次返回 NTSTATUS 均为 0，请求数据长度均为 2 |
| 目标与实际值 | `0x14` 请求原始值 3830（`0x0ef6`），`0x15` 请求 8760（`0x2238`）；SBS 电池电流两次为 +2529 / +2530 mA，电压 8636–8642 mV，温度约 34.25–34.55 °C |
| 容量 | 系统电池状态由 33,506 增至 33,914 mWh，约 82% → 83%；两端均报告 AC、充电中、未放电。这仍是 Windows 遥测 |

写入证据来自 message GUID `245af9f0-4406-34ac-f755-f0b0bd0e4b58`、ID `12`，不能与 `RefreshCharger` 入口混为一谈。该事件是四个小端 uint32：寄存器、请求原始值、返回 NTSTATUS、请求数据长度。反汇编链为：`0x17ac8` 写助手 → `0x7908` 构造命令字节与两字节数据 → `0x7a38` 调用 WDF 表项 184（`WdfIoTargetSendWriteSynchronously`）→ 返回值保存至 `w19` → `0x17b58` 经 `0xc128` 发出事件。WDF 方法返回请求完成状态，因此比目标值日志更强；**仍不是外部总线捕获或芯片寄存器读回**，事件中的长度 2 也不是实际 BytesWritten。[WDF 同步写的返回值](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdfiotarget/nf-wdfiotarget-wdfiotargetsendwritesynchronously)

`0x14` 的低 6 位在 BQ25710 中不参与电流设定；按 10 mΩ 采样电阻解释，原始 3830 对应 3776 mA 的设定码，不能说实际正在以 3830 mA 充电。`0x15` 的电压分辨率按手册 §9.6.4 为 8 mV。另外，119 条 ID `11` 读日志均为寄存器 `0x3f`、值 `0x3c00`：这是 IIN_HOST（按 10 mΩ 解释为 3000 mA 输入限流），**不是** `0x12` 中的看门狗配置；该消息第三个字段只是重复读值，不是 NTSTATUS。本轮没有据此宣称读到了 Windows 当前看门狗设置，也没有把原厂目标应用到 Linux。[TI BQ25710 §9.6.1、§9.6.3–4、§9.6.6](https://www.ti.com/lit/ds/symlink/bq25710.pdf)

本机 `logman query providers <GUID>` 返回未找到，但原生 `EnumerateTraceGuidsEx(TraceGuidQueryInfo)` 能查询注册和启用状态。实际采集使用系统自带 `logman create trace ... -ets -f bin -max 64 -ct perf -ft 00:00:01 -bs 64 -nb 4 16 -p '{28f88fb3-c7ec-4a0c-bf04-aaaa2e4dc7e0}' 0x200 5`，随后读回配置；没有要求安装 WDK。停止后独有会话查询为 4201（不存在），provider 启用计数为 0。`logman` 列表查询失败不能作为驱动没有 WPP 的证据。[原生查询接口](https://learn.microsoft.com/en-us/windows/win32/api/evntrace/nf-evntrace-enumeratetraceguidsex) · [logman 参数](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/logman-create-trace)

原始记录与执行过的采集、导出脚本位于 `output/hardware-boundary/windows-wpp-20261110/`。ETL 在 `NP545-EmuEC-Awake-c17d0edd3fc0478b9c11f1ab3db175c5/emuec.etl`，SHA256 为 `73d8fd9d3067881747703284eacf5604063863dbfff49feb74a5540612c1568b`。最初导出器误将 WPP 短头判为错误，只导出 2 个事件；保留该失败记录，最终使用 `events-v2.tsv` 和 `decode-result-v2.json`，共 3,703 个事件。WPP 原始头可短于普通 EVENT_HEADER，但回调提供的 EVENT_RECORD 字段布局仍按 API 读取。

[`dump/decode-emuec-wpp.py`](dump/decode-emuec-wpp.py) 可离线复核已导出的 TSV：验证分析样本哈希、已知消息格式和导出计数，分别保存正文、写返回、电池读取及间隔摘要；未知消息仍保留在原始 TSV 中，不猜测其含义。清醒样本已通过该脚本重算，结果与独立首轮解码一致。示例中的目录是原始采集目录，输出目录必须尚不存在：

```sh
python3 docs/dump/decode-emuec-wpp.py "$capture/events-v2.tsv" "$capture/decode-result-v2.json" \
  --driver "$oem_sample/EmuEC.sys" --output "$capture/redecoded"
```

后续已去掉保持清醒请求，在自动待机区间捕获到充电写返回，见下节。若要证明最深低功耗下的执行 / 交接，仍须结合驻留和设备 D-state，必要时追加 WPR Power。原有无追踪基线用于对照追踪带来的扰动。S4/S5、独立保护与异常恢复仍不在本轮验收范围内。

#### 自动待机 WPP 实测（2026-11-10，退出报告待补）

**在 Windows 已记录进入 Modern Standby 的区间内，EmuEC 仍每秒执行维护，并每约 30 秒完成电流、电压写请求。** 本轮未收到操作者“已手动睡眠”的确认；Kernel-Power `506`、记录号 `6204` 显示 UTC `04:01:24.7349130` 因空闲超时（Reason 12）进入待机，BootId 27、ScenarioInstanceId 22。因此记为自动待机观测，不冒充已完成手动睡眠流程。

试验目录为 `output/hardware-boundary/windows-wpp-20261110/20261110-035736-024/`。使用 `55f5fe1b...` 版本的电源基线采集器，Before 的 Errors 为空。WPP 仍启用 `0x200 / level 5`，不申请保持清醒，不触发睡眠或设置唤醒定时器，也不改充电参数。追踪从 UTC `03:58:25.8988754` 至 `04:08:02.6810219`，共约 576.78 s；随后关闭独有会话，查询为 4201，provider 启用记录为空。ETL 为 73,859,072 字节，SHA256 `f39f351937f04012ee56f0dd985c7a53f2158733f94297a77e14b2dfddb6a2f7`，低于 128 MiB 上限；会话与消费者均报告零事件 / 缓冲区丢失。

会话中断恢复后，首次 SSH 检查开始于 UTC `04:04:45.056412`，该次因缺少进程级脚本执行参数未能读取状态；随后使用与此前采集一致的参数重试成功。**两次网络访问都可能扰动待机，不能把它们之后的活动当作无观测干预的结果。** 因此将记录拆分如下：

| 片段 | 时长 | 主维护日志 | 充电器写返回 | 新电池读取与电流 |
| --- | ---: | ---: | ---: | --- |
| 进入待机前 | 178.84 s | 178 | 12 次，均成功 | 26 次轮换读取；电流 +811 → +750 mA |
| 待机进入后、首次网络检查前 | **200.32 s** | **200** | **14 次，均成功** | 28 次轮换读取；5 个电流样本为 +730、+713、+696、+677、+661 mA；SOC 97% → 98% |
| 首次网络检查至停止追踪 | 197.62 s | 196 | 12 次，均成功 | 28 次轮换读取；电流 +645 → +600 mA |

全记录共 17,838 个事件，其中 16,378 条通用正文、574 条主维护、82 条轮换电池读取、38 条写返回。写请求始终为 `0x14=3830 / 0x15=8760`，返回状态全部为 0；同一寄存器间隔约 30.11–30.19 s。200 秒观测前区间的维护间隔最大约 1.018 s，连续写返回可排除“只在入睡之前或恢复之后写入”的解释。采集器两端容量 39,226 → 40,043 mWh，属于整个追踪窗口；真正的待机进入容量为 39,635 mWh，不能把全部增长归入待机。

本轮支持**这种 Modern Standby 运行状态下仍由主机驱动参与充电管理**。截至 UTC `04:10:24`，补查尚未发现该会话退出事件，After / SleepStudy 仍等待操作者唤醒后采集；不能据此给出 DRIPS 驻留结论，也不能推广到持续深睡、休眠或关机。已单独保存 `standby-analysis-pre-wake.json`、首次网络访问时刻、各次命令结果和原始 ETL；待退出报告齐全后，再区分 Screen Off / Sleep 子阶段及平台驻留。

另核对到一个追踪筛选边界：D0Exit 的 D3 分支日志（调用点 `0x6258`，message GUID `4217c437-b0a8-3311-ba92-50484b99ae48`、ID 53）使用 flag index 3，即 `0x4`；D0Entry 的休眠恢复分支 ID 47 也使用该标志。当前 `0x200` 采集不包含它们，因此不能根据缺少 D0 日志断定没有电源状态切换。这里仅为静态调用点映射，保存于 `d0-log-filter-boundary.json`，没有改动本轮正在运行的追踪条件。

#### 后续采集与验收方法

取证分三步，每步使用新目录：

1. 无追踪待机基线已完成，原计划 20 分钟，实际约 39 分钟；容量增加，但 DRIPS 为 0。
2. 清醒两分钟 WPP 正对照已完成，确认实际启用、解码和写返回。后续每轮继续核对服务状态与磁盘哈希；不匹配时重新分析映像。
3. 自动待机 WPP 已捕获主机写请求，尚待唤醒报告补齐驻留边界；必要时另做 WPP 与 WPR Power 联合实验，对齐设备 D-state 与平台驻留。追踪可能改变待机行为，因此与第一步比较。短实验用于识别执行机制；若评价功耗趋势，微软建议至少一小时的 Modern Standby 记录。[WPR Power 与 WPA 分析方法](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/using-windows-performance-analyzer-to-analyze-modern-standby-issues)

管理员 PowerShell 中先检查现有会话。以下命令假设已找到可运行的 WDK Tracelog；若不在 PATH，应使用经过确认的完整路径：

```powershell
tracelog.exe -l -lp
tracelog.exe -enumguidex '#28f88fb3-c7ec-4a0c-bf04-aaaa2e4dc7e0'
wpr.exe -status
wpr.exe -profiles
```

只有目标 provider 未被其他会话占用，才进行 WPP 小样本；联合实验还要求没有其他 WPR 录制。保留查询输出，不修改或停止已有会话。创建唯一名称与目录后，候选命令为：

```powershell
$session = 'NP545-EmuEC-' + [Guid]::NewGuid().ToString('N')
$traceDir = Join-Path $env:LOCALAPPDATA ('NP545-Power\' + $session)
New-Item -ItemType Directory -Path $traceDir -ErrorAction Stop | Out-Null
$session | Set-Content -LiteralPath (Join-Path $traceDir 'session-name.txt')
tracelog.exe -start $session -guid '#28f88fb3-c7ec-4a0c-bf04-aaaa2e4dc7e0' -flag 0x200 -level 5 -UsePerfCounter -seq 64 -f (Join-Path $traceDir 'emuec.etl')
if ($LASTEXITCODE -ne 0) { throw 'Trace start failed; inspect existing sessions and retain the output.' }
tracelog.exe -q $session -lp | Tee-Object -FilePath (Join-Path $traceDir 'session-start.txt')
tracelog.exe -enumguidex '#28f88fb3-c7ec-4a0c-bf04-aaaa2e4dc7e0' | Tee-Object -FilePath (Join-Path $traceDir 'provider-enabled.txt')
```

保持清醒并充电约两分钟后，在同一窗口结束自己创建的会话：

```powershell
tracelog.exe -q $session -lp | Tee-Object -FilePath (Join-Path $traceDir 'session-end.txt')
tracelog.exe -stop $session | Tee-Object -FilePath (Join-Path $traceDir 'session-stop.txt')
```

检查各命令退出结果、provider 的 flags/level、ETL 事件时间范围和 lost events/buffers。`-seq 64` 到达 64 MB 后停止记录，不覆盖开头；若触顶，本次记录不能覆盖完整实验。PowerShell 中 `#GUID` 必须带引号。Tracelog 可能忽略部分错误选项，不能只凭启动命令显示成功验收。[Tracelog 命令与查询说明](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/tracelog-command-syntax)

联合实验另建一轮采集：WPP 启动确认后执行 `wpr.exe -start Power`，仅在成功后手动睡眠；唤醒后用 `wpr.exe -stop <本轮唯一目录>\power.etl` 保存，再停止本轮 WPP。不取消其他 WPR 录制，也不设置开机自动追踪。结合该轮 Before/After 采集，分析以下证据强度：

- `RefreshCharger` 入口日志（`0x14f00`）只能证明主机执行到维护函数，不能证明本次已经写寄存器或写入成功。
- `BatteryPolling::cmd ... wData ...` 日志（`0x12b58`）位于读取助手返回成功的分支，可用于识别本轮返回值与采样时间；仍不是外部总线分析仪证据，也不是每条日志都代表电流采样。
- `SetChargerMain` 的目标值日志与实际充电电流不同；该函数末尾没有依据各次写入结果决定是否打印，且末尾日志不在 level 5 的范围内。
- 待机区间持续出现有效电池读取或充电维护日志，将支持 Windows 主机仍参与管理；必须对齐 Sleep/平台驻留区间，排除只记录到入睡前和恢复后。
- 未出现日志不能证明由硬件接管。还需排除筛选条件、丢失、解码失败、设备 D-state 和追踪改变待机驻留等因素；休眠、关机充电也不能由这轮 S0 实验外推。
