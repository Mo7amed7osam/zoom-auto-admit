// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZoomAutoAdmit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ZoomAutoAdmitCore", targets: ["ZoomAutoAdmitCore"]),
        .executable(name: "ZoomAutoAdmitApp", targets: ["ZoomAutoAdmitApp"]),
        .executable(name: "inspect-zoom", targets: ["InspectZoom"]),
        .executable(name: "auto-admit", targets: ["AutoAdmit"])
    ],
    targets: [
        .target(name: "ZoomAXSupport"),
        .target(name: "ZoomAutoAdmitCore", dependencies: ["ZoomAXSupport"]),
        .executableTarget(name: "ZoomAutoAdmitApp", dependencies: ["ZoomAutoAdmitCore", "ZoomAXSupport"]),
        .executableTarget(name: "InspectZoom", dependencies: ["ZoomAXSupport"]),
        .executableTarget(name: "AutoAdmit", dependencies: ["ZoomAXSupport"]),
        .testTarget(name: "ZoomAXSupportTests", dependencies: ["ZoomAXSupport"]),
        .testTarget(name: "ZoomAutoAdmitCoreTests", dependencies: ["ZoomAutoAdmitCore"]),
        .testTarget(
            name: "ZoomAutoAdmitAppTests",
            dependencies: ["ZoomAutoAdmitApp", "ZoomAutoAdmitCore"]
        )
    ]
)
