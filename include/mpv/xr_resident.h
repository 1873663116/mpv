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

MPV_EXPORT bool xr_resident_configure_external_iosurface(uint32_t iosurface_id,
                                                         int width,
                                                         int height);
MPV_EXPORT void xr_resident_clear_external_iosurface(void);
MPV_EXPORT bool xr_resident_get_info(uint32_t *iosurface_id,
                                     int *width,
                                     int *height,
                                     bool *uses_external_iosurface);

#ifdef __cplusplus
}
#endif

#endif
