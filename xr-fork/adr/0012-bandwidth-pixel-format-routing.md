# ADR 0012 — 按内容路由出口像素格式(SDR 8-bit / HDR 10-bit PQ),冲内存带宽

状态:Phase 1 已实现(待真机签收)· Phase 2 待做 ｜ 日期:2026-06-21 ｜ 上承:[ADR 0004](0004-color-contract.md)、[ADR 0005](0005-fp16-hdr-exit.md)

## 背景:真正的瓶颈是内存带宽,不是算力

ADR 0011 上了三缓冲后,真机仍卡:**videoFPS ≈ 源帧率的 ~0.4 倍**,renderFPS 上不到 90。
按消去法逐一排除(都经真机或 Mac 证实):非解码、非编码(AV1/HEVC 同样卡)、非分辨率本身、非投影
(球/半球都卡)、非 mpv 生产路径(Mac 吞吐夹具喂 360 4K **满 25fps、零丢**)。把渲染分辨率从 8K 压到
1920 后,renderFPS 70→136、videoFPS 10→20——**帧率随渲染目标尺寸大幅变动**,这是带宽签名,不是算力签名。

根因:我们把每帧摊成一张 **fp16 RGBA(8 字节/像素,等价 4:4:4)** 的大纹理。8K 等距一帧 = 7680×3840×8
≈ **236 MB**。mpv 每帧整张写、RealityKit 每个渲染周期整张采样,叠加双眼画面写出,轻松吃掉数十 GB/s,
逼近 M 系列统一内存带宽天花板。GPU「满」的是带宽——核心在空等数据,不在做数学(几何仅 1.6 万三角形、
Unlit 零光照)。降分辨率有效但**有损画质,是"硬吃",只配当调试开关**。

Apple 官方(WWDC25-296/297)做高分辨率沉浸视频靠三件事,**没有一件是 mipmap**:① 静态注视点
(8K 采集→4320×4320 串流,边缘降密度、中心满,感知无损而字节减约 3/4);② 全程原生 YUV + 系统视频
硬件路;③ 投影交系统(APMP 元数据 + `VideoPlayerComponent` 自建网格)。三者全绑死 AVPlayer,mpv 路
拿不到,只能学其原则:**别摊 fp16 RGBA 4:4:4,按内容选最省字节的格式。**

## 决策:播放前按源元数据路由像素格式

| 源 | 出口纹理 | 字节/px | 消费端解码 |
|---|---|---|---|
| SDR(含 SDR 10-bit,靠 mpv 抖动降 8-bit) | 8-bit sRGB(Display P3) | 4 | GPU 自动(`.rgba8Unorm_srgb` 视图),无 shader |
| HDR(PQ/HLG) | **10-bit PQ**(Display P3) | 4 | **ShaderGraph PQ→线性 + EDR 标量**(Phase 2) |
| HDR→SDR 回退 / 兜底 | 8-bit sRGB | 4 | 同 SDR |
| fp16 线性(现默认,保底) | fp16 扩展线性 | 8 | 直采(现 Unlit 路径) |

相对原 fp16(8B)一律腰斩。SDR 零画质损失;HDR 10-bit PQ 是把 fp16 的"线性光"换成感知均匀的 PQ 编码
(10-bit 线性会带状,PQ 不会),故必须配消费端解码 shader。

**焊死的分工**:mpv(libplacebo)继续包办全部 tone-map / 测峰 / 色域 / 峰值(沿用 ADR 0008 调好的值),
只把出口 transfer 从 `linear` 换成 `srgb`(SDR)或 `pq`(HDR)。消费端 shader 只做 EOTF + 一个 EDR 标量,
**绝不把调色逻辑搬进 shader**,否则前期真机调的色全废。

**平台约束(已查实)**:visionOS 不支持手写 Metal `CustomMaterial`,自定义材质只能用
`ShaderGraphMaterial`(MaterialX 节点图)。故 Phase 2 的 PQ 解码用 ShaderGraph(可借 `ShaderGraphCoder`
用 Swift 写),不是 Metal shader。

**路由时机**:`loadfile` 前用 AVFoundation 读视频轨 transfer/primaries 判 HDR(PQ/HLG/BT.2020),
选格式后建对应 IOSurface。auto 默认 + 手动覆盖开关(`auto/forceSDR/forceHDR`);换格式走 reload 重建面。

## Phase 1 实现(本 ADR 已落地的部分)

- C 侧:`xr_resident_texture.m` 早有 8-bit 路由(`XR_PIXFMT_RGBA8` + 读 `IOSurfaceGetPixelFormat` 自识别);
  本次补上 `vo_gpu_next.c` 的缺口——渲染目标 transfer 按 `xr_resident_target_is_srgb()` 在 `SRGB`/`LINEAR`
  间切(原来硬编码 `LINEAR`,8-bit 路因此从没真正跑通)。
- Swift 侧:`XRColorRoute`/`XRRouteMode` 枚举;`ResidentVideoSurface` 按 route 建 IOSurface 像素格式 +
  消费端 Metal 视图(8-bit 用 `_srgb` 变体);`AVController.probeIsHDR`;`VerifyModel` 自动路由 + 强制开关;
  `MpvPlayer.colorOptions(for:)` 按 route 分流;调参面板「出口格式」开关;perf HUD 实时带宽估算
  (`字节/帧 × 帧率`,硬件带宽计数器 visionOS 不开放,故为可解释估算)。
- 验证:Mac 吞吐夹具 `XR_PIXFMT=8` 跑静态彩条,8-bit 解码后线性值 ≈ fp16(差仅量化级 ~1%,非 gamma
  错位)→ 写入侧 sRGB 编码正确。消费端 `.rgba8Unorm_srgb` 硬件解码是 ADR 0004 原已验证的契约。

## 取舍与边界

- 格式路由给 ~2× 带宽余量:够撑 SDR 8K / HDR 4K 档;但 **8K@60 HDR / 16K 流畅靠的是 foveation**,
  格式路由替代不了。那一档若是硬需求,绕不开 Apple 原生路(`VideoPlayerComponent` + APMP),代价是
  让出色彩管线控制权——是另一个待 PM 裁定的战略岔路(留 mpv 自优化 vs AVPlayer 混合路由)。
- 分辨率上限(杠杆A)保留为调试开关,默认关(原生),非正解。
