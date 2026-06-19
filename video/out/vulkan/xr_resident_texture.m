/*
 * [xr] Enchron fork — 常驻纹理出口(resident_texture)
 *
 * 让 vo_gpu_next 把视频帧渲染进「常驻的、IOSurface-backed 的」可渲染纹理,
 * 该 IOSurface 可经 IOSurfaceID 交给外部(Swift / RealityKit)零拷贝共享。
 *
 * 门①(共享纹理写/读同步,见 ADR 0003):用 2 张 IOSurface 双缓冲环——
 * mpv 在两张之间交替写「后台缓冲」,渲染+同步完成后把它「发布」为最新完整帧;
 * 消费方(RealityKit)只读已发布的那张,绝不读 mpv 正在写的那张 → 无撕裂。
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

#define XR_RING_MAX 2

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

// 外部 IOSurface 描述(由 Swift 配置)。
struct xr_ext { uint32_t id; int w, h; };
static struct xr_ext g_ext[XR_RING_MAX];
static int g_count;        // 已配置的外部 IOSurface 数(0 = 无外部,走内部回落)
static int g_write_idx;    // 下一帧写哪个环缓冲
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
void xr_resident_publish_front(uint32_t iosurface_id);
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
    for (int i = 0; i < count; i++) {
        if (!ids[i])
            return false;
        IOSurfaceRef io = IOSurfaceLookup(ids[i]);
        if (!io)
            return false;
        bool ok = IOSurfaceGetWidth(io) == (size_t)width &&
                  IOSurfaceGetHeight(io) == (size_t)height &&
                  // [xr] 像素格式必须是 fp16 RGBA(64RGBAHalf / 'RGhA'),与渲染目标
                  // (RGBA16Float)及内部自建缓冲一致;否则绑定纹理会颜色错乱却不报错。
                  IOSurfaceGetPixelFormat(io) == 0x52476841;
        CFRelease(io);
        if (!ok)
            return false;
        staged[i] = (struct xr_ext){ .id = ids[i], .w = width, .h = height };
    }

    pthread_mutex_lock(&g_lock);
    memcpy(g_ext, staged, sizeof(g_ext));
    g_count = count;
    g_write_idx = 0;
    atomic_store(&g_front_id, 0);
    pthread_mutex_unlock(&g_lock);
    return true;
}

void xr_resident_clear_external_iosurface(void)
{
    pthread_mutex_lock(&g_lock);
    memset(g_ext, 0, sizeof(g_ext));
    g_count = 0;
    g_write_idx = 0;
    atomic_store(&g_front_id, 0);
    pthread_mutex_unlock(&g_lock);
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

        IOSurfaceRef io = NULL;
        if (want_external) {
            io = IOSurfaceLookup(want_id);
        } else {
            // [xr] HDR 出口(ADR 0005):fp16 RGBA(每像素 8 字节)承载扩展线性 Display P3。
            // 外部 IOSurface 由 Swift 端以同格式创建(kCVPixelFormatType_64RGBAHalf);
            // 这里的内部自建仅在「未配置外部 IOSurface」的回落路径用到,格式须与之一致。
            NSDictionary *props = @{
                (id)kIOSurfaceWidth:           @(w),
                (id)kIOSurfaceHeight:          @(h),
                (id)kIOSurfaceBytesPerElement: @(8),
                (id)kIOSurfacePixelFormat:     @(0x52476841), // 'RGhA' = kCVPixelFormatType_64RGBAHalf
            };
            io = IOSurfaceCreate((CFDictionaryRef)props);
        }
        if (!io) {
            mp_msg(log, MSGL_ERR, "[xr] IOSurface %s 失败\n",
                   want_external ? "Lookup" : "Create");
            return false;
        }

        MTLTextureDescriptor *desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                               width:w height:h mipmapped:NO];
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        id<MTLTexture> mt = [dev newTextureWithDescriptor:desc iosurface:io plane:0];
        if (!mt) {
            mp_msg(log, MSGL_ERR, "[xr] newTextureWithDescriptor:iosurface 失败\n");
            CFRelease(io);
            return false;
        }

        pl_fmt fmt = pl_find_fmt(gpu, PL_FMT_FLOAT, 4, 16, 16, PL_FMT_CAP_RENDERABLE);
        if (!fmt) {
            mp_msg(log, MSGL_ERR, "[xr] 找不到 renderable rgba16f pl_fmt\n");
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
               "[xr] 常驻 IOSurface[%d] 纹理就绪 %dx%d IOSurfaceID=%u %s\n",
               idx, w, h, b->iosurface_id, want_external ? "(external)" : "(internal)");
        return true;
    }
}

// 双缓冲:取下一帧要写的「后台缓冲」纹理(在环上交替,避开当前 front)。
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

// 渲染+同步完成后调用:把刚写完的后台缓冲发布为 front,并把写指针移到另一张。
void xr_resident_publish_front(uint32_t iosurface_id)
{
    pthread_mutex_lock(&g_lock);
    atomic_store(&g_front_id, iosurface_id);
    g_write_idx = (g_write_idx + 1) % xr_ring_count();
    pthread_mutex_unlock(&g_lock);
}
