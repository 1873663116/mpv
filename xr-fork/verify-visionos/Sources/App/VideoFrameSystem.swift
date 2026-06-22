import RealityKit

/// 标记组件:挂在被驱动的视频实体上,供 [[VideoFrameSystem]] 查询。
/// LLDR 零拷贝路径下不再逐帧换材质(一张材质常驻、永不换);换帧由 [[VideoFrameSystem]].update 每帧
/// 节拍驱动(指针级 `replace(deviceResource:)`)。故本组件退化为纯标记。
struct ResidentVideoComponent: Component {}

/// 渲染心跳 + 换帧驱动:每帧 update 累加 renderTicks(渲染端 fps 的粗略代理,绝对值/瓶颈以 RealityKit
/// Trace 为准),并跟随 RealityKit 每帧节拍驱动零拷贝换帧(调 VerifyModel 安装的 [[onFrameTick]])。
/// `update(context:)` 是 @MainActor,可安全调 @MainActor 的 `LowLevelTexture.replace` —— 这取代了旧的
/// 自走 ~120Hz `Task.sleep` 循环(Instruments 真机实测:自走循环与显示/视频两个时钟都不同步 → 拍频
/// 抖动 + 主线程 `CFRunLoop` 空转;而 GPU/CPU 本身仅 ~4/3ms,远低于 11.1ms 预算)。
struct VideoFrameSystem: System {
    static let query = EntityQuery(where: .has(ResidentVideoComponent.self))

    /// 性能计数器(渲染线程单写、主线程读作 HUD,良性竞争)。
    /// `renderTicks`=渲染回调次数(≈刷新率);`framesPublished`=实际换上的新视频帧数(onFrameTick 单写)。
    nonisolated(unsafe) static var renderTicks = 0
    nonisolated(unsafe) static var framesPublished = 0
    /// [xr-perf 测量] 冻结换帧开关(诊断):update 据此暂停 replace,只留纯采样;真机读 renderFPS 定瓶颈。
    nonisolated(unsafe) static var freezeSwap = false
    /// 每帧节拍换帧回调(VerifyModel 安装):每帧 update 调它一次驱动换帧。回调内读当前 surface,
    /// 故 reload 重建 surface 后自动跟上,无需重设。update 为 @MainActor → 闭包也是 @MainActor。
    nonisolated(unsafe) static var onFrameTick: (@MainActor () -> Void)?

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        Self.renderTicks &+= 1
        if !Self.freezeSwap { Self.onFrameTick?() }
    }
}
