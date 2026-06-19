import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import RealityKit
import UniformTypeIdentifiers
import os

/// 对照组:AVFoundation → `VideoMaterial` 贴到 `screen(AV(` 平面。
/// 与 mpv 屏放同一片源做公平色彩比对。注意(ADR 0004):VideoMaterial 走系统色彩管理,
/// 与 mpv 的 Unlit sRGB 出口本就有学派差异,判据是「无结构性偏差」而非逐像素一致。
@MainActor
final class AVController {
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "enchron.verify.visionos", category: "av")

    func attach(to entity: Entity, url: URL) {
        // 换片重连前清掉上一个 player/观察者,避免泄漏与重复的循环回调。
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()

        let item = AVPlayerItem(url: url)
        // 720p 上限:与 mpv 出口同分辨率(双路都缩),省模拟器内存。分辨率与色彩格式
        // (PQ/Rec2020/HDR)正交 —— 下采样不改变 HDR 性质,两屏仍是同源 HDR 比对(ADR 0005)。
        item.preferredMaximumResolution = CGSize(width: 1280, height: 720)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        self.player = player

        let material = VideoMaterial(avPlayer: player)
        if var model = entity.components[ModelComponent.self] {
            let count = max(1, model.materials.count)
            model.materials = Array(repeating: material, count: count)
            entity.components.set(model)
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        // 不在此自动起播:由 VerifyModel 以 mpv 为主钟统一对齐后起播(消除「AV 起得比 mpv 早」)。
    }

    /// 跳到指定时间(秒),用于把 AV 对照对齐到 mpv 主钟。精确 seek(容差为零)以求同帧。
    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 暂停/继续:与 mpv 同步,由 VerifyModel.togglePause 一并调用,两屏一起冻结。
    func setPaused(_ paused: Bool) {
        if paused { player?.pause() } else { player?.play() }
    }

    /// Gate 1(对照源端断言):读 AVFoundation 解析出的色彩/HDR 元数据,确认与 mpv 同为 HDR10。
    /// 从视频轨的 CMFormatDescription 扩展读 ColorPrimaries / TransferFunction / 母带显示体积(MDCV)
    /// / 内容光强(MaxCLL/MaxFALL)。这是「两边都是 HDR」判定里 AV 侧的硬证据。
    func dumpHDRMetadata(url: URL) async {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                logger.error("[xr-verify] av-source 无视频轨: \(url.lastPathComponent, privacy: .public)")
                return
            }
            let formats = try await track.load(.formatDescriptions)
            guard let fd = formats.first else {
                logger.error("[xr-verify] av-source 无 formatDescription")
                return
            }
            let ext = (CMFormatDescriptionGetExtensions(fd) as? [CFString: Any]) ?? [:]
            func str(_ key: CFString) -> String { (ext[key] as? String) ?? "?" }
            let prim = str(kCMFormatDescriptionExtension_ColorPrimaries)
            let trc = str(kCMFormatDescriptionExtension_TransferFunction)
            let matrix = str(kCMFormatDescriptionExtension_YCbCrMatrix)
            let hasMDCV = ext[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] != nil
            let hasCLL = ext[kCMFormatDescriptionExtension_ContentLightLevelInfo] != nil
            let dims = CMVideoFormatDescriptionGetDimensions(fd)
            // PQ(ST 2084)或 HLG 或 Rec.2020 原色 = HDR10/HLG。
            let isHDR = trc.contains("2084") || trc.localizedCaseInsensitiveContains("HLG")
                || prim.contains("2020")
            logger.info("[xr-verify] av-source \(dims.width, privacy: .public)x\(dims.height, privacy: .public) prim=\(prim, privacy: .public) trc=\(trc, privacy: .public) matrix=\(matrix, privacy: .public) MDCV=\(hasMDCV, privacy: .public) CLL=\(hasCLL, privacy: .public) → \(isHDR ? "HDR10 ✓" : "SDR ✗", privacy: .public)")
        } catch {
            logger.error("[xr-verify] av-source 元数据读取失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// AV 侧**饱和度地面真值**(ADR 0006):用 AVAssetImageGenerator 让系统按 Apple 色管解出
    /// 指定时刻的帧 → 画进 8-bit Display P3 上下文 → 测同款 u'v' 色度 + 存 PNG。作 mpv 输出
    /// 饱和度的独立对照(perceptual 应明显低于它,clip/relative 应贴近)。
    /// 注:ImageGenerator 的 tone/gamut 与 VideoMaterial 实时 EDR 路径略有差异,但同属 Apple
    /// colorimetric(域内满饱和),作色度地面真值足够;最终视觉仍以真机 VideoMaterial 为准。
    func sampleSourceChroma(url: URL, at seconds: Double, pngTo pngURL: URL?) async -> (mean: Float, p90: Float)? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 1280, height: 720)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        // visionOS 无同步 copyCGImage,用 async image(at:)(iOS16+/visionOS1+)。
        let cg: CGImage
        do {
            cg = try await gen.image(at: time).image
        } catch {
            logger.error("[xr-verify] sat av image(at:) 失败 @\(seconds, privacy: .public)s: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // 画进已知 Display P3 上下文 → 输出原色固定 = P3,便于与 mpv 同口径测 u'v'。
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let pngURL, let image = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        let uw: Float = 0.19783, vw: Float = 0.46832
        func lin(_ u: UInt8) -> Float {
            let c = Float(u) / 255
            return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        var chromas: [Float] = []
        chromas.reserveCapacity((w / 4) * (h / 4))
        for y in stride(from: 0, to: h, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                let o = (y * w + x) * 4
                let r = lin(rgba[o]), g = lin(rgba[o + 1]), b = lin(rgba[o + 2])
                let X = 0.4865709 * r + 0.2656677 * g + 0.1982173 * b
                let Y = 0.2289746 * r + 0.6917385 * g + 0.0792869 * b
                let Z = 0.0451134 * g + 1.0439444 * b
                let den = X + 15 * Y + 3 * Z
                if den <= 1e-6 || Y <= 1e-4 { continue }
                chromas.append(hypotf(4 * X / den - uw, 9 * Y / den - vw))
            }
        }
        guard !chromas.isEmpty else { return nil }
        let mean = chromas.reduce(0, +) / Float(chromas.count)
        let p90 = chromas.sorted()[Int(Float(chromas.count - 1) * 0.9)]
        return (mean, p90)
    }

    func stop() {
        player?.pause()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player = nil
    }
}
