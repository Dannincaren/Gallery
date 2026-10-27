// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Gallery",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Gallery", targets: ["GalleryApp"])],
    targets: [
        .target(name: "GalleryCore"),
        .target(name: "GalleryNative", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("ApplicationServices")
        ]),
        .executableTarget(name: "GalleryApp", dependencies: ["GalleryCore", "GalleryNative"]),
        .executableTarget(name: "GalleryChecks", dependencies: ["GalleryCore"], path: "Tests/GalleryCoreTests")
    ]
)
