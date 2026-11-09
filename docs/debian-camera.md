# NP545XLA 内置摄像头试验

2026-11-09 后续整合：蓝牙与摄像头现已同时启用于默认 Latest，合盖恢复和普通默认启动均已验收，旧 Latest 保留作回退。见[综合日用入口](debian-latest-media.md)。以下保留此前独立试验阶段的说明。

在三星的 GRUB 菜单中选择 **Debian 13 - Camera 720p test (Samsung)**。倒计时默认仍选已验收的 Adreno 桌面。摄像头入口共用原 Lid edge 内核、Adreno 驱动和 USB 根分区。它的专用设备树让 GPIO166 在该次启动期间保持高电平，符合三星固件给内置 USB 摄像头上电的行为。启动服务只加载 UVC 驱动，开始采集需要显式运行测试工具。[三星供电引脚](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L87800) · [USB 供电方法](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L95692)

## 采集

从测试项启动后执行：

```sh
systemctl status np545xla-camera.service
np545xla-camera-test --seconds 60
```

工具只选 USB ID 为 `04f2:b72f`、报告原生 1280×720 的视频采集节点。优先选 MJPEG，其次选 YUYV，按设备公布的帧率打开。GStreamer 用 jpegdec 解码 MJPEG，检查实际输出分辨率、帧长、时间戳和驱动提供的序号，随即丢弃画面，仅输出统计数字。开流后的首帧与第二帧之间的间隔和缺失序号单独报告，要求两秒内开始连续输出。其后通过条件为解码帧数达到目标、没有解码警告、错误或序号跳变、平均帧率达到标称值的 95%，且最大相邻帧间隔不超过 2.5 个标称帧周期。可重复运行以验证流关闭后的重新打开。

从 SSH 验证时可用 sudo 运行采集测试；本地图形登录用户使用当前座席的摄像头权限。

## 构建与安装

在项目现有 ARM64 Debian 构建机上，用与 U 盘 Linux 7.0.0 匹配的源码和输出构建：

```sh
work=/var/tmp/np545xla-diag
src/build-camera-drivers.sh "$work/linux-7.0" "$work/obj" "$work/artifacts" output/camera
src/build-camera-boot.sh output/debian-final/manifest.txt output/daily/lid-edge/boot-esp output/camera/boot
```

将构建出的软件包、整个 `boot` 目录、原 U 盘的 `manifest.txt` 和本版本的 `install-daily-boot.sh` 放入三星 USB Debian 上的同一目录。在三星执行：

```sh
sudo apt-get install --no-install-recommends ./np545xla-camera_7.0.0-3_arm64.deb
sudo systemctl daemon-reload
sudo bash install-daily-boot.sh --camera boot manifest.txt
```

安装器校验根分区 UUID、USB 总线和当前启动器指纹，保留旧启动器为同一 EFI 分区上的 `EFI/BOOT/BOOTAA64.EFI.pre-camera`，最后才发布带新菜单的启动器。再次启动时可以直接选原日用入口。摄像头模块保存在独立目录；测试项通过内核参数请求加载它们。EFI 内的可选单次选择使用 `boot/np545-camera.env` 中的 `np545_camera_once=1`，GRUB 在交给测试项前清零，下次自动选原默认项。

## 2026-11-06 三星真机结果

三星从现有 SanDisk 上的新增入口启动 Linux 7.0.0，启动 ID 为 `c21ee3e1-caad-4d70-8fa2-790191a6cf0b`，根分区 UUID 为 `aeb13805-ba45-4385-8a98-067b839ca579`。内核参数含 `np545.camera=1`。GPIO166 被摄像头试验节点占用。USB 以 480 Mb/s 枚举出 Chicony `04f2:b72f`，上游 UVC 1.00 驱动建立了图像节点 `/dev/video0`。此前的正常启动中未枚举该设备。摄像头公布的 1280×720 模式为 MJPEG 30/15 fps、YUYV 10 fps。

以下三轮均为 MJPEG，每一轮重新打开设备，逐帧解码为 1280×720 I420。窗口从第二个成功解码的帧起算。整个测试过程只记录统计。

| 轮次 | 稳定阶段解码帧数 | 首末帧跨度 | 实测帧率 | 最大帧间隔 | 连续阶段序号跳变 |
|---|---:|---:|---:|---:|---:|
| 1 | 1,800 | 59.526 秒 | 30.22 fps | 36.98 毫秒 | 0 |
| 2 | 1,800 | 59.527 秒 | 30.22 fps | 37.07 毫秒 | 0 |
| 3 | 5,400 | 178.653 秒 | 30.22 fps | 38.22 毫秒 | 0 |

三轮每次开流最初均少一个序号，首帧到第二帧分别相隔 395.09、396.00 和 395.18 毫秒。两次额外的 900 帧诊断均记录到启动序号从 0 直接到 2，随后连续；其中一次暂时关闭了动态帧率，测完恢复原设置。正式采集时间窗 05:34:25–05:39:40 UTC 的内核日志没有新增消息。

Debian 的 FFmpeg 7.1 在读取这台相机的 MJPEG 时反复报告 JPEG APP 字段解析错误，因此 MJPEG 验收使用 GStreamer 的 jpegdec。另用 FFmpeg 检查原始 YUYV 模式，600 帧均解码为 1280×720，帧长正确，600 个像素哈希各不相同；该轮最大帧间隔约 700 毫秒。构建机上的试验记录位于 `output/camera/physical-boot.txt`、`physical-capture-v3.txt`、`timing-diagnostic.txt`、`exposure-diagnostic.txt`、`yuyv-60s.txt` 和 `capture-kernel-window.txt`（均在同一目录）。

采集后，U 盘 EFI 分区只读检查得到 `np545_camera_once=0`。正常重启后，三星自动进入原 Adreno 日用入口，启动 ID 为 `b8ab138f-2730-4a44-bd19-9785d37f3094`。实测根分区 UUID 一致，`np545.daily=1`、`separate_gpu_kms=N`，内屏已连接并启用，LightDM 活动，摄像头试验服务和 UVC 模块均未加载。[日用启动记录](usb-daily.md)
