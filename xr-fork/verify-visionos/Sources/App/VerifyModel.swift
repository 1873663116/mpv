import Darwin
import Foundation
import Libmpv
import RealityKit
import SwiftUI
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
    private let width = 1280
    private let height = 720
    /// 纹理/IOSurface 比例(16:9)。消费端按此把面片等比定形为 16:9(铺满、无黑边、不失真)。
    private var displayAspect: Float { Float(width) / Float(height) }
    /// 纹理转正的面内自转量(1/4 圈为单位)。面片网格 UV 随建模平面朝向被转了 90°,
    /// 需绕法线反转回来。-1 = 顺时针 90°;若视频呈上下颠倒/仍旋转,改这里的符号或圈数即可。
    private let textureQuarterTurns: Float = -1
    /// 各面片的原始 RCP transform(orientPanel 的幂等基准:每次都从原始推导,避免反复叠加)。
    private var originalPanelTransforms: [String: Transform] = [:]

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
        tuning.attach()
        report("[xr-tune] 调参面板已接线 —— 控制窗『调参面板』进入")
    }

    /// 跳到对照帧(2s/27s):seek mpv,AV 经 PLAYBACK_RESTART 自动对齐。
    func tuningJump(_ t: Double) { mpv.seekAbsolute(t) }

    /// 读 front IOSurface 的 fp16 仪表(>1.0高光% / 黑位p1 / 饱和p90 / >2.0过曝%),显示无关。
    private func sampleMetrics() -> (gt1: Double, p1: Double, sat: Double, gt2: Double)? {
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
        report("阶段0:场景已加载(未接纹理面/mpv)。逐级点开关定位崩溃。")
    }

    /// 阶段 1:建零拷贝 IOSurface 纹理环 + 把 mpv 屏材质换成 UnlitMaterial。
    /// 单独测 Metal / IOSurface / `TextureResource.__texture` + 材质替换这一层,尚不启动 mpv。
    func enableTexturePlane() {
        guard let world else { report("请先进入沉浸场景"); return }
        guard surface == nil else { report("纹理面已接入"); return }
        do {
            let surface = try ResidentVideoSurface(width: width, height: height)
            self.surface = surface
            guard let screen = world.findEntity(named: "screen") else {
                report("场景里找不到 'screen' 实体")
                return
            }
            bindResident(surface: surface, to: screen)
            orientPanel(screen, textureAspect: displayAspect)
            report("阶段1:纹理面已接入(IOSurface 环 + UnlitMaterial + 摆正),未启动 mpv。崩则在 Metal/纹理层。")
        } catch {
            report("阶段1 建纹理面失败: \(error.localizedDescription)")
        }
    }

    /// 阶段 2:启动 mpv(MoltenVK/Vulkan 设备 + 渲染进 IOSurface,逐帧换 front)。
    /// 崩在这里 = mpv/MoltenVK 与 RealityKit Metal 共存的问题。
    func enableMpv() {
        guard let surface else { report("请先接入纹理面(阶段1)"); return }
        guard !mpvStarted else { report("mpv 已启动"); return }
        do {
            let (mpvSource, avURL) = resolveSources()
            try mpv.start(source: mpvSource, surfaceIDs: surface.iosurfaceIDs,
                          width: width, height: height)
            mpvStarted = true
            report("阶段2:mpv 已启动 | IOSurfaceIDs=\(surface.iosurfaceIDs) | src=\(mpvSource)")

            // 对照组:AVFoundation → AV 面片(仅在已选真实片源时;testsrc 无对应 URL,按设计跳过)。
            if let avURL {
                attachAV(url: avURL)
            }
            // 接线运行时调参面板(读回当前值 + 启动实时仪表/进度轮询)。
            wireTuning()
        } catch {
            report("阶段2 启动 mpv 失败: \(error.localizedDescription)")
        }
    }

    private func bindResident(surface: ResidentVideoSurface, to screen: Entity) {
        let materials = Dictionary(uniqueKeysWithValues:
            surface.buffers.map { ($0.id, Self.makeMaterial($0.textureResource)) })
        let faceCount = screen.components[ModelComponent.self]?.materials.count ?? 1

        // 先挂第 0 张,免得首帧前平面是空白。
        if var model = screen.components[ModelComponent.self],
           let initial = materials[surface.buffers[0].id] {
            model.materials = Array(repeating: initial, count: max(1, faceCount))
            screen.components.set(model)
        }
        screen.components.set(ResidentVideoComponent(materialsByID: materials, faceCount: faceCount))
    }

    /// 关闭 RealityKit 默认 tone mapping:视频帧已是显示就绪的 sRGB 颜色(ADR 0004)。
    private static func makeMaterial(_ resource: TextureResource) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(resource))
        return material
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
        mpv.setPaused(isPaused)
        // 暂停:把 AV 定格到 mpv 当前帧(两屏同帧比对);继续:对齐后一起播。
        syncAVToMpv(play: !isPaused)
        report(isPaused ? "已暂停(两屏定格同一帧)" : "已继续(已对齐时间线)")
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
                          width: width, height: height)
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
    private func resolveSources() -> (mpv: String, av: URL?) {
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
            mpv.loadFile(url.path)
            report("换片 → \(url.lastPathComponent) | 看状态末行确认硬/软解")
        } else {
            report("已选 \(url.lastPathComponent),进入沉浸场景后播放")
        }
        // AV 对照随选片接入/重连:已进沉浸场景(world 在)就把同一片源接到对照屏。
        // 旧逻辑只在 enableMpv 接一次,「先启动 mpv 再选片」会漏掉对照组——这里补上。
        if world != nil {
            attachAV(url: url)
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
        mpv.stop()
        av.stop()
        if let url = scopedURL {
            url.stopAccessingSecurityScopedResource()
            scopedURL = nil
        }
    }
}
