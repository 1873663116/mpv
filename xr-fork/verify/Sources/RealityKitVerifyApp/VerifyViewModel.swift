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
        guard started else {
            return
        }
        guard newMode != activeMode else {
            return
        }

        status = "switching to \(newMode.title)"
        DebugLog.write(status)
        stop {
            self.start(mode: newMode)
        }
    }

    private func start(mode: PlaybackMode) {
        guard !started else {
            return
        }
        started = true
        activeMode = mode
        latestMpvStatus = "mpv idle"
        tickCount = 0

        do {
            try player.start(
                mode: mode,
                surfaceID: surface.iosurfaceID,
                width: ResidentVideoSurface.width,
                height: ResidentVideoSurface.height
            )
            status = "\(mode.title) mode started" +
                (mode.usesResidentTexture ? ", IOSurfaceID=\(surface.iosurfaceID)" : ", resident path disabled")
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
        let video = makeVideoMaterial()
        let side = SimpleMaterial(color: .init(white: 0.18, alpha: 1.0), roughness: 0.55, isMetallic: false)
        let mesh = MeshResource.generateBox(width: 1.6, height: 0.9, depth: 0.9, splitFaces: true)
        let cube = ModelEntity(mesh: mesh, materials: [video, side, side, side, side, side])
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
        if tickCount == 1 || tickCount.isMultiple(of: 120) {
            guard activeMode?.usesResidentTexture == true else {
                let frameStatus = "window mode: resident path disabled | \(latestMpvStatus)"
                status = frameStatus
                DebugLog.write(frameStatus)
                return
            }

            let sample = surface.samplePixelSum()
            let frameStatus = "zero-copy surface sample=\(sample) \(sample > 0 ? "nonzero" : "black") | \(latestMpvStatus)"
            status = frameStatus
            DebugLog.write(frameStatus)
        }
    }

    private func makeVideoMaterial() -> UnlitMaterial {
        let texture = MaterialParameters.Texture(surface.makeTextureResource())
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: texture)
        return material
    }
}
