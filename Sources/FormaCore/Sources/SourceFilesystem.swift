import CryptoKit
import Darwin
import Foundation

struct SourceFileMetadata: Sendable, Equatable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let linkCount: UInt16
    let birthNanoseconds: Int64
    let modifiedNanoseconds: Int64
    let changedNanoseconds: Int64
    let sizeBytes: Int64
    let isHydrationPending: Bool

    var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    var isRegular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    var fileType: Int64 { Int64(mode & UInt16(S_IFMT)) }
    var isSymlink: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFLNK) }
    var objectKey: String { "\(device):\(inode):\(birthNanoseconds)" }

    init(_ value: stat, ubiquitousPending: Bool = false) {
        device = value.st_dev
        inode = value.st_ino
        mode = value.st_mode
        linkCount = value.st_nlink
        birthNanoseconds = Self.nanoseconds(value.st_birthtimespec)
        modifiedNanoseconds = Self.nanoseconds(value.st_mtimespec)
        changedNanoseconds = Self.nanoseconds(value.st_ctimespec)
        sizeBytes = value.st_size
        isHydrationPending = ubiquitousPending || (value.st_flags & UInt32(SF_DATALESS)) != 0
    }

    static func read(_ url: URL) throws -> Self {
        var value = stat()
        guard try url.withUnsafeFileSystemRepresentation({ path in
            guard let path else { throw FormaError.invalidSource }
            return lstat(path, &value)
        }) == 0 else { throw sourcePOSIXError() }
        let metadata = Self(value)
        guard !metadata.isSymlink else { return metadata }
        let ubiquitous = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ])
        return Self(value, ubiquitousPending: ubiquitous?.isUbiquitousItem == true
            && ubiquitous?.ubiquitousItemDownloadingStatus == .notDownloaded)
    }

    static func read(descriptor: Int32) throws -> Self {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw sourcePOSIXError() }
        return Self(value)
    }

    static func read(in directory: Int32, name: String) throws -> Self {
        var value = stat()
        guard fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw sourcePOSIXError() }
        return Self(value)
    }

    private static func nanoseconds(_ value: timespec) -> Int64 {
        // Avoid trapping on an out-of-range filesystem timestamp.
        let (seconds, overflow) = Int64(value.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return value.tv_sec < 0 ? .min : .max }
        let (result, additionOverflow) = seconds.addingReportingOverflow(Int64(value.tv_nsec))
        return additionOverflow ? .max : result
    }
}

func sourcePOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

enum SourcePath {
    static func normalize(_ path: String, caseSensitive: Bool) throws -> String {
        guard !path.hasPrefix("/"), !path.utf8.contains(0) else { throw FormaError.invalidSource }
        var components: [String] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { throw FormaError.invalidSource }
                components.removeLast()
            default:
                let nfc = String(component).precomposedStringWithCanonicalMapping
                let normalized = caseSensitive ? nfc : nfc.folding(
                    options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")
                ).precomposedStringWithCanonicalMapping
                components.append(normalized)
            }
        }
        return components.joined(separator: "/")
    }

    static func join(_ prefix: String, _ path: String) -> String {
        prefix.isEmpty ? path : (path.isEmpty ? prefix : "\(prefix)/\(path)")
    }

    static func contains(_ path: String, in prefix: String) -> Bool {
        prefix.isEmpty || path == prefix || path.hasPrefix(prefix + "/")
    }

    static func sameSpelling(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    static func url(_ root: URL, appending path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: false)
    }

    static func provider(_ url: URL, hydrationPending: Bool) -> SourceProvider {
        let components = url.pathComponents
        if let cloud = components.firstIndex(of: "CloudStorage"), cloud + 1 < components.count {
            let domain = components[cloud + 1].lowercased()
            return domain == "onedrive" || domain.hasPrefix("onedrive-") ? .oneDrive : .fileProvider
        }
        if components.contains("Mobile Documents") { return .iCloud }
        return hydrationPending ? .unknown : .local
    }

    static func relative(_ child: URL, to ancestor: URL) -> String? {
        let parent = ancestor.pathComponents
        let path = child.pathComponents
        guard path.count >= parent.count,
              zip(parent, path).allSatisfy({ sameSpelling($0.0, $0.1) }) else { return nil }
        return path.dropFirst(parent.count).joined(separator: "/")
    }
}

struct SourceRootAccess: Sendable {
    let url: URL
    let metadata: SourceFileMetadata
    let volumeID: String?
    let caseSensitive: Bool?
    let supportsStableIdentity: Bool
    let isCloud: Bool

    var rootIdentity: String {
        if let volumeID { return "\(volumeID):\(metadata.inode):\(metadata.birthNanoseconds)" }
        return metadata.objectKey
    }

    init(_ input: URL) throws {
        guard input.isFileURL else { throw FormaError.invalidSource }
        url = input.standardizedFileURL.resolvingSymlinksInPath()
        metadata = try SourceFileMetadata.read(url)
        guard metadata.isDirectory else { throw FormaError.invalidSource }
        let volume = try? url.resourceValues(forKeys: [
            .volumeUUIDStringKey, .volumeSupportsCaseSensitiveNamesKey, .volumeIsLocalKey
        ])
        volumeID = volume?.volumeUUIDString
        caseSensitive = volume?.volumeSupportsCaseSensitiveNames
        isCloud = url.pathComponents.contains("CloudStorage") || url.pathComponents.contains("Mobile Documents")
            || (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
        var fs = statfs()
        let fileSystem = url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path, statfs(path, &fs) == 0 else { return nil }
            return withUnsafeBytes(of: fs.f_fstypename) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
        supportsStableIdentity = !isCloud && volume?.volumeIsLocal == true
            && volumeID != nil && (fileSystem == "apfs" || fileSystem == "hfs")
    }

    func stableIdentity(for metadata: SourceFileMetadata, at url: URL) -> String? {
        guard supportsStableIdentity, let volumeID, metadata.isRegular, metadata.linkCount == 1,
              metadata.birthNanoseconds > 0, !metadata.isHydrationPending,
              !url.pathComponents.contains("CloudStorage"), !url.pathComponents.contains("Mobile Documents"),
              let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .isUbiquitousItemKey]),
              values.isUbiquitousItem != true else { return nil }
        // Require a filesystem resource identifier, the volume and creation time. Inode alone
        // can be reused, and a provider identifier is not assumed stable through rehydration.
        let identifier: String
        switch values.fileResourceIdentifier {
        case let value as Data: identifier = "data:" + value.base64EncodedString()
        case let value as NSNumber: identifier = "number:" + value.stringValue
        case let value as String: identifier = "string:" + value
        default: return nil
        }
        return "\(volumeID):\(metadata.birthNanoseconds):\(identifier)"
    }

    func openDirectory(_ relative: String) throws -> Int32 {
        var descriptor = try url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { throw FormaError.invalidSource }
            let result = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard result >= 0 else { throw sourcePOSIXError() }
            return result
        }
        do {
            let actual = try SourceFileMetadata.read(descriptor: descriptor)
            guard actual.objectKey == metadata.objectKey else { throw FormaError.sourceChanged }
            for component in relative.split(separator: "/") {
                guard component != ".", component != ".." else { throw FormaError.invalidSource }
                let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw sourcePOSIXError() }
                close(descriptor)
                descriptor = next
                guard try SourceFileMetadata.read(descriptor: descriptor).device == metadata.device else {
                    throw FormaError.invalidSource
                }
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }
}

struct SourceScanRecord: Sendable {
    let relativePath: String
    let normalizedPath: String
    let metadata: SourceFileMetadata
    let provider: SourceProvider
    let stableIdentity: String?

    var state: SourceEntryState {
        if metadata.isRegular { return .present }
        return metadata.isSymlink ? .symlink : .held
    }
}

struct SourceScanResult: Sendable {
    var records: [SourceScanRecord] = []
    var directories: [String] = []
    var issues: [SourceScanIssue] = []
    var collisionPaths: Set<String> = []
}

enum SourceFileScanner {
    static func collect(root: SourceRootAccess, path: String) throws -> SourceScanResult {
        guard let caseSensitive = root.caseSensitive else {
            return SourceScanResult(issues: [.init(relativePath: path, reason: .unknownVolumeSemantics)])
        }
        var result = SourceScanResult()
        var spellings: [String: String] = [:]
        let directory = try root.openDirectory(path)
        let initialDirectory = try? SourceFileMetadata.read(descriptor: directory)
        try walk(directory, at: path, root: root, caseSensitive: caseSensitive, result: &result, spellings: &spellings)
        do {
            let reopened = try root.openDirectory(path)
            defer { close(reopened) }
            let current = try SourceFileMetadata.read(descriptor: reopened)
            if current.objectKey != initialDirectory?.objectKey {
                result.issues.append(.init(relativePath: path, reason: .unreadable))
            }
        } catch {
            result.issues.append(.init(relativePath: path, reason: .unreadable))
        }
        return result
    }

    // Owns the descriptor, including when fdopendir fails.
    private static func walk(
        _ descriptor: Int32, at path: String, root: SourceRootAccess, caseSensitive: Bool,
        result: inout SourceScanResult, spellings: inout [String: String]
    ) throws {
        guard let directory = fdopendir(descriptor) else {
            close(descriptor)
            result.issues.append(.init(relativePath: path, reason: .unreadable))
            return
        }
        defer { closedir(directory) }
        let before = try? SourceFileMetadata.read(descriptor: descriptor)
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                let readError = errno
                let after = try? SourceFileMetadata.read(descriptor: descriptor)
                if before == nil || after?.objectKey != before?.objectKey
                    || after?.modifiedNanoseconds != before?.modifiedNanoseconds
                    || after?.changedNanoseconds != before?.changedNanoseconds {
                    result.issues.append(.init(relativePath: path, reason: .unreadable))
                }
                if readError != 0 { result.issues.append(.init(relativePath: path, reason: .unreadable)) }
                return
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(bytes: bytes.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
            }
            guard let name else {
                result.issues.append(.init(relativePath: path, reason: .unreadable))
                continue
            }
            if name == "." || name == ".." { continue }
            let relative = SourcePath.join(path, name)
            let normalized = try SourcePath.normalize(relative, caseSensitive: caseSensitive)
            if let previous = spellings.updateValue(relative, forKey: normalized),
               !SourcePath.sameSpelling(previous, relative) {
                result.collisionPaths.insert(normalized)
                result.issues.append(.init(relativePath: previous, reason: .pathCollision))
                result.issues.append(.init(relativePath: relative, reason: .pathCollision))
                continue
            }
            do {
                var metadata = try SourceFileMetadata.read(in: descriptor, name: name)
                let url = SourcePath.url(root.url, appending: relative)
                if !metadata.isSymlink, let cloudMetadata = try? SourceFileMetadata.read(url),
                   cloudMetadata.objectKey == metadata.objectKey {
                    metadata = cloudMetadata
                }
                if metadata.isDirectory {
                    guard metadata.device == root.metadata.device, !metadata.isHydrationPending else {
                        result.issues.append(.init(relativePath: relative, reason: metadata.isHydrationPending
                            ? .hydrationPending : .unreadable))
                        continue
                    }
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw sourcePOSIXError() }
                    guard let actual = try? SourceFileMetadata.read(descriptor: child),
                          actual.objectKey == metadata.objectKey else {
                        close(child)
                        throw FormaError.sourceChanged
                    }
                    result.directories.append(normalized)
                    try walk(child, at: relative, root: root, caseSensitive: caseSensitive,
                             result: &result, spellings: &spellings)
                } else {
                    result.records.append(.init(relativePath: relative, normalizedPath: normalized, metadata: metadata,
                                                provider: SourcePath.provider(url, hydrationPending: metadata.isHydrationPending),
                                                stableIdentity: root.stableIdentity(for: metadata, at: url)))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.issues.append(.init(relativePath: relative, reason: .unreadable))
            }
        }
    }
}

func sourceHex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}
