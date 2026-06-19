import Darwin
import Foundation
import os

// 信号处理器只能用 async-signal-safe 的东西:这里用全局预分配缓冲 + 已打开的 fd,
// 处理器内不做任何分配/不调 os_log(os_log 在信号处理器里不安全)。
private var xrCrashLogFd: Int32 = -1
private var xrFrames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)

/// 调试夹具:捕获 `mpv_initialize` 这类 **C 层原生信号崩溃(SIGSEGV/SIGABRT…)** 的调用栈。
///
/// 为什么要文件 + 下次启动回放:
/// 1. 这类崩溃不是 Obj-C 异常,系统默认不打栈;
/// 2. 信号处理器里写 stderr 能拿到栈,但 **Console.app/设备日志流只显示 os_log、不显示 stderr**,
///    所以上一版写 stderr 的栈你看不到;
/// 3. 信号处理器里直接调 os_log 不安全(可能死锁)。
/// 故:处理器里把栈 `backtrace_symbols_fd` 同步写进文件(安全),**下次启动**再读出来用
/// os_log 打到你能看见的频道。定位完成即可整体移除。
enum CrashHandler {
    private static let logger = Logger(subsystem: "enchron.verify.visionos", category: "crash")

    static func install() {
        let path = crashLogPath()

        // 先回放上一次运行写下的崩溃栈(若有),逐行 os_log(避免 os_log 单条长度截断),再删除。
        if let data = FileManager.default.contents(atPath: path), !data.isEmpty,
           let text = String(data: data, encoding: .utf8) {
            logger.error("[xr-crash] ===== 上一次运行的崩溃栈 begin =====")
            for line in text.split(separator: "\n") {
                logger.error("[xr-crash] \(String(line), privacy: .public)")
            }
            logger.error("[xr-crash] ===== 上一次运行的崩溃栈 end =====")
            try? FileManager.default.removeItem(atPath: path)
        }

        // 打开(截断)崩溃日志文件;fd 交给信号处理器同步写。
        xrCrashLogFd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0o644)

        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE]
        for s in signals {
            signal(s) { sig in
                let count = backtrace(&xrFrames, Int32(xrFrames.count))
                backtrace_symbols_fd(&xrFrames, count, STDERR_FILENO) // 若在 Xcode 调试台可直接看到
                if xrCrashLogFd >= 0 {
                    backtrace_symbols_fd(&xrFrames, count, xrCrashLogFd) // 落盘,供下次启动回放
                    fsync(xrCrashLogFd)
                }
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
    }

    private static func crashLogPath() -> String {
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("xr-crash.log")
    }
}
