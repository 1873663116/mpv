import Darwin
import Foundation
import Libmpv
import RealityKit
import SwiftUI
import UIKit
import os

/// 编排:加载 RCP 场景(`Entity(named:"world")`,来自 bundle 的 Immersive_Space.reality),
/// 把 mpv 常驻纹理绑到 `screen` 平面、AVFoundation 对照绑到 `screen(AV(` 平面。
///
/// 解耦边界:本 app 不引用 Enchron、不引用 Xrplay_scene 源码;只消费两样产物——
/// libmpv 的 `xr_resident.h` 四个函数 + Xrplay_scene 导出的 .reality 场景文件。
@MainActor
@Observable
final class VerifyModel {
    var status = "idle"
    /// 暂停态(对照验证用):mpv 与 AVPlayer 同步冻结/恢复,供 UI 切换按钮文案。
    var isPaused = false

    private let logger = Logger(subsystem: "enchron.verify.visionos", category: "verify")
    /// 渲染分辨率:换片时按视频原生尺寸探测后填(reloadAtNativeResolution);testsrc/未选片时为默认。
    private var width = 1280
    private var height = 720
    /// [xr-perf 杠杆A·调试开关] 渲染分辨率长边上限。0 = 不限(原生,默认)。>0 = 等比压到此长边内。
    /// 这是"硬吃"的应急杠杆,不是正解;正解是杠杆2(按内容路由像素格式,不损画质)。默认关,
    /// 仅在调参面板手动开启用于对照。设 1920 即等距 360 → 1920×960。
    private var xrMaxLongEdge = 0
    /// [xr-perf 杠杆2] 像素格式路由:模式(自动/强制)+ 当前解析出的格式。建 IOSurface 前解析,
    /// 换片/换模式时随分辨率一并重定。见 [[XRColorRoute]] / ResidentVideoSurface。
    private var routeMode: XRRouteMode = .auto
    private var currentRoute: XRColorRoute = .hdr16
    /// mpv 屏实体(运行时重建材质 / 重载用)。
    private var mpvScreenEntity: Entity?
    /// 消费端状态(非 mpv 属性):RealityKit tone map 归属 + EDR 曝光乘子。
    private var realityKitToneMap = false
    private var edrExposure = 1.0
    /// EDR 曝光>1 时 target-peak 提亮的基准(= 策略一默认峰值)。
    private let exposurePeakBase = 406.0
    /// 连续漂移校正阈值(秒):|av−mpv| 超过即把 AV 重对齐到 mpv 主钟。≈3–4 帧@30fps,避免反复 seek 抖动。
    private let driftTolerance = 0.12
    /// 纹理/IOSurface 比例。消费端按此把面片等比定形(铺满、无黑边、不失真)。窗口模式平面也用它。
    var displayAspect: Float { Float(width) / Float(height) }
    /// 纹理转正的面内自转量(1/4 圈为单位)。面片网格 UV 随建模平面朝向被转了 90°,
    /// 需绕法线反转回来。-1 = 顺时针 90°;若视频呈上下颠倒/仍旋转,改这里的符号或圈数即可。
    private let textureQuarterTurns: Float = -1
    /// 各面片的原始 RCP transform(orientPanel 的幂等基准:每次都从原始推导,避免反复叠加)。
    private var originalPanelTransforms: [String: Transform] = [:]

    /// 顶层显示模式(三选一,各是独立 scene):
    /// - `window`:WindowGroup 平面播放窗(选片即播,不进沉浸)。
    /// - `immersive`:RCP 场景 + 虚拟屏(私人影院)。
    /// - `panorama`:裸朝内球(360/180),独立于 RCP 场景。
    enum DisplayMode: String, CaseIterable { case window, immersive, panorama }
    private(set) var mode: DisplayMode = .immersive

    /// 全景模式下的子投影(只在 panorama 内有意义)。
    enum PanoramaProjection: String, CaseIterable { case sphere360, hemisphere180 }
    private(set) var panoramaProjection: PanoramaProjection = .sphere360

    /// 立体拆眼(路 A 单眼正确):mono=整幅;SBS/TB 取主眼半幅烘进 UV。真景深(左右眼分离)
    /// 留给后续 RCP Camera Index Switch(同一套 `StereoLayout` 数学)。
    private(set) var stereoPacking: StereoLayout.Packing = .mono
    private(set) var stereoSwap = false

    /// 全景球实体(panorama 模式;运行时建/拆)。`mpvScreenEntity`(上方)= RCP 虚拟屏。
    private var panoramaEntity: Entity?
    /// 窗口模式平面实体。
    private var windowPlaneEntity: Entity?
    /// AV 对照屏开关:默认**关**。开则并行解第二路(色彩比对用),8K 素材会显著加载;
    /// 真机看全景只需 mpv 单路,需比色时再开。遥控器/控制窗都可切。
    private(set) var avEnabled = false

    private var surface: ResidentVideoSurface?
    private let mpv = MpvPlayer()
    private let av = AVController()
    private var world: Entity?
    private var sampleCount = 0
    private var mpvStarted = false
    /// 文件选择器选中的片源:沙盒读取需持有安全作用域,整段播放期间不释放。
    private var scopedURL: URL?
    /// 当前接入 AV 对照的片源 URL(含模拟器自动样片);Gate 1 读它的 HDR 元数据。
    private var currentAVURL: URL?
    /// Gate 1 一次性自动验证:首帧后跑一次(loop 重启不重复)。
    private var didAutoVerify = false
    /// 饱和度探针一次性标志(seek 会再触发 PLAYBACK_RESTART,防重入)。
    private var didProbe = false
    /// 探针取样时刻(秒):2s 与 27s = 高光/色彩/对比度与 AV 差异最大的两帧(用户指定对照帧)。
    /// 经 env XR_PROBE_FRAMES="2,27" 可覆盖;各 config 轮次都测同两帧,跨轮逐帧对照。
    private let probeSeekFrames: [Double] = {
        if let s = ProcessInfo.processInfo.environment["XR_PROBE_FRAMES"] {
            let v = s.split(separator: ",").compactMap { Double($0) }
            if !v.isEmpty { return v }
        }
        return [2.0, 27.0]
    }()

    // ── 运行时调参面板(TuningPanel,ADR 0008 后续):把全部 libplacebo/mpv 色彩旋钮暴露给播放时热拧 ──
    let tuning = TuningStore()
    private var tuningWired = false

    /// mpv 起好后接线 tuning store(读回当前生效值、恢复持久化、启动仪表/进度轮询)。enableMpv 调一次。
    private func wireTuning() {
        guard !tuningWired else { return }
        tuningWired = true
        tuning.setCb = { [weak self] n, v in self?.mpv.setColorProperty(n, v) }
        tuning.getCb = { [weak self] n in self?.mpv.getProperty(n) ?? nil }
        tuning.seekCb = { [weak self] t in self?.mpv.seekAbsolute(t) }
        tuning.toggleCb = { [weak self] in self?.togglePause() }
        tuning.sampleCb = { [weak self] in self?.sampleMetrics() ?? nil }
        tuning.timeCb = { [weak self] in self?.mpv.timePosDur() ?? nil }
        tuning.syncCb = { [weak self] in self?.correctDriftIfNeeded() }
        tuning.reloadCb = { [weak self] in self?.reloadAtNativeResolution() }
        tuning.rollOffCb = { [weak self] on in self?.setRealityKitToneMap(on: on) }
        tuning.exposureCb = { [weak self] m in self?.setEdrExposure(m) }
        tuning.routeModeCb = { [weak self] m in self?.setRouteMode(m) }
        tuning.resolutionCapCb = { [weak self] on in self?.setResolutionCap(on ? 1920 : 0) }
        tuning.freezeSwapCb = { [weak self] on in self?.setFreezeSwap(on) }
        tuning.isPaused = isPaused
        tuning.rollOffRealityKit = realityKitToneMap
        tuning.edrExposure = edrExposure
        tuning.routeMode = routeMode
        tuning.resolutionCapOn = xrMaxLongEdge > 0
        tuning.freezeSwap = VideoFrameSystem.freezeSwap
        tuning.attach()
        report("[xr-tune] 调参面板已接线 —— 控制窗『调参面板』进入")
    }

    /// 跳到对照帧(2s/27s):seek mpv,AV 经 PLAYBACK_RESTART 自动对齐。
    func tuningJump(_ t: Double) { mpv.seekAbsolute(t) }

    /// 读 front IOSurface 的 fp16 仪表(>1.0高光% / 黑位p1 / 饱和p90 / >2.0过曝%),显示无关。
    private func sampleMetrics() -> (gt1: Double, p1: Double, sat: Double, gt2: Double)? {
        // sampleLuminanceStats/sampleChroma 硬当 fp16(8 字节/像素)读;sdr8 路是 4 字节/像素,
        // 按 8 字节步进会越界/读垃圾。故仅 fp16 路采样(仪表本就是 HDR 色彩验证用)。
        guard currentRoute == .hdr16 else { return nil }
        let f = xr_resident_front_iosurface_id()
        guard let surface, f != 0 else { return nil }
        let L = surface.sampleLuminanceStats(forID: f)
        let c = surface.sampleChroma(forID: f)
        return (Double(L.fracGt1 * 100), Double(L.p1), Double(c.p90), Double(L.fracGt2 * 100))
    }

    // ───────────────────────────────────────────────────────────────────────
    // 隔离实验(定位崩溃在「我们的代码」还是「RCP 场景」):参考 app 加载同一个
    // .reality、同种接法,真机能正常进沉浸 → 场景没问题,崩在我们多出来的代码。
    // 于是把我们的东西拆成三级,运行时逐级打开,一次构建即可定位到具体哪一层崩。
    // ───────────────────────────────────────────────────────────────────────

    /// 阶段 0:只加载并显示 RCP 场景,不接任何我们自己的东西。这一步与参考 app 等价。
    /// 若此处就崩 → 问题在工程配置/场景加载,与 mpv 无关;正常 → 用下面两级开关继续定位。
    func installScene(into content: RealityViewContent) async {
        mpv.onStatus = { [weak self] message in
            // 仅更新头显状态行;mpv 日志的 os_log 已由 MpvPlayer.dbg 单份落地,这里不重复记录,
            // 避免每行日志被打两遍(控制台减半,呼应 Xcode MCP 自取日志的降噪需求)。
            self?.status = message
        }
        // mpv 首帧/循环重启时(PLAYBACK_RESTART)把 AV 对齐到 mpv 时间并一起起播:
        // mpv 的 VO/Vulkan 初始化有秒级延迟,AV 起得早很多——以 mpv 为主钟,消除起播错位。
        mpv.onPlaybackStart = { [weak self] in
            guard let self else { return }
            self.syncAVToMpv(play: !self.isPaused)
            // Gate 1 自动验证:首帧就绪后等几秒(让 IOSurface 写入若干帧、解码参数稳定)跑一次。
            if !self.didAutoVerify {
                self.didAutoVerify = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.runVerification()
                }
            }
        }

        if let world {            // 再次进入沉浸:复用已加载场景(与参考 app 一致)。
            content.add(world)
            return
        }

        let world: Entity
        do {
            world = try await Entity(named: "world")
        } catch {
            report("加载场景失败: \(error.localizedDescription)")
            return
        }
        content.add(world)
        self.world = world
        // 转储整棵实体树名字:.reality 是 AES 加密 zip,离线挖不出实体名;
        // 真实名(尤其 AV 对照面片)从这里的 [xr-scene] 行确认(经 Xcode MCP 读控制台)。
        dumpEntityNames(world)
        // 沉浸模式:绑 RCP 虚拟屏 + 起播(幂等)。
        mode = .immersive
        enterImmersiveScreen()
        report("沉浸场景已加载,起播中…")
    }

    /// 性能 HUD 文本(遥控器显示):渲染帧率 / 视频出帧率 / 内存。
    var perf = "perf —"
    private var perfStarted = false

    /// 每 5 秒采样一次帧率计数器(原 1s 刷屏),算出渲染 fps 与视频出帧 fps,落 HUD + 日志。
    /// ⚠️ 这是粗略量,非地面真值:`renderTicks` 数的是 System.update 调用次数,且在 MainActor 拥塞时
    /// `Task.sleep` 会漂移——故改用**真实经过时间**换算(修掉旧版把每秒次数算成 2~3 倍、冒出 >90 假值的 bug)。
    /// 绝对帧率/瓶颈归属以 Instruments『RealityKit Trace』的 GPU/CPU Frame Time 为准,此处仅作现场速览。
    /// 诊断:videoFPS 远低于源帧率 = 卡在 mpv 解码/出帧;renderFPS 也低 = 卡在 RealityKit 渲染端。
    private func startPerfMonitor() {
        guard !perfStarted else { return }
        perfStarted = true
        var lastTicks = VideoFrameSystem.renderTicks
        var lastFrames = VideoFrameSystem.framesPublished
        var lastDrop = 0, lastDecDrop = 0
        var lastNanos = DispatchTime.now().uptimeNanoseconds
        Task { @MainActor [weak self] in
            while let self, self.mpvStarted {
                try? await Task.sleep(nanoseconds: 5_000_000_000)   // 5s:降打印频率
                let nowNanos = DispatchTime.now().uptimeNanoseconds
                let elapsed = Double(nowNanos &- lastNanos) / 1_000_000_000   // 真实经过秒(非假定窗口)
                lastNanos = nowNanos
                guard elapsed > 0.1 else { continue }
                let t = VideoFrameSystem.renderTicks, f = VideoFrameSystem.framesPublished
                let rFps = Double(t - lastTicks) / elapsed
                let vFps = Double(f - lastFrames) / elapsed
                lastTicks = t; lastFrames = f
                let mem = Int(self.currentMemoryFootprintMB())
                // [xr-perf 诊断·第二问题] mpv 自带计数器,把"跳帧"钉到具体环节:
                // drop=VO 因晚到丢的帧(framedrop=vo 默认);decDrop=解码跟不上丢的;
                // vfFps=mpv 滤镜后实际产出帧率(≈源帧率说明 mpv 产得出,卡在下游;<源说明卡在 mpv)。
                let drop = Int(self.mpv.getProperty("frame-drop-count") ?? "") ?? lastDrop
                let decDrop = Int(self.mpv.getProperty("decoder-frame-drop-count") ?? "") ?? lastDecDrop
                let dDrop = drop - lastDrop, dDec = decDrop - lastDecDrop
                lastDrop = drop; lastDecDrop = decDrop
                let vfFps = self.mpv.getProperty("estimated-vf-fps") ?? "?"
                // [xr-perf 杠杆2·带宽估算] 真·硬件带宽计数器 visionOS 不开放,这里给可解释的估算:
                // 写 = 每帧整张纹理 × 发布帧率;读 = 每帧整张 × 渲染帧率(上界,忽略缓存命中)。
                let texMB = Double(self.currentRoute.bytesPerPixel * self.width * self.height) / 1_048_576.0
                let bwGBs = texMB * (vFps + rFps) / 1024.0
                let rI = Int(rFps.rounded()), vI = Int(vFps.rounded())
                let frozen = VideoFrameSystem.freezeSwap ? " · ❄️冻结" : ""
                self.perf = "渲染 \(rI) · 视频 \(vI)fps · \(self.currentRoute.label) · ~\(String(format: "%.1f", bwGBs))GB/s · \(mem)MB · \(self.width)×\(self.height)\(frozen)"
                self.logger.info("[xr-perf] renderFPS=\(rI, privacy: .public) videoFPS=\(vI, privacy: .public) frozen=\(VideoFrameSystem.freezeSwap, privacy: .public) vfFps=\(vfFps, privacy: .public) drop=\(dDrop, privacy: .public) decDrop=\(dDec, privacy: .public) route=\(self.currentRoute.rawValue, privacy: .public) texMB=\(String(format: "%.1f", texMB), privacy: .public) bw~\(String(format: "%.1f", bwGBs), privacy: .public)GB/s mem=\(mem, privacy: .public)MB res=\(self.width, privacy: .public)x\(self.height, privacy: .public) mode=\(self.mode.rawValue, privacy: .public)")
            }
        }
    }

    /// [xr] LLDR 零拷贝换帧驱动:把换帧并入 RealityKit 每帧节拍(VideoFrameSystem.update,@MainActor),
    /// 取代旧的自走 ~120Hz `Task.sleep` 轮询(Instruments 真机实测:自走循环与显示/视频两个时钟都不同步
    /// → 拍频抖动 + 主线程 `CFRunLoop` 空转,而 GPU/CPU 本身仅 ~4/3ms,远低于 11.1ms 预算)。
    /// 安装一个读"当前 surface"的回调,System 每帧调它(冻结开关在 update 内生效);surface 重建后
    /// 回调自动读到新值,无需重设。`xr_resident_front_iosurface_id` 变了才真切(presentFront 内部判)。
    private func startPresenter() {
        VideoFrameSystem.onFrameTick = { [weak self] in
            guard let self, let surface = self.surface else { return }
            let f = xr_resident_front_iosurface_id()
            if f != 0, surface.presentFront(f) { VideoFrameSystem.framesPublished &+= 1 }
        }
    }

    /// AV 对照开关(遥控器/控制窗):开则接同源第二路解码做色彩比对,关则停掉省负载。
    func setAVComparison(_ on: Bool) {
        avEnabled = on
        if on {
            if let url = currentSourceURL {
                attachAV(url: url)
                report("AV 对照已开 → \(url.lastPathComponent)")
            } else {
                report("AV 对照:当前无真实片源(testsrc 无对照,跳过)")
            }
        } else {
            av.stop()
            report("AV 对照已关(单路解码)")
        }
    }

    // ── 生命周期(模式无关):IOSurface 环 + mpv,各模式共用一份 ──

    /// 建 IOSurface 纹理环(若未建)。是 mpv 渲染目标,必须在 mpv 起前按尺寸备好。
    @discardableResult
    private func ensureSurface() -> ResidentVideoSurface? {
        if surface == nil {
            do { surface = try ResidentVideoSurface(width: width, height: height, route: currentRoute) }
            catch { report("建 IOSurface 失败: \(error.localizedDescription)"); return nil }
        }
        return surface
    }

    /// 启动 mpv(若未启动):渲染进 IOSurface 环,逐帧换 front。幂等。
    private func startMpvIfNeeded() {
        guard let surface, !mpvStarted else { return }
        do {
            let (mpvSource, avURL) = resolveSources()
            try mpv.start(source: mpvSource, surfaceIDs: surface.iosurfaceIDs,
                          width: surface.width, height: surface.height, route: surface.route)
            mpvStarted = true
            if avEnabled, let avURL { attachAV(url: avURL) }
            wireTuning()
            startPerfMonitor()
            startPresenter()
            Task { @MainActor in await loadStereoMaterialIfNeeded() }   // 预载立体材质,切 SBS/TB 即用
            report("mpv 已启动 \(surface.width)x\(surface.height) | src=\(mpvSource)")
        } catch {
            report("启动 mpv 失败: \(error.localizedDescription)")
        }
    }

    /// 通用绑定:把 IOSurface 环的逐帧材质挂到任意实体(平面/球面共用)。
    private func bindResident(to entity: Entity, faceCount: Int) {
        guard let surface else { return }
        let material = currentMaterial(surface)
        if var model = entity.components[ModelComponent.self] {
            model.materials = Array(repeating: material, count: max(1, faceCount))
            entity.components.set(model)
        }
        entity.components.set(ResidentVideoComponent())
    }

    // ── 三个模式各自的接入入口(由对应 scene 的 RealityView 调用)──

    /// 沉浸模式:绑 RCP 虚拟屏 `screen` + 摆正 + 起播。
    func enterImmersiveScreen() {
        guard let world, let screen = world.findEntity(named: "screen") else {
            report("沉浸:找不到 RCP 'screen' 实体"); return
        }
        guard ensureSurface() != nil else { return }
        mpvScreenEntity = screen
        let faceCount = screen.components[ModelComponent.self]?.materials.count ?? 1
        bindResident(to: screen, faceCount: faceCount)
        orientPanel(screen, textureAspect: displayAspect)
        startMpvIfNeeded()
    }

    /// 全景模式:建/复用朝内球(360/180)+ 绑定 + 起播,返回球实体供 scene 添加。
    func enterPanorama() -> Entity? {
        guard ensureSurface() != nil else { return nil }
        let entity = panoramaEntity ?? Entity()
        entity.name = "xr-panorama"
        panoramaEntity = entity
        applyPanoramaMesh(to: entity)
        startMpvIfNeeded()
        return entity
    }

    /// 窗口模式:绑窗口里的平面实体(立体可烘 UV)+ 起播。
    func enterWindowPlane(_ entity: Entity) {
        guard ensureSurface() != nil else { return }
        windowPlaneEntity = entity
        applyWindowQuad(to: entity)
        startMpvIfNeeded()
    }

    /// 装全景球:**满幅 equirect mesh**(分眼交给立体材质的 Camera Index Switch,mono 则整幅)+ 材质。
    private func applyPanoramaMesh(to entity: Entity) {
        guard let surface else { return }
        let spec: PanoramaMesh.Spec = (panoramaProjection == .sphere360) ? .sphere360 : .hemisphere180
        do {
            let mesh = try PanoramaMesh.makeResource(spec)
            let material = currentMaterial(surface)
            entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
            entity.components.set(ResidentVideoComponent())
            report("全景 = \(panoramaProjection.rawValue) · 立体 = \(stereoLabel)(朝内球 r=\(spec.radius)m)")
        } catch {
            report("建全景球失败: \(error.localizedDescription)")
        }
    }

    /// 装窗口/平面 quad:**满幅 UV** + 材质(分眼同上交给材质)。
    private func applyWindowQuad(to entity: Entity) {
        guard let surface else { return }
        do {
            let mesh = try PanoramaMesh.quad(aspect: displayAspect)
            let material = currentMaterial(surface)
            entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
            entity.components.set(ResidentVideoComponent())
            report("窗口平面 · 立体 = \(stereoLabel)")
        } catch {
            report("建窗口平面失败: \(error.localizedDescription)")
        }
    }

    /// 切全景子投影(360↔180,热切无需重载)。
    func setPanoramaProjection(_ p: PanoramaProjection) {
        panoramaProjection = p
        guard let entity = panoramaEntity else { return }
        applyPanoramaMesh(to: entity)
    }

    /// 切立体拆眼(mono/SBS/TB + swap,热切)。SBS/TB 走 ShaderGraph 真分眼,先确保材质就绪再重绑。
    func setStereo(packing: StereoLayout.Packing, swap: Bool) {
        stereoPacking = packing
        stereoSwap = swap
        Task { @MainActor in
            if packing != .mono { await loadStereoMaterialIfNeeded() }
            switch mode {
            case .panorama: if let e = panoramaEntity { applyPanoramaMesh(to: e) }
            case .window:   if let e = windowPlaneEntity { applyWindowQuad(to: e) }
            case .immersive: report("沉浸虚拟屏暂不拆眼 — 看 3D 用窗口/全景模式")
            }
        }
    }

    private var stereoLabel: String {
        let p: String
        switch stereoPacking { case .mono: p = "mono"; case .sbs: p = "SBS"; case .tb: p = "TB" }
        return stereoPacking == .mono ? p : (stereoSwap ? "\(p)·swap" : p)
    }

    /// 模式标记(由控制窗在打开对应 scene 前/后设置,用于状态与 perf 日志)。
    func setMode(_ m: DisplayMode) { mode = m }

    /// [xr-perf 杠杆A] 把源宽高按 xrMaxLongEdge 等比压到上限内,长宽取偶数(采样/对齐友好)。
    /// 0 或已在上限内则原样返回。三个赋值点(prepareBench / reload / selectVideo)统一过这道。
    private func cappedRenderSize(_ w: Int, _ h: Int) -> (Int, Int) {
        guard xrMaxLongEdge > 0, max(w, h) > xrMaxLongEdge else { return (w, h) }
        let scale = Double(xrMaxLongEdge) / Double(max(w, h))
        let cw = max(2, Int((Double(w) * scale).rounded()) / 2 * 2)
        let ch = max(2, Int((Double(h) * scale).rounded()) / 2 * 2)
        return (cw, ch)
    }

    /// [xr-perf 杠杆2] 解析像素格式路由。强制模式直接定;auto 读源元数据(AVFoundation)判 HDR。
    /// 无 URL(testsrc 等)按 HDR 保守(保持现有 fp16 默认路径)。必须在建 IOSurface 前调用。
    private func resolveRoute(url: URL?) async {
        switch routeMode {
        case .forceSDR: currentRoute = .sdr8
        case .forceHDR: currentRoute = .hdr16
        case .auto:
            if let url { currentRoute = await av.probeIsHDR(url: url) ? .hdr16 : .sdr8 }
            else { currentRoute = .hdr16 }
        }
        logger.info("[xr-perf] route=\(self.currentRoute.rawValue, privacy: .public) mode=\(self.routeMode.rawValue, privacy: .public)")
    }

    /// [xr-bench] 投影开销对照:设源 + 探原生分辨率(供 App 层开全景空间后驱动 360↔180 对照)。
    func prepareBench(path: String) async {
        benchSource = path
        let url = URL(fileURLWithPath: path)
        if let sz = await av.naturalSize(url: url), sz.width > 0, sz.height > 0 {
            (width, height) = cappedRenderSize(Int(sz.width), Int(sz.height))
            benchLog("源 \(Int(sz.width))×\(Int(sz.height)) → 渲染 \(width)×\(height)(长边上限 \(xrMaxLongEdge))")
        }
        await resolveRoute(url: url)
        benchLog("准备完成 src=\(path) res=\(width)x\(height) route=\(currentRoute.rawValue)")
    }
    func benchLog(_ s: String) { logger.info("[xr-bench] \(s, privacy: .public)") }

    /// 换片重载后按当前模式重绑(surface 重建 → 材质引用全变,必须重绑)。
    private func rebindCurrentMode() {
        switch mode {
        case .immersive:
            if let screen = mpvScreenEntity {
                bindResident(to: screen, faceCount: screen.components[ModelComponent.self]?.materials.count ?? 1)
                orientPanel(screen, textureAspect: displayAspect)
            }
        case .panorama:
            if let e = panoramaEntity { applyPanoramaMesh(to: e) }
        case .window:
            if let e = windowPlaneEntity { applyWindowQuad(to: e) }
        }
    }

    /// 构造 mpv 屏材质。两个消费端旋钮在此生效:
    /// - `realityKitToneMap`:applyPostProcessToneMap。false=mpv 自己做软肩(直通);true=RealityKit 折 >1.0(与 mpv 互斥)。
    /// - `edrExposure`:<1 时用 tint 灰度做消费端即时衰减(>1 的提亮走 mpv target-peak,见 setEdrExposure)。
    private func makeMaterial(_ resource: TextureResource) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: realityKitToneMap)
        let tintLevel = CGFloat(min(max(edrExposure, 0), 1))   // tint 只能衰减(≤1),>1 提亮交给 target-peak
        material.color = .init(tint: UIColor(white: tintLevel, alpha: 1), texture: .init(resource))
        return material
    }

    /// 运行时重建 mpv 屏全部材质(切 roll-off 归属 / EDR 曝光后调)。纹理不变只换材质 —— 无需重载视频。
    /// 立即把当前 front 对应的新材质贴上,暂停态也即时生效。
    private func rebuildMaterials() {
        guard let surface else { return }
        // 立体(ShaderGraph)实体:重走 apply 保留分眼,不要被换成 Unlit。
        if stereoPacking != .mono {
            if let e = panoramaEntity, mode == .panorama { applyPanoramaMesh(to: e); return }
            if let e = windowPlaneEntity, mode == .window { applyWindowQuad(to: e); return }
        }
        // mono / 沉浸虚拟屏:重建那张常驻 UnlitMaterial(调色 roll-off/EDR 即时生效);纹理零拷贝不变。
        let material = currentMaterial(surface)
        for entity in [mpvScreenEntity, panoramaEntity, windowPlaneEntity].compactMap({ $0 }) {
            let faceCount = entity.components[ModelComponent.self]?.materials.count ?? 1
            if var model = entity.components[ModelComponent.self] {
                model.materials = Array(repeating: material, count: max(1, faceCount))
                entity.components.set(model)
            }
        }
    }

    // ── 立体真分眼(路 B):ShaderGraph + Camera Index Switch ──

    /// 手写的立体材质(StereoMaterial.usda),加载一次复用。已在模拟器证实可加载。
    private var stereoBaseMaterial: ShaderGraphMaterial?

    /// 加载立体材质(幂等,异步一次)。startMpv 后预载,切 SBS/TB 即用。
    private func loadStereoMaterialIfNeeded() async {
        guard stereoBaseMaterial == nil else { return }
        do {
            stereoBaseMaterial = try await ShaderGraphMaterial(named: "/Root/Material", from: "StereoMaterial")
            report("[xr-stereo] 立体材质已加载")
        } catch {
            report("[xr-stereo] 立体材质加载失败: \(error.localizedDescription)")
        }
    }

    /// 当前该用的**单一**材质:mono→UnlitMaterial,SBS/TB 且材质就绪→ShaderGraph 真分眼,否则回落 mono。
    /// LLDR 零拷贝下纹理是常驻单张(surface.textureResource),不再按缓冲建字典 —— 换帧靠 LLT.replace。
    private func currentMaterial(_ surface: ResidentVideoSurface) -> any RealityKit.Material {
        if stereoPacking != .mono, let stereo = stereoMaterial(surface) { return stereo }
        return makeMaterial(surface.textureResource)
    }

    /// 单一立体材质(ShaderGraph):`videoTexture` 绑常驻 textureResource + UV 拆半(左/右眼子矩形)。
    /// 分眼由 GPU 的 Camera Index Switch 每眼自动完成;参数一次性设定,无逐帧 setParameter。
    private func stereoMaterial(_ surface: ResidentVideoSurface) -> ShaderGraphMaterial? {
        guard var base = stereoBaseMaterial else { return nil }
        let l = StereoLayout.eyeRect(isLeft: true, packing: stereoPacking, swap: stereoSwap)
        let r = StereoLayout.eyeRect(isLeft: false, packing: stereoPacking, swap: stereoSwap)
        do {
            try base.setParameter(name: "sclX", value: .float(l.scale.x))
            try base.setParameter(name: "sclY", value: .float(l.scale.y))
            try base.setParameter(name: "offLX", value: .float(l.origin.x))
            try base.setParameter(name: "offLY", value: .float(l.origin.y))
            try base.setParameter(name: "offRX", value: .float(r.origin.x))
            try base.setParameter(name: "offRY", value: .float(r.origin.y))
            try base.setParameter(name: "videoTexture", value: .textureResource(surface.textureResource))
        } catch {
            report("[xr-stereo] 立体材质参数设置失败: \(error.localizedDescription)")
            return nil
        }
        return base
    }


    /// 摆正面片(纹理转正 + 等比定形,二合一,幂等)。两块屏共用,AV 与 mpv 同时摆正。
    ///
    /// 背景:面片网格是「平躺方形」立起来用的(extent 某轴≈0,尺寸全在 transform.scale),
    /// 立起来时 UV 跟着转了 90° → 贴上的视频(mpv UnlitMaterial 与 AV VideoMaterial 都吃这套 UV)
    /// 被旋转 90°。所以:① 绕面片法线做面内自转把纹理转正(法线不变 → 位置/朝向不变,只面内旋转);
    /// ② 转正后按世界朝向重新判定水平/竖直轴,绝对赋值定形为 16:9(保持原始高度,不放大)。
    private func orientPanel(_ entity: Entity, textureAspect: Float) {
        guard let mesh = entity.components[ModelComponent.self]?.mesh else {
            report("orientPanel: \(entity.name) 无 ModelComponent.mesh,跳过")
            return
        }
        // 原始 RCP transform 作幂等基准(首次捕获,之后每次都从它推导)。
        let base = originalPanelTransforms[entity.name] ?? entity.transform
        if originalPanelTransforms[entity.name] == nil { originalPanelTransforms[entity.name] = base }

        let ext = mesh.bounds.extents
        let extArr = [ext.x, ext.y, ext.z]
        let baseScaleArr = [base.scale.x, base.scale.y, base.scale.z]
        let eps: Float = 1e-5
        let planar = [0, 1, 2].filter { extArr[$0] > eps }     // 两个面内轴(排除 extent≈0 的法线轴)
        func axisVec(_ k: Int) -> SIMD3<Float> {
            k == 0 ? SIMD3<Float>(1, 0, 0) : (k == 1 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1))
        }
        let normalKey = [0, 1, 2].min(by: { extArr[$0] < extArr[$1] })!   // extent 最小 = 法线轴
        guard planar.count == 2 else {
            logger.info("[xr] orientPanel \(entity.name, privacy: .public) 无法定位平面轴 ext=(\(ext.x),\(ext.y),\(ext.z))")
            return
        }

        // 原始竖直高度 H(base 朝向下映射到世界 Y 的平面轴长度)→ 摆正后保持原尺寸,不放大。
        let origVAxis = planar.max(by: { abs(base.rotation.act(axisVec($0)).y) < abs(base.rotation.act(axisVec($1)).y) })!
        let targetHeight = extArr[origVAxis] * baseScaleArr[origVAxis]

        // ① 面内自转把纹理转正(绕法线,法线方向不变 → 位置/朝向保持)。
        var transform = base
        transform.rotation = simd_normalize(base.rotation * simd_quatf(angle: textureQuarterTurns * .pi / 2, axis: axisVec(normalKey)))

        // ② 转正后重新判定水平/竖直轴,绝对赋值定形 16:9(宽 = textureAspect*H,高 = H)。
        let widthKey = planar.max(by: { abs(transform.rotation.act(axisVec($0)).x) < abs(transform.rotation.act(axisVec($1)).x) })!
        let heightKey = planar.first(where: { $0 != widthKey })!
        var scale = base.scale
        scale[widthKey] = textureAspect * targetHeight / extArr[widthKey]
        scale[heightKey] = targetHeight / extArr[heightKey]
        transform.scale = scale

        let before = entity.visualBounds(relativeTo: nil).extents
        entity.transform = transform
        let after = entity.visualBounds(relativeTo: nil).extents
        logger.info("[xr] orientPanel \(entity.name, privacy: .public) 法线=\(normalKey) 宽轴=\(widthKey) 高=\(targetHeight) world前=(\(before.x),\(before.y),\(before.z)) 后=(\(after.x),\(after.y),\(after.z))")
    }

    /// 接入 AVFoundation 对照并等比适配。从 enableMpv(已选片启动)与 selectVideo(换片)两处调用 ——
    /// 旧逻辑只在 enableMpv 接一次,导致「先进沉浸启动 mpv、之后才选片」时 AV 永远连不上。
    private func attachAV(url: URL) {
        guard let world else { return }
        // 实体真名为 `screen(AV(`(括号不配对但确实如此);模糊匹配兼容,不再被死名坑。
        guard let avScreen = firstEntity(in: world, where: {
            let name = $0.name.lowercased()
            return name.contains("av") && name.contains("screen")
        }) ?? firstEntity(in: world, where: { $0.name.lowercased().contains("av") }) else {
            report("未找到 AV 对照面片;见控制台 [xr-scene] 实体名清单")
            return
        }
        currentAVURL = url
        av.attach(to: avScreen, url: url)
        orientPanel(avScreen, textureAspect: displayAspect)
        // 初始对齐:mpv 已在播 → AV 立刻对齐其时间并同播;否则保持暂停,等 mpv 首帧再一起起播。
        syncAVToMpv(play: mpvStarted && !isPaused)
        report("AVFoundation 对照 → \(avScreen.name) | \(url.lastPathComponent)")
    }

    /// 以 mpv 为主钟把 AVPlayer 对齐到同一时间点。play=true 则对齐后一起播,false 则定格同一帧。
    private func syncAVToMpv(play: Bool) {
        if let t = mpv.currentTime() {
            av.seek(to: t)
        }
        av.setPaused(!play)
    }

    /// 深度优先找首个满足条件的实体(RealityKit 的 findEntity 只支持精确名,这里支持谓词匹配)。
    private func firstEntity(in root: Entity, where match: (Entity) -> Bool) -> Entity? {
        if match(root) { return root }
        for child in root.children {
            if let found = firstEntity(in: child, where: match) { return found }
        }
        return nil
    }

    /// 转储实体树名字到 os_log(诊断:确认 RCP 场景里各面片的真实实体名)。
    private func dumpEntityNames(_ entity: Entity, depth: Int = 0) {
        let indent = String(repeating: "  ", count: depth)
        let name = entity.name.isEmpty ? "<unnamed>" : entity.name
        logger.info("[xr-scene] \(indent, privacy: .public)• \(name, privacy: .public)")
        for child in entity.children {
            dumpEntityNames(child, depth: depth + 1)
        }
    }

    /// 暂停/继续:同步切换 mpv 与 AVPlayer,两屏一起冻结,便于逐帧色彩/画质比对。
    func togglePause() {
        isPaused.toggle()
        tuning.isPaused = isPaused        // 镜像给调参面板,按钮文案随之变(▶/⏸)
        mpv.setPaused(isPaused)
        // 暂停:把 AV 定格到 mpv 当前帧(两屏同帧比对);继续:对齐后一起播。
        syncAVToMpv(play: !isPaused)
        report(isPaused ? "已暂停(两屏定格同一帧)" : "已继续(已对齐时间线)")
    }

    /// 连续漂移校正(bug2):两屏只在 PLAYBACK_RESTART 对齐一次会随各自时钟漂移。由调参轮询(~3Hz)持续调用:
    /// 播放中 |av−mpv| 超阈值就把 AV 重对齐到 mpv 主钟,把漂移钳在一帧上下。
    /// (绝对帧锁两套解码管线做不到;严格逐帧对照仍用「暂停 + seek 2s/27s」那条精确路。)
    func correctDriftIfNeeded() {
        guard mpvStarted, !isPaused else { return }
        guard let mt = mpv.currentTime(), let at = av.currentTime() else { return }
        if abs(mt - at) > driftTolerance { av.seek(to: mt) }
    }

    /// 切 roll-off 归属(消费端,热切,无需重载视频):
    /// on=true → RealityKit 折 >1.0 + 把 mpv tone-mapping 设为 clip(互斥,避免双重压缩);
    /// on=false → RealityKit 直通 + mpv 用面板选的曲线做软肩。
    func setRealityKitToneMap(on: Bool) {
        realityKitToneMap = on
        tuning.rollOffRealityKit = on
        rebuildMaterials()
        let mpvTone = on ? "clip" : (tuning.values["tone-mapping"] ?? "bt.2390")
        mpv.setColorProperty("tone-mapping", mpvTone)
        report(on ? "roll-off 归属=RealityKit(mpv tone-mapping=clip)" : "roll-off 归属=mpv(tone-mapping=\(mpvTone))")
    }

    /// EDR 曝光乘子(消费端衰减 + target-peak 提亮):
    /// <1 → tint 灰度即时衰减;>1 → 联动 mpv target-peak = 406×m 提亮。拉到画面不再变亮即触到系统 headroom 上限。
    func setEdrExposure(_ m: Double) {
        edrExposure = m
        tuning.edrExposure = m
        rebuildMaterials()
        if m > 1.0 {
            let peak = Int((exposurePeakBase * m).rounded())
            mpv.setColorProperty("target-peak", String(peak))
            tuning.values["target-peak"] = String(peak)
            report("EDR 曝光 ×\(String(format: "%.2f", m)) → target-peak=\(peak)")
        } else {
            report("EDR 曝光 ×\(String(format: "%.2f", m))(消费端衰减)")
        }
    }

    /// [xr-perf 杠杆2] 切像素格式路由模式(调参开关)。换格式要重建 IOSurface,故走 reload
    /// (重建面 + 重启 mpv 套用对应色彩选项);未起播则只存模式,下次起播生效。
    func setRouteMode(_ m: XRRouteMode) {
        routeMode = m
        tuning.routeMode = m
        if mpvStarted {
            report("像素格式路由 → \(m.label),重载生效…")
            reloadAtNativeResolution()
        } else {
            report("像素格式路由 → \(m.label)(下次起播生效)")
        }
    }

    /// [xr-perf 杠杆A·调试] 开关渲染分辨率上限(硬吃应急,非正解)。同样走 reload 重建。
    func setResolutionCap(_ longEdge: Int) {
        xrMaxLongEdge = longEdge
        tuning.resolutionCapOn = longEdge > 0
        if mpvStarted {
            report("分辨率上限 → \(longEdge == 0 ? "原生" : String(longEdge)),重载生效…")
            reloadAtNativeResolution()
        } else {
            report("分辨率上限 → \(longEdge == 0 ? "原生" : String(longEdge))(下次起播生效)")
        }
    }

    /// [xr-perf 测量] 冻结消费端换材质(mpv 继续播)。摘掉每帧换材质提交 + RealityKit 重摄取拷贝
    /// (假设 B+C),只留纯采样。真机读 perf HUD 的 renderFPS 分清瓶颈:
    /// ① 冻结 → renderFPS 跳升 = 拷贝/换材质是墙(B+C),重构对症;
    /// ② 冻结后不变,再按暂停(停 mpv)→ 跳升 = 生产端 GPU 争用;
    /// ③ 冻结 + 暂停都不变 = 纯采样/两极(A)→ 走 mipmap/几何。
    /// 注:冻结时画面停在最后一帧并可能撕裂(mpv 仍在写环),只为测帧率,非视觉验证。
    func setFreezeSwap(_ on: Bool) {
        VideoFrameSystem.freezeSwap = on
        tuning.freezeSwap = on
        report(on ? "❄️ 冻结换材质(mpv 继续播)— 读 renderFPS:跳升=拷贝/换材质是墙" : "已恢复换材质")
    }

    /// 当前真实片源 URL(重载/探测用);testsrc 无 URL 返回 nil。
    private var currentSourceURL: URL? { scopedURL ?? currentAVURL }

    /// 重载(bug3 + 卡死自救):按当前片源原生分辨率重建 IOSurface 环 + 重启 mpv,免杀后台。
    /// 分辨率不能热切(IOSurface 必须在 mpv 加载前按尺寸建好),故走这条整重启路。换片也走它。
    func reloadAtNativeResolution() {
        guard surface != nil else { report("重载需先起播(选模式进入)"); return }
        Task { @MainActor in
            let url = currentSourceURL
            if let url, let sz = await av.naturalSize(url: url), sz.width > 0, sz.height > 0 {
                (width, height) = cappedRenderSize(Int(sz.width), Int(sz.height))
            }
            await resolveRoute(url: url)
            report("重载 → \(width)x\(height) route=\(currentRoute.rawValue) …")
            // 1. 停 mpv(异步清理),等彻底退出再重建,避免两个 mpv 抢同一 IOSurface。
            if mpvStarted {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    mpv.stop { cont.resume() }
                }
                mpvStarted = false
            }
            // 2. 按原生尺寸重建 surface 环并重绑(沿用当前 toneMap/曝光状态)。
            do {
                self.surface = try ResidentVideoSurface(width: width, height: height, route: currentRoute)
                rebindCurrentMode()   // 新 surface → 按当前模式重绑(平面/球/窗口)
            } catch {
                report("重载建 surface 失败: \(error.localizedDescription)"); return
            }
            // 3. 重启 mpv 渲染进新 surface。
            guard let s = self.surface else { return }
            do {
                let src = url?.path ?? "av://lavfi:testsrc2=size=\(width)x\(height):rate=30"
                try mpv.start(source: src, surfaceIDs: s.iosurfaceIDs, width: width, height: height, route: s.route)
                mpvStarted = true
                replayTuning()                       // 把用户调过的旋钮重放到新 handle
                startPresenter()                      // 重启零拷贝换帧驱动(surface 已重建)
                if avEnabled, let url { attachAV(url: url) }     // 重接 AV 对照(同源、重定 aspect)
                report("重载完成 \(width)x\(height) ✓")
            } catch {
                report("重载启动 mpv 失败: \(error.localizedDescription)")
            }
        }
    }

    /// 重启后把面板上用户调过的可写旋钮重放到新 mpv handle(mpv.start 只设了出厂默认)。
    private func replayTuning() {
        for p in TuneInventory.writable {
            if let v = tuning.values[p.prop] { mpv.setColorProperty(p.prop, v) }
        }
        if realityKitToneMap { mpv.setColorProperty("tone-mapping", "clip") }   // 维持与 RealityKit 的互斥
    }

    /// [xr-verify] headless 自驱(模拟器自动验证,env XR_HEADLESS_VERIFY 触发):**不进沉浸空间、
    /// 不绑场景面片**,只建 IOSurface 环 + 启 mpv 渲染进它,首帧后自动跑 Gate 1。用于在模拟器里
    /// 自动拿数值(源 HDR10 判定 / AV 元数据 / fp16 出口峰值),免去手点沉浸 UI。
    /// ⚠️ 模拟器 MoltenVK 与真机可能有差异:fp16 峰值=0 不代表真机失败,源/AV 元数据则可信。
    func runHeadlessVerify() {
        guard !mpvStarted else { report("headless: mpv 已在跑"); return }
        mpv.onStatus = { [weak self] message in self?.status = message }
        mpv.onPlaybackStart = { [weak self] in
            guard let self, !self.didAutoVerify else { return }
            self.didAutoVerify = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.runSaturationProbe()
            }
        }
        do {
            let surface = try ResidentVideoSurface(width: width, height: height)
            self.surface = surface
            let (mpvSource, avURL) = resolveSources()
            currentAVURL = avURL
            try mpv.start(source: mpvSource, surfaceIDs: surface.iosurfaceIDs,
                          width: surface.width, height: surface.height)
            mpvStarted = true
            report("[xr-verify] headless 自驱:mpv 已启动 src=\(mpvSource) | 首帧后自动 Gate 1")
        } catch {
            report("[xr-verify] headless 自驱失败: \(error.localizedDescription)")
        }
    }

    /// Gate 1(数值/量化,设备无关):一次跑完所有源端 + 出口端断言,逐行打 [xr-verify]。
    /// ① mpv 解码源 = HDR10;② AV 对照源 = HDR10(两边都是 HDR);③ mpv fp16 出口线性峰值
    /// >1.0(真 HDR 出口、在 EDR headroom 内);④ 内存 footprint(穿插监控,防爆)。
    /// 模拟器 SDR-clamp 看不到绝对亮度 → 数值是承重门,截图只验对齐(Gate 2)。
    func runVerification() {
        report("[xr-verify] ── Gate 1 数值验证开始 ──")
        // ① mpv 源端:primaries/transfer 判 HDR10
        mpv.dumpSourceColorParams()
        // ③ mpv 出口:fp16 线性峰值(>1.0 = 真 HDR 出口)
        let front = xr_resident_front_iosurface_id()
        if let surface, front != 0 {
            let (sum, peak) = surface.samplePeak(forID: front)
            let verdict = peak > 1.0001 ? "含 HDR>1.0 ✓"
                : (sum > 0 ? "非空但 ≤1.0(SDR 或被钳;调 target-peak 重标定)✗" : "全黑 ✗")
            logger.info("[xr-verify] mpv-output fp16 抽样和=\(sum, privacy: .public) 线性峰值=\(peak, privacy: .public) front=\(front, privacy: .public) → \(verdict, privacy: .public)")
        } else {
            logger.info("[xr-verify] mpv-output 暂无已发布 front(front=\(front, privacy: .public);未起播?)")
        }
        // ② AV 对照源端:CMFormatDescription 判 HDR10
        if let url = currentAVURL {
            Task { await av.dumpHDRMetadata(url: url) }
        } else {
            logger.info("[xr-verify] av-source 跳过(当前 testsrc / 未接入真实片源)")
        }
        // ④ 内存
        logger.info("[xr-verify] 内存 phys_footprint=\(self.currentMemoryFootprintMB(), privacy: .public) MB")
        report("[xr-verify] Gate 1 完成 —— 结果见控制台 [xr-verify] 行")
    }

    /// 饱和度根因验证探针(ADR 0006,headless):seek 到固定帧 + 暂停,让同一画面在当前
    /// gamut 模式(env XR_GAMUT_MODE,默认 clip)下稳定渲染,测 mpv 输出的 u'v' 色度 + 存 PNG;
    /// 再用 AVAssetImageGenerator 解同一时刻作地面真值(色度 + PNG)。多次启动切 perceptual/clip/
    /// relative 得 A/B/C 对照,证明「perceptual 降域内饱和、clip 贴近 AV」。结果全打 [xr-verify] sat。
    func runSaturationProbe() {
        guard !didProbe else { return }
        didProbe = true
        let env = ProcessInfo.processInfo.environment
        let mode = MpvPlayer.gamutMode
        // 扫参 run tag:区分不同 config 轮次(策略一 vs 旧基线 vs 备选曲线);否则 PNG/日志互相覆盖。
        let tag = env["XR_RUN_TAG"] ?? mode
        let cfg = "gamut=\(mode) trc=\(env["XR_TARGET_TRC"] ?? "linear") tone=\(env["XR_TONE_MAPPING"] ?? "bt.2390") peak=\(env["XR_TARGET_PEAK"] ?? "406") cpeak=\(env["XR_HDR_COMPUTE_PEAK"] ?? "yes") contrast=\(env["XR_TARGET_CONTRAST"] ?? "inf")"
        let frames = probeSeekFrames
        Task { @MainActor in
            // 定格再逐帧 seek(同一画面才可跨轮逐像素对照);exact seek 即使暂停也会渲染目标帧。
            mpv.setPaused(true)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            for t in frames {
                let fs = Int(t.rounded())
                mpv.seekAbsolute(t)
                try? await Task.sleep(nanoseconds: 2_000_000_000)   // 等暂停帧渲染稳定并发布 front
                let front = xr_resident_front_iosurface_id()
                guard let surface, front != 0 else {
                    logger.info("[xr-verify] sat mpv 无 front @\(fs, privacy: .public)s(front=\(front, privacy: .public))")
                    continue
                }
                // mpv 出口 SDR-clamp PNG(视觉对照)+ 色度(饱和度)+ 亮度分位(高光/黑位/发白)。
                if let docs {
                    surface.dumpPNG(forID: front, to: docs.appendingPathComponent("mpv-\(tag)-f\(fs).png"))
                }
                let (mean, p90, n) = surface.sampleChroma(forID: front)
                let L = surface.sampleLuminanceStats(forID: front)
                logger.info("[xr-verify] sat mpv tag=\(tag, privacy: .public) f=\(fs, privacy: .public)s [\(cfg, privacy: .public)] meanChroma=\(mean, privacy: .public) p90=\(p90, privacy: .public) n=\(n, privacy: .public)")
                logger.info("[xr-verify] sat-lum tag=\(tag, privacy: .public) f=\(fs, privacy: .public)s min=\(L.min, privacy: .public) p1=\(L.p1, privacy: .public) p5=\(L.p5, privacy: .public) p50=\(L.p50, privacy: .public) p95=\(L.p95, privacy: .public) p99=\(L.p99, privacy: .public) max=\(L.max, privacy: .public) >1=\(L.fracGt1 * 100, privacy: .public)% >2=\(L.fracGt2 * 100, privacy: .public)%")
            }
            // AV 地面真值色度 + PNG(模拟器多半解不了 HDR HEVC,失败则由主机侧 ffmpeg 补)。
            if let url = currentAVURL {
                for t in frames {
                    let fs = Int(t.rounded())
                    let png = docs?.appendingPathComponent("av-source-f\(fs).png")
                    if let (mean, p90) = await av.sampleSourceChroma(url: url, at: t, pngTo: png) {
                        logger.info("[xr-verify] sat av f=\(fs, privacy: .public)s meanChroma=\(mean, privacy: .public) p90=\(p90, privacy: .public)")
                    }
                }
            } else {
                logger.info("[xr-verify] sat av 跳过(无真实片源 URL)")
            }
            // 仍跑原 Gate 1(源/出口峰值/内存),不丢既有断言
            self.runVerification()
            self.report("[xr-verify] 探针完成 tag=\(tag) frames=\(frames) —— PNG 在 Documents/")
        }
    }

    /// [xr-stereo] 立体材质加载自测(路 B 命门):验证手写 StereoMaterial.usda 能被 RealityKit
    /// 解析(info:id 是否抠对)+ promote 参数是否可见。成功 = 真景深的 ShaderGraph 路打通。
    /// 模拟器只渲单眼,故这里只验"加载/参数",真分眼仍真机签。
    func testStereoMaterialLoad() {
        Task { @MainActor in
            await loadStereoMaterialIfNeeded()
            guard let mat = stereoBaseMaterial else {
                logger.error("[xr-stereo] load FAILED")
                return
            }
            let params = mat.parameterNames.sorted().joined(separator: ",")
            logger.info("[xr-stereo] load OK params=\(params, privacy: .public)")
            // 验参数面:确认 videoTexture / UV 参数名存在(真分眼真机签;此处只验加载 + 参数通路,
            // 不建 ResidentVideoSurface —— LLDR 零拷贝路径需真机,模拟器会抛)。
            let need = ["videoTexture", "sclX", "sclY", "offLX", "offLY", "offRX", "offRY"]
            let missing = need.filter { !mat.parameterNames.contains($0) }
            report(missing.isEmpty ? "[xr-stereo] 加载✓ 参数面齐全✓(videoTexture + UV 拆半,真分眼真机签)"
                                   : "[xr-stereo] 加载✓ 但缺参数: \(missing.joined(separator: ","))")
        }
    }

    /// 进程物理内存占用(MB)。过夜运行穿插监控,防内存爆满(Phase E)。
    private func currentMemoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }

    /// 片源:文件选择器选过片就用它(mpv 与 AVFoundation 共用同一 URL 做公平比对);
    /// 模拟器上文件选择器空白,故若已把样片 push 进 Documents 则自动取用;
    /// 都没有则退回 mpv 内建 testsrc2 合成图样(无解码,仅验证输出通路)。
    /// [xr-bench] 投影开销对照夹具的源覆盖(直读路径,无安全作用域)。
    var benchSource: String?

    private func resolveSources() -> (mpv: String, av: URL?) {
        if let p = benchSource {
            return (p, URL(fileURLWithPath: p))
        }
        if let url = scopedURL {
            return (url.path, url)
        }
        #if targetEnvironment(simulator)
        // 模拟器:`xcrun simctl ... data` 容器的 Documents/HDR10-test.MP4(见 ADR 0005 样片导入)。
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let sample = docs?.appendingPathComponent("HDR10-test.MP4"),
           FileManager.default.fileExists(atPath: sample.path) {
            return (sample.path, sample)
        }
        #endif
        return ("av://lavfi:testsrc2=size=\(width)x\(height):rate=30", nil)
    }

    /// 文件选择器回调:把播放源换成本地选中的视频。沙盒读取需开安全作用域,
    /// 且 mpv 整段播放期间持续持有,直到换片或停止才释放。
    func selectVideo(_ url: URL) {
        if let prev = scopedURL {
            prev.stopAccessingSecurityScopedResource()
            scopedURL = nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            report("无法访问所选文件(安全作用域被拒): \(url.lastPathComponent)")
            return
        }
        scopedURL = url
        if mpvStarted {
            // 换片 = 可能换分辨率 → 走重载(按原生尺寸重建 IOSurface + 重启 mpv + 重接 AV)。
            report("换片 → \(url.lastPathComponent),按原生分辨率重载…")
            reloadAtNativeResolution()
        } else {
            // 未起播:先探原生分辨率,下次建 surface 就按它(首帧即原生,不必再重载)。
            Task { @MainActor in
                if let sz = await av.naturalSize(url: url), sz.width > 0, sz.height > 0 {
                    (self.width, self.height) = self.cappedRenderSize(Int(sz.width), Int(sz.height))
                }
                await self.resolveRoute(url: url)
                self.report("已选 \(url.lastPathComponent) \(self.width)x\(self.height) \(self.currentRoute.rawValue),进入沉浸后播放")
            }
            // AV 对照随选片接入/重连:已进沉浸场景(world 在)就把同一片源接到对照屏。
            if avEnabled, world != nil { attachAV(url: url) }
        }
    }

    /// [xr-debug] 在 2D 控制窗(未进沉浸空间)单测 mpv_initialize,把「沉浸空间环境交互」
    /// 这个维度从崩因里分出来。崩 → 与沉浸无关;不崩 → 崩因是沉浸环境交互。
    func testMpvInit() {
        report("测试 mpv_init(MPVKit 同款最小选项,2D)… 看 [xr-test]")
        mpv.testInitialize()
        report("mpv_init 未崩 ✓ → 我们的构建没问题,崩因在我们额外设的选项(下一步二分)")
    }

    private func report(_ message: String) {
        status = message
        logger.info("\(message, privacy: .public)")
    }

    func stop() {
        VideoFrameSystem.onFrameTick = nil
        mpv.stop()
        av.stop()
        if let url = scopedURL {
            url.stopAccessingSecurityScopedResource()
            scopedURL = nil
        }
    }
}
