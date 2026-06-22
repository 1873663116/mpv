import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import IOSurface
import Metal
import RealityKit
import UniformTypeIdentifiers

/// 门① 三缓冲:持有 3 张 IOSurface(写/读环,ADR 0011)。mpv 轮流写后台缓冲、延迟一帧发布 front;
/// 消费侧按 mpv 发布的 front IOSurfaceID 取对应 TextureResource 给 RealityKit。三张让「正写 /
/// 待发布 / 消费中」互不重叠 → C 侧得以用 pl_gpu_flush + pl_tex_poll 取代每帧 pl_gpu_finish 全停。
///
/// visionOS 出口走**公有零拷贝** API(vOS27):`LowLevelDeviceResource(textureDescriptor:iosurface:plane:)`
/// 把 mpv 的 IOSurface 就地导入,`LowLevelTexture` + `TextureResource(from:)` 给材质,换帧用
/// `LLT.replace(deviceResource:)` 指针级切换(取代私有 `__texture(from:)`,以便上架)。不引入 AppKit。
/// [xr-perf 杠杆2] 出口像素格式路由(Phase 1,见 ADR 0004/0005)。按源 HDR 与否选最省带宽的格式:
///   `.sdr8`  = 8-bit sRGB(Display P3),4 字节/px —— SDR 专用,带宽腰斩,零画质损失;
///   `.hdr16` = fp16 扩展线性(Display P3),8 字节/px —— HDR EDR(承载 >1.0 线性光),真机调好的默认。
/// (Phase 2 将加 `.hdr10pq`:10-bit PQ + 消费端 ShaderGraph 解码,把 HDR 带宽也腰斩。)
enum XRColorRoute: String, CaseIterable {
    case sdr8
    case hdr16

    var bytesPerPixel: Int { self == .sdr8 ? 4 : 8 }
    /// IOSurface 像素格式(与 C 侧 xr_resident_texture.m 的 XR_PIXFMT_* 对齐)。
    var iosurfacePixelFormat: OSType { self == .sdr8 ? kCVPixelFormatType_32RGBA
                                                     : kCVPixelFormatType_64RGBAHalf }
    /// 消费端 Metal 视图:8-bit 用 `_srgb` 变体 → 采样时 GPU 自动解 sRGB→线性(与 C 写入侧的
    /// plain rgba8Unorm + libplacebo sRGB 编码严格互逆);fp16 直采线性。
    var metalConsumerFormat: MTLPixelFormat { self == .sdr8 ? .rgba8Unorm_srgb : .rgba16Float }
    var label: String { self == .sdr8 ? "8-bit sRGB" : "fp16 线性" }
}

/// 路由模式(调参开关):自动按源元数据选,或手动强制。
enum XRRouteMode: String, CaseIterable {
    case auto
    case forceSDR
    case forceHDR
    var label: String { self == .auto ? "自动" : (self == .forceSDR ? "强制 SDR 8-bit" : "强制 HDR fp16") }
}

@MainActor
final class ResidentVideoSurface {
    let width: Int
    let height: Int
    let route: XRColorRoute
    static let bufferCount = 3

    struct Buffer {
        let iosurface: IOSurfaceRef
        let id: UInt32
        // 同一张 IOSurface 的两个 LLDR 实例:换帧时交替使用 —— RK 把「同实例 replace」当 no-op,
        // 换实例才触发重读(Apple『Displaying low-latency connected video』样例同款机制)。
        let deviceResA: LowLevelDeviceResource
        let deviceResB: LowLevelDeviceResource
    }

    let buffers: [Buffer]
    /// 零拷贝零换材质契约:**一个** LLT + **一张** TextureResource 始终绑给材质;换帧只对 LLT 调
    /// `replace(deviceResource:)` 切到 front 那张 IOSurface(见 presentFront)。
    let lowLevelTexture: LowLevelTexture
    let textureResource: TextureResource
    /// 当前已 present 的 IOSurfaceID + 交替计数(保证每次 replace 用不同 LLDR 实例 → RK 必重读)。
    private var presentedID: UInt32 = 0
    private var toggle = 0

    var iosurfaceIDs: [UInt32] { buffers.map(\.id) }

    init(width: Int = 1280, height: Int = 720, route: XRColorRoute = .hdr16) throws {
        self.width = width
        self.height = height
        self.route = route

        #if targetEnvironment(simulator)
        // LLDR 零拷贝(共享纹理)在 visionOS 模拟器不可用(Apple 样例明示),且模拟器本就渲染不了 MoltenVK。
        throw VerifyError("LowLevelDeviceResource 零拷贝路径不支持模拟器,请用真机")
        #else
        // 消费端纹理视图格式:8-bit 用 _srgb(GPU 自动解 sRGB→线性,与写入侧编码互逆);fp16 直采线性。
        // 这份描述符既给每张 IOSurface 的 LLDR 导入,也与下方 LLT 描述符同格式。
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: route.metalConsumerFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        var made: [Buffer] = []
        for index in 0..<Self.bufferCount {
            // fp16(8B/px)= 扩展线性 Display P3 承载 HDR(>1.0 线性光);8-bit(4B/px)= IEC sRGB,SDR。
            // 与 C 侧(xr_resident_texture.m)创建的格式一致,两侧包同一面。
            let properties: [CFString: Any] = [
                kIOSurfaceWidth: width,
                kIOSurfaceHeight: height,
                kIOSurfaceBytesPerElement: route.bytesPerPixel,
                kIOSurfacePixelFormat: route.iosurfacePixelFormat,
            ]
            guard let iosurface = IOSurfaceCreate(properties as CFDictionary) else {
                throw VerifyError("IOSurfaceCreate[\(index)] failed")
            }
            // 同一张 IOSurface 建两个 LLDR 实例,换帧交替使用(承重机制见 Buffer 注释)。
            let a = try LowLevelDeviceResource(textureDescriptor: descriptor, iosurface: iosurface, plane: 0)
            let b = try LowLevelDeviceResource(textureDescriptor: descriptor, iosurface: iosurface, plane: 0)
            made.append(Buffer(iosurface: iosurface, id: IOSurfaceGetID(iosurface),
                               deviceResA: a, deviceResB: b))
        }
        buffers = made

        // 一个 LLT(描述符与消费视图格式一致)+ 一个 TextureResource;初始指向 buffers[0]。
        let lltDescriptor = LowLevelTexture.Descriptor(
            pixelFormat: route.metalConsumerFormat, width: width, height: height,
            depth: 1, mipmapLevelCount: 1, textureUsage: [.shaderRead])
        let llt = try LowLevelTexture(descriptor: lltDescriptor)
        llt.replace(deviceResource: made[0].deviceResA)
        self.lowLevelTexture = llt
        self.textureResource = try TextureResource(from: llt)
        // 初始 0(非 buffers[0].id):生产端首发 front 恰是 buffers[0],设 0 让首帧也必触发一次 replace
        // 重读真内容,而非停在 init 时的空纹理。
        self.presentedID = 0
        #endif
    }

    /// 换帧(@MainActor,零拷贝、指针级):把 LLT 切到 front 那张 IOSurface。front 未变返回 false。
    /// 写完同步由生产端保证(front 仅在 pl_tex_poll 确认写完后才发布),故无需 command buffer。
    /// 每次交替用该缓冲的两个 LLDR 实例,确保 RK 必重读(同实例 = no-op)。
    @discardableResult
    func presentFront(_ id: UInt32) -> Bool {
        guard id != presentedID, let buf = buffers.first(where: { $0.id == id }) else { return false }
        toggle &+= 1
        lowLevelTexture.replace(deviceResource: (toggle & 1 == 0) ? buf.deviceResA : buf.deviceResB)
        presentedID = id
        return true
    }

    func buffer(forID id: UInt32) -> Buffer? {
        buffers.first { $0.id == id }
    }

    /// fp16 抽样(验证夹具,Gate 1):返回抽样通道和 + **线性峰值**。峰值 >1.0 = 出口确含
    /// 超过 SDR 参考白(1.0)的内容 → 真 HDR;落在 ~1.0–2.0 = 在 visionOS EDR headroom(2.0)
    /// 内,与 AVFoundation 对齐。每像素 8 字节 = 4×Float16,读 RGB 三通道。生产接入时去掉。
    func samplePeak(forID id: UInt32) -> (sum: Double, peak: Float) {
        guard let buffer = buffer(forID: id) else { return (0, 0) }
        let iosurface = buffer.iosurface
        IOSurfaceLock(iosurface, .readOnly, nil)
        defer { IOSurfaceUnlock(iosurface, .readOnly, nil) }

        let base = IOSurfaceGetBaseAddress(iosurface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(iosurface)
        var sum: Double = 0
        var peak: Float = 0
        for y in stride(from: 0, to: height, by: 16) {
            let row = base.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: 16) {
                let px = row.advanced(by: x * 8).assumingMemoryBound(to: Float16.self)
                for c in 0..<3 {
                    let v = Float(px[c])
                    sum += Double(v)
                    if v > peak { peak = v }
                }
            }
        }
        return (sum, peak)
    }

    /// fp16 抽样**色度**(饱和度验证夹具)。把线性 Display P3 像素经 P3→XYZ→CIE1976 u'v',
    /// 取离 D65 白点的色度距离作「饱和度」代理 —— **与亮度无关**,故 HDR(峰值>1)与 SDR
    /// 的 tone-map 差异不污染比较,纯反映色域映射对饱和度的影响。返回均值 + p90(对彩色区更敏感)。
    /// 用于 perceptual vs clip vs relative vs AV 地面真值的数值对照(ADR 0006)。
    func sampleChroma(forID id: UInt32) -> (mean: Float, p90: Float, n: Int) {
        guard let buffer = buffer(forID: id) else { return (0, 0, 0) }
        let iosurface = buffer.iosurface
        IOSurfaceLock(iosurface, .readOnly, nil)
        defer { IOSurfaceUnlock(iosurface, .readOnly, nil) }

        let base = IOSurfaceGetBaseAddress(iosurface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(iosurface)
        let uw: Float = 0.19783, vw: Float = 0.46832   // D65 in CIE 1976 u'v'
        var chromas: [Float] = []
        chromas.reserveCapacity((height / 4) * (width / 4))
        for y in stride(from: 0, to: height, by: 4) {
            let row = base.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: 4) {
                let px = row.advanced(by: x * 8).assumingMemoryBound(to: Float16.self)
                let r = max(0, Float(px[0])), g = max(0, Float(px[1])), b = max(0, Float(px[2]))
                // 线性 Display P3 (D65) → XYZ
                let X = 0.4865709 * r + 0.2656677 * g + 0.1982173 * b
                let Y = 0.2289746 * r + 0.6917385 * g + 0.0792869 * b
                let Z = 0.0451134 * g + 1.0439444 * b
                let den = X + 15 * Y + 3 * Z
                if den <= 1e-6 || Y <= 1e-4 { continue }   // 跳过黑/近黑(色度无意义)
                chromas.append(hypotf(4 * X / den - uw, 9 * Y / den - vw))
            }
        }
        guard !chromas.isEmpty else { return (0, 0, 0) }
        let mean = chromas.reduce(0, +) / Float(chromas.count)
        let p90 = chromas.sorted()[Int(Float(chromas.count - 1) * 0.9)]
        return (mean, p90, chromas.count)
    }

    /// fp16 抽样**亮度统计**(发白/黑位/高光削顶诊断)。读线性 Display P3 的 Y(亮度,1.0=SDR
    /// 参考白),给分位数 + 超过 1.0/2.0 的像素占比。用途:对比源的亮度分布,判别"发白(黑位抬升)"
    /// 与"高光削顶"到底出在 mpv 输出字节里(管线),还是出在合成器对未打 HDR 语义纹理的误读(显示端)。
    /// 源黑区在输出 Y≈0 → 管线没抬黑,发白是显示端;输出高光在 ~2.0 堆积 → tone-map 削顶(管线)。
    func sampleLuminanceStats(forID id: UInt32)
        -> (min: Float, p1: Float, p5: Float, p50: Float, p95: Float, p99: Float, max: Float, fracGt1: Float, fracGt2: Float) {
        guard let buffer = buffer(forID: id) else { return (0, 0, 0, 0, 0, 0, 0, 0, 0) }
        let iosurface = buffer.iosurface
        IOSurfaceLock(iosurface, .readOnly, nil)
        defer { IOSurfaceUnlock(iosurface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(iosurface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(iosurface)
        var lum: [Float] = []
        lum.reserveCapacity((height / 4) * (width / 4))
        var gt1 = 0, gt2 = 0
        for y in stride(from: 0, to: height, by: 4) {
            let row = base.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: 4) {
                let px = row.advanced(by: x * 8).assumingMemoryBound(to: Float16.self)
                let r = max(0, Float(px[0])), g = max(0, Float(px[1])), b = max(0, Float(px[2]))
                let Y = 0.2289746 * r + 0.6917385 * g + 0.0792869 * b   // 线性 P3 → Y
                lum.append(Y)
                if Y > 1.0 { gt1 += 1 }
                if Y > 2.0 { gt2 += 1 }
            }
        }
        guard !lum.isEmpty else { return (0, 0, 0, 0, 0, 0, 0, 0, 0) }
        lum.sort()
        let n = lum.count
        func pct(_ p: Float) -> Float { lum[min(n - 1, max(0, Int(Float(n - 1) * p)))] }
        return (lum[0], pct(0.01), pct(0.05), pct(0.50), pct(0.95), pct(0.99), lum[n - 1],
                Float(gt1) / Float(n), Float(gt2) / Float(n))
    }

    /// 把 fp16 IOSurface 转 8-bit Display P3 PNG(SDR-clamp,仅作视觉对照截图)。
    /// 线性 P3 → 钳到 [0,1] → IEC sRGB/P3 传递编码 → 8-bit,贴 Display P3 色彩空间标签。
    /// 三种 gamut 模式各存一张(mpv-<mode>.png),供报告里并排看饱和度差异。
    @discardableResult
    func dumpPNG(forID id: UInt32, to url: URL) -> Bool {
        guard let buffer = buffer(forID: id) else { return false }
        let iosurface = buffer.iosurface
        IOSurfaceLock(iosurface, .readOnly, nil)
        defer { IOSurfaceUnlock(iosurface, .readOnly, nil) }

        let base = IOSurfaceGetBaseAddress(iosurface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(iosurface)
        func encode(_ v: Float) -> UInt8 {
            let c = min(max(v, 0), 1)
            let s = c <= 0.0031308 ? 12.92 * c : 1.055 * powf(c, 1 / 2.4) - 0.055
            return UInt8(min(max(s * 255, 0), 255).rounded())
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let px = row.advanced(by: x * 8).assumingMemoryBound(to: Float16.self)
                let o = (y * width + x) * 4
                rgba[o + 0] = encode(Float(px[0]))
                rgba[o + 1] = encode(Float(px[1]))
                rgba[o + 2] = encode(Float(px[2]))
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = ctx.makeImage(),
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}

struct VerifyError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
