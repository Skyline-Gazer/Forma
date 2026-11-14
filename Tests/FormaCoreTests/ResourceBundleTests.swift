import Foundation
import Testing
@testable import FormaCore

/// The resource bundle, resolved the way the app resolves it.
///
/// The Batch 2A field run showed the difference between "the resource bundle was
/// built" and "the app can find it": `swift test` passes because the bundle sits
/// next to the test executable, while the `.app` crashed because SwiftPM's
/// accessor only looked in the sealed root. These tests pin the resolver and the
/// shipped loaders, so a layout change fails here before it fails on a Mac.
@Suite("Resource bundle resolution")
struct ResourceBundleTests {
    private let requiredFiles = [
        "project-archive.v1.json",
        "vendor-library.v1.json",
        "forma-governance-cases.v1.json",
        "forma-eligibility.v1.json",
        "manifest-1.0.schema.json",
        "proposal-1.0.schema.json",
    ]

    @Test func theBundleIsFoundWithoutSwiftPMsAccessor() {
        let bundle = FormaResourceBundle.bundle
        #expect(bundle != nil, "searched: \(FormaResourceBundle.searchDirectories.map(\.path))")
        #expect(bundle?.bundleURL.lastPathComponent == "Forma_FormaCore.bundle")
    }

    @Test func everyShippedResourceIsResolvable() {
        for file in requiredFiles {
            let name = (file as NSString).deletingPathExtension
            let ext = (file as NSString).pathExtension
            #expect(FormaResourceBundle.url(forResource: name, withExtension: ext) != nil, "\(file)")
        }
        #expect(FormaResourceBundle.url(forResource: "does-not-exist", withExtension: "json") == nil)
    }

    @Test func theShippedLoadersOpenTheirResources() throws {
        #expect(try MappingProfile.projectArchive().profileID == "project-archive")
        #expect(try MappingProfile.vendorLibrary().profileID == "vendor-library")
        _ = try CasePack.shipped()
        _ = try EligibilityPolicy.shipped()
    }

    @Test func anAppWithoutTheResourceBundleIsReportedIncomplete() {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let result = ShippedResourceProbe.probe(appURL: app)
        #expect(result.bundlePath == nil)
        #expect(result.isComplete == false)
        #expect(result.missing.count == ShippedResourceProbe.requiredFiles.count)
    }

    @Test func anAppWithTheBuiltBundleCanOpenEveryResource() throws {
        let source = try #require(FormaResourceBundle.bundle?.bundleURL)
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = ShippedResourceProbe.resourceBundleURL(in: app)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        defer { try? FileManager.default.removeItem(at: app) }

        let result = ShippedResourceProbe.probe(appURL: app)
        #expect(result.isComplete,
                "missing=\(result.missing) unreadable=\(result.unreadable)")
    }
}
