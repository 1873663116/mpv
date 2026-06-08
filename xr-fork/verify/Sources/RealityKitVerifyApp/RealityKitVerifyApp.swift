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
                }
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (((@escaping () -> Void) -> Void))?

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
