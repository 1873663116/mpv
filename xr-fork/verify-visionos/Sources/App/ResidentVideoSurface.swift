import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import IOSurface
import Metal
import RealityKit
import UniformTypeIdentifiers

/// 门① 双缓冲:持有 2 张 IOSurface(写/读环)。mpv 在两张间交替写后台缓冲、
/// 写完发布为 front;消费侧按 mpv 发布的 front IOSurfaceID 取对应 TextureResource 给 RealityKit。
///
/// visionOS 移植说明(与 macOS verify 唯一差异):不引入 AppKit。零拷贝包装 API
/// `TextureResource.__texture(from:)` 经 xros SDK typecheck 确认可用,路径与 macOS 一致。
@MainActor
final class ResidentVideoSurface {
    let width: Int
    let height: Int
    static let bufferCount = 2

    struct Buffer {
        let iosurface: IOSurfaceRef
        let id: UInt32
        let metalTexture: any MTLTexture
        let textureResource: TextureResource
    }

    let buffers: [Buffer]

    var iosurfaceIDs: [UInt32] { buffers.map(\.id) }

    init(width: Int = 1280, height: Int = 720) throws {
        self.width = width
        self.height = height

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw VerifyError("MTLCreateSystemDefaultDevice failed")
        }

        var made: [Buffer] = []
        for index in 0..<Self.bufferCount {
            // HDR 出口(ADR 0005):fp16 RGBA(每像素 8 字节)承载「扩展线性 Display P3」。
            // mpv 经 libplacebo 把 HDR10 源 tone-map 进 EDR headroom(参考白=1.0,峰值≤~2.0)
            // 写进这张 IOSurface;>1.0 的线性光即 HDR。kCVPixelFormatType_64RGBAHalf 与 C 侧
            // (xr_resident_texture.m)创建的内部回落格式一致,两侧都以 .rgba16Float 包装同一面。
            let properties: [CFString: Any] = [
                kIOSurfaceWidth: width,
                kIOSurfaceHeight: height,
                kIOSurfaceBytesPerElement: 8,
                kIOSurfacePixelFormat: kCVPixelFormatType_64RGBAHalf,
            ]
            guard let iosurface = IOSurfaceCreate(properties as CFDictionary) else {
                throw VerifyError("IOSurfaceCreate[\(index)] failed")
            }

            // rgba16Float 是线性浮点格式(无 _srgb 变体):字节即扩展线性光,采样不做 EOTF 解码。
            // ⚠️ 限制(SDK 实测):零拷贝路径 TextureResource.__texture(from:) 只吃 MTLTexture,
            // 不接受 CreateOptions/semantic,故无法显式打 `.hdrColor` 语义;visionOS 也无
            // RealityView EDR 开关(沉浸内容由合成器自动按扩展线性 Display P3 合成)。
            // 因此 HDR 与否的唯一信号就是这里的 .rgba16Float 浮点格式 + >1.0 的线性值。详见 ADR 0005。
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared

            guard let metalTexture = device.makeTexture(
                descriptor: descriptor,
                iosurface: iosurface,
                plane: 0
            ) else {
                throw VerifyError("MTLDevice.makeTexture(iosurface:)[\(index)] failed")
            }

            made.append(Buffer(
                iosurface: iosurface,
                id: IOSurfaceGetID(iosurface),
                metalTexture: metalTexture,
                textureResource: TextureResource.__texture(from: metalTexture)
            ))
        }
        buffers = made
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
