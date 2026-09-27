// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MicaVoice",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "mica-voice", targets: ["MicaVoice"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        .executableTarget(
            name: "MicaVoice",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
