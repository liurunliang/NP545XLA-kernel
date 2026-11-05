# 三星 NP545XLA 的持久化 Debian U 盘

这个镜像为 15,376,318,464 字节的 SanDisk 制作。默认的 Debian 13 入口使用三星设备树，从 U 盘的 12 GiB ext4 分区运行。前三项为原来的内存诊断入口。Debian 设备树关闭内置 UFS，原生内屏和内置键盘均启用。

## 实机验收（2026-11-05）

- 镜像的整盘读回 SHA-256 为 `08d93c1cc582d998e29606d83269138ec3c3096b01ec1a2b0590ad89b55c7189`。Mac 上通过五次 QEMU 启动测试。
- 三星首次冷启动进入 Debian 13。现场看到内屏显示实际 DHCP 地址和 SSH 命令。Mac 用公钥登录后确认根分区是 12 GiB 的 USB ext4，挂载为可写，内置 UFS 控制器在该入口禁用。
- 在三星上从 Debian 官方源安装并运行了 `hello 2.10-5 arm64`，写入了 `~/debian-usb-test.txt`。系统也通过 NTP 完成了首次校时。
- 第二次实机冷启动有新的启动 ID。Mac 用第一次保存的 SSH 主机公钥成功登录，机器 ID 一致，测试文件的 SHA-256 相同，`hello` 可以直接运行。两次 DHCP 地址不同，请使用当次内屏显示的地址。最终 Debian 中也实测收到了内置键盘 A 键的按下与松开。
- 最后在同一支 U 盘选择第三项，现场看到 `root@10.86.97.253` 的 2222 登录提示。Mac 成功取回内存诊断报告，原生内屏使用 1920×1080，UFS 六个逻辑单元可枚举，块设备挂载数为零。

## 在笔记本上使用

通过固件一次性启动菜单选择 U 盘，让 GRUB 倒计时进入 Debian。接上 RTL8153 和网线，在同一局域网的 Mac 上可以用固定名称登录，即使 DHCP 地址变化也适用。内屏同时显示当次 IP 和 SSH 主机指纹；网络屏蔽 mDNS 时可用该 IP 登录。

```sh
ssh -p 2223 liurunliang@np545xla-debian.local
```

首次连接时核对内屏指纹。这个账户可以使用 `sudo`。SSH 只接受公钥，主机密钥保存在 U 盘，日常关机使用 `sudo systemctl poweroff`。若需要本机控制台登录，可以先通过 SSH 执行 `sudo passwd liurunliang` 为账户设置密码。

需要救援时，选第三项 **Samsung DT + native display**，通过内存诊断环境的 `root` 账户和端口 `2222` 登录。诊断环境每次启动都会更换 SSH 主机密钥。Debian 启动遇到根分区 UUID 缺失或存在两支匹配的 USB 盘，也会转入内存救援。

## 重新构建与验收

在原生 ARM64 Debian 环境中，先按[诊断镜像构建说明](usb-linux-diag.md)生成并保留内核工作目录、公钥对应的诊断镜像清单以及显示模块。构建持久系统还需 `mmdebstrap`、`debian-archive-keyring`、`uuid-runtime`、`e2fsprogs` 和 `sudo`，工作目录须位于客体 Linux 文件系统。仓库根目录下的示例使用上轮 `diag-native` 清单。

```sh
src/build-debian-usb.sh --public-key /path/to/login-key.pub \
  --diag-work /var/tmp/np545xla-diag \
  --diag-manifest "$PWD/output/diag-native/manifest.txt" \
  --work-dir /var/tmp/np545xla-debian --output "$PWD/output/debian-final"
```

输出包含整盘镜像、SHA-256 和构建清单。镜像按 SanDisk 的精确容量放置 GPT 备份表。稀疏文件复制到另一种文件系统后可能占满其逻辑大小。每次构建生成新的根 UUID，首次启动生成新的系统身份。镜像内的初始软件包版本列在 `/usr/share/doc/np545xla-debian/packages.tsv`。

在 Mac 上用不同的结果目录验证最终镜像。测试使用临时可写层和回环端口，依次检查实际安装软件、冷启动持久化、根分区丢失时救援，以及原诊断入口的断网和有网启动。

```sh
python3 src/test-debian-qemu.py --image output/debian-final/np545xla-debian.img \
  --identity ~/.ssh/id_ed25519 --output output/debian-final/qemu-check
```

由原诊断 Linux 写入时，将压缩镜像和 `src/write-debian-from-ram.sh` 暂存在三星的 `/run`。写盘工具要求调用方提供整盘设备、USB 序列号、容量、原镜像长度与实盘指纹、新镜像长度与清单指纹。它先核对 RAM 根系统、USB 身份、现有镜像和新镜像，再写入、刷盘，最后直接读回整个指定长度并校验 SHA-256。

## 键盘

在诊断 Linux 上，内置键盘实际产生了 A 键的按下和松开事件。其 GPIO91 中断也曾在 60 秒内增加 143,290 次。临时解绑该键盘后，IRQ 注销，60 秒内未观测到新增的不完整 HID 报告；在线重新绑定失败，冷启动后恢复。日常 Debian 保留键盘，用限额 32 MiB 的内存 journal 保存服务日志，内核消息可通过 `sudo dmesg` 查看。高频中断的根因仍可用原诊断入口继续调查。

本机 ACPI 的 `ECKB._CRS` 描述了 GIO0 的 640 号脚、低电平触发和上拉。该虚拟脚对应 TLMM GPIO125，第五项日用入口据此配置。Linux 7.0 中的 `incomplete report (11/261)` 表示一次读回 11 字节，报告头却声明长度为 261；驱动丢弃了这条报告。按键实测和异常计数应分别记录。[日用设备树与键盘验证](usb-daily.md) · [Linux I²C HID 输入实现](https://github.com/torvalds/linux/blob/v7.0/drivers/hid/i2c-hid/i2c-hid-core.c)
