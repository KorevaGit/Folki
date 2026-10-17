// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FolkiDuoCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FolkiDuoCore", targets: ["FolkiDuoCore"])],
    targets: [
        .target(name: "FolkiDuoCore"),
        .testTarget(name: "FolkiDuoCoreTests", dependencies: ["FolkiDuoCore"])
    ]
)
