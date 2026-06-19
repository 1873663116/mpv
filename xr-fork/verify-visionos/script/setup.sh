#!/bin/bash
# 生成 VerifyVisionOS.xcodeproj 并备齐运行所需的本地产物。
# 前置:已跑通 xr-fork 的 MPVKit xros 构建(产出 ~/Applications/MPVKit/dist/release/xcframework/Libmpv.xcframework)。
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # verify-visionos/
SCENE_SRC="$HOME/Applications/Xrplay_scene/Immersive Space/Immersive Space/Immersive_Space.reality"
LIBMPV="$HOME/Applications/MPVKit/dist/release/xcframework/Libmpv.xcframework"

echo "== 前置检查 =="
[ -d "$LIBMPV" ] || { echo "✗ 缺 $LIBMPV;先跑 MPVKit xros 构建"; exit 1; }
command -v xcodegen >/dev/null || { echo "✗ 缺 xcodegen:brew install xcodegen"; exit 1; }

echo "== 拷贝 RCP 场景产物(gitignored)=="
mkdir -p "$HERE/Resources"
if [ -f "$SCENE_SRC" ]; then
  cp "$SCENE_SRC" "$HERE/Resources/Immersive_Space.reality"
  echo "  ✓ Immersive_Space.reality"
else
  echo "  ⚠ 未找到 $SCENE_SRC —— 场景将加载失败,请确认 Xrplay_scene 已导出"
fi

echo "== 可选样片 =="
[ -f "$HERE/Resources/sample.mp4" ] \
  && echo "  ✓ 发现 sample.mp4 —— mpv 与 AVFoundation 将放同一片源" \
  || echo "  ⓘ 无 sample.mp4 —— mpv 退回 testsrc2、AVFoundation 对照跳过(放一个 Resources/sample.mp4 即可启用对照)"

echo "== 生成工程 =="
cd "$HERE"
xcodegen generate
echo "✓ VerifyVisionOS.xcodeproj 已生成"
echo
echo "下一步:Xcode 打开 VerifyVisionOS.xcodeproj,选真机签名后 Run;或"
echo "  xcodebuild -project VerifyVisionOS.xcodeproj -scheme VerifyVisionOS \\"
echo "    -destination 'generic/platform=visionOS' build CODE_SIGNING_ALLOWED=NO"
