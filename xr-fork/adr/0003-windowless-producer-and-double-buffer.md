# ADR 0003 — 无窗生产者模型 + 双 IOSurface 缓冲

状态:Accepted ｜ 日期:2026-06-09 ｜ 前序:ADR 0001、0002

## 背景

阶段 1 的常驻纹理出口已用 macOS 验证,但当时是脚手架,靠三个临时手段:隐藏窗口
(把窗口最小化挪出屏外假装无窗)、画两遍(先渲染进 swapchain 再多渲染一遍进 IOSurface)、
每帧 `pl_gpu_finish` 全停。三者在 macOS 单 GPU 能跑,但隐藏窗口在 visionOS 不存在、画两遍纯浪费、
全停拖帧率。本 ADR 固定生产化设计并替换这三件。

## 决策

**1. mpv 是帧的生产者,不是呈现者。** 窗口模式 mpv 直接贴屏(是呈现者,绑 vsync 合理);
生产模式只把帧写进 IOSurface,RealityKit/系统合成器才是呈现者。所以 **vsync 与 mpv 无关**:
mpv 按音频时钟出帧,补帧/对齐 ProMotion 全归合成器。mpv 侧呈现反馈打**诚实桩**(报"无反馈" →
mpv 回落音频时钟,源码 `render_frame` 已有此退化路径);桩不能撒谎报假 vsync,否则时序算崩。

**2. 无窗 surfaceless 上下文。** 关键事实(`vulkan/context.c`):建设备(`pl_vulkan_create`,
surface 可传 NULL)和建 swapchain(需要 surface)是两个可分开的调用。故 `macvk_resident` 走
`ra_vk_ctx_init_headless()`:建设备、不建 swapchain/窗口;`vo_gpu_next` 在无 swapchain 时跳过
`pl_swapchain_start_frame`,直接把 IOSurface 当渲染目标渲染一次。消灭"画两遍",macOS/visionOS 共用此路径。

**3. 两道门,门①归我们、门②归系统。**

```
门①(生产者→共享纹理)              门②(合成器→显示器)
mpv ──写──▶ [IOSurface 环] ──采样──▶ [合成器缓冲 + 头动重投影] ──▶ 屏幕
解决:别读到写一半的纹理            解决:别显示合成一半的场景;头显防眩晕
```

门② = 系统合成器,含 visionOS 的 reprojection/timewarp,**红线不可碰**,系统已做好。
门① = 共享 IOSurface,横跨 MoltenVK(写)与 RealityKit(读),在合成器之外 —— 唯一需我们工程化的真风险。

**4. 门① = 双 IOSurface 缓冲,环由我们持有(非 RealityKit DrawableQueue)。** 双缓冲(非三,省一张显存)。
职责按"谁天然该管"拆:

| 责任 | 归属 |
|---|---|
| 分配 2 张 IOSurface | **Swift**(延续 ADR 0002:纹理归 Swift) |
| 这一帧写哪张 | **mpv**(VO 线程按音频时钟出帧,只有它知道何时写完) |
| 这一刻读哪张 | **RealityKit**(读 mpv 已发布的"最新完整"那张) |

mpv 只 import 两次(启动各包一个 `pl_tex`,之后 A/B 交替),零每帧 churn。

**5. 预算开关。** 缓冲张数=双缓冲(已定)。位深当前 RGBA8;沉浸影片常 10-bit HDR,
改 RGBA16F 会让显存/带宽翻倍 —— **HDR 取舍留待后续拍板**。

## 考虑过的替代方案

| 方案 | 否决理由 |
|---|---|
| 保留隐藏窗口 + 画两遍 | visionOS 无窗口 VO;白渲染一遍 + 每帧全停拖性能 |
| 让 mpv 拿真 vsync、复制窗口逻辑 | mpv 已非呈现者;给它用不上的刷新率还可能误导时序 |
| 关掉系统合成器缓冲 | 沉浸场景非我们所有;reprojection 是头显防眩晕红线 |
| 三缓冲 | 多一张全分辨率显存;双缓冲足够隔离写/读 |
| RealityKit `DrawableQueue` 持环 | 每帧吐不同纹理 → mpv 每帧重 import;调度黑盒,fence 难对接 |

## 后果

- 拆掉脚手架的性能地雷(全停 → 后续换轻量 fence),生产开销 ≈ 窗口模式。
- 延迟:门① + 门② 合计约 2~3 帧,看视频可接受;常量延迟可用音频偏移精确抵消。
- Apple Silicon 统一内存 + IOSurface 零拷贝,无吞吐风险;唯一要规划的是显存预算(张数 × 分辨率 × 位深)。

## 落地步骤(脚手架 → 生产)

- ✅ **A. surfaceless 上下文**:`vulkan/context_mac_resident.m` + `context.c` 的 `ra_vk_ctx_init_headless()`。
- ✅ **B. 单渲染路径**:`vo_gpu_next` 在无 swapchain 时让 IOSurface 冒充 swapchain frame、只渲染一次。
- ✅ **C. 诚实桩 + 可见性**:headless swapchain fns 全 NULL → 回落 audio-sync;验证夹具用 `force-render=yes`。
- ✅ **D. 门① 双缓冲**:`xr_resident_texture.m` 2-IOSurface 环(`back_tex`/`publish_front`/`front_iosurface_id`),
  交替写、发布最新完整 ID。验证:`distinct=2`、`flips≈30/s`、sample 非空。
  ⚠️ 同步仍是 `pl_gpu_finish` 全停;异步跨设备 fence 未做(后续)。
- ✅ **E. RealityKit 消费侧**:2 个 `TextureResource`,每帧读 front 切绑定。
- ✅ **F. 窗口↔沉浸热切**:运行时改 `gpu-context`(`UPDATE_VO` → 只重建 VO,不重启 mpv)。
  注意:mpv 调用须在后台线程(mac 窗口 VO 重建会 `main.sync` 回主线程,主线程同步调 mpv 会死锁);
  `uninit` 须 `xr_resident_destroy(gpu)` 释放常驻纹理(否则切回沉浸复用悬空纹理)。
- ⬜ **异步 fence**:把全停换成跨设备(Vulkan→Metal)信号量,消除每帧 GPU stall。
- ⬜ **visionOS 交叉编译**:贴 RealityKit 球面,真机验证 MoltenVK device 一致性与同步(阶段 2 本体)。
