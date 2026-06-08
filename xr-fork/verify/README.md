# RealityKitVerifyApp

阶段 1 验证夹具:双击打开后由 libmpv 播放 `av://lavfi:testsrc2` 测试视频。app 带一个验证用假开关:

- `Window`:关闭 `XR_RESIDENT`,不配置 IOSurface,mpv 走正常窗口管线。
- `Immersive`:开启 `XR_RESIDENT`,把视频帧渲染进 Swift 预先创建的 IOSurface。RealityKit 通过同一张 IOSurface-backed `MTLTexture` 构造纹理资源,零拷贝贴到固定斜角的长方体上。

构建与运行:

```bash
./script/build_and_run.sh
./script/build_and_run.sh --verify --window
./script/build_and_run.sh --verify --immersive
```

脚本会先用 `-Dlibmpv=true` 重新配置并编译 `../../build-libmpv`,再构建并打包本 SwiftPM app。
本验证 app 与本地 `libmpv` 构建一致,最低运行系统标为 macOS 26.0。
