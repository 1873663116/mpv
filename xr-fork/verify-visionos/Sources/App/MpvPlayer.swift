import Darwin
import Foundation
import Libmpv
import os

/// visionOS verify 的 mpv 驱动:**只走常驻 IOSurface 出口**(无窗口模式、无热切)。
/// 理由(CLAUDE.md / ADR 0004):visionOS 无 AppKit,mpv 不自己开窗;两种呈现都由
/// 消费端决定怎么贴。这里 mpv 永远渲染进 Swift 提供的 IOSurface 环。
///
/// 与 macOS verify 的差异:
/// - 删掉 `VK_ICD_FILENAMES`:visionOS 上 MoltenVK 静态链接进 app,不经 Homebrew ICD JSON。
/// - 删掉 window/hot-switch 整套(主线程死锁防护也随之不需要)。
final class MpvPlayer {
    // [xr] 调试面包屑 + mpv 日志直出(从事件线程同步落 os_log,保证崩前最后几行不丢)。
    private let dbg = Logger(subsystem: "enchron.verify.visionos", category: "mpv-start")
    private var handle: OpaquePointer?
    private var eventThread: Thread?
    private var eventLoopExited: DispatchSemaphore?
    private let stateLock = NSLock()
    private var shouldStop = false

    var onStatus: @MainActor (String) -> Void = { _ in }
    /// mpv 实际开始/重启播放(首帧就绪、seek 后、循环回到头)时触发,用于让 AV 对照对齐主钟。
    var onPlaybackStart: @MainActor () -> Void = {}

    /// - Parameter source: mpv loadfile 目标。文件路径(与 AVFoundation 对照组同一片源做公平比对),
    ///   或 `av://lavfi:testsrc2=...` 等无片源时的内建图样。
    func start(source: String, surfaceIDs: [UInt32], width: Int, height: Int,
               route: XRColorRoute = .hdr16) throws {
        dbg.info("[xr-start] 1 配置外部 IOSurface ids=\(surfaceIDs, privacy: .public) route=\(route.rawValue, privacy: .public) …")
        xr_resident_set_enabled(true)
        let ok = surfaceIDs.withUnsafeBufferPointer { buf in
            xr_resident_configure_external_iosurfaces(buf.baseAddress, Int32(buf.count),
                                                      Int32(width), Int32(height))
        }
        guard ok else {
            throw VerifyError("xr_resident_configure_external_iosurfaces failed")
        }

        dbg.info("[xr-start] 2 mpv_create …")
        guard let mpv = mpv_create() else {
            throw VerifyError("mpv_create failed")
        }
        handle = mpv

        try setOption("config", "no")
        try setOption("terminal", "no")
        try setOption("input-default-bindings", "no")
        try setOption("vo", "gpu-next")
        try setOption("gpu-api", "vulkan")
        try setOption("ao", "null")
        try setOption("audio", "no")
        try setOption("idle", "yes")
        try setOption("loop-file", "inf")
        try setOption("force-render", "yes")
        // [xr] VideoToolbox 硬解,零拷贝变体(非 -copy):解码帧停留在 GPU,经 hwdec_vt_pl
        // 直接导入 libplacebo,再渲染进常驻 IOSurface。整条链不落 CPU——这是本项目的目标。
        try setOption("hwdec", "videotoolbox")
        // [xr] 无窗 surfaceless 出口:GPU 设备无 surface,直接渲染进外部 IOSurface(ADR 0003)。
        try setOption("gpu-context", "macvk_resident")
        for (name, value) in Self.colorOptions(for: route) {
            try setOption(name, value)
        }

        // [xr] 调试:拉到 verbose,把 VO / vulkan / MoltenVK 初始化与 [xr] 桥日志全打出来,
        // 定位崩在哪一步。事件循环提前到 loadfile 之前启动,确保 VO/渲染线程的日志能被泵出。
        mpv_request_log_messages(mpv, "v")
        dbg.info("[xr-start] 3 mpv_initialize …")
        try check(mpv_initialize(mpv), "mpv_initialize")
        dbg.info("[xr-start] 4 mpv_initialize 完成;启动事件循环 …")

        // [xr] 观察实际生效的解码后端:首帧后 = "videotoolbox"(真硬解,零拷贝链通)
        // 或 "no"(静默回落软解)。让头显状态窗一眼可辨硬/软解,堵死「以为硬解实为软解」。
        mpv_observe_property(mpv, 0, "hwdec-current", MPV_FORMAT_STRING)

        startEventLoop()
        dbg.info("[xr-start] 5 loadfile \(source, privacy: .public) …")
        try command(["loadfile", source])
        dbg.info("[xr-start] 6 loadfile 已下发(VO/渲染初始化自此为异步)")
    }

    /// [xr-debug] 纯初始化探针:只 create + 设与真实路径同一套选项 + mpv_initialize,
    /// **不配 IOSurface、不 loadfile、不进沉浸空间**。用于在 2D 控制窗单测 mpv_initialize 是否崩 ——
    /// 把「mpv 本身/选项」与「沉浸空间环境交互」两个维度分开。定位后移除。
    func testInitialize() {
        dbg.info("[xr-test] A mpv_create …")
        guard let mpv = mpv_create() else {
            dbg.error("[xr-test] mpv_create 失败")
            return
        }
        // MPVKit visionOS demo 的同款最小选项集(它实跑验证过能 mpv_initialize)。
        // 探针 = 我们的构建 + 已证可用的选项:崩→构建坏;不崩→崩因是我们额外设的选项。
        dbg.info("[xr-test] B 设选项(MPVKit demo 同款最小集)…")
        let opts: [(String, String)] = [
            ("subs-match-os-language", "yes"), ("subs-fallback", "yes"),
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"), ("video-rotate", "no"),
        ]
        for (name, value) in opts {
            if mpv_set_option_string(mpv, name, value) < 0 {
                dbg.error("[xr-test] set \(name, privacy: .public) 失败")
            }
        }
        mpv_request_log_messages(mpv, "v")
        dbg.info("[xr-test] C mpv_initialize …(2D / 未进沉浸空间)")
        let rc = mpv_initialize(mpv)
        dbg.info("[xr-test] D mpv_initialize 返回 \(rc) ← 看到这行 = init 没崩")
        mpv_terminate_destroy(mpv)
        dbg.info("[xr-test] E 已销毁")
    }

    /// 运行时换片(文件选择器选片后调用)。mpv 侧零特殊处理 —— loadfile 替换即可;
    /// 解码后端沿用 init 时设的 hwdec=videotoolbox(喂真实片才会真正走 VideoToolbox 硬解)。
    func loadFile(_ path: String) {
        do {
            try command(["loadfile", path])
        } catch {
            Task { @MainActor in self.onStatus("loadfile 失败: \(error)") }
        }
    }

    /// 暂停/继续(对照验证):切 mpv `pause` 属性。线程安全,由 VerifyModel 与 AVPlayer 同步调用。
    func setPaused(_ paused: Bool) {
        guard let handle else { return }
        mpv_set_property_string(handle, "pause", paused ? "yes" : "no")
    }

    /// 精确 seek 到绝对时间(饱和度探针固定帧用):absolute+exact 力求各次启动落同一帧,
    /// 让 perceptual/clip/relative 三次对照测的是同一画面。
    func seekAbsolute(_ seconds: Double) {
        try? command(["seek", String(seconds), "absolute+exact"])
    }

    /// 运行时改色彩属性(真机高光调参,ADR 0007):mpv_set_property_string,gpu-next 下一帧重读生效。
    /// 真机上无法用 env,故用它在头显里实时切 target-peak / tone-mapping,对着 AV 屏找最贴的值。
    @discardableResult
    func setColorProperty(_ name: String, _ value: String) -> Bool {
        guard let handle else { return false }
        let ok = mpv_set_property_string(handle, name, value) >= 0
        dbg.info("[xr-tune] set \(name, privacy: .public)=\(value, privacy: .public) \(ok ? "ok" : "FAIL", privacy: .public)")
        return ok
    }

    /// 当前播放时间(秒),用于把 AV 对照对齐到 mpv 主钟。未就绪返回 nil。
    func currentTime() -> Double? {
        guard let handle else { return nil }
        var t: Double = 0
        return mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &t) >= 0 ? t : nil
    }

    /// 读字符串属性(调参面板用:开面板时把每个旋钮的当前生效值读回来显示)。未就绪/读失败返回 nil。
    func getProperty(_ name: String) -> String? {
        guard let handle else { return nil }
        guard let c = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    /// 读 (当前时间, 总时长) 秒,驱动可拖进度条。任一未就绪返回 nil。
    func timePosDur() -> (pos: Double, dur: Double)? {
        guard let handle else { return nil }
        var pos: Double = 0, dur: Double = 0
        let okP = mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &pos) >= 0
        let okD = mpv_get_property(handle, "duration", MPV_FORMAT_DOUBLE, &dur) >= 0
        guard okP || okD else { return nil }
        return (okP ? pos : 0, okD ? dur : 0)
    }

    /// 沉浸 HDR 出口色彩契约 —— 真机签收的 device-tuned 默认(全文 ADR 0008)。
    /// 渲染目标 = 扩展线性 Display-P3,用带软肩的 EETF 把 HDR10 源平滑滚降进 Vision Pro 真实 EDR
    /// headroom(材质探针实测 = 2.0:乘子 1.0→2.0 变亮、2.0→5 不变 = 合成器在 2.0× 处硬截)。
    ///
    /// 焊死契约(改它需放弃 mpv 出口):target-prim=display-p3、target-trc=linear(写进 fp16 的字节即
    /// 线性光,1.0=SDR 参考白,可 >1.0)、target-colorspace-hint=no(surfaceless 无 swapchain hint)。
    ///
    /// 基线(strategy-1):tone-mapping=bt.2390(带线性段的 hermite 软肩,不像 clip 硬裁过曝、不像
    /// spline 随场景洗白)、target-peak=406(软肩天花板对齐 headroom 2.0)、target-contrast=inf
    /// (自发光真黑,关黑点补偿,p1=0 不发灰)、gamut=clip(Apple Reference 同路,域内满饱和、仅裁越界)。
    ///
    /// device-tuned 层(真机对着 AV 屏拧出来、用户裁定):
    /// - hdr-compute-peak=auto(本路径≈yes,动态测峰开)+ hdr-peak-percentile=99.9:本样片元数据退化
    ///   (MaxCLL=0 → libplacebo 退回 sig-peak≈49=满 PQ),须动态测真实峰值,否则高光压崩(no 时 >1.0 仅 0.75%)。
    /// - hdr-reference-white=183(<203,默认偏低):**真机实测「参考白越高、过曝越狠」,降低 = 软肩更早
    ///   收高光、保护极亮**(用户裁定;与纸面「降参考白→提亮→过曝」推导相反,以真机为准)。
    /// - 轻度均衡器补偿 saturation=9 / contrast=10 / gamma=1 + hdr-contrast-recovery=0.15:补静态管线相对
    ///   AV 动态系统 tone-map 的欠饱和与平。判据用面板「饱和 p90」对齐源 P3 目标(~0.30),勿过冲成二次调色。
    ///
    /// 已接受的取舍:这是「一组静态参数」,大部分场景贴近 AV,极亮场景可能偏硬 —— 接受 HDR 的刺激性而非退回
    /// SDR。AV 的还原 = 系统按内容元数据在「实时动态 headroom」上软裁(AVPlayer 独占的 CAMetalLayer
    /// tone-mapper),静态一组参数无法 1:1 复制其动态自适应(详见 ADR 0008)。
    /// 每项经 env 可覆盖,供真机/模拟器 A/B(例:SIMCTL_CHILD_XR_HDR_REF_WHITE=203)。
    static var gamutMode: String { env("XR_GAMUT_MODE", "clip") }
    private static func env(_ key: String, _ def: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? def
    }

    private static func colorOptions(for route: XRColorRoute) -> [(String, String)] {
        // [xr-perf 杠杆2] SDR 路:源即 SDR,只需把出口编成 IEC sRGB、原色落 Display P3。
        // 不需要 HDR tone-map/动态测峰(对 SDR 源是 no-op)。target-trc=srgb 必须与 vo 端
        // 渲染目标 transfer(xr_resident_target_is_srgb 路由)一致,否则编码与消费端解码不互逆。
        if route == .sdr8 {
            return [
                ("target-colorspace-hint", env("XR_CS_HINT", "no")),
                ("target-prim", env("XR_TARGET_PRIM", "display-p3")),
                ("target-trc", "srgb"),
            ]
        }
        return [
            // 焊死契约(改它需放弃 mpv 出口)
            ("target-colorspace-hint", env("XR_CS_HINT", "no")),
            ("target-prim", env("XR_TARGET_PRIM", "display-p3")),
            ("target-trc", env("XR_TARGET_TRC", "linear")),
            // 基线(strategy-1)
            ("tone-mapping", env("XR_TONE_MAPPING", "bt.2390")),
            ("target-peak", env("XR_TARGET_PEAK", "406")),
            ("target-contrast", env("XR_TARGET_CONTRAST", "inf")),
            ("gamut-mapping-mode", gamutMode),
            // device-tuned 层(真机对着 AV 屏拧出来、用户签收)
            ("hdr-compute-peak", env("XR_HDR_COMPUTE_PEAK", "auto")),
            ("hdr-peak-percentile", env("XR_HDR_PEAK_PERCENTILE", "99.9")),
            ("hdr-peak-decay-rate", env("XR_HDR_PEAK_DECAY", "20")),
            ("hdr-reference-white", env("XR_HDR_REF_WHITE", "183")),
            ("tone-mapping-param", env("XR_TONE_MAPPING_PARAM", "0")),
            ("tone-mapping-max-boost", env("XR_TONE_MAX_BOOST", "1")),
            ("hdr-contrast-recovery", env("XR_HDR_CONTRAST_RECOVERY", "0.15")),
            ("hdr-contrast-smoothness", env("XR_HDR_CONTRAST_SMOOTHNESS", "100")),
            ("saturation", env("XR_SATURATION", "9")),
            ("contrast", env("XR_CONTRAST", "10")),
            ("gamma", env("XR_GAMMA", "1")),
        ]
    }

    /// Gate 1(源端断言):读 mpv 解码后的色彩参数,确认源确为 HDR10(primaries≈bt.2020、
    /// transfer≈pq/hlg)。经 mpv_get_property_string 读 video-params/*;须在首帧就绪后调用。
    func dumpSourceColorParams() {
        guard let handle else { return }
        func prop(_ name: String) -> String {
            guard let c = mpv_get_property_string(handle, name) else { return "?" }
            defer { mpv_free(c) }
            return String(cString: c)
        }
        let w = prop("width"), h = prop("height")
        let prim = prop("video-params/primaries")
        let gamma = prop("video-params/gamma")
        let sigPeak = prop("video-params/sig-peak")
        let pixfmt = prop("video-params/pixelformat")
        let isHDR = gamma.contains("pq") || gamma.contains("hlg") || prim.contains("2020")
        dbg.info("[xr-verify] mpv-source \(w, privacy: .public)x\(h, privacy: .public) prim=\(prim, privacy: .public) gamma=\(gamma, privacy: .public) sig-peak=\(sigPeak, privacy: .public) pixfmt=\(pixfmt, privacy: .public) → \(isHDR ? "HDR10 ✓" : "SDR ✗", privacy: .public)")
        Task { @MainActor in
            self.onStatus("mpv源 \(w)x\(h) \(prim)/\(gamma) \(isHDR ? "HDR✓" : "SDR✗")")
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard let handle else {
            xr_resident_clear_external_iosurface()
            completion?()
            return
        }

        setShouldStop(true)
        mpv_wakeup(handle)
        let eventLoopExited = eventLoopExited
        self.handle = nil
        eventThread = nil
        self.eventLoopExited = nil

        DispatchQueue.global(qos: .userInitiated).async {
            eventLoopExited?.wait()
            let args = CStringArray(["quit"])
            mpv_command(handle, args.pointer)
            mpv_terminate_destroy(handle)
            DispatchQueue.main.async {
                xr_resident_clear_external_iosurface()
                completion?()
            }
        }
    }

    private func setOption(_ name: String, _ value: String) throws {
        guard let handle else {
            throw VerifyError("mpv handle not initialized")
        }
        try check(mpv_set_option_string(handle, name, value), "set \(name)")
    }

    private func command(_ values: [String]) throws {
        guard let handle else {
            throw VerifyError("mpv handle not initialized")
        }
        let args = CStringArray(values)
        try check(mpv_command(handle, args.pointer), values.joined(separator: " "))
    }

    private func check(_ result: Int32, _ operation: String) throws {
        if result >= 0 {
            return
        }
        let reason = String(cString: mpv_error_string(result))
        throw VerifyError("\(operation): \(reason)")
    }

    private func startEventLoop() {
        guard let handle else {
            return
        }
        setShouldStop(false)
        let eventLoopExited = DispatchSemaphore(value: 0)
        self.eventLoopExited = eventLoopExited
        eventThread = Thread { [weak self] in
            defer {
                eventLoopExited.signal()
            }
            while let self, !self.isStopping() {
                guard let event = mpv_wait_event(handle, 0.1) else {
                    continue
                }
                if self.isStopping() {
                    return
                }
                self.handle(event: event.pointee)
            }
        }
        eventThread?.name = "VerifyVisionOS.mpv-events"
        eventThread?.start()
    }

    private func setShouldStop(_ value: Bool) {
        stateLock.lock()
        shouldStop = value
        stateLock.unlock()
    }

    private func isStopping() -> Bool {
        stateLock.lock()
        let value = shouldStop
        stateLock.unlock()
        return value
    }

    private func handle(event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return }
            let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let prefix = message.prefix.map(String.init(cString:)) ?? "mpv"
            let text = (message.text.map(String.init(cString:)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // [xr] 降噪:每帧自验抽样行(check_nonzero,纯验证夹具)刷爆控制台,直接丢弃。
            // C 侧仍在采样(IOSurfaceLock 开销很小),只是不再外泄到 os_log;待下次重编 libmpv 再彻底关。
            if text.contains("抽样像素和") { return }
            // 从事件线程同步落 os_log:崩前最后几行 VO/MoltenVK/[xr] 日志不会因 MainActor 排队而丢。
            dbg.info("[\(prefix, privacy: .public)] \(text, privacy: .public)")
            Task { @MainActor in
                self.onStatus("[\(prefix)] \(text)")
            }
        case MPV_EVENT_FILE_LOADED:
            Task { @MainActor in
                self.onStatus("mpv file loaded")
            }
        case MPV_EVENT_END_FILE:
            Task { @MainActor in
                self.onStatus("mpv end-file")
            }
        case MPV_EVENT_PLAYBACK_RESTART:
            // 首帧就绪 / seek 后 / 循环回头:通知 VerifyModel 把 AV 对照对齐到 mpv 时间。
            Task { @MainActor in
                self.onPlaybackStart()
            }
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard prop.format == MPV_FORMAT_STRING, let pdata = prop.data else { return }
            let value = pdata.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
                .map(String.init(cString:)) ?? ""
            let verdict = value == "no" || value.isEmpty
                ? "解码=\(value.isEmpty ? "?" : value) ✗ 软解(CPU,零拷贝未达成)"
                : "解码=\(value) ✓ 硬解(VideoToolbox 零拷贝)"
            Task { @MainActor in
                self.onStatus(verdict)
            }
        default:
            break
        }
    }
}

private final class CStringArray {
    private let strings: [UnsafeMutablePointer<CChar>?]
    let pointer: UnsafeMutablePointer<UnsafePointer<CChar>?>

    init(_ values: [String]) {
        strings = values.map { strdup($0) } + [nil]
        pointer = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: strings.count)
        for (index, string) in strings.enumerated() {
            pointer[index] = UnsafePointer(string)
        }
    }

    deinit {
        for string in strings {
            free(string)
        }
        pointer.deallocate()
    }
}
