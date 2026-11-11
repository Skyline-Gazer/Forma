// swift-tools-version: 6.0
import PackageDescription

// The GUI is its own Swift package so `swift test` at the repository root
// builds FormaCore only. SwiftUI code generation needs the macro plugins that
// ship with a full Xcode toolchain: a Command Line Tools-only machine can run
// the core test suite but cannot compile this target.
let package = Package(
    name: "FormaApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Forma", targets: ["Forma"]),
    ],
    dependencies: [
        // A path dependency otherwise derives its identity from the checkout
        // directory name, so the registration name is pinned explicitly: the
        // same manifest must resolve in CI (`.../Forma`) and any local copy.
        .package(name: "Forma", path: "../"),
    ],
    targets: [
        .executableTarget(
            name: "Forma",
            dependencies: [
                .product(name: "FormaCore", package: "Forma"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
