import Libmpv
import RealityKit

/// 标记组件:挂在「mpv 屏」实体上,携带按 IOSurfaceID 预制好的 UnlitMaterial。
/// 每张 IOSurface 对应一个 material(纹理已零拷贝包好),换 front 时只是切 material 引用。
struct ResidentVideoComponent: Component {
    var materialsByID: [UInt32: UnlitMaterial]
    var faceCount: Int
    var currentID: UInt32 = 0
}

/// 逐帧系统(visionOS 惯用法,替代 macOS verify 的 SceneEvents.Update tick):
/// 读 mpv 发布的 front IOSurfaceID,变了就把对应 material 换到屏实体上。
/// `xr_resident_front_iosurface_id()` 是 atomic 读,任意线程安全。
struct VideoFrameSystem: System {
    static let query = EntityQuery(where: .has(ResidentVideoComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let front = xr_resident_front_iosurface_id()
        guard front != 0 else { return }

        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var component = entity.components[ResidentVideoComponent.self],
                  front != component.currentID,
                  let material = component.materialsByID[front]
            else { continue }

            component.currentID = front
            entity.components.set(component)

            if var model = entity.components[ModelComponent.self] {
                model.materials = Array(repeating: material, count: max(1, component.faceCount))
                entity.components.set(model)
            }
        }
    }
}
