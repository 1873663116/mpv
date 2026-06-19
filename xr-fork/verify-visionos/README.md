# verify-visionos — mpv 纹理注入 Vision Pro 验证

把 mpv(经 gpu-next → libplacebo → MoltenVK)渲染的视频帧,以**零拷贝、常驻 IOSurface
Metal 纹理**注入 Reality Composer Pro 场景的 `screen` 平面;**unlit、不受 tone mapping
影响**(ADR 0004 色彩契约)。另设 AVFoundation 对照屏(`screen(AV(` 平面)。

阶段 2 的 visionOS 版,macOS 版在 `../verify/`。

## 它消费什么(解耦边界)

本 app **不引用** Enchron、**不往 Xrplay_scene 塞代码**,只消费三样产物:

| 产物 | 来源 | 提供 |
|---|---|---|
| `Libmpv.xcframework` | 本仓库经 MPVKit 构建的 visionOS libmpv | mpv + `xr_resident_*` 常驻出口 |
| 其余依赖 xcframework | MPVKit 官方同版本(0.41.0-n8.1)远程包 | FFmpeg / MoltenVK / libplacebo / libass … |
| `Immersive_Space.reality` | Xrplay_scene 导出的 RCP 场景 | `world` → `screen` / `screen(AV(` 平面 |

`import Libmpv` 即拿到 `mpv_*` 与 `xr_resident_*`(头在 framework 的 umbrella module 里)。

## 注入机制(逐帧零拷贝)

1. `ResidentVideoSurface` 建 2 张 IOSurface,各包一张 `.rgba8Unorm_srgb` 的 Metal 纹理
   (`TextureResource.__texture(from:)`,visionOS SDK 已确认可用)→ 这是零拷贝。
2. `MpvPlayer` 用 `--gpu-context=macvk_resident` 让 mpv 无窗渲染进这些 IOSurface;色彩按
   ADR 0004 钉死(`target-trc=srgb` / `treat-srgb-as-power22=input` / `target-colorspace-hint=no`)。
3. `VideoFrameSystem`(RealityKit System)每帧读 `xr_resident_front_iosurface_id()`,把
   `screen` 实体的材质换成对应 front 缓冲的 `UnlitMaterial(applyPostProcessToneMap: false)`。
4. `AVController` 给 `screen(AV(` 贴 `VideoMaterial(avPlayer:)` 做对照。

## 构建运行

前置:Xcode(含 xros SDK)、`brew install xcodegen`,且已产出 `Libmpv.xcframework`
(见下「依赖产物的来历」)。

```bash
bash script/setup.sh          # 拷场景 .reality + xcodegen 生成工程
# Xcode 打开 VerifyVisionOS.xcodeproj → 选真机签名 → Run
# 或仅验证编译链接(免签名):
xcodebuild -project VerifyVisionOS.xcodeproj -scheme VerifyVisionOS \
  -destination 'generic/platform=visionOS' build CODE_SIGNING_ALLOWED=NO
```

控制窗有「进入沉浸场景」按钮;进入后看两块屏:右 `screen` = mpv,左 `screen(AV(` = AVFoundation。
放一个 `Resources/sample.mp4` 可让两者播**同一片源**做公平色彩比对;无样片时 mpv 退回 testsrc2
彩条、AV 对照跳过。

## 依赖产物的来历(Libmpv.xcframework 怎么来的)

用 MPVKit(基线 = 本仓库 mpv 0.41.0 + libplacebo 7.360.1 + MoltenVK 1.4.1)本地构建:

```bash
git clone --depth 1 https://github.com/mpvkit/MPVKit ~/Applications/MPVKit
# 种入本仓库 enchron 源(beforeBuild 见目录存在即跳过 clone+patch):
rsync -a --exclude .git --exclude build --exclude xr-fork \
  ~/Applications/mpv/ ~/Applications/MPVKit/dist/libmpv-v0.41.0/
# MPVKit 侧两处改:
#  1. Sources/BuildScripts/XCFrameworkBuild/main.swift:BuildMPV.arguments 加
#     -Dlibcurl/libarchive/cdda/dvdnav/sixel=disabled(homebrew .pc 泄漏会卡 xros 交叉编译)
#  2. Package.swift:Libmpv binaryTarget 的 url+checksum 换成
#     path: "dist/release/xcframework/Libmpv.xcframework"
cd ~/Applications/MPVKit && make build platform=xros   # 产出 xros + xrsimulator 双 slice
```

## 本仓库为此做的 mpv 源改动(durable,可 rebase)

- **moltenvk context 合并**(MPVKit `0001` 补丁的内容并入 enchron,构建时不再打补丁):
  `context_moltenvk.m`(新)+ `meson.build` / `meson.options` / `video/out/gpu/context.c` /
  `video/out/vulkan/common.h`。受 `moltenvk` feature 守卫,本机 macOS 冒烟须 `-Dmoltenvk=disabled`
  (头只在 brew、不在 LunarG SDK 路径)。
- **可移植性修复**:`xr_resident_texture.m` 的 `<IOSurface/IOSurface.h>` → `<IOSurface/IOSurfaceRef.h>`
  (伞头在 iOS/visionOS SDK 不公开;IOSurfaceRef.h 两平台通用)。

## 真机待验(build pass ≠ 体验正确)

- **场景加载**:`.reality` 含 RealityKitScripting 脚本图,本 app 不 boot RKS(它非系统框架);
  几何应正常加载,脚本驱动的行为不跑。若 `Entity(named:"world")` 失败,日志会报。
- **Vulkan 起不起得来**:已删 macOS 的 `VK_ICD_FILENAMES`,visionOS 靠静态链接的 MoltenVK;
  真机首帧能否出图是第一道坎。
- **色彩**:mpv Unlit sRGB vs AVFoundation 系统色彩管理,判据是「无结构性偏差」非逐像素一致(ADR 0004)。
- **HDR**:出口按 SDR 设计;真 HDR 裁决见 ADR 0004 开放问题。
