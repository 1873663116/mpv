import RealityKit
import simd

/// 自建朝内 equirect 球面网格(全景核心,SPEC §3.1)。
///
/// 为什么不用 `MeshResource.generateSphere`:它 ①法线朝外(从内部看会被背面剔除)
/// ②只能整球、取不了半球 ③细分不可控。三个需求都指向自建。
///
/// 朝内做法:用 **CW 缠绕**让内表面成为正面(避 `scale.x *= -1` 负缩放的 winding/
/// determinant 歧义,见 SPEC §7、Apple 论坛 thread/794821)。
///
/// 这是纯数据构造,不依赖运行时,可在模拟器单测里直接断言顶点/UV/朝向。
enum PanoramaMesh {

    /// 投影规格:水平/垂直张角 + 是否翻转纹理 v 轴。
    /// - 360 全景:水平 2π、垂直 π。
    /// - 180(VR180 单眼半球):水平 π、垂直 π,前方(-Z)铺满纹理宽。
    struct Spec {
        /// 水平张角(弧度)。360 = 2π,180 = π。
        var thetaSpan: Float
        /// 垂直张角(弧度)。两者通常都是 π(整条经线)。
        var phiSpan: Float
        /// 球半径(米)。纯主观距离、无视差,真机签收项;默认 10m。
        var radius: Float
        /// 经度分段(水平)。
        var lonSegments: Int
        /// 纬度分段(垂直)。
        var latSegments: Int
        /// 纹理 v 轴翻转(equirect 顶行常对应 φ=0 即天顶;RealityKit UV 原点差异需要时翻)。
        var flipV: Bool
        /// 立体拆眼 UV 子矩形:`uv' = uvOrigin + uv·uvScale`。默认 (0,0)+(1,1)=整幅(mono)。
        /// SBS 取左半 = (0,0)+(0.5,1);TB 取上半 = (0,0)+(1,0.5)。来自 `StereoLayout.eyeRect`。
        var uvOrigin: SIMD2<Float> = .zero
        var uvScale: SIMD2<Float> = .one

        static let sphere360 = Spec(thetaSpan: 2 * .pi, phiSpan: .pi,
                                    radius: 10, lonSegments: 128, latSegments: 64, flipV: true)
        static let hemisphere180 = Spec(thetaSpan: .pi, phiSpan: .pi,
                                        radius: 10, lonSegments: 128, latSegments: 64, flipV: true)
    }

    /// 几何原始数据(供单测断言,与 RealityKit 解耦)。
    struct Geometry {
        var positions: [SIMD3<Float>]
        var uvs: [SIMD2<Float>]
        var normals: [SIMD3<Float>]
        var indices: [UInt32]
    }

    /// 生成 equirect 球面几何。
    ///
    /// 坐标约定(RealityKit 右手系、相机默认看向 -Z):
    /// - φ(极角)从 0(天顶 +Y)到 π(天底 -Y)。
    /// - θ(方位)0 → -Z 正前方,绕 +Y 旋转;θ 居中铺在张角内,正前方落在纹理水平中心。
    /// - u = (θ + thetaSpan/2)/thetaSpan,v = φ/phiSpan(可选翻转),令纹理在张角内铺满。
    static func geometry(_ spec: Spec) -> Geometry {
        let lon = max(3, spec.lonSegments)
        let lat = max(2, spec.latSegments)
        // φ 在垂直张角内居中:phiSpan=π 时即 [0,π] 整条经线。
        let phi0 = (.pi - spec.phiSpan) / 2
        let theta0 = -spec.thetaSpan / 2

        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity((lon + 1) * (lat + 1))

        for j in 0...lat {
            let vt = Float(j) / Float(lat)
            let phi = phi0 + vt * spec.phiSpan
            let sinP = sin(phi), cosP = cos(phi)
            for i in 0...lon {
                let ut = Float(i) / Float(lon)
                let theta = theta0 + ut * spec.thetaSpan
                // θ=0 → -Z 正前方;+θ 转向 +X。
                let x = spec.radius * sinP * sin(theta)
                let y = spec.radius * cosP
                let z = -spec.radius * sinP * cos(theta)
                let pos = SIMD3<Float>(x, y, z)
                positions.append(pos)
                // 朝内法线:指向球心(单位化的 -pos 方向)。
                normals.append(simd_normalize(-pos))
                // 基础 equirect UV → 立体拆眼子矩形(mono 时为整幅,无变化)。
                let baseV = spec.flipV ? 1 - vt : vt
                uvs.append(SIMD2<Float>(spec.uvOrigin.x + ut * spec.uvScale.x,
                                        spec.uvOrigin.y + baseV * spec.uvScale.y))
            }
        }

        // CW 缠绕(内表面为正面)。每个格子两个三角形。
        var indices: [UInt32] = []
        indices.reserveCapacity(lon * lat * 6)
        let stride = lon + 1
        for j in 0..<lat {
            for i in 0..<lon {
                let a = UInt32(j * stride + i)
                let b = UInt32(j * stride + i + 1)
                let c = UInt32((j + 1) * stride + i)
                let d = UInt32((j + 1) * stride + i + 1)
                // 朝内 CW:面法线(叉积)指向球心。外向序是 (a,b,c)/(b,d,c),反序得此。
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }

        return Geometry(positions: positions, uvs: uvs, normals: normals, indices: indices)
    }

    /// 把几何构造成 `MeshResource`(供 RealityKit 实体使用)。
    static func makeResource(_ spec: Spec) throws -> MeshResource {
        let geo = geometry(spec)
        var descriptor = MeshDescriptor(name: "xr-panorama")
        descriptor.positions = MeshBuffers.Positions(geo.positions)
        descriptor.normals = MeshBuffers.Normals(geo.normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(geo.uvs)
        descriptor.primitives = .triangles(geo.indices)
        return try MeshResource.generate(from: [descriptor])
    }

    /// 朝前平面 quad(窗口模式 / 平面 3D),UV 子矩形可烘立体拆眼(与球同口径)。
    /// 在 XY 面、法线 +Z 朝相机;`height=1`、`width=aspect`(等比)。
    /// `uvOrigin/uvScale` 同 `Spec`:mono=(0,0)+(1,1),SBS 左半=(0,0)+(0.5,1),TB 上半=(0,0)+(1,0.5)。
    static func quad(aspect: Float,
                     uvOrigin: SIMD2<Float> = .zero,
                     uvScale: SIMD2<Float> = .one) throws -> MeshResource {
        let w = aspect / 2, h: Float = 0.5
        let positions: [SIMD3<Float>] = [
            [-w, -h, 0], [w, -h, 0], [-w, h, 0], [w, h, 0],
        ]
        // 左下原点 UV;v 轴翻转使图像正立(纹理顶行在上)。
        func uv(_ u: Float, _ v: Float) -> SIMD2<Float> {
            SIMD2(uvOrigin.x + u * uvScale.x, uvOrigin.y + (1 - v) * uvScale.y)
        }
        let uvs = [uv(0, 0), uv(1, 0), uv(0, 1), uv(1, 1)]
        let normals = [SIMD3<Float>](repeating: [0, 0, 1], count: 4)
        let indices: [UInt32] = [0, 1, 2, 2, 1, 3]
        var d = MeshDescriptor(name: "xr-quad")
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        d.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        d.primitives = .triangles(indices)
        return try MeshResource.generate(from: [d])
    }
}
