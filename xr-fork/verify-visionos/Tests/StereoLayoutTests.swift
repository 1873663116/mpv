import Testing
import simd

/// 立体 UV 拆半数学的确定性验收(SPEC §4「拆眼 UV 拆半数学 🤖 验死」)。
struct StereoLayoutTests {
    typealias L = StereoLayout

    @Test func monoTakesFullFrame() {
        let r = L.eyeRect(isLeft: true, packing: .mono)
        #expect(r.origin == .zero && r.scale == SIMD2<Float>(1, 1))
    }

    @Test func sbsLeftTakesLeftHalf() {
        let l = L.eyeRect(isLeft: true, packing: .sbs)
        let r = L.eyeRect(isLeft: false, packing: .sbs)
        #expect(l.origin == SIMD2<Float>(0, 0) && l.scale == SIMD2<Float>(0.5, 1))
        #expect(r.origin == SIMD2<Float>(0.5, 0) && r.scale == SIMD2<Float>(0.5, 1))
    }

    @Test func tbLeftTakesTopHalf() {
        let l = L.eyeRect(isLeft: true, packing: .tb)
        let r = L.eyeRect(isLeft: false, packing: .tb)
        #expect(l.origin == SIMD2<Float>(0, 0) && l.scale == SIMD2<Float>(1, 0.5))
        #expect(r.origin == SIMD2<Float>(0, 0.5) && r.scale == SIMD2<Float>(1, 0.5))
    }

    @Test func swapExchangesHalves() {
        let l = L.eyeRect(isLeft: true, packing: .sbs, swap: true)
        let r = L.eyeRect(isLeft: false, packing: .sbs, swap: true)
        // swap 后左眼取右半、右眼取左半。
        #expect(l.origin == SIMD2<Float>(0.5, 0))
        #expect(r.origin == SIMD2<Float>(0, 0))
    }

    @Test func halfFullAspectFix() {
        #expect(L.aspectFix(packing: .sbs, half: true) == SIMD2<Float>(2, 1))
        #expect(L.aspectFix(packing: .tb, half: true) == SIMD2<Float>(1, 2))
        #expect(L.aspectFix(packing: .sbs, half: false) == SIMD2<Float>(1, 1))
        #expect(L.aspectFix(packing: .mono, half: true) == SIMD2<Float>(1, 1))
    }

    /// 两眼子矩形不重叠且并起来覆盖全幅(拆分既无重叠也无遗漏)。
    @Test func eyesPartitionFrame() {
        for packing in [L.Packing.sbs, .tb] {
            let l = L.eyeRect(isLeft: true, packing: packing)
            let r = L.eyeRect(isLeft: false, packing: packing)
            // 面积各占一半,合计为 1。
            #expect(abs(l.scale.x * l.scale.y - 0.5) < 1e-6)
            #expect(abs(r.scale.x * r.scale.y - 0.5) < 1e-6)
            // 起点不同 → 取的是不同半。
            #expect(l.origin != r.origin)
        }
    }
}
