# 在持久化 Debian U 盘上试验内置设备

启动菜单的前三项是诊断系统，第四项使用已验收的原 Debian 设备树。第五项 **Debian 13 - daily desktop (Samsung)** 使用单独的日用设备树，可手动选择以回退。当前 SanDisk 的默认项是 **Debian 13 - Adreno unified DRM trial (Samsung)**。这些 Debian 入口共用 USB 根文件系统和系统账户，均关闭内置 UFS。更新日用设备树后，菜单中的 **previous daily device tree** 可启动前一版日用配置。

## 生成设备树与菜单

在制作原镜像的 Debian ARM64 环境运行。以下命令使用原 Debian 镜像清单及其 FAT 启动分区里的 `/boot/debian-samsung.dtb`。从同一介质提取这个文件，先与清单的 SHA-256 核对。使用 `--port0-x1` 构建对应内核的无线模块包和设备树片段。示例假设无线产物位于 `output/daily/wifi`。[无线驱动构建说明](debian-wifi.md)

```sh
work=/var/tmp/np545xla-diag
src/build-debian-eckb.sh "$work/linux-7.0" "$work/obj" "$work/artifacts" output/daily/eckb
src/build-debian-touchpad-probe-dtb.sh debian-samsung.dtb touchpad.dtb
fdtoverlay -i touchpad.dtb -o pci0.dtb output/daily/wifi/sc8180xp-np545xla-wifi.dtbo
src/build-debian-wifi-phy-dtb.sh --port0-x1 pci0.dtb daily.dtb
src/build-daily-efi.sh output/debian-final/manifest.txt BOOTAA64.EFI
```

Windows 枚举把 `SSTP0001` 下的子设备标为 Samsung TPD 和 HID 鼠标。三星 DSDT 的 `I2C1.TCPD` 位于 400 kHz 的 GENI 控制器（880000.i2c），设备地址是 0x40，HID 描述符寄存器是 0x0e。其运行态供电表声明 LDO11_C，电压为 3.3 V。原设备树的 0x62 对应 Samsung EC2。

固件为触控板提供的虚拟中断脚是 448。按 Qualcomm 公开的 WoA 映射，448 / 64 取 GIO0 的第 7 项（从 0 开始），得到 GSI 590。减 32 得 SPI 558，对照本 SoC 的 PDC 范围得到 PDC 78，再查 SC8180x 的 wakeirq_map 得到 GPIO104。独立对照用合盖信号，其虚拟脚 320 映射为 GPIO50，与 DSDT 里读取盖子状态的 LIDR 一致。[Qualcomm 工程师的映射算法](https://marc.info/?l=devicetree&m=178272904036845&w=3) · [Linux v7.0 SC8180x 引脚表](https://github.com/torvalds/linux/blob/v7.0/drivers/pinctrl/qcom/pinctrl-sc8180x.c)

### 内置键盘

键盘 ECKB 的虚拟脚 640 映射为 GPIO125（GSI 605、SPI 573、PDC 93），日用设备树配置低电平中断和上拉。实机在启动时和进入桌面后均出现过相同故障。Linux v7.0 的通用驱动先在地址 `0x05` 做一次无寄存器的单字节读，两次尝试均报告 `clock line undriveable`。同一启动直接成对发送寄存器 `0x0020` 并读取 30 字节，得到有效键盘描述符 `0CF2:9028`。[Linux v7.0 探测代码](https://github.com/torvalds/linux/blob/v7.0/drivers/hid/i2c-hid/i2c-hid-core.c)

键盘模块直接读取描述符，核对长度、HID 版本和厂商产品编号，再沿用原驱动的复位、中断和输入报告处理。日用设备树的 `samsung,np545xla-eckb` 让 udev 在启动时加载它。驱动要求本机型号、`a80000.i2c/keyboard@5` 和 GPIO125 匹配。使用之前的 GPIO125 日用树可手动执行 `sudo modprobe np545_eckb existing_dt=1`。[板级驱动修改](../patches/linux-7.0-np545xla-eckb.patch)

在已启动的 Xfce 实机热加载后，内核注册了 `0CF2:9028 Keyboard`。30 秒空闲抽样中 GPIO125 保持 128 次，键盘传输错误为零，整机 CPU 空闲及 I/O 等待合计 99.2%。

在日用设备树冷启动后，内核自动加载模块并注册了键盘。udev 还把主键盘识别成绘图板按钮，Xorg 将它分配给指针。键盘包 `7.0.0-3` 随附 udev 规则，在该键盘的 `inputN` 父节点及事件节点上移除两项绘图板标签。现场复核中 `libinput list-devices` 将其列为 `keyboard pointer`，Xorg 为同一设备注册了 `KEYBOARD`。该规则位于 X11 和 Wayland 共用的输入层；本次图形会话实测使用 Xfce/X11。

## 安装与回退

在三星现有 USB Debian 上安装 `grub-common`、`device-tree-compiler` 和两个本地驱动包。`7.0.0-3` 无线包提供单通道 PCIe0 PHY 驱动。把本地包、清单、日用 DTB、EFI 程序及安装脚本放到 U 盘上的家目录，运行以下命令。无线固件及监管数据库的设置见[无线驱动说明](debian-wifi.md)。

```sh
sudo apt install grub-common device-tree-compiler ./np545xla-wifi-modules_7.0.0-3_arm64.deb ./np545xla-eckb_7.0.0-3_arm64.deb
sudo bash install-daily-boot.sh manifest.txt daily.dtb BOOTAA64.EFI
```

安装脚本根据当前根分区的 UUID 和 USB 总线识别同盘的 EFI 分区，逐份检查原始载荷。首次执行保存旧启动器为 `/EFI/BOOT/BOOTAA64.EFI.baseline`，写后比对新增的 DTB 与 EFI 程序。在 Mac 的 ARM64 UEFI QEMU 上已对一次性可写副本执行两次安装，再冷启动原 Debian 的 QEMU 入口，通过同一 SSH 主机公钥连接并确认 USB ext4 仍可写。

如需完整恢复旧菜单，可在第四项 Debian 中重新核对 USB 根与同盘 EFI 分区，并用保留的 `BOOTAA64.EFI.baseline` 替换该分区上的 `BOOTAA64.EFI`。原始整盘镜像则保存在 Mac。

### Adreno 统一 DRM 试验入口

这个可选菜单项让内置屏幕与 GPU 共用一个 DRM 设备，供 Xorg 的 modesetting 驱动在内屏使用 Glamor 加速。它复用当前日用 DT、内核和 USB 根盘，额外载入一个 initramfs 补充包。补充包中的独立 PID 1 在加载 MSM 之前校验三份固件，然后传入 `separate_gpu_kms=0`。只读检查根分区时，它还会验证切换到 Debian 后同一路径有相同的固件。固件路径为 `/var/lib/np545xla-adreno/firmware`。[Linux v7.0 的 MSM 设备模式](https://github.com/torvalds/linux/blob/v7.0/drivers/gpu/drm/msm/msm_drv.c)

用已验证来源的 Debian SQE、GMU 目录和三星原厂驱动包中的签名 ZAP 文件在 ARM64 Debian 中生成试验包。检查 `daily.dtb` 是当前 U 盘已启动并验收的版本。在三星上执行后两条命令，将固件保存在持久目录，并安装试验菜单。

```sh
work=/var/tmp/np545xla-diag
src/build-adreno-msm.sh "$work/linux-7.0" "$work/obj" "$work/artifacts" msm-v2
src/build-adreno-boot.sh --msm-module msm-v2 manifest.txt debian-firmware qcdxkmsuc8180.mbn unified-trial-v2
# 在三星 USB Debian 上使用以上固件、unified-trial-v2、清单和当前的 daily.dtb。
sudo bash install-adreno-firmware.sh debian-firmware qcdxkmsuc8180.mbn
sudo bash install-daily-boot.sh --adreno unified-trial-v2 manifest.txt daily.dtb
```

使用修复版 MSM 模块构建菜单后，GRUB 在三星上倒计时 5 秒，自动选择 **Debian 13 - Adreno unified DRM trial (Samsung)**。启动后可用 `sudo cat /sys/module/msm/parameters/separate_gpu_kms` 核对结果为 `N`。要回退，在 GRUB 倒计时期间用方向键选择 **Debian 13 - daily desktop (Samsung)** 并按回车。该入口使用 `separate_gpu_kms=1`。若只构建基础日用菜单，或打包未带修复模块的早期试验版本，默认项仍为原日用入口。首次安装 Adreno 菜单前的启动器保存在同一 USB EFI 分区的 `/EFI/BOOT/BOOTAA64.EFI.pre-adreno`。

2026-11-05 在 SanDisk 上更新默认项后，重新只读挂载 EFI 分区并核对全部 13 个文件，唯一变化是 `EFI/BOOT/BOOTAA64.EFI`，SHA-256 为 `5b426aac339ed2e6bf36b338e9734e7067f11ec41a2d514a5b39f5bdc728faad`。同一 EFI 在模拟三星产品名的 QEMU 中，经无人操作倒计时进入 `adreno-unified`，手选回退进入 `daily`。这两次检查覆盖 GRUB 的菜单选择。两个入口在三星上的启动验收早于本次菜单调整。

首次使用原始 Linux 7.0 模块启动统一 DRM 后，三星在约 49 秒出现 GMU 调频请求超时，随后两次触发 watchdog 和 Xorg 提交队列恢复。Surface Pro X 上的同款 A680 已复现这一顺序。上游作者定位到内核重构遗漏了 A680 的四个 GBIF 服务质量寄存器。第二版补充包回移这项修复，并将 A680 的片上 GMEM 基址及用户态查询值同步设为零。后者针对同一 GPU 在 Vulkan 中出现的纹理损坏。[上游 GBIF 修复](https://lore.kernel.org/dri-devel/20261103011358.65398-2-val@packett.cool/) · [上游 GMEM 修复与实测](https://lore.kernel.org/dri-devel/20261103011358.65398-3-val@packett.cool/)

第二版在补充包中覆盖 `lib/modules/7.0.0/kernel/drivers/gpu/drm/msm/msm.ko`。它对照原始模块检查 vermagic、依赖、别名与导入符号。实机启动后可执行 `sudo od -An -tx1 -j16 -N20 /sys/module/msm/notes/.note.gnu.build-id`，将 20 字节与本次构建输出 `msm-v2/build-id.txt` 比较。原日用回退入口加载原始模块。QEMU 已通过 USB 冷启动验证第二版叠加包的校验、根盘 SSH 登录及原 Debian 入口的回退。三星实机已核对运行模块的构建 ID，并用 FD680 完成 100 秒 X11 连续绘图，期间新增 GPU 故障为零。[内屏与图形协议实测](debian-graphics.md)

三星 DSDT 按 `SOID=0x194`、`SIDV=0x20001`、`SIDT=3` 为 Windows 选择 GPU 表 P003，活动频率为 156、235、315、392、530、595、625、670、718 MHz。Linux v7.0 原 DT 提供 177、256、315、405、461、500、514 MHz。第一版实机的 `simple_ondemand` 在 177、405 与 514 MHz 之间记录到 178 次转换。第二版沿用这个策略与频率表，以便检验驱动修复。两套表共同列出的 315 MHz 可在后续诊断中用作固定频率对照。[三星 DSDT](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L85690) · [Linux v7.0 设备树](https://github.com/torvalds/linux/blob/v7.0/arch/arm64/boot/dts/qcom/sc8180x.dtsi#L2286)

### 合盖开关和睡眠

在原 Adreno 入口上，手动浅睡眠后用触控板唤醒已实测通过。三星固件用 GPIO50 读取盖子，实机合盖时电平变低、开盖时恢复高。旧设备树将同组的电源键连到 PMIC 的原生按键设备，内核找不到 GPIO 控制器的 `#gpio-cells`，导致整组 `gpio-keys` 注册失败。修正只删去重复的 `/gpio-keys/power-key`，保留 GPIO50 上的 `SW_LID`、它的唤醒标记和 PMIC 自身的电源键节点。

要在已经通过验收的 Adreno 安装上重建盖子试验入口，先用构建 Mac 上的 Debian ARM64 环境运行下面的命令。参数中的 `output/daily/eckb/daily.dtb` 是这台机器当前 SanDisk 上的原日用设备树副本。构建器将修正后的完整设备树与预期的单节点差异比对。

```sh
mkdir -p output/daily/lid-test
src/build-debian-lid-dtb.sh output/daily/eckb/daily.dtb output/daily/lid-test/daily-lid.dtb
src/build-lid-boot.sh output/debian-final/manifest.txt output/adreno/default-menu \
    output/daily/eckb/daily.dtb output/daily/lid-test/daily-lid.dtb output/daily/lid-test/boot
```

把生成的 `boot` 目录、清单及对应版本的安装脚本复制到三星 USB Debian，执行 `sudo bash src/install-daily-boot.sh --lid output/daily/lid-test/boot output/debian-final/manifest.txt`。安装器先核对当前 U 盘的根分区、设备树、Adreno 驱动包和启动器指纹，再新增按 SHA-256 命名的设备树及其菜单项。手动选 **Debian 13 - Lid test (Samsung)** 使用修正，`/proc/cmdline` 会包含 `np545.lid=1`。这个菜单的倒计时仍进入此前的 Adreno 桌面。

在 SanDisk 上首次安装后，卸载再只读挂载，已核对启动分区全部 14 个文件。候选 DTB 的 SHA-256 为 `16c50d3e0048fda7ce311888db605346845f7ecde279c42fdfa7f3e4fdcc4de1`，EFI 为 `81e381fe2af8aeb5095fc25b6b1b8bd7f73be499f4dd1ed8f4ef24725e481278`。使用同一 EFI 的 ARM64 QEMU 已验证倒计时加载原日用设备树、手选试验入口加载候选设备树、候选缺失时明确报错。QEMU 的测试范围截至 GRUB 选取设备树。

2026-11-06，三星从该试验入口启动，`gpio-keys` 注册了 GPIO50 的盖子开关，logind 收到 `SW_LID=1` 后自动请求睡眠。北京时间 10:38:32 合盖，10:39:19 日志记录系统恢复并收到 `SW_LID=0`。按包含和排除睡眠时间的两种时钟之差，本轮在 `s2idle` 中度过 43.453 秒，内核计数为成功 1 次、失败 0 次。现场确认仅打开盖子，内屏就很快自行亮起，原 Xfce Wayland 会话继续运行。

恢复时 xHCI 控制器重新初始化，USB 网卡重新枚举。Wi-Fi、SSH 和 USB 根盘写入、同步、读回均恢复，ext4 错误数为零。内核未记录具体的唤醒中断号。原始记录在构建 Mac 的 `output/daily/lid-test/physical-d523f6e4/`。

**重复合盖仍有漏报。** 同一次开机稍后，10:42:01 操作者先手动请求睡眠，10:42:07 系统恢复并记录合盖，10:42:10 记录开盖。这是内核计数中的第二次睡眠。10:45:11 仅合盖，GPIO50 由高变低，IRQ 166 计数仍为 7，输入设备保持 `SW_LID=0`。约 18 秒后开盖，GPIO50 恢复高电平，IRQ 计数才变为 8。期间 logind 没有收到新的盖子事件，成功计数一直为 2，累计睡眠时间保持 45.606 秒。已定位到这次合盖的下降沿没有传递到 GPIO 中断，仍需查明中断控制器丢失该边沿的条件。现场对照记录为同一目录的 `gpio-irq-reproduction.txt` 和 `second-window.txt`。

#### GPIO50 的边沿检测

在上述原版内核的同一次启动中，只读快照确认中断路径为 GPIO50 → PDC52 → GIC564。PDC 版本寄存器为 `0x00010701`。在已经发生过漏报的状态下，PDC52 仍启用且配置为双沿（类型 7），GIC 未屏蔽。临时阻止合盖睡眠后再做一次 5 秒开合，两个电平均有中断送达，IRQ 计数由 8 增至 10，PDC 配置始终为 7。这说明漏报并非每次必现；之前漏报的瞬间没有寄存器快照。原版记录位于 `output/daily/lid-edge/old-open-pdc.txt` 和 `old-ab.jsonl`。

试验内核只为 NP545XLA 的 SC8180x GPIO50 采用 Linux 已有的双沿处理方法。驱动在盖子打开时让 PDC 等待下降沿，在盖子关闭时等待上升沿，并在处理中重读引脚，防止切换期间错过状态变化。类似的下降沿漏报曾在搭载 SDM845 的 Lenovo Yoga C630 实机上通过这一机制修复。[上游 C630 讨论](https://lkml.iu.edu/2111.0/01388.html) · [三星板级补丁](../patches/linux-7.0-np545xla-lid-edge.patch)

在 ARM64 构建机上先运行 `src/build-lid-edge-image.sh LINUX_SOURCE KERNEL_BUILD DIAG_ARTIFACTS KERNEL_OUT`，然后运行 `src/build-lid-edge-boot.sh output/debian-final/manifest.txt output/daily/lid-test/boot KERNEL_OUT BOOT_OUT`。在三星上运行 `sudo bash src/install-daily-boot.sh --lid-edge BOOT_OUT output/debian-final/manifest.txt`，手选 **Debian 13 - Lid edge kernel (Samsung)**。该入口从同一 SanDisk 的 ext4 根分区按 SHA-256 校验并加载独立内核，设备树、内存启动环境、Adreno 固件均来自前一轮验收件。原 Adreno 仍为默认项，原 Lid test 可用于同机对照。启动后可核对 `np545.lid_edge=1` 和内核日志中的 `NP545XLA lid GPIO50: alternating PDC edges`。[同步记录盖子状态、中断与睡眠时间](../src/probe-debian-lid.py)

当前安装使用内核 SHA-256 `509f2ff696f9dfc090e58bbe3a38593d8184561f6099fd328188243eb190561f` 和 EFI SHA-256 `e5d1ce10259cb74788d63479a75b34f4144576207bd672ed94e1866a3c0a6830`。QEMU 从最终菜单冷启动，通过 USB 根盘和公钥 SSH 登录验证了候选与原版，候选 Image 损坏或根分区 UUID 不符时均在加载 Linux 前停止。三星安装后已读回 16 个 EFI 分区文件，并绕过文件缓存读回完整候选内核。三星运行内核的构建 ID 为 `5b9aa4b062a74ae1d4f9ddd3cb4d8e9309034a9b`，开盖时 PDC52 的配置为下降沿（类型 2）。

11 月 6 日，三星 Xfce Wayland 桌面连续进行了三轮合盖睡眠和开盖唤醒。每轮都是 logind 收到盖子关闭事件后自动发起 `s2idle`。每次只打开盖子，现场均看到内屏自行亮起。

| 轮次 | 实际睡眠时间 | GPIO50 中断累计计数 | 成功 / 失败累计 |
| --- | ---: | --- | --- |
| 1 | 14.222 秒 | 0 → 2 | 1 / 0 |
| 2 | 17.349 秒 | 2 → 4 | 2 / 0 |
| 3 | 14.344 秒 | 4 → 6 | 3 / 0 |

三次合盖后的快照均显示 PDC52 已切换到上升沿（类型 6），三次开盖后均已重新等待下一次下降沿（类型 2）。原版间歇漏掉的下降沿在两次连续唤醒后的后续合盖均正常送达。三轮结束后仍是同一开机编号和同一 Xfce 会话。USB 控制器每次恢复都重新初始化，但 SSH、Wi-Fi 和 USB 根盘写入、同步、读回通过，ext4 错误数为零。原始记录位于 `output/daily/lid-edge/physical-2d0bf52c/`，包括逐事件快照 `cycles.jsonl`、逐轮计数 `cycle-summary.txt` 及 logind 和内核日志 `journal.txt`。

#### 睡眠时内屏背光

在上述 GPIO50 修复内核上，现场观察到合盖十几秒后缝隙里仍有光。2026-11-06 保持盖子打开、从 Xfce 手动睡眠后，从正面看到整块面板仍有均匀微光。北京时间 11:19:30 至 11:20:08 日志记录了一次 `s2idle` 进入和恢复，成功计数由 3 增至 4，失败计数为 0。此次观察区分了系统睡眠和物理背光关闭。

这台机器的 BOE 07d3 面板通过 eDP 输出，设备树只有 `edp-panel` 和 `no-hpd`，没有指定背光设备，内核日志显示面板供电使用 dummy regulator。实机没有注册 `/sys/class/backlight`。Linux 配置为 `DRM=y`、`BACKLIGHT_CLASS_DEVICE=m`，这组配置下当前 `panel-edp` 模块没有调用外部背光或 AUX 背光的注册函数。本机 DSDT 的 GPU0 面板配置声明 PMIC 背光、9 位 PWM、频率字段 586 及 100 级亮度。相同 SoC 的参考板不能代替三星实机的通道和引脚映射。调查记录位于 `output/daily/backlight-diag/`。[三星面板固件](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L86620) · [Linux eDP 面板驱动](https://github.com/torvalds/linux/blob/v7.0/drivers/gpu/drm/panel/panel-edp.c#L890)

屏幕点亮时，通过现有 SPMI regmap 只读取 USID 5 的五个已知 PWM 外设。第 3 路（从 0 计数，地址 `0xbc00`）是唯一启用且频率与原厂配置一致的候选：纯 PWM 子类型 `0x0b`、9 位、585.937 Hz、占空计数 256/511、使能 `0x80`。第 2 路也启用，但频率为 18.75 kHz、占空比 100%，其余三路均未启用。只读快照为 `output/daily/backlight-diag/pwm-live.txt`。[高通纯 PWM 寄存器实现](https://android.googlesource.com/kernel/msm.git/+/android-wear-6.0.1_r0.40/drivers/pwm/pwm-qpnp.c#555)

同一面板的 eDP DPCD `0x700–0x703` 实读为 `02 fb c7 00`。`0x721` 为 0，当前亮度使用外部 PWM。面板公布了 AUX 设置亮度值的能力，但背光启停使用使能引脚，未公布 AUX 启停能力。原始记录为 `output/daily/backlight-diag/aux-live.txt`。

在正常桌面用一次受限试验确认了接线。内核仅将 `0xbc00` 的占空计数由 256 降到 166，保持 3 秒后恢复为 256，写入和恢复后都通过 `PWM_SYNC` 锁存并读回。频率和使能保持原值，现场看到浅色窗口明显变暗，随后恢复原亮度。记录位于 `output/daily/backlight-diag/dim-physical.txt`。

睡眠背光驱动通过独立的 USB Debian 软件包提供，加载时核对本机型号、`np545.lid_edge=1` 启动参数以及该通道的实际配置。它在设备的挂起回调保存当前亮度、将占空计数置零，在恢复回调写回原值，两次都锁存并核对。PWM 输出使能和频率沿用固件设置。可在原 Debian ARM64 构建机运行 `src/build-debian-backlight.sh /var/tmp/np545xla-diag/obj /var/tmp/np545xla-diag/artifacts output/daily/suspend-backlight`。在三星上校验 `backlight.sha256` 后安装同目录的本地 deb，用 `sudo systemctl start np545xla-sleep-backlight.service` 启动；确认物理熄灯与恢复后，可用 `sudo systemctl enable np545xla-sleep-backlight.service` 随该入口启动，用 `sudo systemctl disable --now np545xla-sleep-backlight.service` 回退。

实机一次开盖手动睡眠和两次合盖睡眠均记录到占空计数从 256 到 0、恢复时回到 256。现场确认睡眠时原有的面板微光消失，此服务已设为仅随 Lid edge 入口启用。两次合盖均在上次唤醒约 10–12 秒后发生。按 logind 与内核的单调时钟对齐，等待的主要部分发生在 logind 收到合盖事件之后、发出挂起请求之前。下表的“置零”以驱动写入并读回为准。光学熄灭由现场观察确认，未测量其毫秒级时刻。

| 合盖时间（北京时间） | 合盖到挂起请求 | 请求到背光置零 | 合盖到置零 |
| --- | ---: | ---: | ---: |
| 11:37:45.804 | 17.168 秒 | 0.821 秒 | 17.989 秒 |
| 11:38:22.401 | 15.571 秒 | 0.961 秒 | 16.532 秒 |

这台三星的 logind 使用 30 秒的启动及恢复后合盖等待设置 `HoldoffTimeoutSec`，用于等待扩展坞及外接显示器枚举。先前超过该等待期的三轮测试中，合盖到挂起请求约为 40 毫秒。以上测量使用背光包 `7.0.0-1`，该版本在系统挂起时关灯。记录见 `output/daily/backlight-diag/lid-off-timing.txt` 及 `fixed-sleep-journal.txt`。[Debian logind 的等待设置](https://manpages.debian.org/trixie/systemd/logind.conf.5.en.html#HoldoffTimeoutSec=)

同芯片的 Lenovo Flex 5G 和 Qualcomm Primus 分别描述盖子开关和内屏背光。eDP 面板引用 PWM 背光，DRM 关闭面板时先禁用背光；是否在合盖时请求关闭内屏仍由显示或电源策略决定。另一个可参考的做法是 ChromiumOS 的内屏控制器直接响应盖子状态，将合盖亮度设为零并保留外接屏，然后由电源管理独立处理挂起。参考板的 PWM 通道和使能引脚与三星不同。[Flex 5G](https://github.com/torvalds/linux/blob/v7.0/arch/arm64/boot/dts/qcom/sc8180x-lenovo-flex-5g.dts#L25-L46) · [Primus](https://github.com/torvalds/linux/blob/v7.0/arch/arm64/boot/dts/qcom/sc8180x-primus.dts#L28-L53) · [DRM 面板关闭顺序](https://github.com/torvalds/linux/blob/v7.0/drivers/gpu/drm/drm_panel.c#L266-L310) · [ChromiumOS 内屏策略](https://chromium.googlesource.com/chromiumos/platform2/+/HEAD/power_manager/powerd/policy/internal_backlight_controller.cc#907)

##### 合盖时立即熄灭内屏

`7.0.0-2` 在同一背光模块中直接订阅板载 `/gpio-keys` 的 `SW_LID`。它在工作队列中保存当前 PWM 占空值并关掉内屏背光，开盖时按原值恢复。模块分别记录合盖与挂起状态，任一条件成立时保持熄灯。因此刚唤醒后再合盖，内屏可以在 logind 等待扩展坞期间就熄灭。系统是否睡眠仍由 logind 决定。此逻辑也适用于图形登录页和 X11/Wayland 会话。[板级实现](../src/debian-backlight/np545_sleep_backlight.c)

在已安装旧版的三星上升级时，保持盖子打开，先用 `sudo systemctl stop np545xla-sleep-backlight.service` 停止旧服务，确认 `/sys/module/np545_sleep_backlight` 已消失，再校验并安装新版 deb。随后启动同名服务。包保留原来的开机启用状态。降级可以按相同顺序安装已保存的 `7.0.0-1` 包。停用当前版本时，停止服务会先解除盖子控制并恢复保存的亮度，再卸载模块。

2026-11-06 的三轮实机测试中，每次合盖后驱动均写入并读回占空值 0，开盖后均恢复到原值 256。现场观察三轮均正常。第一、三轮分别在内核进入 `s2idle` 前 0.658 秒和 0.651 秒就已将背光清零。第二轮在刚唤醒约 3.6 秒后再次合盖；logind 未发出挂起请求，内核也没有进入睡眠，背光仍熄灭了 3.232 秒并在开盖时恢复。成功睡眠计数由 7 增至 9，失败计数保持 0。原 Xfce Wayland 会话继续运行，logind 的等待设置仍为 30 秒。

试验记录见 `output/daily/instant-lid/physical/acceptance.txt`、`kernel.txt` 和 `logind.jsonl`。限时输入采样在现场操作前已结束；上述时间比较使用同一份内核日志的 PWM 读回和睡眠入口，无法据此给出从物理开合到光学亮度变化的精确毫秒数。

## 启动探测日志

这台机器的键盘异常报告可在一秒内覆盖原来的内核缓冲区。日用入口将缓冲区设为 16 MiB。在三星 Debian 上安装限时记录服务并启用，下一次该入口开机时，前三分钟的驱动探测信息会保存到内存中的 `/run/np545xla-daily-probe.log`。

```sh
sudo install -m 644 src/debian-rootfs/np545xla-daily-probe.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable np545xla-daily-probe.service
```

## 桌面

将整个 `src/debian-desktop/` 目录复制到三星 Debian，运行 `sudo bash debian-desktop/provision`。Xfce 通过 LightDM 正常登录。如果还没有本机密码，请从自己的 Mac SSH 终端执行 `sudo passwd liurunliang`。无线凭据可在桌面右上角的网络菜单中输入。安装时保留有线 SSH，网络管理器只配置 Wi-Fi。

触控板测试运行 `sudo sh probe-debian-touchpad.sh`，从它列出的 880000.i2c 下属触控板事件节点验证手指移动和点击。无线测试先查 `iw dev` 的关联和地址，最后拔下网线及外接鼠标，用内置触控板在 Firefox 中打开新的 HTTPS 页面。整个过程须保留用作根分区的 U 盘和它所在的 USB 集线器。

## 已验收的实机结果

2026-11-05，在原持久化 Debian 上安装桌面后，LightDM 以 X11 启动 GTK 登录页。`xrandr` 实测内屏为 1920×1080、60 Hz，Xorg 使用连接 eDP 的 MSM KMS 卡和软件渲染。有线 SSH 在整个安装中保持可用。Firefox ESR 153.6.0 以普通用户和临时配置通过有线网络打开 Debian 官网，取回的渲染截图中可见首页和下载入口。桌面与驱动安装后，12 GiB 根分区还有约 9.6 GiB 可用。这些检查先于新设备树的触控板和 Wi-Fi 现场验收。

首版日用设备树已在三星上绑定 `14E5:650E` 的 HID 多点触控驱动，输入设备来自 880000.i2c 的 0x40。两次启动均完成枚举。现场在登录页实测用内置触控板移动指针并点击；GPIO104 中断随使用累计到 1,528 次。无线控制器在初始化 PCIe0 PHY 时报告超时，此时还没有 PCI 无线设备。

使用单通道 PCIe0 配置后，QCA6390 在三次冷启动中完成枚举。首次从 Xfce 的网络菜单连接 Wi-Fi 时，精简系统缺少 `polkitd`，桌面提示 `Not authorized to control networking`。补装后，当前登录会话中的 `nm-applet` 通过联网授权，现场连上 5 GHz 接入点。限定到 `wlp1s0` 的 DNS 查询和 HTTPS 下载页请求均成功，HTTP 状态为 200，TLS 证书校验通过。保存的连接在下次启动的登录页就已自动取得无线地址。[无线驱动与实测](debian-wifi.md)

在最终的 Xfce/X11 实机验收中，操作者确认用内置实体键盘在 Firefox 输入框按 A 后看到了 `a`。拔掉网线和外接鼠标后，操作者用内置触控板点击链接，经内置 Wi-Fi 打开了 Debian 下载页。前一段的 HTTP 状态码来自单独的无线链路测试。Wayland 原生客户端的离屏绘制、内屏输出和硬件加速的验证范围另见[图形兼容性记录](debian-graphics.md)。
