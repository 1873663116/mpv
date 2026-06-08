import Foundation
import IOSurface
import Metal
import RealityKit

@MainActor
final class ResidentVideoSurface {
    static let width = 1280
    static let height = 720

    let iosurface: IOSurfaceRef
    let iosurfaceID: UInt32
    let metalTexture: any MTLTexture
    private let textureResource: TextureResource

    init() throws {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: Self.width,
            kIOSurfaceHeight: Self.height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: UInt32(0x52474241),
        ]

        guard let iosurface = IOSurfaceCreate(properties as CFDictionary) else {
            throw VerifyError("IOSurfaceCreate failed")
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw VerifyError("MTLCreateSystemDefaultDevice failed")
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
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
            throw VerifyError("MTLDevice.makeTexture(iosurface:) failed")
        }

        self.iosurface = iosurface
        self.iosurfaceID = IOSurfaceGetID(iosurface)
        self.metalTexture = metalTexture
        self.textureResource = TextureResource.__texture(from: metalTexture)
    }

    func makeTextureResource() -> TextureResource {
        textureResource
    }

    func samplePixelSum() -> UInt64 {
        IOSurfaceLock(iosurface, .readOnly, nil)
        defer {
            IOSurfaceUnlock(iosurface, .readOnly, nil)
        }

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
