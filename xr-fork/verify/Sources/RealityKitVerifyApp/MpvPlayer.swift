import CMpv
import Darwin
import Foundation

final class MpvPlayer {
    private var handle: OpaquePointer?
    private var eventThread: Thread?
    private var eventLoopExited: DispatchSemaphore?
    private let stateLock = NSLock()
    private var shouldStop = false

    var onStatus: @MainActor (String) -> Void = { _ in }

    func start(mode: PlaybackMode, surfaceID: UInt32, width: Int, height: Int) throws {
        setenv("VK_ICD_FILENAMES", "/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json", 1)

        if mode.usesResidentTexture {
            setenv("XR_RESIDENT", "1", 1)
            guard xr_resident_configure_external_iosurface(surfaceID, Int32(width), Int32(height)) else {
                throw VerifyError("xr_resident_configure_external_iosurface failed")
            }
        } else {
            unsetenv("XR_RESIDENT")
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
            try setOption("focus-on", "never")
            try setOption("border", "no")
            try setOption("window-minimized", "yes")
            try setOption("force-window-position", "yes")
            try setOption("geometry", "\(width)x\(height)-10000-10000")
        } else {
            try setOption("geometry", "\(width)x\(height)+80+80")
        }

        mpv_request_log_messages(mpv, "info")
        try check(mpv_initialize(mpv), "mpv_initialize")

        let file = "av://lavfi:testsrc2=size=\(width)x\(height):rate=30"
        try command(["loadfile", file])
        startEventLoop()
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
