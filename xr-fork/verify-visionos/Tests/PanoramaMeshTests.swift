import Testing
import simd
import RealityKit

/// 全景球几何的确定性验收(SPEC §4 🤖 模拟器通道:几何类型/UV 落位/朝向数学)。
/// 纯数据断言,不需进沉浸 UI;`PanoramaMesh.swift` 直接编进本测试目标。
struct PanoramaMeshTests {

    /// 360:顶点数 = (lon+1)(lat+1),三角形数 = lon·lat·2。
    @Test func sphere360Topology() {
        let spec = PanoramaMesh.Spec.sphere360
        let g = PanoramaMesh.geometry(spec)
        #expect(g.positions.count == (spec.lonSegments + 1) * (spec.latSegments + 1))
        #expect(g.indices.count == spec.lonSegments * spec.latSegments * 6)
        #expect(g.uvs.count == g.positions.count)
        #expect(g.normals.count == g.positions.count)
    }

    /// 所有顶点落在半径球面上(±0.1%),证明这是球而非别的形状。
    @Test func allVerticesOnSphere() {
        let spec = PanoramaMesh.Spec.sphere360
        let g = PanoramaMesh.geometry(spec)
        for p in g.positions {
            #expect(abs(simd_length(p) - spec.radius) < spec.radius * 1e-3)
        }
    }

    /// UV 完整覆盖 [0,1]²:equirect 纹理铺满,无裁剪、无越界。
    @Test func uvCoversUnitSquare() {
        let g = PanoramaMesh.geometry(.sphere360)
        let us = g.uvs.map(\.x), vs = g.uvs.map(\.y)
        #expect(us.min()! == 0 && us.max()! == 1)
        #expect(vs.min()! == 0 && vs.max()! == 1)
    }

    /// 法线朝内:每条法线指向球心,即 normal·(-pos) > 0。这是"从内部能看到"的几何前提。
    @Test func normalsFaceInward() {
        let g = PanoramaMesh.geometry(.sphere360)
        for (p, n) in zip(g.positions, g.normals) where simd_length(p) > 1e-4 {
            #expect(simd_dot(n, simd_normalize(-p)) > 0.99)
        }
    }

    /// 三角形缠绕朝内:几何法线(叉积)与朝内方向同向 → 内表面是正面、不被剔除。
    @Test func windingIsInward() {
        let spec = PanoramaMesh.Spec.sphere360
        let g = PanoramaMesh.geometry(spec)
        var checked = 0
        for t in stride(from: 0, to: g.indices.count, by: 3) {
            let a = g.positions[Int(g.indices[t])]
            let b = g.positions[Int(g.indices[t + 1])]
            let c = g.positions[Int(g.indices[t + 2])]
            let faceNormal = simd_cross(b - a, c - a)
            // 极点处(φ=0/π)整行顶点坍缩 → 零面积退化三角形,无朝向可言,跳过(标准 UV 球产物,渲染无害)。
            guard simd_length(faceNormal) > 1e-4 else { continue }
            let centroid = (a + b + c) / 3
            // 朝内 = 几何法线与"指向球心"同向。
            #expect(simd_dot(faceNormal, -centroid) > 0)
            checked += 1
        }
        // 非退化三角形应占绝大多数(退化仅两极各一行)。
        #expect(checked >= g.indices.count / 3 - 2 * spec.lonSegments)
    }

    /// 正前方(纹理水平中心 u≈0.5)落在 -Z 方向:θ=0 约定正确,全景中心对准用户视线。
    @Test func forwardCenterMapsToMinusZ() {
        let g = PanoramaMesh.geometry(.sphere360)
        // 取 u 最接近 0.5、v 最接近 0.5 的顶点。
        var best = 0; var bestErr = Float.greatestFiniteMagnitude
        for (i, uv) in g.uvs.enumerated() {
            let e = abs(uv.x - 0.5) + abs(uv.y - 0.5)
            if e < bestErr { bestErr = e; best = i }
        }
        let p = simd_normalize(g.positions[best])
        #expect(p.z < -0.9)            // 指向 -Z 正前方
        #expect(abs(p.x) < 0.2 && abs(p.y) < 0.2)
    }

    /// 立体拆眼烘 UV:SBS 左半 spec → 所有 u 落在 [0,0.5],v 仍满 [0,1]。
    @Test func sbsLeftBakesIntoUVHalf() {
        var spec = PanoramaMesh.Spec.sphere360
        let r = StereoLayout.eyeRect(isLeft: true, packing: .sbs)   // (0,0)+(0.5,1)
        spec.uvOrigin = r.origin; spec.uvScale = r.scale
        let g = PanoramaMesh.geometry(spec)
        let us = g.uvs.map(\.x), vs = g.uvs.map(\.y)
        #expect(us.min()! == 0 && abs(us.max()! - 0.5) < 1e-6)
        #expect(vs.min()! == 0 && abs(vs.max()! - 1) < 1e-6)
    }

    /// TB 上半 spec → v 落在 [0,0.5],u 仍满 [0,1]。
    @Test func tbTopBakesIntoUVHalf() {
        var spec = PanoramaMesh.Spec.sphere360
        let r = StereoLayout.eyeRect(isLeft: true, packing: .tb)    // (0,0)+(1,0.5)
        spec.uvOrigin = r.origin; spec.uvScale = r.scale
        let g = PanoramaMesh.geometry(spec)
        let vs = g.uvs.map(\.y)
        #expect(vs.min()! == 0 && abs(vs.max()! - 0.5) < 1e-6)
    }

    /// 180 半球:水平张角 π → 顶点的方位角范围约为 [-90°,+90°],不绕到背后。
    @Test func hemisphere180HorizontalSpan() {
        let g = PanoramaMesh.geometry(.hemisphere180)
        // 赤道一圈(y≈0)的顶点 z 都 ≤ 微小正值:半球不含背面(+Z 深处)。
        for p in g.positions where abs(p.y) < 0.5 {
            #expect(p.z < 0.5)         // 前半球,不绕到 +Z 背后
        }
    }
}
