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
        // 控制窗 = 准备台:选片 + 选模式。极简,进沉浸后高频控制交给各场景内遥控器。
        WindowGroup {
            ControlPanel(model: model)
        }
        .defaultSize(width: 460, height: 420)

        // 窗口模式:2D 窗口里平面播放(选片即播,不进沉浸)。
        WindowGroup(id: "player") {
            PlayerWindow(model: model)
        }
        .defaultSize(width: 720, height: 520)

        // 调参窗:从遥控器/控制窗按需打开,独立浮窗。
        WindowGroup(id: "tuning") {
            NavigationStack {
                TuningPanelView(store: model.tuning, jump: { model.tuningJump($0) })
            }
        }
        .defaultSize(width: 520, height: 720)

        // 沉浸模式:RCP 场景 + 虚拟屏。
        ImmersiveSpace(id: "immersive") {
            ImmersiveView(model: model)
        }
        .immersionStyle(selection: .constant(.progressive), in: .progressive)

        // 全景模式:裸朝内球(360/180),独立 scene。全景天然要包裹用户 → full 沉浸。
        ImmersiveSpace(id: "panorama") {
            PanoramaView(model: model)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

/// 控制窗 = 准备台:选片 + 进/出沉浸,极简。进沉浸后高频控制移到沉浸内遥控器
/// (`LiveControlPanel`)。排版借 Enchron design system 的理念,不引其包,保持 verify app 零耦合。
struct ControlPanel: View {
    let model: VerifyModel

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var mode: VerifyModel.DisplayMode = .immersive
    @State private var activeImmersive: String? = nil
    @State private var windowActive = false
    @State private var showPicker = false
    @State private var showDebug = false

    private var isActive: Bool { activeImmersive != nil || windowActive }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusCard
                sourceSection
                modeSection
                if isActive {
                    Text("高频控制(投影/暂停/AV对照/调参)在当前模式自带的遥控器上。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                debugSection
            }
            .padding(24)
        }
        .frame(width: 460)
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
            // [xr-stereo] 立体材质加载自测:SIMCTL_CHILD_XR_STEREO_TEST=1 注入,日志按 [xr-stereo] 过滤。
            if ProcessInfo.processInfo.environment["XR_STEREO_TEST"] != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    model.testStereoMaterialLoad()
                }
            }
            // [xr-bench] 投影开销对照:XR_BENCH_FILE=<path> → 自动进全景,整球 12s → 半球 12s。
            // 同一文件、只变投影 = 单变量。videoFPS 看 [xr-perf](proj=...),阶段看 [xr-bench]。
            if let benchPath = ProcessInfo.processInfo.environment["XR_BENCH_FILE"] {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await model.prepareBench(path: benchPath)
                    model.setMode(.panorama)
                    _ = await openImmersiveSpace(id: "panorama")
                    model.benchLog("=== PHASE sphere360 begin ===")
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    model.setPanoramaProjection(.hemisphere180)
                    model.benchLog("=== PHASE hemisphere180 begin ===")
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    model.benchLog("=== PHASE done ===")
                }
            }
            // [xr-perf 诊断] headless 自动进沉浸空间:触发沉浸 RealityView(installScene + 面板 attachment),
            // 用于在模拟器上无 UI 读「liveControls 面板展开实体数」与 RealityKit 瓶颈。SIMCTL_CHILD_XR_AUTO_IMMERSIVE=1。
            if ProcessInfo.processInfo.environment["XR_AUTO_IMMERSIVE"] != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    model.setMode(.immersive)
                    _ = await openImmersiveSpace(id: "immersive")
                }
            }
        }
    }

    // MARK: - 分组子视图

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube.transparent")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Enchron · mpv 纹理验证")
                .font(.headline)
            Spacer()
            // 当前模式指示灯。
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? .green : .secondary)
                    .frame(width: 8, height: 8)
                Text(isActive ? "\(modeName(model.mode)) 中" : "未进入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func modeName(_ m: VerifyModel.DisplayMode) -> String {
        switch m { case .window: "窗口"; case .immersive: "沉浸"; case .panorama: "全景" }
    }

    /// 进入所选模式:先退当前,再开对应 scene(只能开一个 ImmersiveSpace,故先互斥关闭)。
    private func enter(_ m: VerifyModel.DisplayMode) async {
        await exitAll()
        model.setMode(m)
        switch m {
        case .window:
            openWindow(id: "player"); windowActive = true
        case .immersive:
            if case .opened = await openImmersiveSpace(id: "immersive") { activeImmersive = "immersive" }
        case .panorama:
            if case .opened = await openImmersiveSpace(id: "panorama") { activeImmersive = "panorama" }
        }
    }

    private func exitAll() async {
        if activeImmersive != nil { await dismissImmersiveSpace(); activeImmersive = nil }
        if windowActive { dismissWindow(id: "player"); windowActive = false }
    }

    private var statusCard: some View {
        Text(model.status)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var sourceSection: some View {
        SectionCard(title: "片源", icon: "film") {
            Button { showPicker = true } label: {
                Label("选择视频…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    /// ★ 显示模式:三选一,各是独立 scene。选片后选模式进入。
    private var modeSection: some View {
        SectionCard(title: "显示模式", icon: "rectangle.3.group") {
            VStack(spacing: 12) {
                Picker("模式", selection: $mode) {
                    Text("窗口").tag(VerifyModel.DisplayMode.window)
                    Text("沉浸").tag(VerifyModel.DisplayMode.immersive)
                    Text("全景").tag(VerifyModel.DisplayMode.panorama)
                }
                .pickerStyle(.segmented)
                Text(modeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { Task { await enter(mode) } } label: {
                    Label("进入「\(modeName(mode))」模式", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                if isActive {
                    Button(role: .destructive) { Task { await exitAll() } } label: {
                        Label("退出当前模式", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var modeHint: String {
        switch mode {
        case .window: "2D 窗口平面播放 — 选片即播,不进沉浸"
        case .immersive: "RCP 虚拟屏 — 私人影院,平面/平面3D"
        case .panorama: "裸朝内球 — 360/180 全景,进入后遥控器切"
        }
    }

    /// 调试:Gate 1 复跑 + mpv_init 探针。默认折叠,验收时不碍眼。
    private var debugSection: some View {
        DisclosureGroup(isExpanded: $showDebug) {
            VStack(spacing: 12) {
                if isActive {
                    Button("运行验证(Gate 1)") { model.runVerification() }
                        .frame(maxWidth: .infinity)
                }
                Button("测试 mpv_init(2D)") { model.testMpvInit() }
                    .frame(maxWidth: .infinity)
                // 路 B 命门:验手写立体材质能否被 RealityKit 加载。
                Button("测试立体材质加载") { model.testStereoMaterialLoad() }
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 8)
        } label: {
            Label("调试 / 管线", systemImage: "wrench.and.screwdriver")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// 分组卡片:统一标题(图标+文字)+ 内容,圆角材质背景。verify app 专用,不引 Enchron 包。
private struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
