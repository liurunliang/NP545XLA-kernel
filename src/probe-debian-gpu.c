/* SPDX-License-Identifier: MIT
 * Build on Debian 13 ARM64 with libwaffle-dev, libgbm-dev, libdrm-dev,
 * libegl-dev, libgles-dev, libwayland-dev, libx11-dev and pkg-config:
 *   cc -O2 -Wall -Wextra -Werror probe-debian-gpu.c -o probe-debian-gpu \
 *   $(pkg-config --cflags --libs waffle-1 egl glesv2 gbm libdrm x11 wayland-client)
 * Usage: probe-debian-gpu node|x11|wayland /dev/dri/renderD128
 *        LIBGL_ALWAYS_SOFTWARE=1 probe-debian-gpu surfaceless|x11|wayland software
 * For an existing Xfce seat, clear LIBGL_ALWAYS_SOFTWARE for this command.
 * Mesa 25's DRI_PRIME=platform-2c00000_gpu can select the separate Adreno
 * on DRI3-capable X or Wayland. Leave it unset for a unified DRM device.
 * A direct X11/Wayland probe opens a small window on the selected display.
 * probe-debian-wayland.sh instead runs a new Cage headless output.
 * Never opens an input device or requests DRM master.
 */
#define _GNU_SOURCE
#define WAFFLE_API_VERSION 0x0107
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <X11/Xutil.h>
#include <ctype.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <waffle.h>
#include <waffle_wayland.h>
#include <waffle_x11_egl.h>
#include <wayland-client.h>
#include <xf86drm.h>

static void fail(const char *reason)
{
    fprintf(stderr, "FAIL: %s\n", reason);
    exit(1);
}

static void waffle_check(bool ok, const char *stage)
{
    if (!ok) {
        const struct waffle_error_info *err = waffle_error_get_info();
        fprintf(stderr, "%s: %s\n", stage, err->message);
        fail("window system operation failed");
    }
}

static bool same_device(const char *a, const char *b)
{
    struct stat x, y;
    return a && b && stat(a, &x) == 0 && stat(b, &y) == 0 &&
           S_ISCHR(x.st_mode) && S_ISCHR(y.st_mode) && x.st_rdev == y.st_rdev;
}

static void verify_renderer(const char *target)
{
    const char *renderer = (const char *) glGetString(GL_RENDERER);
    if (!renderer)
        fail("no GLES renderer");
    printf("GL renderer: %s\n", renderer);
    bool software = strstr(renderer, "llvmpipe") || strstr(renderer, "softpipe") ||
                    strstr(renderer, "swrast");
    if (strcmp(target, "software") == 0) {
        if (!software)
            fail("expected a software reference renderer");
        return;
    }
    if (software || (!strcasestr(renderer, "adreno") &&
        !(strncmp(renderer, "FD", 2) == 0 && isdigit((unsigned char)renderer[2]))))
        fail("expected Freedreno/Adreno hardware; refusing software or another GPU");

    PFNEGLQUERYDISPLAYATTRIBEXTPROC query_display =
        (PFNEGLQUERYDISPLAYATTRIBEXTPROC) eglGetProcAddress("eglQueryDisplayAttribEXT");
    PFNEGLQUERYDEVICESTRINGEXTPROC query_device =
        (PFNEGLQUERYDEVICESTRINGEXTPROC) eglGetProcAddress("eglQueryDeviceStringEXT");
    EGLAttrib device = 0;
    if (!query_display || !query_device ||
        !query_display(eglGetCurrentDisplay(), EGL_DEVICE_EXT, &device))
        fail("cannot verify the rendering device behind this EGL display");
    const char *node = query_device((EGLDeviceEXT)device, EGL_DRM_RENDER_NODE_FILE_EXT);
    printf("EGL render node: %s (expected %s)\n", node ? node : "unknown", target);
    if (!same_device(node, target))
        fail("EGL render node does not match requested hardware");
    int fd = open(node, O_RDWR | O_CLOEXEC);
    drmVersionPtr drm = fd < 0 ? NULL : drmGetVersion(fd);
    if (!drm || drmGetNodeTypeFromFd(fd) != DRM_NODE_RENDER)
        fail("could not identify the EGL render node's DRM driver");
    printf("DRM driver: %.*s\n", drm->name_len, drm->name);
    if (drm->name_len != 3 || memcmp(drm->name, "msm", 3) != 0)
        fail("requested node is not an MSM render node");
    drmFreeVersion(drm);
    close(fd);
}

static GLuint compile_shader(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "%s\n", log);
        fail("shader compilation failed");
    }
    return shader;
}

static GLint setup_pattern(void)
{
    static const GLfloat triangle[] = {-1, -1, 3, -1, -1, 3};
    GLuint prog = glCreateProgram();
    glAttachShader(prog, compile_shader(GL_VERTEX_SHADER,
        "attribute vec2 pt; void main(){gl_Position=vec4(pt,0.,1.);}"));
    glAttachShader(prog, compile_shader(GL_FRAGMENT_SHADER,
        "precision mediump float; uniform float turn;"
        "void main(){float right=step(16.,gl_FragCoord.x);"
        "gl_FragColor=vec4(1.-right,right,turn,1.);}"));
    glBindAttribLocation(prog, 0, "pt");
    glLinkProgram(prog);
    GLint ok = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok)
        fail("shader program failed to link");
    glUseProgram(prog);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, triangle);
    glEnableVertexAttribArray(0);
    glViewport(0, 0, 32, 32);
    glDisable(GL_DITHER);
    return glGetUniformLocation(prog, "turn");
}

static void render_frame(GLint uniform, int frame)
{
    glUniform1f(uniform, frame % 2);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    GLubyte pixels[32 * 32 * 4];
    glReadPixels(0, 0, 32, 32, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    if (glGetError() != GL_NO_ERROR)
        fail("GLES drawing or readback failed");
    for (unsigned i = 0; i < 32 * 32; ++i) {
        bool right = (i % 32) >= 16;
        const GLubyte expected[] = {right ? 0 : 255, right ? 255 : 0,
                                    frame % 2 ? 255 : 0, 255};
        if (memcmp(pixels + 4 * i, expected, 4) != 0)
            fail("shader pattern mismatch on readback");
    }
    printf("Frame %d: 1024 matching RGBA pixels\n", frame + 1);
}

static void probe_offscreen(const char *target)
{
    bool software = strcmp(target, "software") == 0;
    int fd = -1;
    struct gbm_device *gbm = NULL;
    EGLDisplay dpy;
    if (software) {
        dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, NULL, NULL);
    } else {
        fd = open(target, O_RDWR | O_CLOEXEC);
        if (fd < 0 || drmGetNodeTypeFromFd(fd) != DRM_NODE_RENDER)
            fail("expected an accessible DRM render node");
        gbm = gbm_create_device(fd);
        if (!gbm)
            fail("gbm_create_device failed");
        dpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
    }
    EGLConfig config;
    EGLint n;
    const EGLint cfg[] = {EGL_SURFACE_TYPE, 0, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                           EGL_NONE};
    const EGLint api[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    if (!eglInitialize(dpy, NULL, NULL) || !eglBindAPI(EGL_OPENGL_ES_API) ||
        !eglChooseConfig(dpy, cfg, &config, 1, &n) || n != 1)
        fail("cannot initialize offscreen EGL");
    EGLContext ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, api);
    if (!ctx || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx))
        fail("cannot make surfaceless EGL context current");
    verify_renderer(target);
    GLuint tex, fbo;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 32, 32, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        fail("offscreen framebuffer incomplete");
    GLint uniform = setup_pattern();
    for (int i = 0; i < 3; ++i)
        render_frame(uniform, i);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(dpy, ctx);
    eglTerminate(dpy);
    if (gbm) gbm_device_destroy(gbm);
    if (fd >= 0) close(fd);
}

static void frame_done(void *data, struct wl_callback *callback, uint32_t time)
{
    (void) time;
    *(bool *)data = true;
    wl_callback_destroy(callback);
}

/* Read a strip of our own window after the swap. Present may complete after
 * XSync, and the blue component alternates to distinguish successive frames. */
static void verify_x11_window(struct waffle_x11_egl_window *window, int frame)
{
    Display *dpy = window->display.xlib_display;
    for (int retry = 0; retry < 50; ++retry) {
        XImage *image = XGetImage(dpy, window->xlib_window, 0, 12, 32, 1,
                                  AllPlanes, ZPixmap);
        if (!image)
            fail("cannot read the test X11 window");
        bool match = true;
        for (int x = 0; x < 32; ++x) {
            unsigned long expected = x < 16 ? image->red_mask : image->green_mask;
            if (frame % 2) expected |= image->blue_mask;
            unsigned long mask = image->red_mask | image->green_mask | image->blue_mask;
            if ((XGetPixel(image, x, 0) & mask) != expected) match = false;
        }
        XDestroyImage(image);
        if (match) return;
        usleep(10000);
    }
    fail("X server did not return the presented pattern from the test window");
}

static void probe_window(bool wayland, const char *target)
{
    const int32_t init[] = {WAFFLE_PLATFORM,
        wayland ? WAFFLE_PLATFORM_WAYLAND : WAFFLE_PLATFORM_X11_EGL, 0};
    const int32_t cfg[] = {WAFFLE_CONTEXT_API, WAFFLE_CONTEXT_OPENGL_ES2,
        WAFFLE_RED_SIZE, 8, WAFFLE_GREEN_SIZE, 8, WAFFLE_BLUE_SIZE, 8,
        WAFFLE_DOUBLE_BUFFERED, 1, 0};
    waffle_check(waffle_init(init), "initialize Waffle");
    struct waffle_display *dpy = waffle_display_connect(NULL);
    waffle_check(dpy != NULL, "connect display");
    struct waffle_config *config = waffle_config_choose(dpy, cfg);
    waffle_check(config != NULL, "choose EGL config");
    struct waffle_context *ctx = waffle_context_create(config, NULL);
    waffle_check(ctx != NULL, "create EGL context");
    struct waffle_window *win = waffle_window_create(config, 32, 32);
    waffle_check(win != NULL, "create native window");
    waffle_check(waffle_window_show(win), "map native window");
    waffle_check(waffle_make_current(dpy, win, ctx), "make context current");
    verify_renderer(target);
    union waffle_native_window *native = waffle_window_get_native(win);
    waffle_check(native != NULL, "query native window");
    GLint uniform = setup_pattern();
    for (int i = 0; i < 3; ++i) {
        static const struct wl_callback_listener listener = {.done = frame_done};
        bool done = false;
        if (wayland) {
            struct wl_callback *cb = wl_surface_frame(native->wayland->wl_surface);
            if (!cb || wl_callback_add_listener(cb, &listener, &done) != 0)
                fail("cannot request native Wayland frame callback");
        }
        render_frame(uniform, i);
        waffle_check(waffle_window_swap_buffers(win), "submit native surface");
        if (wayland) {
            while (!done)
                if (wl_display_dispatch(native->wayland->display.wl_display) < 0)
                    fail("Wayland display disconnected before frame callback");
            printf("Wayland frame %d callback acknowledged\n", i + 1);
        } else {
            verify_x11_window(native->x11_egl, i);
            printf("X11 frame %d pattern confirmed by XGetImage\n", i + 1);
        }
    }
    free(native);
    waffle_make_current(dpy, NULL, NULL);
    waffle_window_destroy(win);
    waffle_context_destroy(ctx);
    waffle_config_destroy(config);
    waffle_display_disconnect(dpy);
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "Usage: %s node|x11|wayland /dev/dri/renderDNNN\n"
                        "       %s surfaceless|x11|wayland software\n", argv[0], argv[0]);
        return 2;
    }
    const char *mode = argv[1], *target = argv[2];
    setvbuf(stdout, NULL, _IOLBF, 0);
    alarm(35);
    if (!strcmp(mode, "node") && strcmp(target, "software"))
        probe_offscreen(target);
    else if (!strcmp(mode, "surfaceless") && !strcmp(target, "software"))
        probe_offscreen(target);
    else if (!strcmp(mode, "x11") || !strcmp(mode, "wayland"))
        probe_window(!strcmp(mode, "wayland"), target);
    else
        fail("unsupported platform and renderer combination");
    printf("PASS: %s rendering on %s\n", mode, target);
    return 0;
}
