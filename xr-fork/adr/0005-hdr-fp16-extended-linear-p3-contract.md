# ADR 0005 — HDR 出口契约:fp16 扩展线性 Display P3

状态:Accepted(实现完成,待真机签收) ｜ 日期:2026-06-14 ｜ 前序:ADR 0004

## 背景

ADR 0004 把沉浸出口钉成 **8-bit sRGB SDR**。放真实 HDR10 片(`HDR10-test.MP4`,4K/PQ/Rec2020)
时,这套契约暴露问题:libplacebo 把 HDR10 源 **tone-map 成 SDR** 再写进 `rgba8Unorm_srgb`
IOSurface,`vo_gpu_next.c` 还把 `swframe.color_space` 写死 `pl_color_space_srgb`。结果同一片源,
AVFoundation(`VideoMaterial`,走系统 HDR 管线)显示真 HDR、明显更亮更艳,mpv 一眼是 SDR。

要让 mpv 出口与 AVFoundation 一致,出口必须改成**能承载 >1.0 线性光的真 HDR**。

外加一个独立的几何 bug:surfaceless 路径下 `vo->dwidth/dheight` 停在视频原生 4K(无窗口约束),
但渲染目标 IOSurface 是 720p → `apply_crop` 把视频画到远大于 fbo 的矩形,只剩左上角(放大 ~3×)。

## visionOS HDR 的第一性事实(决定本契约)

- Vision Pro 屏是 **Display P3 色域**。P3 是**色域**(更广的原色),**不等于 HDR**;
  HDR = P3 原色 **+ EDR**(extended dynamic range,线性值可 >1.0)。
- 沉浸合成器期望 **扩展线性 Display P3**,**EDR headroom = 2.0**(1.0 = SDR 参考白,2.0 = 最亮)。
  这也是 AVFoundation 内部把 HDR10 收敛到的工作空间 —— 我们要复刻它。
  (依据:WWDC23 Discover Metal for immersive apps;WWDC21 EDR;WWDC22 Display HDR video in EDR。)
- headroom 只有 2.0,故 HDR10 峰值(数千 nits)**必须 tone-map 进 [0, 2.0]**(和 AV 一样),
  **不是** bypass/clip。仍 tone-map,只是目标是 EDR 2.0 而非 SDR;只选 libplacebo 算法/参数,
  **不动 shader 源码**。

## 决策

**出口契约:IOSurface 里的字节 = `rgba16Float`、扩展线性、Display P3 原色,HDR10 经 tone-map
落进 EDR headroom(参考白=1.0,峰值≤~2.0)。** 写读两端各自咬合:

```
mpv(写端)                              消费端(读端,visionOS)
target-prim=display-p3                   MTLPixelFormat .rgba16Float(线性浮点,无 _srgb 解码)
target-trc=linear                        TextureResource.__texture(from:)(零拷贝包同一 IOSurface)
tone-mapping=auto + hdr-compute-peak     UnlitMaterial(applyPostProcessToneMap: false)
target-peak=406  ← 标定旋钮               沉浸合成器自动按扩展线性 Display P3 合成 EDR(无显式开关)
target-colorspace-hint=no                IOSurface 像素格式 kCVPixelFormatType_64RGBAHalf(8B/像素)
```

`swframe.color_space` 同步改成 `{ PL_COLOR_PRIM_DISPLAY_P3, PL_COLOR_TRC_LINEAR }` 作基底;
`hint=no` 时 `apply_target_options` 按上述 `target-*` 选项覆盖驱动。几何对齐:surfaceless 分支
把 `vo->dwidth/dheight` 对齐到 IOSurface 尺寸并就地 `vo_get_src_dst_rects` 重算 src/dst/osd_res。

## 实现中确证的三条约束(**与原计划假设不同,记录在此**)

1. **`.hdrColor` 语义在零拷贝路径上不可达。** SDK 实测:`TextureResource.__texture(from: MTLTexture)`
   只接受 MTLTexture,**不接受** `CreateOptions`/`semantic`;`TextureResource.semantic` 仅 getter。
   `.hdrColor` 只能经 `generate(from: cgImage, options:)` / `replace(withImage:)` 这类 **CGImage 拷贝
   路径**设置 —— 那会每帧 CPU 拷贝,违背零拷贝目标。`DrawableQueue.Descriptor` 也只有 pixelFormat,
   无 semantic。**结论:运行时 GPU 纹理(零拷贝或 DrawableQueue)无法显式打 HDR 语义,HDR 与否的
   唯一信号是 `.rgba16Float` 浮点格式 + >1.0 的线性值。**
2. **visionOS 无 RealityView EDR 开关。** `RealityViewRenderingEffects.dynamicRange` /
   `wantsExtendedDynamicRangeContent` 是 iOS/macOS API,visionOS SDK 不存在 —— 沉浸内容的 EDR
   由系统合成器自动处理。故消费端无需(也无法)显式"开 HDR"。
3. **参考白/headroom 标定是承重旋钮,且归一化方式待实测。** `target-peak=406`(≈203×2)期望 fp16
   线性峰值落在 ~2.0。但 libplacebo 对 `TRC_LINEAR` 输出的归一化(1.0=参考白 还是 1.0=target-peak)
   未在文档明确。出口实际峰值由 C 侧 `[xr-verify] 线性峰值` 行裁定:
   - 峰值 ~1.0–2.0 → 归一到参考白,契约成立。
   - 峰值被钳到 ≤1.0 → 归一到 target-peak(HDR 被压平),需提高 target-peak 或改 `hdr-reference-white`
     重标定,逐一用数值排查(色域 / 传递 / 峰值任一不对都会显示不出 HDR 或过曝)。

   **✅ 实测闭环(2026-06-14,visionOS 模拟器 headless 自驱跑 `HDR10-test.MP4`):fp16 出口线性
   峰值 = `2.000`(逐帧稳定 1.7–2.0)。** 即 libplacebo 按「1.0=SDR 参考白」归一化,`target-peak=406`
   令 HDR 峰值恰落 EDR headroom 2.0 —— 归一化问题数值上已闭环,契约成立。**唯一留待真机的是
   RealityKit 是否把这些 >1.0 值显示成 EDR 亮度**(模拟器 SDR-clamp 看不到绝对亮度)。

## 验收(两道门控,设备无关优先)

- **Gate 1(数值,承重):** mpv 源 `video-params`(primaries=bt.2020/transfer=pq)+ AV 源
  `CMFormatDescription`(ITU_R_2020 / ST_2084)双双判定 HDR10;mpv fp16 出口线性峰值 >1.0 且 ≤~2.0。
  全部 `[xr-verify]` 前缀,`runVerification()` 一次跑完。
- **Gate 2(截图,二次):** 模拟器 SDR-clamp,**不验绝对亮度**,只验对齐三项(分辨率 / 屏上纹理实际
  显示大小 / 几何)+ 相对色。
- **真机(早晨):** 目视 mpv 明显 HDR 且与 AV 接近。模拟器看不到 EDR 绝对亮度,真机是 HDR 唯一裁判。

## 后果

- 出口从 SDR sRGB 升级为真 HDR;窗口模式(macOS,ADR 0004 的 `target-colorspace-hint=yes` SDR 路径)
  不受影响 —— 本契约只改 surfaceless 沉浸出口。
- 若真机判定 float-only(无 `.hdrColor`)不足以显 HDR,退路是 DrawableQueue + GPU blit
  (仍是 GPU,不落 CPU、不违反零拷贝硬解目标),代价是每帧一次 GPU 拷贝。
- `target-peak` 标定值可能随真机 EDR 实测调整;`check_nonzero` / `samplePeak` 是验证夹具,
  生产接入时去掉。
