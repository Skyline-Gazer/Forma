import CryptoKit
import Darwin
import Foundation

struct SourceEvidenceCapture: Sendable {
    let status: EvidenceStatus
    var items: [EvidenceItem] = []
    var sha256: String?
    var metadata: SourceFileMetadata?
    var stableIdentity: String?
}

enum SourceEvidenceReader {
    static func capture(_ stored: StoredSourceEntry, root: StoredSourceRoot, extracting: Bool) throws -> SourceEvidenceCapture {
        try Task.checkCancellation()
        let fileExtension = (stored.entry.relativePath as NSString).pathExtension.lowercased()
        if extracting && !["pdf", "docx", "xlsx"].contains(fileExtension) { return .init(status: .unavailable) }
        do {
            return try root.withAccess { access in
                try coordinatedCapture(stored, root: access, extracting: extracting)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as POSIXError {
            return .init(status: status(for: error, cloud: stored.entry.provider != .local))
        } catch {
            return .init(status: .unavailable)
        }
    }

    private static func coordinatedCapture(_ stored: StoredSourceEntry, root: SourceRootAccess,
                                           extracting: Bool) throws -> SourceEvidenceCapture {
        let relative = stored.entry.relativePath
        let path = relative as NSString
        let name = path.lastPathComponent
        let parentPath = path.deletingLastPathComponent
        let directory: Int32
        do { directory = try root.openDirectory(parentPath) } catch {
            return .init(status: (error as? POSIXError).map { status(for: $0, cloud: root.isCloud) } ?? .changedDuringRead)
        }
        defer { close(directory) }
        let url = SourcePath.url(root.url, appending: relative)
        let initial: SourceFileMetadata
        do { initial = try SourceFileMetadata.read(in: directory, name: name) } catch let error as POSIXError {
            return .init(status: status(for: error, cloud: root.isCloud))
        }
        guard initial.isRegular else { return .init(status: .changedDuringRead) }
        if initial.isHydrationPending { return .init(status: .hydrationPending, metadata: initial) }
        let metadata = try SourceFileMetadata.read(url)
        guard metadata.objectKey == initial.objectKey else { return .init(status: .changedDuringRead) }
        if metadata.isHydrationPending { return .init(status: .hydrationPending, metadata: metadata) }
        var coordinationError: NSError?
        var result: Result<SourceEvidenceCapture, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { actual in
            result = Result {
                try Task.checkCancellation()
                guard SourcePath.sameSpelling(actual.standardizedFileURL.path, url.standardizedFileURL.path) else {
                    return .init(status: .changedDuringRead)
                }
                do {
                    return try extract(stored, root: root, url: url, directory: directory,
                                       parentPath: parentPath, name: name, fileExtension: path.pathExtension, extracting: extracting)
                } catch let error as POSIXError {
                    if let after = try? SourceFileMetadata.read(in: directory, name: name), after.isHydrationPending {
                        return .init(status: .hydrationPending, metadata: after)
                    }
                    return .init(status: status(for: error, cloud: root.isCloud || initial.isHydrationPending))
                }
            }
        }
        try Task.checkCancellation()
        if let coordinationError {
            let underlying = coordinationError.userInfo[NSUnderlyingErrorKey] as? NSError ?? coordinationError
            if underlying.domain == NSPOSIXErrorDomain, let code = POSIXErrorCode(rawValue: Int32(underlying.code)) {
                return .init(status: status(for: POSIXError(code), cloud: root.isCloud || initial.isHydrationPending))
            }
            return .init(status: initial.isHydrationPending || root.isCloud ? .hydrationPending : .unavailable)
        }
        return try result?.get() ?? .init(status: .unavailable)
    }

    private static func extract(_ stored: StoredSourceEntry, root: SourceRootAccess, url: URL, directory: Int32,
                                parentPath: String, name: String, fileExtension: String,
                                extracting: Bool) throws -> SourceEvidenceCapture {
        let pathMetadata = try SourceFileMetadata.read(in: directory, name: name)
        let before = try SourceFileMetadata.read(url)
        guard before.objectKey == pathMetadata.objectKey, before.isRegular else {
            return .init(status: .changedDuringRead)
        }
        if before.isHydrationPending { return .init(status: .hydrationPending, metadata: before) }
        let identity = root.stableIdentity(for: before, at: url)
        guard stored.matches(before, stableIdentity: identity),
              stored.entry.hydrationPending || stored.changeNanoseconds == before.changedNanoseconds else {
            return .init(status: .changedDuringRead, metadata: before, stableIdentity: identity)
        }
        guard before.sizeBytes >= 0, !extracting || before.sizeBytes <= EvidenceExtractor.maximumInputBytes else {
            return .init(status: .truncated, metadata: before, stableIdentity: identity)
        }
        let input = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw sourcePOSIXError() }
        defer { close(input) }
        guard try SourceFileMetadata.read(descriptor: input) == before else {
            return .init(status: .changedDuringRead)
        }
        let temporaryDirectory: URL?
        if extracting {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forma-\(UUID().sourceKey)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            temporaryDirectory = directory
        } else {
            temporaryDirectory = nil
        }
        defer { if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }
        let copy = temporaryDirectory?.appendingPathComponent("input")
        guard let digest = try copyAndHash(input: input, expectedSize: before.sizeBytes, to: copy) else {
            return .init(status: .changedDuringRead)
        }
        guard try SourceFileMetadata.read(descriptor: input) == before else {
            return .init(status: .changedDuringRead)
        }
        // Reopen from the authorized root in case the directory was swapped during the read.
        // A failed reopen or name lookup here means the source moved while we were reading it,
        // which must not be downgraded to a generic "unavailable" document.
        let currentDirectory: Int32
        do { currentDirectory = try root.openDirectory(parentPath) }
        catch { return .init(status: .changedDuringRead) }
        defer { close(currentDirectory) }
        let after: SourceFileMetadata
        do { after = try SourceFileMetadata.read(in: currentDirectory, name: name) }
        catch { return .init(status: .changedDuringRead) }
        guard after == before else { return .init(status: .changedDuringRead) }
        try Task.checkCancellation()
        guard let copy else { return .init(status: .ok, sha256: digest, metadata: before, stableIdentity: identity) }
        let extraction = try EvidenceExtractor.extract(file: copy, fileExtension: fileExtension)
        guard extraction.status != .changedDuringRead else { return .init(status: .changedDuringRead) }
        return .init(status: extraction.status, items: extraction.items, sha256: digest, metadata: before, stableIdentity: identity)
    }

    /// Returns nil if EOF is reached at a different byte count from the pre-read stat.
    private static func copyAndHash(input: Int32, expectedSize: Int64, to copy: URL?) throws -> String? {
        let output: Int32
        if let copy {
            output = copy.withUnsafeFileSystemRepresentation { path in
                path.map { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) } ?? -1
            }
            guard output >= 0 else { throw sourcePOSIXError() }
        } else {
            output = -1
        }
        var outputOpen = output >= 0
        defer { if outputOpen { close(output) } }
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var sha = SHA256()
        var copied: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw sourcePOSIXError()
            }
            if count == 0 { break }
            copied += Int64(count)
            guard copied <= expectedSize else { return nil }
            try buffer.withUnsafeBytes { bytes in
                let chunk = UnsafeRawBufferPointer(rebasing: bytes.prefix(count))
                sha.update(bufferPointer: chunk)
                guard output >= 0 else { return }
                var written = 0
                while written < count {
                    let result = Darwin.write(output, chunk.baseAddress?.advanced(by: written), count - written)
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else { throw sourcePOSIXError() }
                    written += result
                }
            }
        }
        outputOpen = false
        if output >= 0, close(output) != 0 { throw sourcePOSIXError() }
        guard copied == expectedSize else { return nil }
        return sourceHex(sha.finalize())
    }

    private static func status(for error: POSIXError, cloud: Bool) -> EvidenceStatus {
        switch error.code {
        case .ENOENT, .ENOTDIR, .ELOOP: return .changedDuringRead
        case .ETIMEDOUT, .ENODATA, .ENETDOWN, .ENOTCONN: return .hydrationPending
        case .EPERM, .EACCES, .EIO: return cloud ? .hydrationPending : .unavailable
        default: return .unavailable
        }
    }
}
