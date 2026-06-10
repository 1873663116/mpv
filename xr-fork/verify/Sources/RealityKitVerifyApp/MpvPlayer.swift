import CMpv
import Darwin
import Foundation

final class MpvPlayer {
    private var handle: OpaquePointer?
    private var eventThread: Thread?
    private var eventLoopExited: DispatchSemaphore?
    private let stateLock = NSLock()
    private var shouldStop = false
    // 热切在此后台串行队列上跑:绝不在主线程上同步调用 mpv(见 switchMode 注释)。
    private let switchQueue = DispatchQueue(label: "RealityKitVerifyApp.mpv-switch")

    var onStatus: @MainActor (String) -> Void = { _ in }

    func start(mode: PlaybackMode, surfaceIDs: [UInt32], width: Int, height: Int) throws {
        setenv("VK_ICD_FILENAMES", "/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json", 1)

        if mode.usesResidentTexture {
            xr_resident_set_enabled(true)
            let ok = surfaceIDs.withUnsafeBufferPointer { buf in
                xr_resident_configure_external_iosurfaces(buf.baseAddress, Int32(buf.count),
                                                          Int32(width), Int32(height))
            }
            guard ok else {
                throw VerifyError("xr_resident_configure_external_iosurfaces failed")
            }
        } else {
            xr_resident_set_enabled(false)
            xr_resident_clear_external_iosurface()
        }

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
        if mode.usesResidentTexture {
            // [xr] 无窗 surfaceless 出口:不再开任何窗口(连隐藏窗口都不需要),
            // GPU 设备无 surface 直接渲染进外部 IOSurface(见 ADR 0003)。
            try setOption("gpu-context", "macvk_resident")
        } else {
            try setOption("geometry", "\(width)x\(height)+80+80")
        }
        for (name, value) in Self.colorOptions(usesResident: mode.usesResidentTexture) {
            try setOption(name, value)
        }

        mpv_request_log_messages(mpv, "info")
        try check(mpv_initialize(mpv), "mpv_initialize")

        let file = "av://lavfi:testsrc2=size=\(width)x\(height):rate=30"
        try command(["loadfile", file])
        startEventLoop()
    }

    /// 色彩出口契约(ADR 0004):
    /// - 沉浸(IOSurface):字节钉死为 IEC sRGB 编码 —— target-trc=srgb 强制转换;
    ///   treat-srgb-as-power22=input 保留输入侧 mpv 默认、关掉输出侧「sRGB→纯 2.2 幂」
    ///   重写,使编码恰好与消费端 `_srgb` 纹理视图的硬件解码互逆。
    /// - 窗口(swapchain):target-colorspace-hint=yes,让 swapchain 切到
    ///   BT709_NONLINEAR(layer = ITU-R 709),修 macOS 上 ColorSync 按 IEC sRGB
    ///   解读 BT.1886 直出字节导致的整体发白(mpv#16874)。
    private static func colorOptions(usesResident: Bool) -> [(String, String)] {
        if usesResident {
            return [
                ("target-colorspace-hint", "no"),
                ("target-trc", "srgb"),
                ("treat-srgb-as-power22", "input"),
            ]
        } else {
            return [
                ("target-colorspace-hint", "yes"),
                ("target-trc", "auto"),
                ("treat-srgb-as-power22", "auto"),
            ]
        }
    }

    /// 热切:保住 mpv 实例与播放进度,只在运行时换视频输出通道(窗口 ↔ 无窗 IOSurface)。
    /// 靠运行时改 `gpu-context`(带 UPDATE_VO 标志)触发 mpv 仅重建 VO,不重启实例。
    ///
    /// 关键:mpv 重建 mac 窗口 VO 时,会 `DispatchQueue.main.sync` 回主线程建/拆窗口
    /// (见 video/out/mac_common.swift 的 init/config/uninit)。所以这里**绝不能在主线程上
    /// 同步调用 mpv** —— 否则主线程卡在 mpv 调用里、VO 线程又在等主线程,互相死等(窗口冻结)。
    /// 改到后台串行队列执行,主线程空出来给 mpv 建窗口。
    func switchMode(to mode: PlaybackMode, surfaceIDs: [UInt32], width: Int, height: Int) {
        guard let handle else {
            return
        }
        let usesResident = mode.usesResidentTexture
        let title = mode.title
        switchQueue.async { [weak self] in
            guard let self else {
                return
            }
            // 色彩契约先于 context 切换生效:目标 VO 第一帧就按正确出口编码渲染。
            for (name, value) in Self.colorOptions(usesResident: usesResident) {
                let r = mpv_set_property_string(handle, name, value)
                if r < 0 {
                    self.report("switch set \(name): \(String(cString: mpv_error_string(r)))")
                }
            }
            if usesResident {
                xr_resident_set_enabled(true)
                let ok = surfaceIDs.withUnsafeBufferPointer { buf in
                    xr_resident_configure_external_iosurfaces(buf.baseAddress, Int32(buf.count),
                                                              Int32(width), Int32(height))
                }
                guard ok else {
                    self.report("switch configure failed")
                    return
                }
                let r = mpv_set_property_string(handle, "gpu-context", "macvk_resident")
                guard r >= 0 else {
                    self.report("switch → macvk_resident: \(String(cString: mpv_error_string(r)))")
                    return
                }
            } else {
                let r = mpv_set_property_string(handle, "gpu-context", "macvk")
                guard r >= 0 else {
                    self.report("switch → macvk: \(String(cString: mpv_error_string(r)))")
                    return
                }
                xr_resident_set_enabled(false)
                xr_resident_clear_external_iosurface()
            }
            self.report("hot-switched to \(title)")
        }
    }

    private func report(_ message: String) {
        Task { @MainActor in
            self.onStatus(message)
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
        eventThread?.name = "RealityKitVerifyApp.mpv-events"
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
            let log = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let prefix = log.prefix.map(String.init(cString:)) ?? "mpv"
            let text = log.text.map(String.init(cString:)) ?? ""
            Task { @MainActor in
                self.onStatus("[\(prefix)] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        case MPV_EVENT_FILE_LOADED:
            Task { @MainActor in
                self.onStatus("mpv file loaded")
            }
        case MPV_EVENT_END_FILE:
            Task { @MainActor in
                self.onStatus("mpv end-file")
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
