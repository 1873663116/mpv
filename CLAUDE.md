# CLAUDE.md — Enchron 的 mpv fork 工作指南

这不是上游 mpv 的开发仓库。这是 **Enchron / XrPlayer**(visionOS 沉浸视频播放器,位于
`/Users/xiongzhipeng/Applications/Enchron`)的 mpv **fork**,唯一存在理由是为那个项目
定制一条「拿到视频帧 Metal 纹理」的渲染出口。

> 上游来源:`github.com/1873663116/mpv`(fork 自 mpv-player/mpv),基线版本 v0.41.0。
> 我们自己的东西全部集中在根目录 `CLAUDE.md` 和 `xr-fork/` 下,不散落到上游文件里。

---

## 唯一目标

让 `vo_gpu_next`(经 libplacebo → Vulkan → MoltenVK)渲染出的视频帧,以一张
**常驻的、IOSurface-backed 的 Metal 纹理**形式暴露出来,交给 Enchron 的 RealityKit
材质系统采样。不走的几条路见 `xr-fork/adr/0001`。

两条出口,运行时可热切(不重启 mpv):
- **窗口模式**:走上游原本的 swapchain 呈现,行为与未改 mpv 一致。
- **沉浸模式**:`xr_resident_set_enabled(true)` + `--gpu-context=macvk_resident`,mpv 渲染进
  Swift 提供的 IOSurface,RealityKit 采样同一张纹理。

生产目标:在 Enchron 路由里用窗口/沉浸的真实 if/else 调用上面这对开关。

---

## 三阶段路线

| 阶段 | 证明的唯一一件事 | 状态 |
|---|---|---|
| **0a** | 「改→编→跑→验」闭环通(用现成截图功能) | ✅ |
| **1** | 常驻纹理出口 + macOS RealityKit app 实时采样 + 窗口↔沉浸热切 | ✅ |
| **2** | visionOS 上贴 RealityKit 球面正确、无撕裂(交叉编译 + 设备一致性) | ⬜ |

---

## 我们动了哪些地方

mpv 侧(改动尽量新增、集中):

| 文件 | 改动 |
|---|---|
| `video/out/vulkan/xr_resident_texture.m`(新增) | IOSurface 导入 + 双缓冲环 + 模式开关(`xr_resident_*`) |
| `video/out/vulkan/context_mac_resident.m`(新增) | 无窗 surfaceless 上下文 `macvk_resident`(只建设备,不建窗口/swapchain) |
| `video/out/vulkan/context.{c,h}` | 新增 `ra_vk_ctx_init_headless()`;`ra_vk_ctx_get` 放行 headless |
| `video/out/gpu/context.c` | 注册 `macvk_resident` 上下文 |
| `video/out/vo_gpu_next.c` | `draw_frame` 新增 surfaceless 出口(渲染进后台 IOSurface 并发布 front);`uninit` 无条件释放常驻纹理;`flip_page`/`set_colorspace_hint` 加 `!p->sw` 守卫;headless+未启用时丢帧防御;xr 调用点全在 `__APPLE__ && HAVE_VULKAN` 内 |
| `include/mpv/xr_resident.h`(新增) | 对 Swift 暴露的 API:`set_enabled` / `configure_external_iosurfaces` / `front_iosurface_id` / `clear` |
| `meson.build` | 以 `vulkan && darwin` 守卫编入上述两个新 `.m`(刻意不依赖 cocoa/swift,否则 visionOS 打包会把出口编没,见 ADR 0004) |

设计与权衡见 ADR;落地步骤与同步细节见 `xr-fork/adr/0003`;**色彩出口契约见 `xr-fork/adr/0004`**
(沉浸出口 = IEC sRGB 字节,消费端 `_srgb` 视图 + Unlit 关 tone map;窗口模式
`--target-colorspace-hint=yes` 修 macOS 发白;两组选项随热切一并设置,参考实现
`xr-fork/verify/.../MpvPlayer.swift` 的 `colorOptions`)。

## 解耦边界(给下一个 Agent)

- libmpv **完全不知道 verify app 存在**(`meson`/源码零引用);对外耦合面只有
  `include/mpv/xr_resident.h` 的 4 个函数 + 标准 libmpv client API。
- `xr-fork/verify/` 是**验证专用的参考消费者**(macOS RealityKit app),不是依赖。它不在
  libmpv 构建图里,打包 libmpv 时**天然无视、无需特殊排除**;接入新 app 照那套 API 即可。
- ⚠️ **visionOS 的「窗口模式」尚未解决**:现窗口模式走 mpv 原生 `macvk`,绑死 AppKit
  (`mac_common.swift`),visionOS 无 AppKit → 跑不了。visionOS 上**两种模式都应走 IOSurface 出口**
  (mpv 当生产者),由 Enchron 决定把纹理贴球面还是贴 2D 窗口;别让 mpv 自己开窗。

## 剩余

- 异步跨设备 fence(替掉当前 `pl_gpu_finish` 全停);`check_nonzero` 抽样是验证夹具,生产接入时去掉。
- 阶段 2 打包:用 **MPVKit**(github.com/mpvkit/MPVKit,基线恰为 mpv v0.41.0 + libplacebo 7.360.1
  + MoltenVK 1.4.1,与本仓库一致)fork 后改 `main.swift` 两行指向本 fork 的 enchron 分支;
  ⚠️ 它的 `0001-player-add-moltenvk-context.patch` 与我们改了同两个文件,须把补丁合进 enchron
  分支再删脚本侧 patch;`make build platform=xros` 出 xcframework。visionOS 上两种模式都走
  IOSurface 出口(无 AppKit)。
- 真机 HDR 裁决实验(ADR 0004 开放问题):rgba16Float + Unlit + 关 tone map 能否在 Vision Pro
  上超过 SDR 白;不需要 mpv,纯 RealityKit 小实验。
- 数值验收(可选加强):IOSurface 字节 vs `screenshot-to-file` sRGB PNG 逐块比对。

---

## 改动纪律(为了将来能 rebase 上游)

1. **最小、集中**:改动只碰必要文件、能写成独立 patch。改得越少,rebase 越不疼。
2. **绝不顺手改无关代码**;每多碰一行上游,未来多一份冲突。
3. **新增优先于修改**:能新加函数/分支,就不重写既有函数。
4. `master` 保持干净只跟踪上游;所有工作在 `enchron` 分支。
   更新上游:`git fetch upstream && git rebase upstream/master`(在 enchron 上)。
5. 我们的文档/脚本只放 `xr-fork/`,天然零冲突。

---

## 本地构建与验证(macOS,已验证可复现)

依赖(brew):`meson ninja libplacebo molten-vk libass`(`ffmpeg pkg-config cmake` 通常已有)。
mac 上 `vo_gpu_next` 只有 `--gpu-api=vulkan`(MoltenVK),无 OpenGL,所以**必须开 vulkan**。

**cplayer 冒烟**(改→编→截图闭环):
```bash
meson setup build -Dcplayer=true -Dlibmpv=false -Dtests=false \
  -Dlua=disabled -Djavascript=disabled \
  -Dvulkan=enabled -Dvideotoolbox-pl=disabled -Dcocoa=enabled -Dgl=enabled
meson compile -C build      # 产物 ./build/mpv
export VK_ICD_FILENAMES=/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json
./build/mpv "av://lavfi:testsrc2=size=1280x720:rate=30" --vo=gpu-next --gpu-api=vulkan \
  --no-audio --no-terminal --input-ipc-server=/tmp/mpv.sock --idle=yes &
sleep 5
printf '{"command":["screenshot-to-file","/tmp/shot.png","video"]}\n' | nc -U /tmp/mpv.sock
printf '{"command":["quit"]}\n' | nc -U /tmp/mpv.sock   # /tmp/shot.png 应是彩条
```

**常驻纹理 + 热切验证**(libmpv + RealityKit app):
```bash
xr-fork/verify/script/build_and_run.sh            # 编 libmpv(build-libmpv/)+ Swift app 并启动
# 热切:对运行中的 app 发 SIGUSR1→窗口、SIGUSR2→沉浸;日志在 /tmp/realitykit-verify.log
```

> 阶段 2 的 visionOS 构建是另一套(交叉编译 + xcframework),与此处本地构建不同;届时再写。

---

## 命名约定与协作

- 命名/术语见 `xr-fork/conventions.md`:代码符号随 mpv snake_case,对外新增符号加 `xr_` 前缀。
- 编码、配环境、编译、调试由 Claude 执行;用户是产品经理,定方向与验收。
- 决策结晶写进 `xr-fork/adr/`;本文件是操作指南,不堆背景叙事。
