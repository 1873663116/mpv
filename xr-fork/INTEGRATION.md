# 接入指南 — 把本 fork 的 libmpv 当「视频帧 → RealityKit 纹理」生产者用

给下一个 Agent / 接入 Enchron 生产管线用。读完应能正确接上,知道边界在哪。
背景与权衡见同目录 `adr/`;本文只讲「怎么接」。

## 一句话架构

mpv(VideoToolbox 硬解 → libplacebo → Vulkan/MoltenVK)把视频帧渲染进一张**常驻、IOSurface-backed 的 fp16 Metal 纹理**;你的 app 用 RealityKit **零拷贝**采样它。**窗口与沉浸都走这一条**(ADR 0009):mpv 永远是 producer,RealityKit 永远是 consumer;**窗口 = 平面 quad、沉浸 = 球面**,mpv 侧零差异。别让 mpv 自己开窗——原生窗口路径绑 AppKit,visionOS 跑不了。

## 你只依赖这两样(其余 libmpv 不知道你存在)

1. **`include/mpv/xr_resident.h` 的 4 个函数**(唯一对外耦合面):

   ```c
   void     xr_resident_set_enabled(bool enabled);   // 出口总开关:true=渲染进你的 IOSurface
   bool     xr_resident_configure_external_iosurfaces(const uint32_t *ids, int count,
                                                       int width, int height); // 交 1~2 张 IOSurface 组成写/读环
   uint32_t xr_resident_front_iosurface_id(void);    // 取「最新画好并发布」的 IOSurfaceID(读它绝不撕裂)
   void     xr_resident_clear_external_iosurface(void);
   ```
   > 注:header 注释里「窗口=false 走原 mpv 窗口路径」是 **macOS** 语义。visionOS 无原生窗口路径,**两种模式都 enabled=true 走 IOSurface**,窗口/球面由你消费端决定(ADR 0009)。

2. **标准 libmpv client API**(`mpv_create` / `mpv_initialize` / `mpv_set_option_string` / `command` / `loadfile` …)。

接入顺序:建 mpv → 设选项(见下)→ 建你的 IOSurface 环 → `configure_external_iosurfaces` → `set_enabled(true)` → `initialize` → `loadfile` → 每帧 `front_iosurface_id()` 采样。

## 起 mpv 的关键选项(照搬)

```
vo=gpu-next, gpu-api=vulkan, gpu-context=macvk_resident,
hwdec=videotoolbox            # 零拷贝硬解;绝不能静默退软解
```
**色彩契约**(沉浸 HDR 默认,ADR 0008;窗口同一组):直接照搬 `verify-visionos/Sources/App/MpvPlayer.swift` 的 `colorOptions()` —— 真机签收的 device-tuned 一组,真机再用调参面板微调。`target-prim` / `target-trc` **焊死** display-p3 / linear(改它 = 放弃 mpv 出口)。

## 消费端怎么接(照参考实现,**待归档、非依赖**)

参考消费者:`xr-fork/verify-visionos/Sources/App/`(macOS 旧版在 `xr-fork/verify/`):
- `ResidentVideoSurface.swift`:建 `kCVPixelFormatType_64RGBAHalf` IOSurface 环 → `makeTexture(iosurface:)` → `TextureResource.__texture(from:)`,**双缓冲防撕裂**(消费在用的 buffer 不可改,见 `LowLevelDeviceResource` 契约)。
- `MpvPlayer.swift`:libmpv 生命周期 + `colorOptions()`。
- 材质:`UnlitMaterial(applyPostProcessToneMap: false)` —— **必须 false**,否则 RealityKit 默认 tone-map 会把 HDR 压灰。
- visionOS 27 公开零拷贝入口 `LowLevelTexture.init(deviceResource:using:)`(包 IOSurface)可替私有 `__texture(from:)`,作独立小重构。

## 打包(visionOS xcframework)

用 **MPVKit**(基线恰为 mpv v0.41.0 + libplacebo 7.360.1 + MoltenVK 1.4.1,与本仓库一致)fork 后:
- 改本 fork 的 C 源后,把改过的文件 `cp` 进 `MPVKit/dist/libmpv-v0.41.0/` **同路径**,再 `make build platform=xros`(meson 全量重编,必带新改动;`grep` xcframework 二进制可证改动已入)。
- ⚠️ MPVKit 的 `0001-player-add-moltenvk-context.patch` 改了与我们相同的两个文件 → 须把补丁**合进 enchron 分支再删脚本侧 patch**。
- 「只重 libmpv 时 FFmpeg xcframework 被误删」等两个重建坑详见记忆 `mpv-visionos-hdr-fp16-contract`。

## 边界(进来先知道这些)

1. **visionOS 没有「mpv 自开窗」**:窗口模式也走 IOSurface→RealityKit;贴球面还是贴 2D 窗口由你(Enchron)决定。
2. **色彩是一组静态参数**:贴近 AV 但非逐场景自适应;极亮场景可能偏硬(ADR 0008 已接受的取舍)。AV 的动态系统 tone-map 是 AVPlayer 独占、本路径拿不到。
3. **每帧 `pl_gpu_finish` 全停**:当前用全停屏障保正确,生产应换异步跨设备 fence(性能 TODO,vo_gpu_next.c)。
4. **模拟器 SDR-clamp**:看不到 HDR 绝对亮度,只能验字节级数值/几何;HDR 观感只能真机裁。
5. **Option B(窗口直写 CAMetalLayer)已评估搁置**:`video/out/vulkan/context_moltenvk.m` 是其半成品种子(AppKit-free),不在生产路径(ADR 0009)。

## 本地冒烟(macOS,验出口仍活)

```bash
meson setup build -Dcplayer=true -Dlibmpv=false -Dtests=false \
  -Dlua=disabled -Djavascript=disabled \
  -Dvulkan=enabled -Dvideotoolbox-pl=disabled -Dcocoa=enabled -Dgl=enabled
meson compile -C build          # 改 C 后快编自检
```
常驻纹理 + 热切的完整复跑见根 `CLAUDE.md`「本地构建与验证」。
