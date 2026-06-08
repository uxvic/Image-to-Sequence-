// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImageToSequence",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ImageToSequence",
            path: "Sources/ImageToSequence"
        )
    ]
)
