import Foundation
import IOSurface
import Metal
import RealityKit

/// 门① 双缓冲:持有 2 张 IOSurface(写/读环)。mpv 在两张间交替写后台缓冲、
/// 写完发布为 front;本类按 mpv 发布的 front IOSurfaceID 取对应 TextureResource 给 RealityKit。
@MainActor
final class ResidentVideoSurface {
    static let width = 1280
    static let height = 720
    static let bufferCount = 2

    struct Buffer {
        let iosurface: IOSurfaceRef
        let id: UInt32
        let metalTexture: any MTLTexture
        let textureResource: TextureResource
    }

    let buffers: [Buffer]

    var iosurfaceIDs: [UInt32] { buffers.map(\.id) }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw VerifyError("MTLCreateSystemDefaultDevice failed")
        }

        var made: [Buffer] = []
        for index in 0..<Self.bufferCount {
            let properties: [CFString: Any] = [
                kIOSurfaceWidth: Self.width,
                kIOSurfaceHeight: Self.height,
                kIOSurfaceBytesPerElement: 4,
                kIOSurfacePixelFormat: UInt32(0x52474241),
            ]
            guard let iosurface = IOSurfaceCreate(properties as CFDictionary) else {
                throw VerifyError("IOSurfaceCreate[\(index)] failed")
            }

            // _srgb 视图:mpv 写入的字节是 sRGB 非线性编码(出口契约,ADR 0004),
            // RealityKit 在线性空间采样,必须由像素格式后缀声明解码;
            // 同一 IOSurface 上 mpv 侧的渲染视图仍是 .rgba8Unorm,字节互不影响。
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb,
                width: Self.width,
                height: Self.height,
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

    /// RealityKit 初始挂载用的默认纹理(第 0 张)。
    func initialTextureResource() -> TextureResource {
        buffers[0].textureResource
    }

    func samplePixelSum(forID id: UInt32) -> UInt64 {
        guard let buffer = buffer(forID: id) else { return 0 }
        let iosurface = buffer.iosurface
        IOSurfaceLock(iosurface, .readOnly, nil)
        defer { IOSurfaceUnlock(iosurface, .readOnly, nil) }

        let base = IOSurfaceGetBaseAddress(iosurface)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = IOSurfaceGetBytesPerRow(iosurface)
        var sum: UInt64 = 0
        for y in stride(from: 0, to: Self.height, by: 16) {
            for x in stride(from: 0, to: Self.width, by: 16) {
                let offset = y * bytesPerRow + x * 4
                sum += UInt64(bytes[offset])
                sum += UInt64(bytes[offset + 1])
                sum += UInt64(bytes[offset + 2])
            }
        }
        return sum
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
