// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchHide",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NotchHide", targets: ["NotchHide"])],
    targets: [
        .executableTarget(name: "NotchHide")
    ]
)
