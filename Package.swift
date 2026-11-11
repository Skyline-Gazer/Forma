// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Forma",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FormaCore", targets: ["FormaCore"]),
        .executable(name: "Forma", targets: ["FormaApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(name: "FormaCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ]),
        .executableTarget(name: "FormaApp", dependencies: ["FormaCore"], path: "FormaApp"),
        .testTarget(name: "FormaCoreTests", dependencies: [
            "FormaCore",
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
