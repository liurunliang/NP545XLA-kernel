# 在持久化 Debian U 盘上试验内置设备

启动菜单的前三项仍是诊断系统，第四项使用已验收的原 Debian 设备树。第五项使用单独的日用设备树，实机默认选它。两个 Debian 入口共用同一份根文件系统、系统账户、内核和 initramfs，均关闭内置 UFS。更新日用设备树后，菜单末尾的 **previous daily device tree** 可启动前一版日用配置。第四项始终提供原 Debian 设备树。

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

手动选择 **Debian 13 - Adreno unified DRM trial (Samsung)**。启动后读取 `/sys/module/msm/parameters/separate_gpu_kms`，该入口应返回 `N`。检查 `/sys/class/drm/` 中连接 eDP 的卡在同一设备下拥有渲染节点，再检查会话的渲染器与实际出帧。传统日用入口会传入 `separate_gpu_kms=1`，它仍是三星的默认项。若试验画面异常，重新开机并等待默认倒计时即可回到该入口。安装脚本首次安装时将这之前的日用启动器保存在同一 USB EFI 分区的 `/EFI/BOOT/BOOTAA64.EFI.pre-adreno`。

首次使用原始 Linux 7.0 模块启动统一 DRM 后，三星在约 49 秒出现 GMU 调频请求超时，随后两次触发 watchdog 和 Xorg 提交队列恢复。Surface Pro X 上的同款 A680 已复现这一顺序。上游作者定位到内核重构遗漏了 A680 的四个 GBIF 服务质量寄存器。第二版补充包回移这项修复，并将 A680 的片上 GMEM 基址及用户态查询值同步设为零。后者针对同一 GPU 在 Vulkan 中出现的纹理损坏。[上游 GBIF 修复](https://lore.kernel.org/dri-devel/20261103011358.65398-2-val@packett.cool/) · [上游 GMEM 修复与实测](https://lore.kernel.org/dri-devel/20261103011358.65398-3-val@packett.cool/)

第二版在补充包中覆盖 `lib/modules/7.0.0/kernel/drivers/gpu/drm/msm/msm.ko`。它对照原始模块检查 vermagic、依赖、别名与导入符号。实机启动后可执行 `sudo od -An -tx1 -j16 -N20 /sys/module/msm/notes/.note.gnu.build-id`，将 20 字节与本次构建输出 `msm-v2/build-id.txt` 比较。默认日用入口加载原始模块。QEMU 已通过 USB 冷启动验证第二版叠加包的校验、根盘 SSH 登录及原 Debian 入口的回退，GPU 稳定性需在三星上验收。

三星 DSDT 按 `SOID=0x194`、`SIDV=0x20001`、`SIDT=3` 为 Windows 选择 GPU 表 P003，活动频率为 156、235、315、392、530、595、625、670、718 MHz。Linux v7.0 原 DT 提供 177、256、315、405、461、500、514 MHz。第一版实机的 `simple_ondemand` 在 177、405 与 514 MHz 之间记录到 178 次转换。第二版沿用这个策略与频率表，以便检验驱动修复。两套表共同列出的 315 MHz 可在后续诊断中用作固定频率对照。[三星 DSDT](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L85690) · [Linux v7.0 设备树](https://github.com/torvalds/linux/blob/v7.0/arch/arm64/boot/dts/qcom/sc8180x.dtsi#L2286)

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
