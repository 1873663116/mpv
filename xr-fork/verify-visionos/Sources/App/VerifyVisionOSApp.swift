import RealityKit
import RealityKitScripting
import SwiftUI
import UniformTypeIdentifiers

@main
struct VerifyVisionOSApp: App {
    @State private var model = VerifyModel()

    @MainActor
    init() {
        // 调试夹具:最先装信号级崩溃处理器,捕获 mpv_initialize 等 C 层原生信号崩溃的栈。
        CrashHandler.install()

        // RCP 场景里的实体/材质由 Reality Composer Pro 的 Script Graph 驱动;必须在任何
        // 带脚本实体的 RealityView 渲染之前,在进程启动时把脚本运行时启起来一次。
        // 漏了这步,.scriptingSystem() 空转,场景资产依赖注册不上 →
        // NetworkAssetManager / Invalid sampler binding 报错,沉浸场景加载失败。
        // 与参考 app(Xrplay_scene/Immersive Space)一致。
        do {
            try RKS.initialize()
        } catch {
            fatalError("Failed to initialize RealityKitScripting runtime: \(error)")
        }

        // 自定义组件/系统必须先注册再使用。
        ResidentVideoComponent.registerComponent()
        VideoFrameSystem.registerSystem()
    }

    var body: some SwiftUI.Scene {
        WindowGroup {
            ControlPanel(model: model)
        }
        .defaultSize(width: 460, height: 240)

        ImmersiveSpace(id: "verify") {
            ImmersiveView(model: model)
        }
        .immersionStyle(selection: .constant(.progressive), in: .progressive)
    }
}

/// 简易控制窗:显示状态 + 进/出沉浸场景。验证用,不追求 UI。
struct ControlPanel: View {
    let model: VerifyModel

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var open = false
    @State private var showPicker = false
    @State private var showTuning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enchron · mpv 纹理验证")
                .font(.headline)
            Text(model.status)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button("选择视频…") { showPicker = true }
                Button(open ? "退出沉浸场景" : "进入沉浸场景") {
                    Task {
                        if open {
                            await dismissImmersiveSpace()
                            open = false
                        } else if case .opened = await openImmersiveSpace(id: "verify") {
                            open = true
                        }
                    }
                }
            }
            // [xr-debug] 2D 探针:不进沉浸空间,单测 mpv_initialize 是否崩。
            Button("测试 mpv_init(2D)") { model.testMpvInit() }
            // 隔离实验:进沉浸(阶段0=纯场景)后,逐级打开我们自己的层,定位崩在哪一层。
            if open {
                HStack(spacing: 12) {
                    Button("① 接纹理面") { model.enableTexturePlane() }
                    Button("② 启动 mpv") { model.enableMpv() }
                    // 暂停/继续:同步冻结 mpv 与 AVPlayer,便于两屏逐帧对比。
                    Button(model.isPaused ? "继续" : "暂停") { model.togglePause() }
                    // Gate 1 手动复跑(首帧后也会自动跑一次)。
                    Button("运行验证") { model.runVerification() }
                }
                // 运行时调参面板:全部 libplacebo/mpv 色彩旋钮 + 实时仪表 + 可拖进度条 + A/B/导出。
                Button("🎛 打开调参面板") { showTuning = true }
            }
        }
        .padding(24)
        .frame(width: 460)
        .sheet(isPresented: $showTuning) {
            NavigationStack {
                TuningPanelView(store: model.tuning, jump: { model.tuningJump($0) })
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.movie]) { result in
            if case .success(let url) = result {
                model.selectVideo(url)
            }
        }
        .onAppear {
            // [xr-debug] 模拟器自主测试:设了 XR_AUTOTEST 就在启动后自动跑 mpv_init 探针,
            // 免去在模拟器里手点 UI。用 SIMCTL_CHILD_XR_AUTOTEST=1 注入。
            if ProcessInfo.processInfo.environment["XR_AUTOTEST"] != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    model.testMpvInit()
                }
            }
            // [xr-verify] headless 自驱:模拟器自动跑完整 Gate 1(建纹理环+启 mpv,不进沉浸空间)。
            // 用 SIMCTL_CHILD_XR_HEADLESS_VERIFY=1 注入,日志按 [xr-verify] 过滤。
            if ProcessInfo.processInfo.environment["XR_HEADLESS_VERIFY"] != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    model.runHeadlessVerify()
                }
            }
        }
    }
}
