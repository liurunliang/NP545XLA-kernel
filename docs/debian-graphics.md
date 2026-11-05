# NP545XLA 上的 X11、Wayland 与 Adreno

## 当前 X11 桌面

2026-11-05，三星 USB Debian 的 Xfce/LightDM 会话使用 X11，MSM KMS 驱动负责内屏扫描输出。实机同时提供独立的 Adreno 渲染设备。该次启动的节点如下，编号可能随启动顺序变化。

| 节点 | 内核驱动 | 实机用途 |
| --- | --- | --- |
| `/dev/dri/card1` | `msm_dpu`，`ae01000.display-controller` | `card1-eDP-1` 报告 `connected`。Xorg 驱动从这里输出到 1920×1080 内屏。 |
| `/dev/dri/card0`、`/dev/dri/renderD128` | `adreno`，`2c00000.gpu` | 内核已注册渲染节点。当前启动日志多次报告 `qcom/a630_sqe.fw` 缺失，返回 `-2`。 |

`prepare-xorg` 按已连接的 eDP 选卡。该卡的设备目录没有自己的渲染节点，脚本因此为 Xorg 写入 `AccelMethod=none`，Xsession 给该桌面的应用设置 `LIBGL_ALWAYS_SOFTWARE=1`。实机 `glxinfo -B` 显示 `Accelerated: no`。X11 EGL 报告 Mesa 25.0.7、EGL 1.5、OpenGL ES 3.2，渲染器为 `llvmpipe (LLVM 19.1.7, 128 bits)`。这项会话配置只作用于 Xorg/Xsession。Wayland 需要分别核对合成器与客户端选用的渲染器。[Xorg 选卡](../src/debian-desktop/prepare-xorg) · [Xsession 配置](../src/debian-desktop/provision)

在当前 X11 显示创建了 16×16 的 EGL 离屏画布。GLES 依次清屏为红、绿，通过 `glReadPixels` 在中心读回预期的 RGBA8 `[255,0,0,255]`、`[0,255,0,255]`。渲染器仍为 llvmpipe。该测试无需创建可见窗口。

## 原生 Wayland 客户端的实机离屏测试

在同一台三星上以普通用户启动 Cage 0.2.0 和 wlroots 0.18.2，使用私有的 `XDG_RUNTIME_DIR`、`WLR_BACKENDS=headless` 及 `WLR_RENDERER=pixman`。会话只提供虚拟输出 `HEADLESS-1`，座席没有物理输入能力。合成器进程打开的 `/dev/dri/*` 或 `/dev/input/*` 文件描述符数量为 0。客户端清除了 `DISPLAY`，同时确认 `LIBGL_ALWAYS_SOFTWARE` 和 `GALLIUM_DRIVER` 均未设置。[wlroots 无屏后端实现](https://sources.debian.org/src/wlroots/0.18.2-3/backend/backend.c/)

| 检查 | 结果 |
| --- | --- |
| Wayland 服务 | 私有 socket 公布 `wl_shm`、`wl_output`、`xdg_wm_base`。 |
| 客户端 EGL | Mesa 25.0.7 提供 EGL 1.5、OpenGL ES 3.2，实际选择 llvmpipe。合成器使用上面明确指定的 Pixman。 |
| 连续出帧 | 原生 `weston-simple-egl` 绘制三角形，5 秒报告 277 帧。约 7 秒的协议计数包含 350 次绑定绘图缓冲区的 `wl_surface.attach`、351 次 `wl_surface.commit` 和 350 个帧回调请求。帧数来自虚拟输出。 |

同一隔离会话中的 `es2gears_wayland` 在首次提交表面前崩溃。成功的画帧证据来自独立的 `weston-simple-egl`。该程序从 Debian 官方 Weston 14.0.2-1 包临时提取，测试后已清理。Debian 的 `cage` 与 `wayland-utils` 保留作复查，本次无推荐依赖安装共下载 1.5 MB、占用约 4.7 MB。结束后已核对 Cage 退出、LightDM 和 Xfce/X11 活跃、eDP 仍已连接。现场日志位于本地 `output/daily/wayland/`。

以上覆盖 X11 软件渲染与原生 Wayland 客户端的离屏软件合成。Wayland 合成器独占内屏进行 KMS 扫描输出、跨卡传递渲染缓冲区、Adreno 硬件加速，以及真实 Wayland 座席上的输入仍待验证。

## 输入路径

内置键盘和触控板先经过内核输入驱动、udev 和 libinput。板级键盘包在 `inputN` 父节点和事件节点去除错误的绘图板标签，保留键盘标签。这个修正位于显示协议之下。Xorg 已注册内置键盘，现场也已在登录页用内置触控板移动及点击。使用 libinput 的原生 Wayland 合成器可以读取这些分类，物理设备在该合成器下的键入、移动及点击需要在真实 Wayland 座席单独实测。[板级键盘分类规则](../src/debian-rootfs/70-np545xla-eckb.rules) · [内置输入验收](usb-daily.md)
