// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FolkiDuoCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FolkiDuoCore", targets: ["FolkiDuoCore"]),
        .library(name: "FolkiDuoPersistence", targets: ["FolkiDuoPersistence"])
    ],
    targets: [
        .target(name: "FolkiDuoCore"),
        .target(name: "FolkiDuoPersistence", dependencies: ["FolkiDuoCore"], resources: [.process("Resources")]),
        .testTarget(name: "FolkiDuoCoreTests", dependencies: ["FolkiDuoCore"]),
        .testTarget(name: "FolkiDuoPersistenceTests", dependencies: ["FolkiDuoPersistence"])
    ]
)
