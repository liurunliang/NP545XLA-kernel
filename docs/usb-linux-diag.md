# NP545XLA 从 USB 启动 Linux 诊断环境

镜像包含 ARM64 Linux、三星设备树和装入内存的诊断程序。可分别验证内屏是否显示 `NP545XLA DIAG`，以及能否通过 USB 有线网卡拉取诊断报告。内置 UFS 只做枚举。关机断电后，内存中的报告和 SSH 主机密钥都会消失。

## 三星 NP545XLA-KA1TT 实测（2026-11-05）

| GRUB 入口 | 内屏所见 | Mac 侧验证 |
| --- | --- | --- |
| 原厂 ACPI（首版镜像） | 最后可见 `Loading Linux and RAM diagnostics (ACPI)...` | 尚未取得该入口的实机 Linux 日志 |
| 三星设备树 | 先显示内核日志，随后变黑。全屏测试时左上角有约 1 厘米白线 | Linux 7.0、RTL8153、DHCP、公钥 SSH 和报告导出均通过 |
| 三星设备树，保留供电（上一版第三项） | 先显示内核日志，随后仍只剩白线或黑屏 | 新的启动 ID 和内核命令行确认两个参数均已传入。有线 SSH 再次成功，取回了从第 0 秒开始的日志 |
| **Samsung DT + native display（最终镜像第三项）** | **冷启动后诊断页自动出现，文字持续可读** | **三个显示模块自动加载成功，eDP 已连接。Mac 用公钥独立登录同次启动并取回完整报告** |

三次 DT 启动均枚举到启动 U 盘和内置 UFS 的六个逻辑单元，诊断阶段挂载的块设备为零。GRUB 中实测键盘可用。Linux 注册了内置键盘，但第二次 DT 报告中约有 2400 条不完整 HID 报告每秒，后续在冷启动的诊断 Linux 上，已从该内置键盘实测收到 A 键的按下与松开。详见[持久化 Debian 的键盘记录](usb-debian.md#键盘)。

原版 DT 的 EFI 帧缓冲可读回完整诊断文字。另写入高对比图案后，比对 1920×1080 像素，只有第 705 至 720 行左侧的一个 8×16 字符格与测试图有差异，左上白线位置的内存内容与预期图案一致。保电入口在 0.22 秒左右接管同一 EFI 帧缓冲，实机显示子系统所在 IOMMU 组为 `identity`。仅加上述两个参数，物理屏仍然黑屏。

在同一次保电启动中，通过 SSH 从内存加载与内核完全匹配的 `phy_qcom_edp`、`panel_edp` 和 `msm separate_gpu_kms=1`。原生驱动读到 BOE07D3 面板的 128 字节 EDID，校验通过。eDP 完成两阶段链路训练并启用 1920×1080、60 Hz 模式。控制台切换到 `msm-kmsdrmfb`，活动显示平面绑定了控制台的缓冲区，从该缓冲区可读回诊断文字。现场确认内屏能清楚显示诊断页和末行新写入的 `NATIVE DISPLAY`，同一时间有线 SSH 仍可用。随后用自动加载版镜像冷启动，未从 Mac 干预画面，现场再次确认诊断页持续可读。

这次通过实机验收的镜像 SHA-256 为 `692635888e807c5b99c1a01750c00be9bd71c1f0f788a8335fd1b8cd11c08c0d`。它通过了 QEMU 断网和有网两次冷启动，并在写入 SanDisk 后从 U 盘完整读回核对。

## 构建

在 Debian ARM64 环境中，从仓库根目录运行。Apple Silicon Mac 可以使用 ARM64 Lima 虚拟机。将内核工作目录设在客体的 Linux 文件系统，将结果输出到共享工作区。构建时只传**公钥**，对应私钥留在稍后发起 SSH 的电脑上。公钥文件应只含一行 OpenSSH 公钥。

```sh
src/build-diag.sh --public-key /path/to/login-key.pub \
    --work-dir /var/tmp/np545xla-diag-build --output "$PWD/output/diag"
```

Debian 13 构建依赖包含 `git curl xz-utils build-essential bc bison flex libelf-dev libssl-dev device-tree-compiler cpio gzip kmod gdisk xorriso grub-common grub-efi-arm64-bin dosfstools mtools busybox-static dropbear-bin openssh-client util-linux`。脚本会校验官方内核源码包与 Debian Realtek 固件包的 SHA-256。

首次构建需要 Linux v7.0 源码。如果已有官方 `linux-7.0.tar.xz`，可以追加 `--kernel-archive /path/to/linux-7.0.tar.xz` 复用。写入 U 盘的文件是 `output/diag/np545xla-diag.img`。镜像同时提供 GPT/FAT EFI 系统分区和指向该分区的 El Torito EFI 启动记录，两条路径使用同一套诊断文件。

## 在 Mac 上先验收镜像

需要 `qemu-system-aarch64`、其配套的 EDK2 固件，以及系统 OpenSSH 客户端。以有权使用上述公钥登录的身份运行。加密私钥可先用 `ssh-add` 加载。结果目录应使用新目录名。

```sh
src/test-diag-qemu.sh --image output/diag/np545xla-diag.img \
    --identity ~/.ssh/login-key --output output/diag/qemu-first
```

脚本把镜像作为只读 USB 大容量存储，使用临时 UEFI 变量，走默认 ACPI 菜单项。两轮都从 PL011 串口按顺序检查找到启动介质、读取内核、登记 initramfs、交给 EFI 启动以及出现 `NP545XLA DIAG`。第一轮断网，检查诊断状态。第二轮用模拟网卡取得 DHCP 地址，在本机回环地址转发 SSH，核对串口指纹并校验授权和未授权两种密钥。结果目录内有两次冷启动的串口与 QEMU 日志，以及从客体读回的 `report.txt`。默认宿主端口为 22222，可用 `--port` 改用空闲端口。HVF 不可用时可设 `QEMU_ACCEL=tcg QEMU_TIMEOUT=300`。三星的 USB 枚举、设备树、液晶屏、物理网卡和固件信任链需要在笔记本上验证。

## 手动写盘与启动

1. 如果 Windows 启用了设备加密，先确认可取回 BitLocker 恢复密钥。也可用另一支 U 盘制作含系统文件的 Windows 恢复盘备用。[微软恢复驱动器说明](https://support.microsoft.com/en-us/windows/experience/backup-recovery/recovery-drive)
2. Windows 上可用下方脚本核对指定 U 盘并校验写入。若从 Mac 写入，插拔目标 U 盘，对照两次 `diskutil list external physical` 的结果，用 `diskutil info /dev/diskN` 核对整盘型号、USB 接口与容量。在支持写后校验的镜像写盘工具中打开 `.img`、**手动选择该 U 盘**、写入并等待校验结束，再弹出。镜像会覆盖所选整盘。
3. 在三星接上电源和启动 U 盘。要取报告，再接 Realtek RTL8153 USB 有线网卡和带 DHCP 的有线网络。程序识别产品 ID 为 `8153` 或 USB 产品名称带 `8153` 的适配器，通过 `r8152` 或 `cdc_ether` 驱动联网。使用 Windows 高级启动的“使用设备”或固件的一次性启动菜单，选择 UEFI USB。自建 GRUB 和内核未签名。若固件拒绝加载，确认恢复密钥可用后在固件中临时关闭 Secure Boot，并记录原设置。
4. 默认项在 5 秒后用原厂 ACPI 启动。第二项用三星设备树和固件帧缓冲，可作为有线 SSH 的基线。**要验证内屏，请选第三项 `Samsung DT + native display`**。它保留实机试验中的电源域和稳压器设置，在内存中加载高通原生显示驱动，并报告内屏连接状态。若内屏变黑，保持网线连接，通过 SSH 取回本次报告。

### 判断停在哪一步

菜单打印所选路径和读到文件的 GRUB 设备号。三星条目的 `DT accepted` 表示 GRUB 已读入设备树。`Linux accepted` 表示内核映像已读入，`initrd registered` 表示已登记为内核提供 initramfs 的接口，`before EFI boot` 位于执行 `boot` 之前。随后若出现 `Providing initrd via EFI_LOAD_FILE2_PROTOCOL`，Linux EFI stub 已开始执行并向 GRUB 请求 initramfs。ACPI 项额外开启 EFI 调试和 `earlycon=efifb`，早期内核输出需要可用的 EFI 帧缓冲。遇到 `GRUB STOP` 时拍下错误文字，然后重启。

旧版 U 盘的第三项若显示 `keep power for display test`，该镜像只做保电对照。使用原生显示入口需要包含驱动模块的新镜像。

### 从 Windows 写入指定 U 盘

在管理员 Windows PowerShell 5.1 中，使用 USB 盘之外的本地目录暂存脚本和镜像。从构建端的 `np545xla-diag.img.sha256` 复制完整校验值。下面的目标参数对应此次选定的 SanDisk。先运行只读检查。

```powershell
$writer = '.\write-diag-usb.ps1'
$target = @{ ExpectedLabel='UNRAID'; ExpectedModel='USB SanDisk 3.2Gen1'; ExpectedBytes=[long]15376318464 }
$usb = & $writer -Mode Inspect @target
$usb | Format-List
$target.ExpectedPath = $usb.Path
$target.ExpectedUniqueId = $usb.UniqueId
$target.ImagePath = (Resolve-Path '.\np545xla-diag.img').Path
$target.Sha256 = '<填入构建端的64位十六进制SHA256>'
& $writer -Mode Preflight @target
```

确认预检列出的硬件路径和镜像长度后，用同一组参数执行写入。此步骤会清除 `UNRAID` 现有分区。成功返回 `Verified`，同时显示一致的 `SourceSHA256` 和 `ReadbackSHA256`。单独复核已经写好的同一支 U 盘时，可用 `-Mode Verify` 和保留的 `$target` 参数。

```powershell
& $writer -Mode Write @target
```

如果写盘在清除卷标后中断，先按此前记录的设备路径检查同一硬件。仅当原盘仍为零分区 RAW、MBR 或 GPT 时，可用原有的所有参数和硬件唯一 ID 调用 `-Mode ResumeCleared`，它会重新校验镜像、写入并读回。

## 通过有线网取报告

以诊断屏幕显示的 **IP 地址、2222 端口和本次启动的 SHA256 主机指纹**为准。该地址可能与 Windows 的地址不同。下面命令在 Mac 运行，使用临时的已知主机文件。

```sh
addr=192.0.2.10  # 换成屏幕显示的地址
host_file=$(mktemp)
ssh-keyscan -T 5 -p 2222 -t ed25519 "$addr" > "$host_file"
ssh-keygen -E sha256 -lf "$host_file"
```

把上一步输出的完整指纹与屏幕 `Host key: SHA256:…` 逐字比对。一致后，用与构建公钥匹配的身份下载报告。

```sh
ssh -p 2222 -i ~/.ssh/login-key -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$host_file" \
    root@"$addr" 'cat /run/diagnostics/report.txt' > np545xla-report.txt
```

检查报告里的 `Firmware: ACPI` 或 `Firmware: DT`、`Disk mounts: none`，以及 USB、网卡和块设备列表。每次重启都会生成新指纹，重新核对后再连接。要返回 Windows，先保存报告，关机拔掉诊断 U 盘，恢复原来的 Secure Boot 设置，再选 Windows Boot Manager。若出现 BitLocker 恢复界面，使用此前保存的恢复密钥。
