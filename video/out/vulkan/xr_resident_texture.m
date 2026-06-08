/*
 * [xr] Enchron fork — 常驻纹理出口(resident_texture)
 *
 * 让 vo_gpu_next 把视频帧渲染进一张「常驻的、IOSurface-backed 的」可渲染纹理,
 * 该 IOSurface 可经 IOSurfaceID 交给外部(Swift / RealityKit)零拷贝共享。
 *
 * 参考:video/out/hwdec/hwdec_vt_pl.m(VideoToolbox → 可采样 pl_tex 的导入范例)。
 * 设计依据:ADR 0001 / 0002。
 */

#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>

#include <string.h>

#include <libplacebo/gpu.h>
#include <libplacebo/vulkan.h>

#include "include/mpv/xr_resident.h"

#include "common/msg.h"
#include "video/out/vulkan/common.h"

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

// 常驻资源(单例,验证阶段足够;生产时应随 vo 实例持有)。
struct xr_resident {
    IOSurfaceRef iosurf;
    id<MTLTexture> mtltex;
    pl_tex tex;
    int w, h;
    uint32_t iosurface_id;
    bool external;
};
static struct xr_resident g_res;

struct xr_resident_external {
    uint32_t iosurface_id;
    int w, h;
};
static struct xr_resident_external g_ext;

void xr_resident_destroy(pl_gpu gpu);
pl_tex xr_resident_get(struct mp_log *log, pl_gpu gpu, int w, int h, uint32_t *out_id);
bool xr_resident_check_nonzero(struct mp_log *log, pl_gpu gpu);

bool xr_resident_configure_external_iosurface(uint32_t iosurface_id, int width, int height)
{
    if (!iosurface_id || width <= 0 || height <= 0)
        return false;

    IOSurfaceRef io = IOSurfaceLookup(iosurface_id);
    if (!io)
        return false;

    bool ok = IOSurfaceGetWidth(io) == (size_t)width &&
              IOSurfaceGetHeight(io) == (size_t)height;
    CFRelease(io);
    if (!ok)
        return false;

    g_ext = (struct xr_resident_external) {
        .iosurface_id = iosurface_id,
        .w = width,
        .h = height,
    };
    return true;
}

void xr_resident_clear_external_iosurface(void)
{
    memset(&g_ext, 0, sizeof(g_ext));
}

bool xr_resident_get_info(uint32_t *iosurface_id, int *width, int *height,
                          bool *uses_external_iosurface)
{
    if (!g_res.iosurf)
        return false;
    if (iosurface_id) *iosurface_id = g_res.iosurface_id;
    if (width) *width = g_res.w;
    if (height) *height = g_res.h;
    if (uses_external_iosurface) *uses_external_iosurface = g_res.external;
    return true;
}

void xr_resident_destroy(pl_gpu gpu)
{
    if (g_res.tex)
        pl_tex_destroy(gpu, &g_res.tex);
    if (g_res.mtltex)
        [g_res.mtltex release];
    if (g_res.iosurf)
        CFRelease(g_res.iosurf);
    memset(&g_res, 0, sizeof(g_res));
}

// 取得/创建一张 w×h 的常驻 renderable IOSurface 纹理。按尺寸缓存复用;尺寸变则重建。
// 返回可作为 render target 的 pl_tex,并经 out_id 输出 IOSurfaceID(供外部共享)。
pl_tex xr_resident_get(struct mp_log *log, pl_gpu gpu, int w, int h, uint32_t *out_id)
{
    bool want_external = g_ext.iosurface_id != 0;
    bool same_external = !want_external ||
                         (g_res.external && g_res.iosurface_id == g_ext.iosurface_id);
    if (g_res.tex && g_res.w == w && g_res.h == h && same_external) {
        if (out_id) *out_id = g_res.iosurface_id;
        return g_res.tex;
    }
    xr_resident_destroy(gpu); // 尺寸变化 → 重建(边缘情况:换片/换轨)

    @autoreleasepool {
        id<MTLDevice> dev = xr_get_moltenvk_device(gpu);
        if (!dev)
            dev = MTLCreateSystemDefaultDevice(); // fallback,见 CLAUDE.md 技术债
        if (!dev) {
            mp_msg(log, MSGL_ERR, "[xr] 无法取得 MTLDevice\n");
            return NULL;
        }

        if (want_external && (g_ext.w != w || g_ext.h != h)) {
            mp_msg(log, MSGL_ERR,
                   "[xr] 外部 IOSurface 尺寸 %dx%d 与渲染目标 %dx%d 不匹配\n",
                   g_ext.w, g_ext.h, w, h);
            return NULL;
        }

        IOSurfaceRef io = NULL;
        if (want_external) {
            io = IOSurfaceLookup(g_ext.iosurface_id);
        } else {
            NSDictionary *props = @{
                (id)kIOSurfaceWidth:           @(w),
                (id)kIOSurfaceHeight:          @(h),
                (id)kIOSurfaceBytesPerElement: @(4),
                (id)kIOSurfacePixelFormat:     @(0x52474241), // 'RGBA'
            };
            io = IOSurfaceCreate((CFDictionaryRef)props);
        }
        if (!io) {
            mp_msg(log, MSGL_ERR, "[xr] IOSurface %s 失败\n",
                   want_external ? "Lookup" : "Create");
            return NULL;
        }

        MTLTextureDescriptor *desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:w height:h mipmapped:NO];
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        id<MTLTexture> mt = [dev newTextureWithDescriptor:desc iosurface:io plane:0];
        if (!mt) {
            mp_msg(log, MSGL_ERR, "[xr] newTextureWithDescriptor:iosurface 失败\n");
            CFRelease(io);
            return NULL;
        }

        pl_fmt fmt = pl_find_fmt(gpu, PL_FMT_UNORM, 4, 8, 8, PL_FMT_CAP_RENDERABLE);
        if (!fmt) {
            mp_msg(log, MSGL_ERR, "[xr] 找不到 renderable rgba8 pl_fmt\n");
            [mt release];
            CFRelease(io);
            return NULL;
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
            return NULL;
        }

        g_res.iosurf = io;
        g_res.mtltex = mt;
        g_res.tex = t;
        g_res.w = w;
        g_res.h = h;
        g_res.iosurface_id = IOSurfaceGetID(io);
        g_res.external = want_external;
        if (out_id) *out_id = g_res.iosurface_id;
        mp_msg(log, MSGL_INFO, "[xr] 常驻 IOSurface 纹理就绪 %dx%d IOSurfaceID=%u %s\n",
               w, h, g_res.iosurface_id, want_external ? "(external)" : "(internal)");
        return t;
    }
}

// 自验:GPU 渲染完成后,从 IOSurface 抽样像素,确认确实画进了非空内容。
bool xr_resident_check_nonzero(struct mp_log *log, pl_gpu gpu)
{
    if (!g_res.iosurf)
        return false;
    pl_gpu_finish(gpu); // 确保 GPU 写入完成后再 CPU 读
    IOSurfaceLock(g_res.iosurf, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *base = IOSurfaceGetBaseAddress(g_res.iosurf);
    size_t bpr = IOSurfaceGetBytesPerRow(g_res.iosurf);
    unsigned long sum = 0;
    for (int y = 0; y < g_res.h; y += 16) {
        for (int x = 0; x < g_res.w; x += 16) {
            const uint8_t *px = base + (size_t)y * bpr + (size_t)x * 4;
            sum += px[0] + px[1] + px[2];
        }
    }
    IOSurfaceUnlock(g_res.iosurf, kIOSurfaceLockReadOnly, NULL);
    mp_msg(log, MSGL_INFO, "[xr] IOSurface 抽样像素和=%lu %s\n",
           sum, sum > 0 ? "(非空)" : "(全黑)");
    return sum > 0;
}
