// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Forma",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FormaCore", targets: ["FormaCore"]),
        // Opt-in benchmark entry point. Not built by `swift test`: the
        // benchmark workflow builds and runs it explicitly, so a slow hosted
        // runner can never turn a unit-test PR into a red build.
        .executable(name: "FormaBenchmark", targets: ["FormaBenchmark"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        // PLAN §3 requires a Draft 2020-12 JSON Schema implementation rather than
        // Codable decoding for artifact validation. Chosen over
        // `ajevans99/swift-json-schema`, which is otherwise suitable: its manifest
        // pulls swift-syntax, and with that in the graph the toolchain's
        // TestingMacros plugin stops resolving, so `swift test` cannot build here.
        // Verified by isolated probe packages: GRDB + ZIPFoundation + this package
        // compiles and runs swift-testing tests; the same with swift-json-schema
        // does not. It also adds no transitive dependency of its own.
        .package(url: "https://github.com/objecthub/swift-dynamicjson", exact: "2.0.1"),
    ],
    targets: [
        .target(name: "FormaCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            .product(name: "DynamicJSON", package: "swift-dynamicjson"),
        ], resources: [
            // Profiles, artifact schemas and the CasePack are data, not code:
            // they are versioned as JSON so a policy change is a reviewable diff.
            // An undeclared resource directory is not a build error: the bundle
            // simply lacks the file, and only the test that loads it notices.
            .process("Mapping/Profiles"),
            .process("Mapping/Schemas"),
            .process("Mapping/CasePack"),
            // The eligibility policy is data with its own version and digest;
            // a rule change is a reviewable JSON diff, never a code change.
            .process("Eligibility/Policies"),
        ]),
        .executableTarget(name: "FormaBenchmark", dependencies: ["FormaCore"]),
        .testTarget(name: "FormaCoreTests", dependencies: [
            "FormaCore",
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
