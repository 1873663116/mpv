# ADR 0010 — 渲染出口的承载体:mpv 侧封装优先,libplacebo fork 后端作记录在案的升级路径

状态:Accepted(选 B 封装;C 作期权)｜ 日期:2026-06-19
上承 [ADR 0003](0003-windowless-producer-and-double-buffer.md)、[ADR 0009](0009-visionos-unified-realitykit-output.md)

## 背景

常驻 IOSurface 出口当前在 **mpv 侧**实现:`vo_gpu_next.c` 的 `draw_frame` 绕过 libplacebo swapchain,
手工捏 `pl_swapchain_frame.fbo` 指向导入的 IOSurface 纹理。代价是 mpv 侧散落多处 `!p->sw` 守卫
(`draw_frame` 分叉、`flip_page`、`set_colorspace_hint`、丢帧、`uninit` 释放)——上游每改一处,我们跟着对。

提出的根治方案:**fork libplacebo,在它内部加一个「渲染到外部 IOSurface/Metal 纹理」的 swapchain
后端**。则 mpv 侧 `p->sw` 是真 swapchain,主路径多态分流,散落守卫全消失。问题:这是否是更优的承载体?

## 关键事实裁决(subagent 调研 libplacebo v7.360.1 源码,2026-06-19)

技术可行且干净,且推翻了「内部 API 不稳」的先验:

- **接口极稳**:swapchain 内部抽象 `struct pl_sw_fns`(`src/swapchain.h:28-39`,7 个函数指针:
  destroy/latency/resize/colorspace_hint/start_frame/submit_frame/swap_buffers)**两年零改动**
  (末次实质改动 2023-02)。比 mpv 的 `draw_frame` 还稳。新后端写成独立 `.c` 几乎不蹭冲突。
- **互操作基础现成**:Vulkan 后端经 `VK_EXT_metal_objects` 已支持 `PL_HANDLE_MTL_TEX` /
  `PL_HANDLE_IOSURFACE` 导入(`src/vulkan/gpu_tex.c:358-365`)——正是 mpv 侧现在用的同一套,零新增。
- **工程量中偏小**:最简后端 ~150-250 行(参照 `src/opengl/swapchain.c` 仅 278 行);需新增一个
  公开工厂(纯增量 ABI,不破坏现有)。无现成 headless/offscreen swapchain 蓝本,但 `pl_sw_fns` 槽位极薄。
- **真陷阱**:① `start_frame` 持锁返回、`submit_frame` 解锁的**配对锁语义**必须照抄;
  ② 外部 IOSurface 尺寸变化要在 `resize`/`start_frame` 处理纹理重建。
- **构建链**:阶段 2 用 MPVKit 打包,**本就从源码自编 libplacebo**——故 C 的打包侧构建成本几近为零,
  只剩「本地开发构建从 brew libplacebo 切到自管 fork」这一次性设置。

## 决策

**先做 B(mpv 侧封装),C(fork libplacebo 后端)记录在案作升级路径。**

- **B**:把 `draw_frame` 里 surfaceless 那段(获取渲染目标)抽成 `vo_gpu_next.c` 内的 static 函数,
  令 `draw_frame` 函数体内的 xr 侵入从 ~70 行散码收缩为几个「一行调用点」(`#if` 包裹)。窗口路径一字不动。
  守卫②③⑤(`set_colorspace_hint`/`flip_page`/`uninit`)本就各只一行、且卡在必经点,保持原样。
- 收益:零新依赖、零构建链改动;拿走「整洁度」交换里的大部分——上游改 `draw_frame` 时冲突面只剩调用点。
- 这不解决也不试图解决性能:`pl_gpu_finish` 全停那个 fence 债与 B/C 正交,另行处理。

## 不选什么 / 期权(C 的完整记录,免将来重新调研)

C 若实施,libplacebo 侧改动清单:① 新增 `src/vulkan/swapchain_iosurface.c`(priv 首成员 `pl_sw_fns`
+ 双缓冲 pl_tex 环;start_frame 返回后台纹理、submit_frame 发布 front、swap_buffers 等 fence);
② `src/include/libplacebo/vulkan.h` 加公开工厂 + params;③ `src/vulkan/stubs.c` 加 disabled stub;
④ `meson.build` 注册源文件 + API version。mpv 侧:`context.c` 的 headless 路径改调新工厂,使 `p->sw`
为真 swapchain,删掉 B 收拢的那些调用点。探索副本已 clone 在 `~/Applications/libplacebo`(v7.360.1)。

## 翻盘条件(何时从 B 升级到 C)

满足任一:① 阶段 2 MPVKit 自编 libplacebo 链路已跑通(此时 C 构建成本触底),且愿为「主路径零侵入」
投入一次本地构建切换;② B 的几个调用点在某次上游 rebase 中仍反复冲突(说明 mpv 边界比预期不稳);
③ 需要 libplacebo 层才能做的能力(如把 fence/呈现时序纳入 swapchain 契约)。

## 后果

- 短期:mpv 侧 diff 更集中、rebase 更省心;不引入第二个 fork。
- 长期:C 的可行性、证据、改动清单已固化于此,升级是「按图施工」而非「重新评估」。
- fence 性能债仍独立存在(ADR 0009 已记),不被本决策影响。
