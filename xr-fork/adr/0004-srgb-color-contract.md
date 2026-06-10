# ADR 0004 — sRGB 色彩出口契约 + 平台守卫与 visionOS 打包

状态:Accepted ｜ 日期:2026-06-10 ｜ 前序:ADR 0003

## 背景

阶段 1 验收时发现两条出口颜色表现相反:窗口模式整体发白,常驻纹理出口"看着正常"。
调查结论(实证 + mpv#16874/#16791/#4248):

- **窗口发白是写读错位**:libplacebo ≥7.35x 禁用 `PASS_THROUGH` 后,macOS swapchain 固定
  `SRGB_NONLINEAR`(MoltenVK 把 layer 标成 IEC sRGB),而 mpv 默认对 BT.1886 内容不做
  transfer 转换直出 → ColorSync 按 sRGB 分段解码 BT.1886 字节 → 暗部抬亮(码值 0.1 处
  线性亮度差约 2.5 倍)。
- **常驻出口"正常"是两个错误偶然抵消**:mpv 写入的同样是 BT.1886 编码字节;消费端用
  非 `_srgb` 纹理视图(不解码、当线性值)+ RealityKit 默认 tone mapping。macOS 上近似
  互逆,visionOS(P3 工作空间 + 系统 tone mapping)上同样搭配被社区广泛报告为发白。
- 整条链路里唯一"懂"色彩的环节是 **Metal 像素格式后缀**:RealityKit 在线性空间渲染,
  不读 IOSurface 的 colorspace 附件,解码与否完全由 `_srgb` 后缀决定。

另:MPVKit 打包验证发现我们的源文件挂在 `cocoa && swift` 守卫下,visionOS(无 AppKit、
swift-build 关闭)会把整个出口编没。

## 决策

**1. 出口契约:IOSurface 里的字节 = IEC sRGB 编码、BT.709 原色、full-range RGB、SDR。**
写读两端各自负责咬合:

```
mpv(写端)                          消费端(读端)
target-trc=srgb                     MTLPixelFormat .rgba8Unorm_srgb(硬件解码 IEC sRGB)
treat-srgb-as-power22=input         UnlitMaterial(applyPostProcessToneMap: false)
target-colorspace-hint=no           (不参与光照、不参与系统 tone mapping)
```

`treat-srgb-as-power22=input`:保留输入侧 mpv 默认(sRGB 标记内容按 2.2 幂线性化),
只关输出侧「sRGB→纯 2.2 幂」重写,使 mpv 编码与消费端硬件解码严格互逆。
mpv 侧渲染视图仍是 `.rgba8Unorm`(libplacebo 在 shader 里做编码),与消费端 `_srgb`
视图共存于同一 IOSurface,字节不变、只是解释不同。

**2. 窗口模式(macOS)`target-colorspace-hint=yes`。** swapchain 切到
`BT709_NONLINEAR_EXT`(layer = ITU-R 709),mpv 按 BT.1886 直出、ColorSync 按 709 解读,
写读重新咬合,发白消失。两组选项都是运行时属性,热切时随 `gpu-context` 一并设置
(见 verify app `MpvPlayer.colorOptions`)。

**3. 平台守卫与 cocoa/swift 解耦。** `context_mac_resident.m` + `xr_resident_texture.m`
由 `vulkan && darwin` 守卫编入(meson),context 注册用 `#ifdef __APPLE__`;
不依赖 AppKit/Swift,visionOS 打包(MPVKit,cocoa 自动落空、swift-build 关闭)保留出口。

**4. HDR 战略:出口按 SDR 设计,HDR 内容由 libplacebo tone-map 到 SDR。** 依据:visionOS
上 RealityKit 自定义纹理路径(DrawableQueue/LowLevelTexture/rgba16Float)没有文档化的
EDR 出口,真 HDR 只有 AVFoundation 播放与 CompositorServices 全沉浸两条路。
**待真机裁决的开放问题**:rgba16Float 纹理 + Unlit + 关 tone map 在 Vision Pro 上能否
产生超过 SDR 白的亮度(写 2.0 常数值,与 AVPlayer HDR 白场并排对比,10 分钟实验)。
若能,出口契约升级为 16F + extended linear 是兼容扩展(加格式、不改架构)。

## 防御性加固(随本 ADR 落地)

- `xr_buf` 记录创建纹理的 `pl_gpu`,gpu 变了强制重建;跨 gpu 的句柄只丢弃不销毁
  (跨 gpu `pl_tex_destroy` 是 UB)。`uninit` 无条件销毁环(空环 no-op),
  不再依赖 enabled 开关的设置时序。
- 环状态(`g_ext/g_count/g_res/写指针`)由互斥锁串行化 app 线程(configure/clear)与
  VO 渲染线程;`g_front_id/g_enabled` 保持 atomic,消费端高频读不取锁。
- headless 上下文 + 出口未启用 → `draw_frame` 丢帧返回,不再走进 NULL `start_frame`。
- `vo_gpu_next.c` 的 xr 调用点全部置于 `#if defined(__APPLE__) && HAVE_VULKAN` 内
  (此前 uninit/preinit 裸调用,非 Apple 构建会链接失败)。

## 后果

- 对照组验收的预期校准:QuickTime/AVFoundation 对 BT.709 SDR 用 ~1.961 纯幂 gamma,
  mpv 默认 BT.1886(~2.4)→ Apple 播放器系统性更亮、暗部对比更低,是学派差异不是 bug;
  判据是"无结构性偏差",不是逐像素一致。
- 数值验收成为可能:IOSurface 字节有了确定语义(IEC sRGB),可与 mpv `screenshot-to-file`
  的 sRGB PNG 逐块比对,不经过任何显示器。
- 测 HDR 需要真 HDR 片源(testsrc2 是无标签 SDR):Mehanik HDR10 patterns、
  kodi.wiki/view/Samples、Apple HLS 示例流;本机 brew ffmpeg 无 zscale,生成真转换
  HDR 片需带 libzimg 的 ffmpeg。
