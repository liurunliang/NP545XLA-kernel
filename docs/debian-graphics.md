# NP545XLA 上的 X11、Wayland 与 Adreno

## 在 U 盘上使用已验证的硬件加速

在 GRUB 选 **Debian 13 - Adreno unified DRM trial (Samsung)**。到 LightDM 登录页，选 **Xfce Session** 进入 X11，或选 **Xfce Session (Wayland)** 进入 Wayland。两种会话均已在这台三星的 1920×1080 内屏实测，使用同一套 USB Debian 和用户文件。终端里执行 `echo "$XDG_SESSION_TYPE"` 可查看当前会话。想回到原来的软件渲染桌面时，让 GRUB 自动倒计时进入日用 Debian，在登录页选 **Xfce Session**。登录器可以记住上次选择。[试验入口构建与回退](usb-daily.md#adreno-统一-drm-试验入口)

### 2026-11-05 第二版驱动实机验收

三星冷启动加载了带 A680 GBIF 和 GMEM 修复的模块（构建 ID `af3bbd3937e34dacf29f589bc040a40b09d41d09`），核对到 GMU 固件 2.0.261。统一 DRM 模式下，本次启动的内屏和 GPU 分别对应 `/dev/dri/card0` 和 `/dev/dri/renderD128`。以下测试都在这次启动的实际登录会话或本地座席完成。

| 会话 | 实际观察 |
| --- | --- |
| Xfce / X11 | 默认渲染器为 Mesa Freedreno `FD680`，GLX 报告 `Accelerated: yes`。原生 X11 EGL 窗口绘制三帧，每帧 1024 个 RGBA 像素全部匹配。交换缓冲后，又通过 X 服务器的 `XGetImage` 读回并核对了三帧图案。 |
| X11 连续负载 | glmark2-es2 在 640×360 窗口依次测试纹理、Phong 光照、桌面合成和折射，各 25 秒。四项均完成。结束时，内核累计记录 203 次 GPU 频率转换，本轮新增 GPU 错误为 0。首版曾在启动约 49 秒后出现的 GMU 超时与 watchdog 在此次测试中均未复现。 |
| Wayland 独立座席 | Cage 接管 eDP 的 DRM master。内核显示 eDP-1 连到活动 CRTC。原生 Wayland 客户端在 1920×1080 画面上用 FD680 生成三帧，每帧 1024 个像素全部匹配，三次均收到帧回调。结束后自动切回同一个 Xorg 和 Xfce 会话。[座席检查工具](../src/probe-debian-wayland-seat.py) |
| Xfce / Wayland | 用户从 LightDM 登录，使用内置触控板打开终端，并用实体键盘核对结果为 `wayland`。logind 同时报告活动桌面为 `xfce-wayland`。labwc 持有实际 eDP 所在卡的 DRM master，内屏处于活动状态。原生应用通过 `wayland-0` 在 FD680 上绘制三帧，通过全部像素与帧回调检查。绘制期间 labwc 自身的同一 DRM 客户端累计增加 4,227,376 ns GPU 时间和 882,096 个 GPU 周期。本次启动截至取证时未出现 GPU 超时或挂起记录。 |

构建 Mac 的 `output/adreno/` 目录保存了本次原始记录，包括 `patched-cold.txt`、`patched-x11-window-v2.txt`、`patched-x11-glmark.txt`、`patched-wayland-seat.txt`、`patched-wayland-kms.tar` 与 `patched-wayland-compositor.txt`。持续负载结论的观测窗口为 100 秒。[像素与呈现检查工具](../src/probe-debian-gpu.c)

## 原日用入口的 X11 桌面

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

以上是原日用入口的软件渲染基线，供后续硬件测试对照。

## 三星实机的 Adreno 硬件绘制

2026-11-05，在保留日用 Xfce 的分卡模式下，在一次测试期间将内核固件搜索路径指向 USB 根盘上的专用目录。驱动加载 SQE 和 GMU 固件，GMU 报告版本 2.0.261。MSM 查询返回当前驱动配置的 GPU ID 680、芯片 ID `0x06080001` 和 2 MiB GMEM。随后直接在指定渲染节点运行 GLES 着色器。Mesa 报告 `FD680`，EGL 设备号与 `/dev/dri/renderD128` 的设备号匹配，内核 DRM 驱动为 `msm`。三帧图案每帧 1024 个 RGBA 像素全部匹配。退出后已恢复日用的固件搜索路径，LightDM 保持运行。[固件来源](debian-gpu-firmware.md) · [绘制与校验程序](../src/probe-debian-gpu.c)

在同次启动中，独立的 Cage/Wayland 合成器打开了该渲染节点。原生 Wayland 客户端再次报告 `FD680`，三个窗口缓冲区均通过像素校验并收到帧回调，输出为虚拟屏。在原日用 X11 服务器上，指定 GPU 后客户端仍报告 `llvmpipe`，硬件测试按预期判为失败。上述原始记录在 `output/adreno/` 的 `first-open.txt`、`node-hardware.txt`、`wayland-headless-hardware.txt` 和 `x11-split-hardware.txt`。

## 在 LightDM 选择 Xfce 会话

在本机登录页顶部的会话菜单选择 **Xfce Session**（X11）或 **Xfce Session (Wayland)**，再输入本机密码。安装脚本保留 `xfce` 作为默认项。进入桌面后，在终端执行 `echo "$XDG_SESSION_TYPE"` 可核对当前协议。

三星上的 Debian 13 提供 Xfce 4.20.2。两个会话入口分别执行 `startxfce4` 和 `startxfce4 --wayland`，后者默认用 labwc 启动 `xfce4-session`。`debian-desktop/provision` 安装 labwc，同时把 Xsession 的软件渲染设置限定在 X11 会话。本机既有安装补入了 `labwc` 和 `libsfdo0` 两个包，下载 280 kB、增占 1052 kB。[Debian labwc 软件包](https://packages.debian.org/trixie/labwc) · [Xfce 会话启动脚本](https://sources.debian.org/src/xfce4-session/4.20.2-2/scripts/startxfce4.in/)

## 输入路径

内置键盘和触控板先经过内核输入驱动、udev 和 libinput。板级键盘包在 `inputN` 父节点和事件节点去除错误的绘图板标签，保留键盘标签。这个修正位于显示协议之下。在 X11 已验收内置键盘输入与触控板点击。在 Xfce/Wayland 也已完成打开终端、输入命令和回车的现场操作。[板级键盘分类规则](../src/debian-rootfs/70-np545xla-eckb.rules) · [内置输入验收](usb-daily.md)
