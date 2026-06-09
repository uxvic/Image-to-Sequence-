// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FrameGrab",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "FrameGrab",
            path: "Sources/FrameGrab"
        )
    ]
)
