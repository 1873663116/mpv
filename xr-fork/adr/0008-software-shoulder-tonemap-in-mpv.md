# ADR 0008 — 沉浸出口在 mpv 端做软肩 tone mapping(贴齐 AVFoundation)

状态:Accepted(真机签收 device-tuned 默认,见文末更新)｜ 日期:2026-06-15(2026-06-16 更新)｜ 上承 [ADR 0007](0007-hdr-highlight-crush-and-edr-contract.md)｜ 下接 [ADR 0009](0009-visionos-unified-realitykit-output.md)

## 背景

真机目视:mpv 沉浸出口与 AVFoundation 的差距集中在三处——高光要么过曝成片白、要么发灰不够亮;
饱和度明显偏淡;暗部/对比度也偏弱。两路调查(libplacebo 选项普查 + Apple EDR 机制)给出统一解释:

- **AVFoundation 的「高光又亮又有层次」= 带软肩(highlight roll-off / shoulder)的 tone mapping**,
  标准算法即 EETF(BT.2390 / BT.2446a):把超过参考白的高光平滑滚降进显示器可用 headroom,
  而非一刀切。RealityKit 默认对所有材质做这步(WWDC23);`VideoMaterial` 吃的就是这层系统软肩。
- 我们这条 `UnlitMaterial(applyPostProcessToneMap:false)` 的零拷贝纹理路径**显式退出了系统软肩**
  (`false` = 原样发光,超 headroom 由合成器硬截);而 mpv 端又用了**两条错的曲线**:
  `tone-mapping=clip`(无肩部、硬裁 → 过曝)、或 `tone-mapping=auto`(=spline)+`hdr-compute-peak=yes`
  (拐点随场景明暗浮动 → 暗场被相对提亮、发白)。两头都没有那条「对的软肩」。

**真机材质探针(用户裁定):Vision Pro 沉浸路径 EDR headroom = 2.0。** 把材质亮度乘子
1.0→2.0 画面持续变亮,2.0→5 不再变 = 合成器在 2.0× 处硬截。故软肩的天花板必须对齐 2.0,
高于 2.0 的输出会被硬裁(= 过曝);这正是 `target-peak=1000`(headroom≈4.9)仍过曝的原因。

## 决策

**策略一:既然系统不替自定义纹理做软肩,就在生产端(mpv)自己把 HDR10 高光软肩滚降进真实
headroom 2.0。** 全部经 mpv 选项(运行时/init,不动 libplacebo shader、不动消费端渲染契约)。
沉浸出口默认色彩契约改为:

| 选项 | 值 | 作用 |
|---|---|---|
| `tone-mapping` | `bt.2390` | 带线性段的 hermite 软肩 EETF;高光平滑滚降进 headroom 且保留层次 |
| `hdr-compute-peak` | `yes` | 逐帧测真实峰值。本样片元数据退化(MaxCLL=0→sig-peak≈49),no 会按 49→2.0 压崩高光;bt.2390 拐点不随场景均值走→yes 不洗白暗场。元数据可靠的生产内容可改 no(更静态、贴 AV) |
| `target-peak` | `406` | =2.0×203;软肩天花板对齐真实 headroom 2.0,源最亮落 ~2.0、不撞硬截 |
| `target-contrast` | `inf` | Vision Pro 自发光真黑屏,关黑点补偿抬黑 → 暗部纯黑、不发灰 |
| `gamut-mapping-mode` | `clip` | colorimetric 硬裁(Apple Reference Mode),域内满饱和、仅裁越 P3 界;实测比 perceptual 更贴 P3 目标 |
| `saturation` | `0` | 全局饱和度兜底旋钮,留中性,真机欠饱和可经 env 上调 |
| `target-prim` / `target-trc` | `display-p3` / `linear` | 扩展线性 Display P3 出口,1.0=SDR 参考白(203 nits) |

各项经 `SIMCTL_CHILD_XR_*` env 可覆盖(真机/模拟器 A/B);verify app 控制窗的「峰值切换 /
Tone 曲线」按钮在 406 上下与 bt.2390/bt.2446a/clip 间运行时热切,供真机对着 AV 屏标定。

## 不选什么(策略二,留作 round 2)

把 `applyPostProcessToneMap` 改回 `true` = 重新打开 RealityKit 默认软肩(VideoMaterial 用的同一层)。
可能直接贴 AV,也可能套上 RealityKit 通用 3D tone mapper 把整体压灰——一行 Swift、需重建材质、
**只真机能裁**。先做策略一(mpv 端可控、可运行时热调、真机已证亮度基本对齐),逼不出 AV 亮度上限再试策略二。

## 约束与已知局限

- **headroom 无公开 API**:visionOS 沉浸 RealityView 路径查不到 EDR headroom 数值
  (`UIScreen.currentEDRHeadroom` 无等价物)。故 target-peak 靠真机材质探针标定(当前 2.0)。
- **高光去饱和不可调**:本版 libplacebo 把 tone-map crosstalk 写死 0.04、删了旧 `tone-mapping-mode`
  → 高光去饱和关不掉。若 AV 高光饱和度仍明显更高,这截差距需 `--glsl-shader` 或消费端补,选项调不到。
- **样片 HDR 元数据退化**(MaxCLL=0、sig-peak=49≈满 PQ)→ `hdr-compute-peak=no` 会按 49→2.0 把高光压崩
  (实测 2s >1.0 仅 0.75%);故默认 `yes`、逐帧测真实峰值。bt.2390 拐点不随场景均值走,`yes` 不像 spline 洗白暗场
  (实测 27s 黑位 p1=0)。元数据可靠的生产内容可改 `no`(更静态、贴 AV)。见下方测量。

## 测量(模拟器 headless,2026-06-15,读 fp16 IOSurface 字节,显示无关)

> 对照帧 2s(测试图案)/ 27s(玻璃工);源/AV 目标由主机侧 PQ EOTF 解码算得。亮度单位 = ×SDR 白
> (1.0=203 nits);色度 = CIE1976 u'v' 离 D65 距离 p90(饱和度代理,已裁到 P3 可显示)。

| 配置(2s / 27s) | 黑位 p1 | 峰值 max | >1.0 高光 | >2.0 过曝 | 饱和 p90 |
|---|---|---|---|---|---|
| **源 / AV 目标** | 0 / 0 | 4.5 / 13.8 | 4.33 / 4.40% | 1.45 / 2.48% | 0.303 / 0.272 |
| **策略一(rec)** | **0 / 0** | 2.41 / 2.56 | **4.19 / 4.20%** | **0.53 / 0.89%** | **0.303 / 0.269** |
| 旧基线(old) | 0.005 / 0.005 | 3.5 / 5.2 | 5.63 / 5.04% | 1.58 / 2.56% | 0.147 / 0.071 |

裁定(模拟器 headless 实测,显示无关):
- **compute-peak 必须 yes**:元数据退化(sig-peak=49)使 `no` 把高光压崩(2s >1.0 仅 0.75%≪源 4.33%);`yes` 测真实峰值→4.19% 贴源。
- **gamut clip > perceptual**:perceptual 27s 欠高光(>1.0=1.23%)又欠饱和(0.240);clip 高光 4.20%、饱和 0.269(贴目标 0.272)。
- **target-contrast=inf 修黑位**:old(auto)抬黑到 p1=0.005(灰 veil=「发白」);inf 后 p1=0。
- **target-peak=406 修过曝**:old(peak=1000)源最亮冲到 3.5–5.2×、>2.0 达 1.6–2.6%(被显示器硬截=过曝);406 把软肩天花板对齐 2.0→>2.0 降到 0.5–0.9%(只剩最饱和高光因 clip 略冲顶,可降 peak 至 380 再压)。
- **bt.2446a 在退化元数据下崩更狠**(cp=no:2s max=0.43、>1.0=0%)→ 选 bt.2390。

> ⚠️ 模拟器 SDR-clamp 看不到 >1.0 绝对亮度,以上为字节级数值;真机 HDR 观感与最终 target-peak/曲线由用户标定(见文末更新)。

## 后果

- 改动集中在 verify app 的 `MpvPlayer.colorOptions`(策略一默认)+ `VerifyModel` 探针(抓 2s/27s)
  + 真机微调 UI;libmpv C 侧零改动(全是运行时/init 选项)。
- ⚠️ 生产接入:Enchron 真实播放器须同步这组色彩契约;真机标定出的最终 target-peak/曲线随之固化。
- 上游 rebase 纪律:本 ADR 不涉及 libplacebo/mpv C 源改动,无新增冲突面。

## 更新(2026-06-16):device-tuned 默认(真机签收)

真机对着 AV 屏逐项标定后,默认从「策略一基线」收敛为下表(仍全经 mpv 选项、C 侧零改;每项 env / 调参面板可调)。落地在 `MpvPlayer.colorOptions()` 与 `TuningPanel` 的复位默认。

| 选项 | 基线 → 默认 | 真机裁定 |
|---|---|---|
| `hdr-compute-peak` | yes → auto | 本路径 auto≈yes,动态测峰保持开 |
| `hdr-peak-percentile` | 100 → 99.9 | 把高光点纳入测峰 |
| `hdr-reference-white` | 203 → **183** | **真机实测「参考白越高、过曝越狠」,降低 = 软肩更早收高光、保护极亮**。机制:参考白 = tone 曲线拐点锚,降它 = 肩部提前起滚(与纸面「降参考白→全局提亮→过曝」推导相反,**以真机为准**) |
| `hdr-contrast-recovery` / `-smoothness` | 0.3 / 3.5 → 0.15 / 100 | 找回调温和、平滑半径拉宽(只找回极低频对比) |
| `saturation` / `contrast` / `gamma` | 0 / 0 / 0 → **9 / 10 / 1** | 轻度均衡器补偿,补静态管线相对 AV 动态系统 tone-map 的欠饱和与平。**判据:面板「饱和 p90」对齐源 ~0.30,勿过冲成二次调色** |
| `tone-mapping` / `target-peak` / `target-contrast` / `gamut-mapping-mode` | bt.2390 / 406 / inf / clip | 不变 |

**为什么是「一组静态参数」而非完美贴 AV(已接受的取舍):** AV 的还原 = 系统按内容元数据在**实时动态 headroom** 上软裁(AVPlayer 独占的 CAMetalLayer / `CAEDRMetadata` tone-mapper),其 headroom 随环境光/亮度浮动、且读真实 mastering 元数据。我们这条任意纹理路径**拿不到那个系统动态软裁**(社区调查 + ADR 0009 同结论),只能用 libplacebo 复刻一条**固定**软肩。故:大部分场景贴近 AV,极亮场景可能偏硬——**用户裁定:接受 HDR 的刺激性,而非退回 SDR**。要更逼近只剩一条进阶路:把 `target-peak` 改为跟随真机实时 EDR headroom(独立增量,非必需)。
