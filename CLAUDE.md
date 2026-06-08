# CLAUDE.md — Enchron 的 mpv fork 工作指南

这不是上游 mpv 的开发仓库。这是 **Enchron / XrPlayer**(visionOS 沉浸视频播放器,位于
`/Users/xiongzhipeng/Applications/Enchron`)的 mpv **fork**,唯一存在理由是为那个项目
定制一条「拿到视频帧 Metal 纹理」的渲染出口。

> 上游来源:`github.com/1873663116/mpv`(fork 自 mpv-player/mpv),基线版本 v0.41.0。
> 我们自己的东西全部集中在根目录 `CLAUDE.md` 和 `xr-fork/` 下,不散落到上游文件里。

---

## 唯一目标(第三条路)

让 `vo_gpu_next`(经 libplacebo → Vulkan → MoltenVK)渲染出的视频帧,以一张
**常驻的、IOSurface-backed 的 Metal 纹理**形式暴露出来,交给 Enchron 的 RealityKit
材质系统采样。

不走的几条路,以及为什么不走,见 `xr-fork/adr/0001-render-to-offscreen-iosurface-texture.md`。

**窗口模式不归我们管**:屏幕直出继续走上游原本的 `draw_frame`(swapchain 呈现)。新增代码只在
`XR_RESIDENT=1` 时进入;开关关闭时,窗口模式行为应与未改 mpv 一致。
我们只新增一条「非窗口 / 离屏」出口。

当前验证 app 先做一个假开关:
- `Window`:清掉 `XR_RESIDENT`,不配置 IOSurface,mpv 走正常窗口管线。
- `Immersive`:设置 `XR_RESIDENT=1`,Swift 提供 IOSurface,mpv/libplacebo 渲染进这张纹理,
  RealityKit 采样同一张纹理。

生产目标是在 Enchron 路由里把这个假开关替换成真实 if/else:窗口播放走原 mpv 管线;
全景 / 沉浸空间播放走 RealityKit 纹理路径。

---

## 三阶段路线

| 阶段 | 证明的唯一一件事 | 边界 | 状态 |
|---|---|---|---|
| **0a** | 「改→编→跑→验」闭环通(用现成截图功能) | macOS / cplayer / 不改代码 | ✅ 已完成 |
| ~~0b~~ | ~~渲染到常驻离屏纹理 + PNG 验证~~ | **已取消**:PNG 验证只是重测截图,验不了"常驻"的真正价值(被外部采样),并入阶段 1 | ❌ |
| **1** | 新增「常驻纹理出口」并用 macOS RealityKit app 验证可实时采样 | macOS / libmpv / IOSurface-backed `MTLTexture` → `TextureResource.__texture(from:)` | ✅ 已完成 |
| **2** | visionOS 上贴到 RealityKit 球面正确、无撕裂 | 交叉编译 + 同步/设备一致性验证 | ⬜ |

阶段 1 已证明:mpv 可渲染进 Swift 提供的 IOSurface-backed `MTLTexture`,macOS RealityKit 可实时采样。

---

## 进度日志

- ✅ **0a**:gpu-next/MoltenVK 离屏截图通(`./build/mpv` 截图正确)。
- ✅ **1.0 探针**:`import.tex` 支持 `MTL_TEX`+`IOSURFACE`,`export.tex`=0(导出死路 → 走导入方向)。
- ✅ **1.1 探针**:renderable IOSurface 纹理导入成功(`renderable=1`)。**曳光弹唯一技术风险点已清零。**
  - 探针代码:`video/out/vulkan/xr_resident_texture.m` 的 `xr_probe_renderable_import()`;
    调用在 `vo_gpu_next.c` preinit(`#if HAVE_VULKAN && defined(__APPLE__)`)。
  - ⚠️ **技术债**:当前用 `MTLCreateSystemDefaultDevice()` fallback(`vkExportMetalObjectsEXT`
    未取到 device,疑因 vulkan 头未启用 `VK_EXT_metal_objects` 宏)。单 GPU Mac 上
    系统 device == MoltenVK device 所以可行;严谨实现(多 GPU / visionOS)应拿 MoltenVK 真 device。
- ✅ **常驻纹理出口 + RealityKit 验证 app 完成**:`XR_RESIDENT=1` 时,Swift 创建 IOSurface,
  mpv import 同一 `IOSurfaceID` 渲染,RealityKit 用 `TextureResource.__texture(from:)`
  零拷贝贴到固定斜角长方体。验证 app 在 `xr-fork/verify/`。
  - 验证 app 带 `Window / Immersive` 假开关:Window 分支关闭 resident 出口,
    Immersive 分支开启 resident 出口。
  - ⚠️ 仍是验证形态:渲染驱动依赖被最小化的 mpv 窗口;同步仍是 `pl_gpu_finish`;
    多 GPU / visionOS 还要处理真实 MoltenVK device 与 fence/双缓冲。

## 改动纪律(为了将来能 rebase 上游)

1. **最小、集中**:理想是改动只碰一两个文件、几十行,能写成独立 patch。改得越少,rebase 越不疼。
2. **绝不顺手改无关代码**。每多碰一行上游代码,未来 rebase 多一份冲突。
3. **新增优先于修改**:能新加一个函数/分支,就不去重写既有函数。
4. `master` 分支保持干净、只跟踪上游;所有工作在 `enchron` 分支。
   更新上游:`git fetch upstream && git rebase upstream/master`(在 enchron 分支上)。
5. 我们自己的文档/脚本只放 `xr-fork/`,上游永远不会碰它们,天然零冲突。

---

## 关键代码坐标(`video/out/vo_gpu_next.c`)

| 出口 | 函数/位置 | target 从哪来 | 渲染后 |
|---|---|---|---|
| **屏幕出口(不改)** | `draw_frame` ~:1289 / `flip_page` :1511 | `pl_swapchain_start_frame`(借来的画布) | `pl_swapchain_submit_frame` 呈现 |
| **离屏出口(改这里)** | 截图函数 `video_screenshot` ~:1660–1819 | `pl_tex_create`(自建画布) | `pl_tex_download` 取走 |

离屏出口的四步模板(阶段 0b/1 照着改):
```c
fbo = pl_tex_create(gpu, ...renderable=true, host_readable=true);  // 自建离屏画布
struct pl_frame target = { .planes[0].texture = fbo, ... };        // 包成渲染目标
pl_render_image(p->rr, &image, &target, &params);                  // 画进去（与屏幕同一引擎）
pl_tex_download(gpu, ...tex=fbo);                                   // 取走（阶段1 改为暴露 IOSurface 句柄，不再 download）
```

mac 事实:`vo_gpu_next` 在 mac 上只有 `--gpu-api=vulkan`(macvk),无 OpenGL。
mac 窗口 Swift 代码绑定 MoltenVK:`MetalLayer`(CAMetalLayer 子类)定义于
`video/out/mac/metal_layer.swift`,仅在 `cocoa && vulkan && swift` 时编入(meson.build:1663)。
所以本地构建**必须开 vulkan**。

---

## 本地构建与验证(macOS,阶段 0/1 用;已验证可复现)

依赖(brew):`meson ninja libplacebo molten-vk libass`(`ffmpeg pkg-config cmake` 通常已有)。

配置 + 编译:
```bash
meson setup build \
  -Dcplayer=true -Dlibmpv=false -Dtests=false \
  -Dlua=disabled -Djavascript=disabled \
  -Dvulkan=enabled -Dvideotoolbox-pl=disabled \
  -Dcocoa=enabled -Dgl=enabled
meson compile -C build      # ~22s,产物 ./build/mpv
```

冒烟验证(gpu-next/MoltenVK 渲染 + 截图,会短暂弹窗):
```bash
export VK_ICD_FILENAMES=/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json
./build/mpv "av://lavfi:testsrc2=size=1280x720:rate=30" \
  --vo=gpu-next --gpu-api=vulkan --no-audio --no-terminal \
  --input-ipc-server=/tmp/mpv.sock --idle=yes &
sleep 5
printf '{"command":["screenshot-to-file","/tmp/shot.png","video"]}\n' | nc -U /tmp/mpv.sock
printf '{"command":["quit"]}\n' | nc -U /tmp/mpv.sock
# 打开 /tmp/shot.png 应看到彩条测试图案
```

> 阶段 2 的 visionOS 构建是另一套(`-Dlibmpv=true -Dcplayer=false` + 交叉编译 + xcframework),
> 与此处的本地 cplayer 构建不同。Enchron 里那份 `docs/reference/mpv-build-guide.md` 描述的是
> **另一条已废弃的路(SW→CVPixelBuffer)**,不要照搬;阶段 2 时重写它。

---

## 命名约定与术语

见 `xr-fork/conventions.md`。要点:代码符号跟随 mpv snake_case,我们新增的对外符号加 `xr_` 前缀;
概念/功能/文件命名与术语表(如「常驻纹理出口」)都在该文件统一维护。

---

## 协作约定

- 编码、配环境、编译、调试由 Claude 执行;用户是产品经理,负责定方向与验收。
- 决策结晶后写进 `xr-fork/adr/`;本文件是操作指南,不堆背景叙事。
