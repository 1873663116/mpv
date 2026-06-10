/* Fork-only Enchron XR resident texture bridge.
 *
 * This header is intentionally separate from the upstream libmpv API surface.
 * It exposes the stage-1 IOSurface handoff used by xr-fork/verify.
 */

#ifndef MPV_XR_RESIDENT_H_
#define MPV_XR_RESIDENT_H_

#include <stdbool.h>
#include <stdint.h>

#include "client.h"

#ifdef __cplusplus
extern "C" {
#endif

// 模式开关:沉浸=true(渲染进 IOSurface)、窗口=false(走原 mpv 窗口路径)。
// 线程安全,可在运行时热切;替代早期的 XR_RESIDENT 环境变量。
MPV_EXPORT void xr_resident_set_enabled(bool enabled);
// 门① 双缓冲:注册 1~2 张外部 IOSurface 组成写/读环(见 ADR 0003)。
MPV_EXPORT bool xr_resident_configure_external_iosurfaces(const uint32_t *ids,
                                                          int count,
                                                          int width,
                                                          int height);
// 消费方每帧查询:最新「写完并发布」的 IOSurfaceID(读它绝不撕裂)。
MPV_EXPORT uint32_t xr_resident_front_iosurface_id(void);
MPV_EXPORT void xr_resident_clear_external_iosurface(void);

#ifdef __cplusplus
}
#endif

#endif
