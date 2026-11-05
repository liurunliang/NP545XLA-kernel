# 在持久化 Debian U 盘上试验内置设备

启动菜单的前三项仍是诊断系统，第四项使用已验收的原 Debian 设备树。第五项使用单独的日用设备树，实机默认选它。两个 Debian 入口共用同一份根文件系统、系统账户、内核和 initramfs，均关闭内置 UFS。第四项可用于排查新的设备树带来的启动问题。

## 生成设备树与菜单

在制作原镜像的 Debian ARM64 环境运行。以下命令使用原 Debian 镜像清单及其 FAT 启动分区里的 `/boot/debian-samsung.dtb`。从同一介质提取这个文件，先与清单的 SHA-256 核对。按[无线驱动构建说明](debian-wifi.md)生成对应内核的模块包和无线设备树片段。

```sh
src/build-debian-touchpad-probe-dtb.sh debian-samsung.dtb touchpad.dtb
fdtoverlay -i touchpad.dtb -o daily.dtb output/daily/wifi/sc8180xp-np545xla-wifi.dtbo
src/build-daily-efi.sh output/debian-final/manifest.txt BOOTAA64.EFI
```

Windows 枚举把 `SSTP0001` 下的子设备标为 Samsung TPD 和 HID 鼠标。三星 DSDT 的 `I2C1.TCPD` 位于 400 kHz 的 GENI 控制器（880000.i2c），设备地址是 0x40，HID 描述符寄存器是 0x0e。其运行态供电表声明 LDO11_C，电压为 3.3 V。原设备树的 0x62 对应 Samsung EC2。

固件为触控板提供的虚拟中断脚是 448。按 Qualcomm 公开的 WoA 映射，448 / 64 取 GIO0 的第 7 项（从 0 开始），得到 GSI 590。减 32 得 SPI 558，对照本 SoC 的 PDC 范围得到 PDC 78，再查 SC8180x 的 wakeirq_map 得到 GPIO104。独立对照用合盖信号，其虚拟脚 320 映射为 GPIO50，与 DSDT 里读取盖子状态的 LIDR 一致。[Qualcomm 工程师的映射算法](https://marc.info/?l=devicetree&m=178272904036845&w=3) · [Linux v7.0 SC8180x 引脚表](https://github.com/torvalds/linux/blob/v7.0/drivers/pinctrl/qcom/pinctrl-sc8180x.c)

## 安装与回退

在三星现有 USB Debian 上，安装 `grub-common`、`device-tree-compiler`、无线模块包和所需固件。把清单、日用 DTB、EFI 程序及安装脚本复制到 U 盘上的家目录，然后执行：

```sh
sudo bash install-daily-boot.sh manifest.txt daily.dtb BOOTAA64.EFI
```

安装脚本根据当前根分区的 UUID 和 USB 总线识别同盘的 EFI 分区，逐份检查原始载荷。首次执行保存旧启动器为 `/EFI/BOOT/BOOTAA64.EFI.baseline`，写后比对新增的 DTB 与 EFI 程序。在 Mac 的 ARM64 UEFI QEMU 上已对一次性可写副本执行两次安装，再冷启动原 Debian 的 QEMU 入口，通过同一 SSH 主机公钥连接并确认 USB ext4 仍可写。

如需完整恢复旧菜单，可在第四项 Debian 中重新核对 USB 根与同盘 EFI 分区，并用保留的 `BOOTAA64.EFI.baseline` 替换该分区上的 `BOOTAA64.EFI`。原始整盘镜像则保存在 Mac。

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
