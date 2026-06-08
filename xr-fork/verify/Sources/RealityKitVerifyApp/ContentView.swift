import RealityKit
import SwiftUI
import _RealityKit_SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: VerifyViewModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RealityView { content in
                viewModel.installScene(in: &content)
                _ = content.subscribe(to: SceneEvents.Update.self) { event in
                    Task { @MainActor in
                        viewModel.tick(deltaTime: event.deltaTime)
                    }
                }
            }
            .realityViewCameraControls(.orbit)

            Text(viewModel.status)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(8)

            VStack {
                HStack {
                    Spacer()
                    Picker("", selection: $viewModel.mode) {
                        ForEach(PlaybackMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .padding(12)
                }
                Spacer()
            }
        }
        .task {
            viewModel.start()
        }
        .onChange(of: viewModel.mode) { _, newMode in
            viewModel.switchToMode(newMode)
        }
    }
}
