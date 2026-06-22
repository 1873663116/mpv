/*
 * [xr] Enchron fork — 常驻纹理出口(resident_texture)
 *
 * 让 vo_gpu_next 把视频帧渲染进「常驻的、IOSurface-backed 的」可渲染纹理,
 * 该 IOSurface 可经 IOSurfaceID 交给外部(Swift / RealityKit)零拷贝共享。
 *
 * 门①(共享纹理写/读同步,见 ADR 0003/0010):用 3 张 IOSurface 三缓冲环——
 * mpv 轮流写「后台缓冲」,渲染完成后把「上一帧」那张发布为最新完整帧(延迟一帧发布);
 * 消费方(RealityKit)只读已发布的那张,绝不读 mpv 正在写的那张 → 无撕裂。
 * 三缓冲让「正写 / 待发布 / 消费中」三张互不重叠,从而能把每帧 pl_gpu_finish 全停
 * 换成 pl_gpu_flush(非阻塞)+ 只等上一帧的 pl_tex_poll,渲染与消费并行(ADR 0011)。
 *
 * 参考:video/out/hwdec/hwdec_vt_pl.m(VideoToolbox → 可采样 pl_tex 的导入范例)。
 * 设计依据:ADR 0001 / 0002 / 0003。
 */

#import <Metal/Metal.h>
// IOSurfaceRef.h(C API)在 macOS 与 visionOS 通用;伞头 <IOSurface/IOSurface.h>
// 在 iOS/visionOS SDK 不公开,会编不过(只有 macOS 有)。
#import <IOSurface/IOSurfaceRef.h>

#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#include <libplacebo/gpu.h>
#include <libplacebo/vulkan.h>

#include "include/mpv/xr_resident.h"

#include "common/msg.h"
#include "video/out/vulkan/common.h"

#define XR_RING_MAX 3

// 取得 MoltenVK 实际使用的 MTLDevice(纹理必须与 MoltenVK 同 device)。
static id<MTLDevice> xr_get_moltenvk_device(pl_gpu gpu)
{
    pl_vulkan vk = pl_vulkan_get(gpu);
    if (!vk || !vk->device || !vk->instance || !vk->get_proc_addr)
        return nil;
#ifdef VK_EXT_METAL_OBJECTS_SPEC_VERSION
    PFN_vkExportMetalObjectsEXT fn = (PFN_vkExportMetalObjectsEXT)
        vk->get_proc_addr(vk->instance, "vkExportMetalObjectsEXT");
    if (!fn)
        return nil;
    VkExportMetalDeviceInfoEXT dev_info = {
        .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT,
    };
    VkExportMetalObjectsInfoEXT obj_info = {
        .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT,
        .pNext = &dev_info,
    };
    fn(vk->device, &obj_info);
    return dev_info.mtlDevice;
#else
    return nil;
#endif
}

// 单张常驻缓冲。
struct xr_buf {
    IOSurfaceRef iosurf;
    id<MTLTexture> mtltex;
    pl_tex tex;
    pl_gpu gpu;   // 创建 tex 的 gpu:热切后 gpu 会换,据此判定纹理是否仍有效
    int w, h;
    uint32_t iosurface_id;
    bool external;
};
static struct xr_buf g_res[XR_RING_MAX];

// [xr] 出口像素格式(色彩路由,见 ADR 0004/0005):按源 HDR 与否选最省带宽的格式。
//   fp16 RGBA('RGhA')= 扩展线性 Display P3,承载 HDR(>1.0 线性光),8 字节/像素。
//   8-bit RGBA('RGBA')= IEC sRGB 编码 Display P3,SDR 专用,4 字节/像素(带宽腰斩)。
// 由 configure 时读 IOSurfaceGetPixelFormat 自动识别,无需改 API 签名。
#define XR_PIXFMT_FP16  0x52476841u // 'RGhA' = kCVPixelFormatType_64RGBAHalf
#define XR_PIXFMT_RGBA8 0x52474241u // 'RGBA' = kCVPixelFormatType_32RGBA

// 外部 IOSurface 描述(由 Swift 配置)。
struct xr_ext { uint32_t id; int w, h; };
static struct xr_ext g_ext[XR_RING_MAX];
static int g_count;        // 已配置的外部 IOSurface 数(0 = 无外部,走内部回落)
static uint32_t g_pixfmt = XR_PIXFMT_FP16; // 当前出口像素格式(默认 fp16;无外部回落亦用它)
static int g_write_idx;    // 下一帧写哪个环缓冲
static int g_pending_idx = -1; // 已渲染并提交、待下一帧发布的缓冲(-1=无;三缓冲流水线)
static _Atomic uint32_t g_front_id; // 最新完整 IOSurfaceID(消费方读它)
static _Atomic bool g_enabled; // 模式开关:沉浸=true、窗口=false(替代环境变量,线程安全)
// 串行化 app 线程(configure/clear)与 VO 渲染线程(back_tex/publish/destroy)
// 对环状态的访问;g_front_id/g_enabled 走 atomic,消费端高频读不取锁。
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

// 模式开关:由 Swift 在窗口/沉浸切换时设置(set_enabled 见 xr_resident.h),
// vo_gpu_next 每帧/uninit 读取(enabled 为内部跨 TU 符号,vo_gpu_next extern 引用)。
bool xr_resident_enabled(void);
void xr_resident_set_enabled(bool enabled) { atomic_store(&g_enabled, enabled); }
bool xr_resident_enabled(void) { return atomic_load(&g_enabled); }

void xr_resident_destroy(pl_gpu gpu);
pl_tex xr_resident_back_tex(struct mp_log *log, pl_gpu gpu, int w, int h, uint32_t *out_id);
void xr_resident_submit_back(pl_gpu gpu);
bool xr_resident_external_size(int *w, int *h);

static inline int xr_ring_count(void)
{
    return g_count > 0 ? g_count : 1; // 无外部时退化为单缓冲(内部)
}

bool xr_resident_configure_external_iosurfaces(const uint32_t *ids, int count,
                                               int width, int height)
{
    if (!ids || count < 1 || count > XR_RING_MAX || width <= 0 || height <= 0)
        return false;

    struct xr_ext staged[XR_RING_MAX] = {0};
    uint32_t staged_pixfmt = 0;
    for (int i = 0; i < count; i++) {
        if (!ids[i])
            return false;
        IOSurfaceRef io = IOSurfaceLookup(ids[i]);
        if (!io)
            return false;
        uint32_t pf = (uint32_t)IOSurfaceGetPixelFormat(io);
        // [xr] 色彩路由:接受 fp16(HDR)或 8-bit RGBA(SDR);全环必须同格式,否则
        // 绑定纹理会颜色错乱却不报错。格式由 Swift 端按源 HDR 与否选定(ADR 0004/0005)。
        bool ok = IOSurfaceGetWidth(io) == (size_t)width &&
                  IOSurfaceGetHeight(io) == (size_t)height &&
                  (pf == XR_PIXFMT_FP16 || pf == XR_PIXFMT_RGBA8) &&
                  (staged_pixfmt == 0 || staged_pixfmt == pf);
        CFRelease(io);
        if (!ok)
            return false;
        staged_pixfmt = pf;
        staged[i] = (struct xr_ext){ .id = ids[i], .w = width, .h = height };
    }

    pthread_mutex_lock(&g_lock);
    memcpy(g_ext, staged, sizeof(g_ext));
    g_pixfmt = staged_pixfmt;
    g_count = count;
    g_write_idx = 0;
    g_pending_idx = -1;
    atomic_store(&g_front_id, 0);
    pthread_mutex_unlock(&g_lock);
    return true;
}

void xr_resident_clear_external_iosurface(void)
{
    pthread_mutex_lock(&g_lock);
    memset(g_ext, 0, sizeof(g_ext));
    g_count = 0;
    g_pixfmt = XR_PIXFMT_FP16;
    g_write_idx = 0;
    g_pending_idx = -1;
    atomic_store(&g_front_id, 0);
    pthread_mutex_unlock(&g_lock);
}

// [xr] 色彩路由查询(vo_gpu_next 据此设渲染目标传递曲线):
//   8-bit 出口 = IEC sRGB 编码(libplacebo 在 shader 里编码,消费端 `_srgb` 视图硬件解码,互逆);
//   fp16 出口 = 扩展线性(消费端直采)。返回 true = 当前出口要 sRGB 编码。
bool xr_resident_target_is_srgb(void);
bool xr_resident_target_is_srgb(void)
{
    return atomic_load(&g_enabled) && g_pixfmt == XR_PIXFMT_RGBA8;
}

bool xr_resident_external_size(int *w, int *h)
{
    pthread_mutex_lock(&g_lock);
    bool ok = g_count >= 1;
    if (ok) {
        if (w) *w = g_ext[0].w;
        if (h) *h = g_ext[0].h;
    }
    pthread_mutex_unlock(&g_lock);
    return ok;
}

uint32_t xr_resident_front_iosurface_id(void)
{
    return atomic_load(&g_front_id);
}

static void xr_destroy_buf(pl_gpu gpu, int idx)
{
    struct xr_buf *b = &g_res[idx];
    if (b->tex) {
        if (b->gpu == gpu) {
            pl_tex_destroy(gpu, &b->tex);
        } else {
            // 纹理属于别的(可能已销毁的)gpu:跨 gpu 销毁是未定义行为,
            // 丢弃句柄即可(其 Vulkan 资源已随原 gpu 一并消亡)。
            b->tex = NULL;
        }
    }
    if (b->mtltex)
        [b->mtltex release];
    if (b->iosurf)
        CFRelease(b->iosurf);
    memset(b, 0, sizeof(*b));
}

void xr_resident_destroy(pl_gpu gpu)
{
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < XR_RING_MAX; i++)
        xr_destroy_buf(gpu, i);
    g_pending_idx = -1;
    pthread_mutex_unlock(&g_lock);
}

// 确保 g_res[idx] 已按 (w,h) 导入(外部 g_ext[idx] 或内部自建)。尺寸/来源变则重建。
static bool xr_ensure_buf(struct mp_log *log, pl_gpu gpu, int idx, int w, int h)
{
    struct xr_buf *b = &g_res[idx];
    bool want_external = idx < g_count;
    uint32_t want_id = want_external ? g_ext[idx].id : 0;

    bool same = b->tex && b->gpu == gpu && b->w == w && b->h == h &&
                (want_external ? (b->external && b->iosurface_id == want_id)
                               : !b->external);
    if (same)
        return true;

    xr_destroy_buf(gpu, idx); // 尺寸/来源变化 → 重建(边缘:换片/换轨/重配)

    @autoreleasepool {
        id<MTLDevice> dev = xr_get_moltenvk_device(gpu);
        if (!dev)
            dev = MTLCreateSystemDefaultDevice(); // fallback,见 CLAUDE.md 技术债
        if (!dev) {
            mp_msg(log, MSGL_ERR, "[xr] 无法取得 MTLDevice\n");
            return false;
        }

        if (want_external && (g_ext[idx].w != w || g_ext[idx].h != h)) {
            mp_msg(log, MSGL_ERR,
                   "[xr] 外部 IOSurface[%d] 尺寸 %dx%d 与渲染目标 %dx%d 不匹配\n",
                   idx, g_ext[idx].w, g_ext[idx].h, w, h);
            return false;
        }

        // [xr] 色彩路由(ADR 0004/0005):8-bit 出口 = IEC sRGB 编码字节(SDR,4 字节/像素,
        // 带宽腰斩);fp16 出口 = 扩展线性 Display P3(HDR,8 字节/像素)。mpv 写入侧统一用
        // plain(非 _srgb)Metal 视图——libplacebo 在 shader 里按渲染目标 transfer 编码,
        // 消费端再以 `.rgba8Unorm_srgb` 视图硬件解码,严格互逆(见 ADR 0004)。
        bool eightbit = (g_pixfmt == XR_PIXFMT_RGBA8);

        IOSurfaceRef io = NULL;
        if (want_external) {
            io = IOSurfaceLookup(want_id);
        } else {
            // 内部自建仅用于「未配置外部 IOSurface」的回落路径,默认 fp16(g_pixfmt 此时为默认值)。
            NSDictionary *props = @{
                (id)kIOSurfaceWidth:           @(w),
                (id)kIOSurfaceHeight:          @(h),
                (id)kIOSurfaceBytesPerElement: @(eightbit ? 4 : 8),
                (id)kIOSurfacePixelFormat:     @(eightbit ? XR_PIXFMT_RGBA8 : XR_PIXFMT_FP16),
            };
            io = IOSurfaceCreate((CFDictionaryRef)props);
        }
        if (!io) {
            mp_msg(log, MSGL_ERR, "[xr] IOSurface %s 失败\n",
                   want_external ? "Lookup" : "Create");
            return false;
        }

        MTLTextureDescriptor *desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                (eightbit ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA16Float)
                                                               width:w height:h mipmapped:NO];
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        id<MTLTexture> mt = [dev newTextureWithDescriptor:desc iosurface:io plane:0];
        if (!mt) {
            mp_msg(log, MSGL_ERR, "[xr] newTextureWithDescriptor:iosurface 失败\n");
            CFRelease(io);
            return false;
        }

        pl_fmt fmt = eightbit
            ? pl_find_fmt(gpu, PL_FMT_UNORM, 4, 8, 8, PL_FMT_CAP_RENDERABLE)
            : pl_find_fmt(gpu, PL_FMT_FLOAT, 4, 16, 16, PL_FMT_CAP_RENDERABLE);
        if (!fmt) {
            mp_msg(log, MSGL_ERR, "[xr] 找不到 renderable %s pl_fmt\n",
                   eightbit ? "rgba8" : "rgba16f");
            [mt release];
            CFRelease(io);
            return false;
        }

        struct pl_tex_params params = {
            .w = w, .h = h,
            .format = fmt,
            .renderable = true,
            .sampleable = true,
            .import_handle = PL_HANDLE_MTL_TEX,
            .shared_mem = { .handle = { .handle = (void *)mt } },
        };
        pl_tex t = pl_tex_create(gpu, &params);
        if (!t) {
            mp_msg(log, MSGL_ERR, "[xr] pl_tex_create(renderable import) 失败\n");
            [mt release];
            CFRelease(io);
            return false;
        }

        b->iosurf = io;
        b->mtltex = mt;
        b->tex = t;
        b->gpu = gpu;
        b->w = w;
        b->h = h;
        b->iosurface_id = IOSurfaceGetID(io);
        b->external = want_external;
        mp_msg(log, MSGL_INFO,
               "[xr] 常驻 IOSurface[%d] 纹理就绪 %dx%d %s IOSurfaceID=%u %s\n",
               idx, w, h, eightbit ? "RGBA8/sRGB" : "RGBA16F/linear",
               b->iosurface_id, want_external ? "(external)" : "(internal)");
        return true;
    }
}

// 三缓冲:取下一帧要写的「后台缓冲」纹理(在环上轮转,避开当前 front 与待发布)。
pl_tex xr_resident_back_tex(struct mp_log *log, pl_gpu gpu, int w, int h, uint32_t *out_id)
{
    pthread_mutex_lock(&g_lock);
    int idx = g_write_idx % xr_ring_count();
    pl_tex tex = NULL;
    if (xr_ensure_buf(log, gpu, idx, w, h)) {
        if (out_id) *out_id = g_res[idx].iosurface_id;
        tex = g_res[idx].tex;
    }
    pthread_mutex_unlock(&g_lock);
    return tex;
}

// 提交本帧渲染并发布上一帧(三缓冲流水线,ADR 0011)。取代旧的「pl_gpu_finish 全停 + 立即发布」:
//   1) pl_gpu_finish 抽干整条 GPU 队列、每帧阻塞 → 吞吐被串行化(360 4K 实测掉到 ~10fps)。
//   2) 改为 pl_gpu_flush(仅提交、不阻塞)+ 只对「上一帧」那张缓冲 pl_tex_poll 等其写完再发布。
//      上一帧已过了一整个帧间隔,几乎必然完成 → 等待近乎为零;本帧 GPU 工作与 RealityKit 消费并行。
//      三缓冲保证「正写 / 待发布 / 消费中」三张互不重叠,故无撕裂。
// pl_tex_poll 正是 libplacebo 文档点名的用法:外部内存(IOSurface)需知导入纹理何时写完、可安全移交。
// 注:跨设备信号量(pl_vulkan_hold/release)移交是后续优化,但 RealityKit 侧无等待钩子,故在
// 生产者侧用 poll 保证写完是正确做法,而非权宜。
void xr_resident_submit_back(pl_gpu gpu)
{
    pl_gpu_flush(gpu); // 非阻塞提交本帧渲染,确保其尽快入队,流水线才能真正重叠
    pthread_mutex_lock(&g_lock);
    if (g_pending_idx >= 0 && g_res[g_pending_idx].tex) {
        // 只等上一帧那张写完(稳态下几乎即时);不等本帧 → 实现流水线。
        while (pl_tex_poll(gpu, g_res[g_pending_idx].tex, UINT64_MAX))
            ; // 自旋直到 GPU 不再占用该纹理
        atomic_store(&g_front_id, g_res[g_pending_idx].iosurface_id);
    }
    // 本帧(g_write_idx 指向、刚渲染的那张)成为下一次待发布;写指针轮到下一张。
    g_pending_idx = g_write_idx % xr_ring_count();
    g_write_idx = (g_write_idx + 1) % xr_ring_count();
    pthread_mutex_unlock(&g_lock);
}
