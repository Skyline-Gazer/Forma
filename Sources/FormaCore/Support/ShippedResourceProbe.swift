import Foundation

/// Checks that an assembled `.app` can actually load the resources it ships.
///
/// The Batch 2A field run proved that "the bundle is in the app" and "the app can
/// read it" are different claims: the signed bundle contained files the runtime
/// never found. This probe answers the second question on the artifact itself —
/// it resolves the resource bundle at the same path the app uses, opens every
/// required file, and decodes it as JSON.
public enum ShippedResourceProbe {
    public struct Result: Sendable, Equatable {
        public let bundlePath: String?
        public let missing: [String]
        public let unreadable: [String]

        public var isComplete: Bool {
            bundlePath != nil && missing.isEmpty && unreadable.isEmpty
        }
    }

    /// Files every installation must be able to open.
    public static let requiredFiles = [
        "project-archive.v1.json",
        "vendor-library.v1.json",
        "forma-governance-cases.v1.json",
        "forma-eligibility.v1.json",
        "manifest-1.0.schema.json",
        "proposal-1.0.schema.json",
    ]

    /// Where the app looks first: `Contents/Resources/Forma_FormaCore.bundle`.
    public static func resourceBundleURL(in appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/Resources/Forma_FormaCore.bundle")
    }

    public static func probe(appURL: URL) -> Result {
        let bundleURL = resourceBundleURL(in: appURL)
        guard FileManager.default.fileExists(atPath: bundleURL.path),
              let bundle = Bundle(url: bundleURL) else {
            return Result(bundlePath: nil, missing: requiredFiles, unreadable: [])
        }

        var missing: [String] = []
        var unreadable: [String] = []
        for file in requiredFiles {
            let name = (file as NSString).deletingPathExtension
            let extensionName = (file as NSString).pathExtension
            guard let url = bundle.url(forResource: name, withExtension: extensionName) else {
                missing.append(file)
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                unreadable.append(file)
                continue
            }
        }
        return Result(bundlePath: bundleURL.path, missing: missing, unreadable: unreadable)
    }
}
