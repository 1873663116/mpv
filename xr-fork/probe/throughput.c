// [xr-probe] 常驻出口吞吐夹具(诊断用,非生产)。
// 目的:把「mpv 常驻路径的出帧率」和「RealityKit 球面渲染」切开。
// 它配置 3 张 IOSurface、驱动 macvk_resident 的 libmpv 播放真实文件(surfaceless,无窗口、
// 无 RealityKit),按真实时序计时,数 front IOSurfaceID 的变化率 = mpv 端真实发布帧率。
//
// 若某文件在这里就只有 ~10fps → 瓶颈在 mpv 常驻路径(与球面无关)。
// 若两文件都接近源帧率/cplayer 上限 → 常驻路径不背锅,app 的差距来自球面。
//
// 用法: xr_tput <file> <width> <height> [seconds]   环境变量 XR_TUNE=1 套用 app 的色彩选项。

#include <mpv/client.h>
#include <mpv/xr_resident.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static CFNumberRef num(int v) { return CFNumberCreate(NULL, kCFNumberIntType, &v); }

// [xr-probe] 色彩验证辅助:half→float、sRGB→线性。用于把两条出口的字节都还原成线性光对比。
static float h2f(uint16_t h) {
    uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff, f;
    if (e == 0) {
        if (m == 0) { f = s << 31; }
        else { e = 127 - 15 + 1; while (!(m & 0x400)) { m <<= 1; e--; } m &= 0x3ff;
               f = (s << 31) | (e << 23) | (m << 13); }
    } else if (e == 0x1f) { f = (s << 31) | (0xffu << 23) | (m << 13); }
    else { f = (s << 31) | ((e - 15 + 127) << 23) | (m << 13); }
    float r; memcpy(&r, &f, 4); return r;
}
static float srgb2lin(float c) {
    return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f);
}

// XR_PIXFMT=8 → 8-bit 'RGBA'(SDR,sRGB 编码,4 字节);否则 'RGhA' fp16(HDR,线性,8 字节)。
static int g_fmt8;
static IOSurfaceRef make_surf(int w, int h) {
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight,
                           kIOSurfaceBytesPerElement, kIOSurfacePixelFormat };
    CFNumberRef vals[] = { num(w), num(h), num(g_fmt8 ? 4 : 8),
                           num(g_fmt8 ? 0x52474241 /* 'RGBA' 8-bit */
                                      : 0x52476841 /* 'RGhA' fp16 */) };
    CFDictionaryRef d = CFDictionaryCreate(NULL, keys, (const void **)vals, 4,
                                           &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    for (int i = 0; i < 4; i++) CFRelease(vals[i]);
    return s;
}

// 把 front 表面横向采 7 个点,各通道还原成线性光打印。两格式跑同一静态源,逐点应相等。
static void dump_linear(IOSurfaceRef *surfs, uint32_t front, int w, int h) {
    IOSurfaceRef s = NULL;
    for (int i = 0; i < 3; i++)
        if (surfs[i] && IOSurfaceGetID(surfs[i]) == front) { s = surfs[i]; break; }
    if (!s) { printf("[xr-tput] dump: 找不到 front 表面\n"); return; }
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(s);
    size_t bpr = IOSurfaceGetBytesPerRow(s);
    int y = h / 2;
    printf("[xr-tput] linear @y=%d  fmt=%s\n", y, g_fmt8 ? "8bit-sRGB" : "fp16-linear");
    for (int i = 1; i <= 7; i++) {
        int x = w * i / 8;
        uint8_t *px = base + y * bpr + x * (g_fmt8 ? 4 : 8);
        float r, gg, b;
        if (g_fmt8) {
            r = srgb2lin(px[0] / 255.0f); gg = srgb2lin(px[1] / 255.0f); b = srgb2lin(px[2] / 255.0f);
        } else {
            uint16_t *h16 = (uint16_t *)px;
            r = h2f(h16[0]); gg = h2f(h16[1]); b = h2f(h16[2]);
        }
        printf("  x=%-5d  R=%.4f G=%.4f B=%.4f\n", x, r, gg, b);
    }
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <file> <w> <h> [seconds]\n", argv[0]);
        return 2;
    }
    const char *file = argv[1];
    int w = atoi(argv[2]), h = atoi(argv[3]);
    double dur = argc > 4 ? atof(argv[4]) : 8.0;
    const double warm = 2.5; // 跳过启动/SPIR-V/管线创建/首帧解码

    g_fmt8 = getenv("XR_PIXFMT") && atoi(getenv("XR_PIXFMT")) == 8;

    IOSurfaceRef surfs[3];
    uint32_t ids[3];
    for (int i = 0; i < 3; i++) {
        surfs[i] = make_surf(w, h);
        if (!surfs[i]) { fprintf(stderr, "IOSurfaceCreate[%d] 失败\n", i); return 1; }
        ids[i] = IOSurfaceGetID(surfs[i]);
    }
    xr_resident_set_enabled(true);
    if (!xr_resident_configure_external_iosurfaces(ids, 3, w, h)) {
        fprintf(stderr, "configure_external_iosurfaces 失败\n");
        return 1;
    }

    mpv_handle *m = mpv_create();
    mpv_set_option_string(m, "vo", "gpu-next");
    mpv_set_option_string(m, "gpu-api", "vulkan");
    mpv_set_option_string(m, "gpu-context", "macvk_resident");
    mpv_set_option_string(m, "hwdec", "videotoolbox");
    mpv_set_option_string(m, "audio", "no");
    mpv_set_option_string(m, "terminal", "no");
    mpv_set_option_string(m, "msg-level", "all=no");
    // [xr] 出口色彩契约:8-bit→sRGB 编码、fp16→线性。target-trc 必须与 vo 端渲染目标
    // transfer(xr_resident_target_is_srgb 路由)一致,否则字节编码与消费端解码不互逆。
    mpv_set_option_string(m, "target-prim", "display-p3");
    mpv_set_option_string(m, "target-trc", g_fmt8 ? "srgb" : "linear");
    if (getenv("XR_UNTIMED")) {
        // 忽略源帧率,按最大速度出帧 → 量「常驻渲染上限」,去掉源 fps 混淆
        mpv_set_option_string(m, "untimed", "yes");
        mpv_set_option_string(m, "video-sync", "desync");
    }
    if (getenv("XR_TUNE")) {
        // app 的沉浸色彩契约(影响渲染开销,两文件都套用以对齐 app)
        mpv_set_option_string(m, "target-prim", "display-p3");
        mpv_set_option_string(m, "target-trc", g_fmt8 ? "srgb" : "linear");
        mpv_set_option_string(m, "tone-mapping", "bt.2390");
        mpv_set_option_string(m, "hdr-compute-peak", "yes");
        mpv_set_option_string(m, "target-peak", "566");
        mpv_set_option_string(m, "target-contrast", "inf");
    }
    if (mpv_initialize(m) < 0) { fprintf(stderr, "mpv_initialize 失败\n"); return 1; }

    const char *cmd[] = { "loadfile", file, NULL };
    mpv_command(m, cmd);

    double t0 = now_s();
    uint32_t last = 0;
    int count = 0;
    while (now_s() - t0 < dur + warm) {
        mpv_wait_event(m, 0.004); // 泵事件,保持播放循环推进
        uint32_t f = xr_resident_front_iosurface_id();
        if (f != 0 && f != last) {
            last = f;
            if (now_s() - t0 >= warm) count++;
        }
    }
    double elapsed = (now_s() - t0) - warm;
    printf("[xr-tput] %s  %dx%d  fmt=%s tune=%s  →  %d 帧 / %.1fs = %.1f fps\n",
           file, w, h, g_fmt8 ? "8bit" : "fp16", getenv("XR_TUNE") ? "on" : "off",
           count, elapsed, count / elapsed);
    if (getenv("XR_DUMP"))
        dump_linear(surfs, xr_resident_front_iosurface_id(), w, h);
    mpv_terminate_destroy(m);
    return 0;
}
