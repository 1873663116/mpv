# ADR 0007 — HDR 发白/高光削顶:mpv 端高光裁切(EDR 显示本身正常)

状态:Superseded-in-part(根因①成立;根因②与 A/B 分叉**已被用户真机推翻**)｜ 日期:2026-06-15

> 🟥 **2026-06-15 修正(用户真机裁定,载重)。** 本 ADR 原写「根因② 消费端零拷贝材质路径无 EDR 通道 →
> 合成器把 >1.0 当 SDR 截掉」并据此提出「路 A 干净 SDR / 路 B CompositorServices」产品分叉 —— **这个判断错误,
> 已被真机推翻,作废。** 真机事实:**visionOS RealityKit 沉浸路径支持 EDR。** 零拷贝 `__texture(from:)` +
> UnlitMaterial + rgba16Float(**无 `.hdrColor` 语义**)就能显示 >1.0 的 EDR 亮度——AV(VideoMaterial)明显是 EDR
> (亮一个层次、无信息丢失),fp16 修复后 mpv 亮度与 AV **基本持平**。`.hdrColor` 对沉浸浮点纹理显示 EDR 非必需;
> 那条 Apple DTS forum 756298 不适用本路径。**下方「根因②」「消费端 EDR 契约缺口」「产品分叉 A/B」三处作废。**
>
> **仍成立的是根因①(mpv 端高光裁切)。** 剩余 mpv-vs-AV 差距 = **饱和度 + 高光裁切 + 可能对比度**,
> 都是【在已工作的 EDR 显示内】的缺陷,不是「显示不了 HDR」。下一步:在工作的 EDR 内调 mpv 的
> tone-map/峰值/饱和去贴 AV,**不需要 CompositorServices、不走 SDR 退路**。最明显对比帧:样片 **2s 与 27s**。

## 背景

真机目视:mpv 沉浸出口比 AVFoundation 明显「发白、发灰、不通透」,黑压不下去,峰值周围
「超过 1.0 的亮度成片消失」。ADR 0006(色域 perceptual→clip)只略微改善饱和度,未解此问题。

## 诊断:不是单一 bug,是两段独立错误叠加成三症状

**根因①(mpv 端,已锤实、可修):`target-trc=linear` 使 libplacebo 判出口为 SDR 目标
(nominal_peak(LINEAR)=1.0,is_hdr=false),叠加 `target-peak=406` + `hdr-compute-peak=yes` +
`tone-mapping=auto`(spline 压缩曲线),把数千 nits 的 HDR10 真实 tone-map 压进 [0,2.0] 窄盒,
高光被拉到 SDR 白以下、中调相对发灰。**

模拟器 headless 量化(读 fp16 IOSurface 亮度分位,度量「亮于 SDR 白的像素占比」,显示无关):

| 配置(gamut 都=clip) | 黑位 p1 | p50 | p95 | p99 | 峰值 | **>1.0** |
|---|---|---|---|---|---|---|
| **源 / AV 目标** | 0.000 | 0.345 | 1.478 | 2.149 | 10.6 | **14.8%** |
| **p406(旧默认,bug)** | 0.002 | 0.260 | 0.810 | 0.957 | 2.08 | **0.82%** |
| **tone-mapping=clip(406)** | 0.000 | 0.354 | 1.481 | 2.062 | 9.60 | 14.7% |
| target-peak=1000 | 0.005 | 0.406 | 1.408 | 1.756 | 5.04 | 15.3% |
| target-peak=4000 | 0.020 | 0.627 | 2.248 | 2.918 | 9.79 | 31.2%(过头) |

旧默认 p406 只剩 **0.82%** 高光(源 14.8%)—— 实锤「高光被削」。`tone-mapping=clip` 或 `target-peak=1000`
都能还原源分布。**ADR 0005「峰值=2.0 ⇒ HDR 达成」的结论是误导**:个别像素到 2.0,但绝大多数高光被压没。

**根因②(消费端,只能真机判):零拷贝 RealityKit 材质路径无 EDR 元数据通道。**
`TextureResource.__texture(from:)` 不能打 `.hdrColor`;IOSurface `kIOSurfaceColorSpace` 不被读;
沉浸 RealityView 无 EDR 开关。Apple DTS(forum 756298):rgba16Float 单独不渲染 HDR、DrawableQueue
配不了 EDR 层属性。⇒ 即便 mpv 字节里有 >1.0,合成器很可能按 SDR 截掉。

**排除项:黑位不是 mpv 抬的**(输出 p1=0.002≈源 0.000)→「发白」是显示端按 SDR 合成的结果,
不是管线抬黑,也不是 sRGB double-decode(那会变暗非变白)。饱和不足是「亮度压扁」的继发产物。

## 决策(分两部分)

**已落地(mpv 端,零 C 改动、可逆):`target-peak` 默认 406→1000**(graceful、源分布对齐、不爆高光);
`tone-mapping=clip` 作更激进备选(逐项最贴源,但 passthrough,低 headroom 设备可能硬裁高光)。
各项经 env(`XR_TARGET_PEAK`/`XR_TONE_MAPPING`/…)可扫,真机最终值随 EDR headroom 标定。

**待定(产品分叉,需 PM 决策)——真 HDR 能否在沉浸场景显示卡在根因②:**
- **路 A 干净 SDR**:放弃材质路径假装 HDR,mpv 正确 HDR10→SDR(如 `target-trc=srgb` + `tone-mapping=bt.2390`)、
  消费端 `_srgb` 硬件解码。黑正/对比正常/不过曝/饱和回升,与 AV 的 SDR 回退一致;代价是无真 HDR 上限。
- **路 B 真 HDR**:消费端从 RealityKit 材质换 **CompositorServices drawable**(Apple 唯一文档化的沉浸 EDR 路,
  rgba16Float + 扩展线性 P3 + headroom)。最贴 AV,但是 Enchron 消费端大改,不在 mpv fork 内。
- **建议先做**:把 mpv 高光修法上真机,量「当前 RealityKit 路径 + 正确字节」能逼近 AV 几成 → 消除最大不确定性再选 A/B。

## 验证

- mpv 端:模拟器 headless `[xr-verify] sat-lum` 读 fp16 亮度分位(显示无关,已证 p1000/tclip 还原源分布)。
- 消费端(根因②/路 A/B):tone-map 与 EDR 合成发生在合成阶段、不写回 IOSurface 字节 → **只能真机目视**。
- 诊断来自 7-agent 调研工作流(参数普查 + visionOS EDR 契约 + 症状成因 + AV 参照 + 对抗核验)。

## 后果

- 报告 `xr-fork/report/report-round2.html`;历史截图 `xr-fork/report/screenshots/round{1,2}-…`。
- ⚠️ 修复需同步到 Enchron 真实播放器(verify app 只是参考);路 B 一旦选定,消费端改动在 Enchron 侧。
