# RealityKitVerifyApp

> 验证专用的**参考消费者**,不是 libmpv 的依赖(libmpv 构建图里没有它,生产打包天然无视)。
> 接入只认 `include/mpv/xr_resident.h` 的 API;本 app 只是其中一个实现样例。

阶段 1 验证夹具:libmpv 播放 `av://lavfi:testsrc2` 测试视频,顶部段控件在两种模式间**热切**
(不重启 mpv):

- `Window`:`xr_resident_set_enabled(false)`,mpv 走正常窗口管线(出现 mpv 窗口)。
- `Immersive`:`xr_resident_set_enabled(true)` + `--gpu-context=macvk_resident`,mpv 渲染进 Swift
  预建的两张 IOSurface(双缓冲环)。RealityKit 用同一张 IOSurface-backed `MTLTexture` 构造纹理资源,
  零拷贝贴到自转的长方体上,每帧跟随 mpv 发布的 front。

构建与运行:

```bash
./script/build_and_run.sh                 # 编 libmpv + 打包 app 并启动(默认 immersive)
./script/build_and_run.sh --window        # 默认起窗口模式
```

脚本会用 `-Dlibmpv=true` 配置并编译 `../../build-libmpv`,再构建打包本 SwiftPM app(最低 macOS 26.0)。

热切验证(对运行中的 app):
```bash
kill -USR1 $(pgrep -x RealityKitVerifyApp)   # → 窗口模式(mpv 窗口出现、盒子冻结)
kill -USR2 $(pgrep -x RealityKitVerifyApp)   # → 沉浸模式(窗口消失、盒子继续播)
# 日志:/tmp/realitykit-verify.log(front/flips/distinct/sample 逐帧)
```
> `SIGUSR1/2` 是验证用测试钩子(`RealityKitVerifyApp.swift`),等价于点段控件。
