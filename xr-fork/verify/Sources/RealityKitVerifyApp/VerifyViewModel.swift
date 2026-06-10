import CMpv
import Foundation
import RealityKit
import _RealityKit_SwiftUI

@MainActor
final class VerifyViewModel: ObservableObject {
    @Published var status = "starting"
    @Published var mode: PlaybackMode

    private let surface: ResidentVideoSurface
    private let player = MpvPlayer()
    private weak var cube: ModelEntity?
    private var tickCount = 0
    private var started = false
    private var activeMode: PlaybackMode?
    private var latestMpvStatus = "mpv idle"

    // 门① 双缓冲消费侧状态:跟随 mpv 发布的 front。
    private var currentFrontID: UInt32 = 0
    private var frontFlips = 0
    private var seenFrontIDs = Set<UInt32>()

    // 盒子缓慢自转的累计角度(用来肉眼确认视频确实贴在 3D 物体上)。
    private var spin: Float = 0

    init(initialMode: PlaybackMode = .commandLineDefault()) {
        mode = initialMode
        do {
            DebugLog.reset()
            surface = try ResidentVideoSurface()
            player.onStatus = { [weak self] message in
                self?.latestMpvStatus = message
                self?.status = message
                DebugLog.write(message)
            }
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    func start() {
        start(mode: mode)
    }

    func switchToMode(_ newMode: PlaybackMode) {
        guard started, newMode != activeMode else {
            return
        }

        // 热切:不销毁 mpv、不重载文件,只换视频输出通道。
        // mpv 调用在后台线程执行(避免主线程死锁,见 MpvPlayer.switchMode);这里先乐观更新消费侧状态。
        DebugLog.write("hot-switch \(activeMode?.title ?? "?") → \(newMode.title)")
        player.switchMode(
            to: newMode,
            surfaceIDs: surface.iosurfaceIDs,
            width: ResidentVideoSurface.width,
            height: ResidentVideoSurface.height
        )
        activeMode = newMode
        mode = newMode
        currentFrontID = 0 // 重新跟随 front:窗口模式 front=0→盒子冻结;沉浸模式恢复播放
        status = "hot-switching to \(newMode.title)"
        DebugLog.write(status)
    }

    private func start(mode: PlaybackMode) {
        guard !started else {
            return
        }
        started = true
        activeMode = mode
        latestMpvStatus = "mpv idle"
        tickCount = 0

        currentFrontID = 0
        frontFlips = 0
        seenFrontIDs.removeAll()

        do {
            try player.start(
                mode: mode,
                surfaceIDs: surface.iosurfaceIDs,
                width: ResidentVideoSurface.width,
                height: ResidentVideoSurface.height
            )
            status = "\(mode.title) mode started" +
                (mode.usesResidentTexture ? ", IOSurfaceIDs=\(surface.iosurfaceIDs)" : ", resident path disabled")
            DebugLog.write(status)
        } catch {
            started = false
            activeMode = nil
            status = error.localizedDescription
            DebugLog.write("start_failed \(status)")
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard started else {
            completion?()
            return
        }
        started = false
        player.stop {
            self.activeMode = nil
            completion?()
        }
    }

    func installScene(in content: inout RealityViewCameraContent) {
        let video = makeVideoMaterial(surface.initialTextureResource())
        let mesh = MeshResource.generateBox(width: 1.6, height: 0.9, depth: 0.9, splitFaces: true)
        // 六面全贴视频:无论盒子转到哪个角度都能看到视频,排除「视频面恰好背对/灰面无光显黑」的歧义。
        let cube = ModelEntity(mesh: mesh, materials: Array(repeating: video, count: 6))
        cube.position = [0, 0, 0]
        let yaw = simd_quatf(angle: .pi / 7, axis: [0, 1, 0])
        let pitch = simd_quatf(angle: -.pi / 10, axis: [1, 0, 0])
        cube.orientation = yaw * pitch

        let root = Entity()
        root.addChild(cube)
        content.add(root)
        content.camera = .virtual
        content.cameraTarget = cube
        self.cube = cube
    }

    func tick(deltaTime: TimeInterval) {
        tickCount += 1

        // 缓慢自转:转起来时贴着视频的那一面透视会变,证明视频确实在 3D 物体上。
        if let cube {
            spin += Float(deltaTime) * 0.6
            let yaw = simd_quatf(angle: spin, axis: [0, 1, 0])
            let pitch = simd_quatf(angle: -.pi / 10, axis: [1, 0, 0])
            cube.orientation = yaw * pitch
        }

        guard activeMode?.usesResidentTexture == true else {
            if tickCount == 1 || tickCount.isMultiple(of: 120) {
                let frameStatus = "window mode: resident path disabled | \(latestMpvStatus)"
                status = frameStatus
                DebugLog.write(frameStatus)
            }
            return
        }

        // 跟随 mpv 发布的最新完整缓冲(门①双缓冲消费侧)。
        let frontID = xr_resident_front_iosurface_id()
        if frontID != 0, frontID != currentFrontID {
            currentFrontID = frontID
            frontFlips += 1
            seenFrontIDs.insert(frontID)
            if let buffer = surface.buffer(forID: frontID), var model = cube?.model {
                let mat = makeVideoMaterial(buffer.textureResource)
                model.materials = Array(repeating: mat, count: model.materials.count)
                cube?.model = model
            }
        }

        if tickCount == 1 || tickCount.isMultiple(of: 120) {
            let sample = frontID != 0 ? surface.samplePixelSum(forID: frontID) : 0
            let frameStatus = "front=\(frontID) flips=\(frontFlips) distinct=\(seenFrontIDs.count) " +
                "sample=\(sample) \(sample > 0 ? "nonzero" : "black") | \(latestMpvStatus)"
            status = frameStatus
            DebugLog.write(frameStatus)
        }
    }

    private func makeVideoMaterial(_ textureResource: TextureResource) -> UnlitMaterial {
        let texture = MaterialParameters.Texture(textureResource)
        // 关闭 RealityKit 默认的 post-process tone mapping:视频帧已是显示就绪的
        // sRGB 颜色,再过一道 tone map 会改变颜色(Apple 文档:精确还原用 false)。
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: texture)
        return material
    }
}
