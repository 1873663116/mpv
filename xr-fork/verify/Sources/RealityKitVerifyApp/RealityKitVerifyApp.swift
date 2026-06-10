import AppKit
import SwiftUI

@main
struct RealityKitVerifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = VerifyViewModel(initialMode: .commandLineDefault())

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 900, minHeight: 650)
                .onAppear {
                    appDelegate.onTerminate = { [viewModel] completion in
                        viewModel.stop(completion: completion)
                    }
                    // 仅用于验证:SIGUSR1→切窗口、SIGUSR2→切沉浸,等价于点段控件,
                    // 让热切可被 `kill -USR1/-USR2` 可复现地触发(无需点 UI)。
                    appDelegate.installModeSwitchSignals { [viewModel] mode in
                        viewModel.switchToMode(mode)
                    }
                }
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (((@escaping () -> Void) -> Void))?

    // 仅用于验证:保活信号源,见 installModeSwitchSignals。
    private var usr1Source: DispatchSourceSignal?
    private var usr2Source: DispatchSourceSignal?

    func installModeSwitchSignals(_ handler: @escaping @MainActor (PlaybackMode) -> Void) {
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)
        let s1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s1.setEventHandler { MainActor.assumeIsolated { handler(.window) } }
        s1.resume()
        usr1Source = s1
        let s2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        s2.setEventHandler { MainActor.assumeIsolated { handler(.immersive) } }
        s2.resume()
        usr2Source = s2
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let onTerminate else {
            return .terminateNow
        }

        onTerminate {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
