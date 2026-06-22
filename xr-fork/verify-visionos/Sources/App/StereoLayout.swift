import simd

/// 立体拆眼的 **UV 子矩形数学**(SPEC §3.2 / §4「拆眼 UV 拆半数学」)。
///
/// 这是立体拆眼里**确定性、可在模拟器验死**的那一半:给定打包方式(SBS/TB)、
/// half/full、是否 swap,算出左/右眼各自该采样的纹理子矩形(原点 + 缩放)。
/// 真机残值只剩「`Camera Index Switch` 自动选哪只眼」——那一半无法静态验。
///
/// 用法:把 `eyeRect(...)` 的 origin/scale 喂给材质的 UV 变换
/// (ShaderGraph 单纹理 UV-offset,或 Swift 侧切两张 `TextureResource` 的源矩形)。
enum StereoLayout {

    /// 打包方式。mono = 整幅给两眼;sbs = 左右并排;tb = 上下堆叠。
    enum Packing { case mono, sbs, tb }

    /// 一只眼采样的纹理子矩形:`uv' = origin + uv * scale`。
    struct EyeRect: Equatable {
        var origin: SIMD2<Float>
        var scale: SIMD2<Float>
    }

    /// 计算某只眼的采样子矩形。
    /// - isLeft:true=左眼,false=右眼(经 swap 翻转)。
    /// - packing:SBS 沿 U 切半,TB 沿 V 切半。
    /// - swap:装反一键纠正,交换左右占位。
    ///
    /// half/full 不改变"取哪半"(都是各取一半),只影响下游是否再 ×2 拉伸还原宽高比 —— 见 `aspectFix`。
    static func eyeRect(isLeft: Bool, packing: Packing, swap: Bool = false) -> EyeRect {
        // mono:整幅。
        guard packing != .mono else {
            return EyeRect(origin: .zero, scale: SIMD2<Float>(1, 1))
        }
        // swap 后这只眼实际取的是"另一半"。
        let takeLeftHalf = (isLeft != swap)
        switch packing {
        case .mono:
            return EyeRect(origin: .zero, scale: SIMD2<Float>(1, 1))
        case .sbs:
            // 沿 U 切:左半 u∈[0,0.5],右半 u∈[0.5,1]。
            return EyeRect(origin: SIMD2<Float>(takeLeftHalf ? 0 : 0.5, 0),
                           scale: SIMD2<Float>(0.5, 1))
        case .tb:
            // 沿 V 切:上半(left)v∈[0,0.5],下半(right)v∈[0.5,1]。
            return EyeRect(origin: SIMD2<Float>(0, takeLeftHalf ? 0 : 0.5),
                           scale: SIMD2<Float>(1, 0.5))
        }
    }

    /// half/full 的宽高比修正系数(供几何或采样还原每眼比例):
    /// - full:每眼本就是全分辨率,拼接只是并排 → 不额外拉伸,(1,1)。
    /// - half:每眼被压到半幅 → 切半后需在被切轴上 ×2 还原,(SBS=2×U,TB=2×V)。
    static func aspectFix(packing: Packing, half: Bool) -> SIMD2<Float> {
        guard half, packing != .mono else { return SIMD2<Float>(1, 1) }
        switch packing {
        case .mono: return SIMD2<Float>(1, 1)
        case .sbs:  return SIMD2<Float>(2, 1)
        case .tb:   return SIMD2<Float>(1, 2)
        }
    }
}
