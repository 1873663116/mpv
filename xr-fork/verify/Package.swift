// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
let libmpvBuild = repoRoot.appendingPathComponent("build-libmpv").path

let package = Package(
    name: "RealityKitVerifyApp",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "RealityKitVerifyApp", targets: ["RealityKitVerifyApp"]),
    ],
    targets: [
        .systemLibrary(name: "CMpv", path: "Sources/CMpv"),
        .executableTarget(
            name: "RealityKitVerifyApp",
            dependencies: ["CMpv"],
            path: "Sources/RealityKitVerifyApp",
            linkerSettings: [
                .unsafeFlags([
                    "-L", libmpvBuild,
                    "-lmpv",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
                .linkedFramework("AppKit"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("RealityKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
