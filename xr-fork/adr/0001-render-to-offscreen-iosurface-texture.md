# ADR 0001 — 改 mpv 源码,让 gpu-next 渲染到常驻 IOSurface 纹理

状态:Accepted(方向已定;阶段 0a 已验证「改→编→跑→验」闭环可行,实现待续)
日期:2026-06-08
范围:Enchron / XrPlayer 的 mpv fork(`enchron` 分支)

## 背景

Enchron 是 visionOS 沉浸视频播放器,需要把视频帧作为纹理,贴到 RealityKit 的球面 /
沉浸空间模型上(全景、虚拟影院等)。阶段 1 的 macOS 验证路径是
IOSurface-backed `MTLTexture` → `TextureResource.__texture(from:)`。

现状(集成方式):
- 通过 **MPVKit**(预编译 SPM 二进制包)引入 libmpv,默认 `vo=gpu-next` + Vulkan/MoltenVK。
- 拿纹理的方式是 **drawable-hack**:把 `CAMetalLayer` 指针经 `--wid` 交给 mpv,再子类化
  `CAMetalLayer` 重写 `nextDrawable()` 偷出 `lastVendedDrawable`,用 CADisplayLink 轮询读取
  `drawable.texture` 拷进 `LowLevelTexture`。
- 另有 `vo=libmpv` 软渲染(`mpv_render_context_render` → CVPixelBuffer)作 fallback。

平台事实:
- libmpv 公开 render API 只有 `OPENGL` 和 `SW` 两种,**没有 Metal**;其 GPU backend 仅注册
  OpenGL,且 visionOS 无 OpenGL。
- mac/visionOS 上 `vo_gpu_next` 唯一 GPU 路径是 Vulkan → MoltenVK → CAMetalLayer。

## 问题

drawable-hack 的脆弱性:`CAMetalDrawable` 为「画完即上屏即回收」设计,present 后内容不保证有效;
swapchain 只有少数几张轮转,扣住不放会破坏呈现循环;异步轮询读取存在撕裂/竞态风险;且仍有一次
drawable→LowLevelTexture 的拷贝。它本质是「停在借来的画布上」。

## 决策

Fork mpv,在 `vo_gpu_next` 已有的**截图路径**(`pl_tex_create` → `pl_render_image` →
`pl_tex_download`,见 `video/out/vo_gpu_next.c` 的 `video_screenshot`)基础上,新增一条
「非窗口 / 离屏」出口:

- 渲染到一张**常驻的、IOSurface-backed 的纹理**(归我们所有,不参与任何 swapchain 呈现循环)。
- 把该纹理的句柄(IOSurface / MTLTexture)暴露给 Swift 侧。
- RealityKit 直接采样同一张 IOSurface-backed `MTLTexture`,实现零拷贝。
- **窗口模式继续走上游 `draw_frame` 的 swapchain 呈现,不改动**。

## 考虑过的替代方案

| 方案 | 否决理由 |
|---|---|
| SW render(`MPV_RENDER_API_TYPE_SW` → CVPixelBuffer) | CPU 做色彩/缩放/字幕,4K/HDR 吃力,且每帧一次 CPU→GPU 拷贝 |
| GL + IOSurface 互操作 | macOS OpenGL 已废弃,**visionOS 根本无 OpenGL**,对 XR 死路 |
| 继续用 drawable-hack | 见「问题」:正确性/同步隐患 + 仍有拷贝;停在借来的画布上 |
| 直接拿 swapchain 的 VkImage | 该画布生命周期归 CAMetalLayer 呈现循环,语义上不可安全扣留 |

## 后果

正面:
- 零拷贝(共用 IOSurface),且保留 mpv/libplacebo 完整 GPU 后处理(色彩管理、HDR、字幕)。
- 出口语义干净:画完即可被 RealityKit 长期采样,无呈现循环约束。

代价 / 风险:
- 进入「维护 fork」状态,需定期 rebase 上游(靠改动纪律把成本压到「简单 review」级)。
- **阶段 1 结论**:macOS tracer app 已证明 mpv 可写入 Swift 提供的 IOSurface-backed
  `MTLTexture`,RealityKit 可实时采样。后续风险集中在同步、设备一致性和 visionOS 移植。

## 许可证备注

当前用 MPVKit-**GPL** 且 Enchron 仓库已开源,GPL 合规无额外负担。需另行处理的是
**GPL 软件上 App Store 的已知争议**(发版前评估,不阻塞开发)。
