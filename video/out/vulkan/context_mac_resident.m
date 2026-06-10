/*
 * [xr] Enchron fork — 无窗 surfaceless Vulkan 上下文(macvk_resident)
 *
 * 与 context_mac.m(窗口上下文)并列的「第三条出口」专用上下文:
 * 只建 MoltenVK 设备,不建窗口、不建 surface、不建 swapchain。
 * mpv 在此上下文下不向任何屏幕呈现,只把帧渲染进外部导入的 IOSurface
 * (见 video/out/vulkan/xr_resident_texture.m 与 ADR 0003)。
 *
 * 选用方式:--gpu-api=vulkan --gpu-context=macvk_resident
 * 窗口模式仍走 context_mac.m(macvk),本文件零改动于上游。
 *
 * 本文件刻意不依赖 cocoa 窗口栈(MacCommon),以便同一逻辑可移植到 visionOS。
 */

#include "video/out/gpu/context.h"

#include "common.h"
#include "context.h"
#include "utils.h"

struct priv {
    struct mpvk_ctx vk;
};

static void mac_vk_resident_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;

    ra_vk_ctx_uninit(ctx);
    mpvk_uninit(&p->vk);
}

static void mac_vk_resident_swap_buffers(struct ra_ctx *ctx)
{
    // 无呈现链:不向任何 swapchain 呈现。帧已经在 IOSurface 里,无事可做。
}

static bool mac_vk_resident_init(struct ra_ctx *ctx)
{
    // 仅允许显式 --gpu-context=macvk_resident 选用,绝不参与 auto 探测
    // (否则窗口路径偶发失败时会静默回落到无窗,行为迷惑)。
    if (ctx->opts.probing)
        return false;

    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    struct mpvk_ctx *vk = &p->vk;
    int msgl = MSGL_ERR;

    // 实例带上 metal surface 扩展(无害):我们不建 surface,只为拿到能导出
    // Metal 对象的 MoltenVK 实例/设备。
    if (!mpvk_init(vk, ctx, VK_EXT_METAL_SURFACE_EXTENSION_NAME)) {
        MP_MSG(ctx, msgl, "[xr] mpvk_init 失败\n");
        goto error;
    }

    // check_visible 留空:headless swapchain 无 start_frame,VO 不会因可见性跳过渲染;
    // 验证夹具也加了 force-render=yes。
    struct ra_ctx_params params = {
        .swap_buffers = mac_vk_resident_swap_buffers,
    };

    if (!ra_vk_ctx_init_headless(ctx, vk, params)) {
        MP_MSG(ctx, msgl, "[xr] ra_vk_ctx_init_headless 失败\n");
        goto error;
    }

    MP_INFO(ctx, "[xr] 无窗 surfaceless 上下文就绪(macvk_resident,无 swapchain)\n");
    return true;

error:
    mac_vk_resident_uninit(ctx);
    return false;
}

static bool mac_vk_resident_reconfig(struct ra_ctx *ctx)
{
    // 无窗口可配置;尺寸由外部 IOSurface 决定。
    return true;
}

static int mac_vk_resident_control(struct ra_ctx *ctx, int *events, int request,
                                   void *arg)
{
    return VO_NOTIMPL;
}

const struct ra_ctx_fns ra_ctx_vulkan_mac_resident = {
    .type        = "vulkan",
    .name        = "macvk_resident",
    .description = "mac/Vulkan headless (Enchron resident IOSurface 出口)",
    .reconfig    = mac_vk_resident_reconfig,
    .control     = mac_vk_resident_control,
    .init        = mac_vk_resident_init,
    .uninit      = mac_vk_resident_uninit,
};
