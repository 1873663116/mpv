import OSLog
import RealityKit
import RealityKitScripting
import SwiftUI

/// [xr-perf 诊断] 递归数一棵实体子树的实体总数。用于定位 Instruments『Entity Count≈2,696』的来源:
/// SwiftUI attachment 会被 RealityKit 展开成一棵实体子树,这里直接数出它的规模。生产接入时删。
func xrEntityCount(_ entity: Entity) -> Int {
    1 + entity.children.reduce(0) { $0 + xrEntityCount($1) }
}

private let xrPerfLog = Logger(subsystem: "com.enchron.VerifyVisionOS", category: "xr-perf")

/// [xr-perf 诊断] 跳过场景内 SwiftUI 控制面板 attachment 的开关(SIMCTL_CHILD_XR_NO_PANEL=1 注入)。
/// 用于「排除嫌疑」:对照「有/无面板」的 Entity Count 与 RealityKit Trace 瓶颈,坐实面板是否是编码瓶颈源。
let xrNoPanel = ProcessInfo.processInfo.environment["XR_NO_PANEL"] != nil

// MARK: - 沉浸模式(RCP 场景 + 虚拟屏)

struct ImmersiveView: View {
    let model: VerifyModel

    var body: some View {
        RealityView { content, attachments in
            model.setMode(.immersive)
            await model.installScene(into: content)
            if !xrNoPanel, let panel = attachments.entity(for: "liveControls") {
                panel.position = [0, 1.0, -1.3]
                content.add(panel)
                xrPerfLog.info("[xr-perf] liveControls 面板展开实体数=\(xrEntityCount(panel), privacy: .public)")
            }
        } attachments: {
            Attachment(id: "liveControls") {
                LiveControlPanel(model: model, showPanoramaProjection: false)
            }
        }
        // RCP3 场景带脚本系统:必须 boot,否则带 Custom Components 的实体资产依赖建不起来。
        .scriptingSystem()
    }
}

// MARK: - 全景模式(裸朝内球,独立于 RCP 场景)

struct PanoramaView: View {
    let model: VerifyModel

    var body: some View {
        RealityView { content, attachments in
            model.setMode(.panorama)
            if let sphere = model.enterPanorama() {
                content.add(sphere)
            }
            if let panel = attachments.entity(for: "liveControls") {
                panel.position = [0, 1.0, -1.3]
                content.add(panel)
            }
        } attachments: {
            Attachment(id: "liveControls") {
                LiveControlPanel(model: model, showPanoramaProjection: true, showStereo: true)
            }
        }
        // 全景无 RCP 脚本资产,不需要 .scriptingSystem()。
    }
}

// MARK: - 窗口模式(2D 窗口里贴平面,选片即播)

struct PlayerWindow: View {
    let model: VerifyModel

    var body: some View {
        VStack(spacing: 12) {
            RealityView { content in
                model.setMode(.window)
                let plane = Entity()
                plane.position = [0, 0, 0]
                model.enterWindowPlane(plane)   // 模型按当前立体拆眼建 quad mesh + 绑定
                content.add(plane)
            }
            .frame(minHeight: 240)
            // 窗口里也给一套高频遥控(2D 控件,跟沉浸内遥控器同款 model)。
            LiveControlPanel(model: model, showPanoramaProjection: false, showStereo: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }
}

// MARK: - 共用遥控器(高频实时控制)

/// 高频实时控制:全景子投影(可选)+ 暂停 + AV 对照 + 调参 + 性能 HUD。
/// 三个模式共用同一个 `model`;沉浸/全景内作浮面板,窗口内作底部控件。
struct LiveControlPanel: View {
    let model: VerifyModel
    /// 仅全景模式显示 360/180 子投影切换。
    var showPanoramaProjection: Bool
    /// 全景/窗口模式显示立体拆眼(mono/SBS/TB);沉浸虚拟屏不支持,隐藏。
    var showStereo: Bool = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            if showPanoramaProjection {
                Picker("全景", selection: Binding(
                    get: { model.panoramaProjection },
                    set: { model.setPanoramaProjection($0) })
                ) {
                    Text("360 全球").tag(VerifyModel.PanoramaProjection.sphere360)
                    Text("180 半球").tag(VerifyModel.PanoramaProjection.hemisphere180)
                }
                .pickerStyle(.segmented)
            }

            if showStereo {
                Picker("立体", selection: Binding(
                    get: { model.stereoPacking },
                    set: { model.setStereo(packing: $0, swap: model.stereoSwap) })
                ) {
                    Text("Mono").tag(StereoLayout.Packing.mono)
                    Text("左右 SBS").tag(StereoLayout.Packing.sbs)
                    Text("上下 TB").tag(StereoLayout.Packing.tb)
                }
                .pickerStyle(.segmented)
                if model.stereoPacking != .mono {
                    Toggle("交换左右眼(装反时开)", isOn: Binding(
                        get: { model.stereoSwap },
                        set: { model.setStereo(packing: model.stereoPacking, swap: $0) }))
                        .font(.caption)
                }
            }

            HStack(spacing: 12) {
                Button { model.togglePause() } label: {
                    Label(model.isPaused ? "继续" : "暂停",
                          systemImage: model.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                Toggle(isOn: Binding(
                    get: { model.avEnabled },
                    set: { model.setAVComparison($0) })
                ) {
                    Label("AV 对照", systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .toggleStyle(.button)
            }

            Button { openWindow(id: "tuning") } label: {
                Label("调参面板", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }

            Text(model.perf)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380)
        .glassBackgroundEffect()
    }
}
