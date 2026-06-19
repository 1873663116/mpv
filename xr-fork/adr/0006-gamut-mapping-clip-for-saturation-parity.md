# ADR 0006 — 色域映射设 clip:让饱和度贴近 AVFoundation

状态:Accepted(实现完成,数值验证通过,待真机签收) ｜ 日期:2026-06-15 ｜ 前序:ADR 0005

## 背景

ADR 0005 把沉浸出口做成真 HDR(fp16 扩展线性 Display P3),真机实测 HDR 峰值/亮度已与
AVFoundation 接近。但留下一个**一眼可辨、非微妙**的差别:同一段 HDR10 片,mpv 屏的**饱和度
明显低于 AVFoundation 屏**(VideoMaterial,走系统 HDR 管线)。

要点:这**不是** tone-map 亮度问题(亮度已对齐),也**不能**用「mpv 与 AVFoundation 着色器
不同」搪塞——下面有明确证据指向一个**我们从未显式设置、因而吃了 libplacebo 默认值**的具体旋钮。

## 根因(三条硬证据,非猜测)

1. **libplacebo 默认色域映射 = 感知压缩(perceptual)。**
   `pl_color_map_default_params.gamut_mapping = &pl_gamut_map_perceptual`
   (`shaders/colorspace.h:315`,libplacebo 7.360.1)。mpv 的 `--gamut-mapping-mode` 默认 `auto`
   正好接到这个默认值(`video/out/vo_gpu_next.c:2746`:`[GAMUT_AUTO] = pl_color_map_default_params.gamut_mapping`)。
   我们的 `colorOptions()` 里**一个色域选项都没设** → 全链吃的就是 perceptual。
   perceptual 的定义(libplacebo 头注释 + 文档):"perceptually balanced **(saturation)** gamut
   mapping, using a soft knee... followed by a final softclip" —— 它把**整个 Rec.2020 容器色域**
   压进 P3,soft knee 会**提前压缩、连带降低在域内(本就 ≤P3)颜色的饱和度**。这就是发淡的机制。

2. **Apple 的 HDR 视频显示管线 = 比色裁剪(colorimetric clip),不做全色域感知压缩。**
   官方 Tech Talk **"Discover Reference Mode"**(Apple Display and Color Technologies team)原话:
   > "colors will be displayed correctly as long as they ... are within the P3 color gamut ...
   > Colors that are out of gamut ... will be **clipped** with no tone-mapping."
   即:**域内颜色精确呈现(满饱和)、仅裁剪越界色**。该路径明确覆盖 AVFoundation 与 Metal 渲染,
   正是我们对照的 VideoMaterial 走的系统色管。所以 AVFoundation 保住了饱和度,mpv(perceptual)压低了它。
   (注:`CGColorRenderingIntent` 文档里"sampled image 默认 perceptual"只适用 Core Graphics 2D
   静图路径,**不适用** HDR 视频的 CoreVideo/Metal/EDR 实时路径,勿混用。)

3. **真实 HDR10 内容基本在 P3 内调色(Rec.2020 只是容器)。**
   HDR 母带普遍用 P3-D65 mastering display(Apple Immersive Video 母带规范本身即 P3-D65 PQ),
   真正用满 Rec.2020 角点的像素极罕见。所以 Apple 的「保域内 + 裁越界」视觉近乎无损;而 perceptual
   为极少数越界色把一大片域内色一起降饱和,代价不成比例。

## 决策

把 mpv 的 `gamut-mapping-mode` 从默认 `auto`(=perceptual)显式改为 **`clip`**:

```
colorOptions() 增加一项 → ("gamut-mapping-mode", "clip")
```

- **`clip`** = 逐通道硬裁越界色、域内不动 → 最贴 Apple Reference Mode 描述的实际行为。
- 备选 **`relative`**(相对比色裁剪,沿恒色相裁到边界)在色彩科学语义上更"干净",若 clip 在越界
  高光出现色相/明度偏移再换。两者对域内饱和度都**远胜默认 perceptual**。
- **不调饱和度滤镜、不动 libplacebo shader 源码**——只换一个既有的色域映射算法选项。

这是一个**运行时 mpv 选项**(`mpv_set_option_string`),改动仅在 verify app 的 Swift
`colorOptions()` 一行,**零 C 改动、零 libmpv 重编**,完美守 rebase 纪律。

## 验证(数值,设备无关 —— 这次模拟器能验)

关键洞察:**色域映射是发生在显示 clamp 之前的色度运算**,perceptual/clip 的差异直接写进 fp16
IOSurface 字节。所以(不同于 ADR 0005 的 HDR 绝对亮度)**这次模拟器就能数值裁定**:

- 度量 = **CIE 1976 u'v' 色度**(离 D65 白点的距离)的均值/p90。它**与亮度无关**,故 mpv(HDR,
  峰值>1)与 AV(SDR-clamp)的 tone-map 差异**不污染**比较,纯反映饱和度。
- A/B/C 同帧对照(样片 10s 彩色竖条帧):三次启动切 `XR_GAMUT_MODE=perceptual/clip/relative`,
  各 seek 到同一时刻、测 mpv 出口 u'v' 色度 + 存 PNG;`AVAssetImageGenerator` 解同帧作地面真值。
- 断言:`chroma(perceptual) < chroma(clip) ≈ chroma(AV 地面真值)`。

**实测(2026-06-15,模拟器 headless 同帧 A/B/C + 宿主机独立地面真值,样片 10s 彩色竖条帧):**

| 模式 | meanChroma(u'v') | p90 | 对 AV 等效 |
|---|---|---|---|
| perceptual(旧默认,我们的 bug) | 0.1478 | 0.2844 | 均值 −11%、p90 −6.3% |
| **clip(本决策)** | **0.1598** | **0.3030** | **均值 −3.7%、p90 −0.05%(几乎相同)** |
| relative | 0.1564 | 0.2978 | 均值 −5.8% |
| **AV 等效 = 源→P3-clip(P3 屏 colorimetric 实显)** | **0.1660** | **0.3032** | 基准 |

- **clip 的 p90 与 AV 等效几乎完全重合(0.3030 vs 0.3032),均值差 3.7%;perceptual 比 AV 低 11%。**
  即 perceptual 是降饱和的异类,clip ≈ AV。relative 此内容略逊 clip → 选 **clip**。
- 该帧 **39.96% 像素落在 P3 外**(高饱和测试图),最大化触发 perceptual 全局压缩 —— 解释了
  「为何用户一眼可见、差别非常大」:这类内容正是 perceptual 降饱和最严重处。
- 旁注:clip 不压缩越界亮值 → fp16 峰值升到 2.68(perceptual 为 2.0);超 EDR headroom 2.0 的高光
  由合成器在显示端裁掉,与 Apple"越界即 clip"一致,非饱和度问题。
- ⚠️ 模拟器 SDR-clamp 把 >1.0 高光压平,故上表**低估**真机 EDR 下的实际饱和度差;真机差更大。

## 后果

- 沉浸出口饱和度回到接近 AVFoundation;窗口模式(macOS,ADR 0004 路径)不受影响——本决策只改
  surfaceless 沉浸出口的一个色域选项。
- `clip` 对极少数越界色逐通道硬裁,理论上可能轻微偏色相;若真机在高饱和高光处发现偏移,切 `relative`。
- 真机仍是 HDR 绝对观感的最终裁判;本 ADR 解决的是「饱和度学派/默认值」问题,与 ADR 0005 的
  「HDR 亮度」问题正交。
