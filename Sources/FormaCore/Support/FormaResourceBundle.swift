import Foundation

/// Locates Forma's SwiftPM resource bundle.
///
/// SwiftPM's generated accessor (`Bundle.module`) looks in exactly two places:
///
/// 1. `Bundle.main.bundleURL/<bundle>.bundle` — inside a `.app` that is the bundle
///    **root**, which `codesign --strict` refuses ("unsealed contents present in
///    the bundle root");
/// 2. the `.build/.../<bundle>.bundle` path of the machine that compiled it.
///
/// Neither is right for a signed app: the first breaks sealing, the second does not
/// exist on a user's machine and kills the process with a `fatalError`. So the
/// app never calls `Bundle.module`; it resolves the bundle itself, preferring the
/// standard `Contents/Resources` location, and every loader turns a missing bundle
/// into `FormaError.unavailable` instead of a crash.
///
/// The `.build` fallback is deliberately absent: a release build must not depend
/// on the machine that produced it.
enum FormaResourceBundle {
    /// The SwiftPM resource bundle name for the `FormaCore` target.
    static let bundleName = "Forma_FormaCore"

    /// Resolved once; `nil` means the installation is incomplete, which is a
    /// reportable error for every loader, not a reason to abort the process.
    static let bundle: Bundle? = resolve()

    static func url(forResource name: String, withExtension extensionName: String) -> URL? {
        bundle?.url(forResource: name, withExtension: extensionName)
    }

    /// The directories searched, in order. Exposed so a diagnostic can say which
    /// places were checked instead of "resources are missing".
    static var searchDirectories: [URL] {
        var directories: [URL] = []
        if let resources = Bundle.main.resourceURL { directories.append(resources) }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            directories.append(executable)
        }
        // Legacy layout some development runs produce. Kept last: signing an app
        // with this layout fails, so it is never the intended location.
        directories.append(Bundle.main.bundleURL)
        if let frameworkResources = Bundle(for: BundleToken.self).resourceURL {
            directories.append(frameworkResources)
        }
        directories.append(Bundle(for: BundleToken.self).bundleURL)
        return directories
    }

    static func resolve() -> Bundle? {
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent("\(bundleName).bundle")
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let bundle = Bundle(url: candidate) else { continue }
            return bundle
        }
        return nil
    }
}

private final class BundleToken {}
