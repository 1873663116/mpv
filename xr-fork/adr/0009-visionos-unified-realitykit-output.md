# ADR 0009 — visionOS 输出架构:窗口与沉浸统一走 IOSurface→RealityKit(否决分离 CAMetalLayer)

状态:Accepted(沉浸路径真机已验;窗口路径同机制复用)｜ 日期:2026-06-16
上承 [ADR 0001](0001-render-to-offscreen-iosurface-texture.md)、[ADR 0003](0003-windowless-producer-and-double-buffer.md)、[ADR 0008](0008-software-shoulder-tonemap-in-mpv.md)

## 背景

visionOS 上,「窗口/平面 2D 播放」该怎么出有两种放法(沉浸已由 ADR 0001/0003 定死:IOSurface→RealityKit 球面):

- **Option A(统一)**:窗口也走 IOSurface(rgba16Float)→ RealityKit LowLevelTexture,画在 `WindowGroup` 里一张平面 quad 上。窗口与沉浸共用同一 producer+consumer,只差**场景容器**(WindowGroup vs ImmersiveSpace)与**网格**(quad vs sphere),mpv 侧零差异。
- **Option B(分离)**:窗口让 mpv 经 MoltenVK swapchain **直接呈现到** SwiftUI 托管的 CAMetalLayer(树里已有 AppKit-free 的 `context_moltenvk.m` 半成品 producer,经 `--wid` 取 layer);沉浸仍走 IOSurface→RealityKit。两条路。

## 关键事实裁决(多代理调研 + 双方对辩 + 对抗审查,2026-06-16)

促成决策的胜负手:**「窗口 CAMetalLayer 能否白嫖系统动态 tone-map(贴 AV)」——结论是不能 / 查无实证。**

- 窗口挂 CAMetalLayer:**可行**,且是 Apple 官方推荐的平面 Metal 路径(WWDC24-10093 + DTS 论坛明说);`context_moltenvk.m` 已能 AppKit-free 呈现。阻断 mpv 原生窗口路径的是 **AppKit**(mac_common.swift / NSApp),不是 Metal 本身。
- 但系统**动态** tone-map:**visionOS 上拿不到**。① Apple「Metal layer 系统 tone-map」文档族通篇 macOS-only,从不点名 visionOS;② tvOS 前例——同样的 `wantsExtendedDynamicRangeContent` badge 在,功能却是 no-op;③ 让它「动态」的 `UIScreen.currentEDRHeadroom` 在 visionOS **根本不存在**;④ 零正面实证,官方窗口 Metal session(WWDC24-10093)通篇不提 EDR。动态 tone-mapper 在 visionOS 是 **AVFoundation/AVKit 独占**(与 ADR 0008 沉浸路径同一结论)。

胜负手既已中性化,决策塌缩为「一套机制 vs 两套机制」。

## 决策

**采用 Option A:窗口与沉浸统一走 IOSurface→RealityKit。** mpv 永远是 producer(`macvk_resident` 无窗上下文 + 双缓冲 IOSurface 环),消费端永远是 RealityKit(零拷贝纹理 + `UnlitMaterial`);窗口 vs 沉浸只是消费端换场景容器与网格,mpv 侧零差异。

四维(对辩 + 审查净结论):

| 维度 | A 统一 | B 分离 |
|---|---|---|
| 性能 | 一张零拷贝 foveated quad;主成本(解码+tone-map+写)在 mpv 上游、两路相同 | swapchain 理论更短,但窗口 CAMetalLayer **仍经系统合成器**(非直扫描)、delta 无实测 |
| 复杂度 | **一套** producer+consumer,已设备验证、零新传输 | **两套**永久维护;resize/control 桥未建(`moltenvk_control=VO_NOTIMPL`) |
| 可维护性 | 一套色彩契约,沉浸契约即窗口契约 | EDR/colorspace/resize/lifecycle/热切测试矩阵翻倍,违 fork「最小表面积」纪律 |
| 未来 | 唯一通向立体(MV-HEVC)/曲面窗/ornament/窗↔沉浸复用同一纹理;Apple 指引「移向 LowLevelTexture 获最大控制」 | 平面 CAMetalLayer 是 2D 死胡同 |

## 不选什么 / 期权

- `context_moltenvk.m` 及其注册(`video/out/gpu/context.c`、`video/out/vulkan/common.h`、`meson.build`、`meson.options` 的改动)是 **Option B 的半成品种子**:AppKit-free,经 `vulkan and moltenvk` 编译守卫(不依赖 cocoa/swift,能在 visionOS 构建里存活)。**保留作参考与期权,不在生产路径**(当前未跟踪)。它同时是个合法的通用 macOS 窗口 swapchain 上下文(经 `--wid`),留着无害。

## 翻盘条件(写明以免将来反复纠结)

仅当**同时**满足:① 出现「必须 app 自持亚帧级呈现调度(CADisplayLink)保 A/V 同步、而 RealityKit commit 驱动满足不了」的硬需求;② 真机实测 MoltenVK `VK_EXT_metal_surface` swapchain 确能呈现在 visionOS 2D 窗口(repo 从未跑过这条)——Option B 的窗口分离才重新可议。

## 已知代价(如实记;均属统一路径内可改,非拆分理由)

- 当前每发布帧 `pl_gpu_finish` 全停 GPU(`video/out/vo_gpu_next.c`)→ 待换异步跨设备 fence。
- 呈现时序交 RealityKit commit 驱动,无 app 自持 CADisplayLink;对上游已定速的 mpv 足够。

## 后果

- 生产接入只需对接**一套** producer/consumer + **一组**色彩契约(见 `INTEGRATION.md`、ADR 0008)。
- 上游 rebase:本决策不新增 libplacebo/mpv C 改动面;moltenvk 种子若永久不用,可后续连注册一并回收。
