# NP545XLA 内置摄像头试验

在三星的 GRUB 菜单中选择 **Debian 13 - Camera 720p test (Samsung)**。倒计时默认仍选已验收的 Adreno 桌面。摄像头入口共用原 Lid edge 内核、Adreno 驱动和 USB 根分区。它的专用设备树让 GPIO166 在该次启动期间保持高电平，符合三星固件给内置 USB 摄像头上电的行为。启动服务只加载 UVC 驱动，开始采集需要显式运行测试工具。[三星供电引脚](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L87800) · [USB 供电方法](dump/NP545XLA-hw-dump/redisasm/dsdt.dsl#L95692)

## 采集

从测试项启动后执行：

```sh
systemctl status np545xla-camera.service
np545xla-camera-test --seconds 60
```

工具只选 USB ID 为 `04f2:b72f`、报告原生 1280×720 的视频采集节点。优先选 MJPEG，其次选 YUYV，按设备公布的帧率打开。FFmpeg 解码全部帧，在内存中校验分辨率、帧长、时间戳和像素哈希，仅输出统计数字。通过条件为解码帧数达到目标、没有解码错误、画面哈希有变化、平均帧率达到标称值的 95%，且最大相邻帧间隔不超过 2.5 个标称帧周期。可重复运行以验证流关闭后的重新打开。

## 构建与安装

在项目现有 ARM64 Debian 构建机上，用与 U 盘 Linux 7.0.0 匹配的源码和输出构建：

```sh
work=/var/tmp/np545xla-diag
src/build-camera-drivers.sh "$work/linux-7.0" "$work/obj" "$work/artifacts" output/camera
src/build-camera-boot.sh output/debian-final/manifest.txt output/daily/lid-edge/boot-esp output/camera/boot
```

将构建出的软件包、整个 `boot` 目录、原 U 盘的 `manifest.txt` 和本版本的 `install-daily-boot.sh` 放入三星 USB Debian 上的同一目录。在三星执行：

```sh
sudo apt-get install --no-install-recommends ./np545xla-camera_7.0.0-1_arm64.deb
sudo systemctl daemon-reload
sudo bash install-daily-boot.sh --camera boot manifest.txt
```

安装器校验根分区 UUID、USB 总线和当前启动器指纹，保留旧启动器为同一 EFI 分区上的 `EFI/BOOT/BOOTAA64.EFI.pre-camera`，最后才发布带新菜单的启动器。再次启动时可以直接选原日用入口。摄像头模块保存在独立目录；测试项通过内核参数请求加载它们。EFI 内的可选单次选择使用 `boot/np545-camera.env` 中的 `np545_camera_once=1`，GRUB 在交给测试项前清零，下次自动选原默认项。
