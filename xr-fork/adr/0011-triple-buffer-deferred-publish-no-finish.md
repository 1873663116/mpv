# ADR 0011 — 三缓冲 + 延迟一帧发布,替掉每帧 pl_gpu_finish 全停

状态:Proposed(待真机签收) ｜ 日期:2026-06-21 ｜ 上承:[ADR 0003](0003-windowless-producer-and-double-buffer.md)

## 背景

ADR 0003 给门①定的阶段 1 设计是「双缓冲(非三,省一张显存)+ 渲染后每帧 `pl_gpu_finish` 全停再发布」。
全停是为保证「发布 front 前 IOSurface 已写完」,因为 RealityKit 侧不提供任何「等 GPU fence」的钩子,
只能在生产者侧暴力等齐。

真机实测暴露代价:播 **360 度 4K(3840×2160 AV1)** 时 `videoFPS≈10`(源 25)、`renderFPS` 站不稳 90;
而播分辨率小一半的 180 文件正常。根因不是投影(mpv 对投影是瞎的,只渲一张平帧),是**每帧全停把渲染
彻底串行化**:`pl_gpu_finish` 抽干整条 GPU 队列,mpv 渲第 N 帧→干等 GPU 全跑完→才发布→才开第 N+1 帧,
零流水线;且与 RealityKit 共用一块 GPU,全停戳出的气泡也拖累合成器。代价随渲染分辨率涨,故只在 4K 咬人。

## 决策

**1. 缓冲 2→3。** 三张让「正写 / 待发布 / 消费中」三个角色任一时刻互不重叠;双缓冲做不到延迟发布
(写指针会撞上待发布张)。多一张 IOSurface 显存(4K fp16 ≈ 64MB)换吞吐,值。

**2. 全停 → 非阻塞提交 + 单纹理 fence。** `pl_gpu_finish`(全队列阻塞)换成:
   - `pl_gpu_flush`:仅提交本帧渲染、不阻塞,保证及时入队,流水线才能真重叠;
   - `pl_tex_poll(gpu, 上一帧那张, UINT64_MAX)`:**只等上一帧**那张缓冲写完再发布它。上一帧已过一整个
     帧间隔,稳态下几乎必然完成 → 等待近乎为零;而本帧 GPU 工作与 RealityKit 消费并行推进。

**3. 延迟一帧发布。** 渲完本帧不立即发布,记为 pending;下一次 draw_frame 时才发布它(此时已写完)。
代价是 +1 帧延迟,视频播放无感。

`pl_tex_poll` 是 libplacebo 文档点名的正解用法:「外部内存(IOSurface)需知导入纹理何时写完、可安全移交」。

## 取舍与边界

- **为何不用跨设备信号量(`pl_vulkan_hold/release`)。** 那是更"正"的异步 fence,但要消费端能等这个信号量;
  RealityKit 不给等待钩子,信号量递不过去。故只能在生产者侧用 poll 保证写完——对本架构这不是权宜,是正解。
  真正的信号量移交要等 RealityKit 暴露同步点或改走 `DrawableQueue`,属另一议题。
- **撕裂风险。** 仅当 GPU 严重过载、单帧渲染耗时 > 一个完整 draw_frame CPU 周期,poll 才会真自旋等待
  (退化为接近旧全停的串行,但不撕裂);三缓冲保证写目标(本帧)与发布目标(上一帧)永不同张。
- **+1 帧延迟、+1 张显存。** 见上,均可接受。

## 验证

- ✅ 本地 macOS `meson compile` 过(`xr_resident_texture.m` + `vo_gpu_next.c` typecheck/link)。
- ⬜ **真机签收(本 ADR 转 Accepted 的前提)**:360 4K 的 `videoFPS` 应升向源帧率、`renderFPS` 站稳 90+,
  且无撕裂/接缝错位。若真机出现撕裂 → 回退本 ADR(改回 0003 全停),状态转 Rejected 并记录现象。

## 落地

| 文件 | 改动 |
|---|---|
| `video/out/vulkan/xr_resident_texture.m` | `XR_RING_MAX` 2→3;新增 `g_pending_idx` + `xr_resident_submit_back()`(flush + 上一帧 poll + 延迟发布),替掉 `xr_resident_publish_front()` |
| `video/out/vo_gpu_next.c` | `xr_publish_render_target` 改调 `xr_resident_submit_back`,删每帧 `pl_gpu_finish` |
| `include/mpv/xr_resident.h` | 注释 1~2 张 → 1~3 张 |
| `xr-fork/verify-visionos/.../ResidentVideoSurface.swift` | `bufferCount` 2→3 |
