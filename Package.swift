// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TimeFlowStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TimeFlow", targets: ["TimeFlowApp"])
    ],
    targets: [
        .executableTarget(
            name: "TimeFlowApp",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO")
            ]
        ),
        .testTarget(
            name: "TimeFlowCoreTests",
            dependencies: ["TimeFlowApp"]
        )
    ],
    swiftLanguageModes: [.v5]
)
