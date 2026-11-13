import Foundation

public struct SourceScope: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let rootID: UUID
    /// Relative to the canonical source root. Empty for the root itself.
    public let relativePath: String
    public let displayName: String
}

public enum SourceScanState: String, Codable, Sendable {
    case notScanned, scanning, complete, incomplete, cancelled, interrupted
}

public struct SourceScanIssue: Sendable, Equatable {
    public enum Reason: String, Sendable {
        case authorization, unreadable, hydrationPending, unknownVolumeSemantics, pathCollision
    }

    public let relativePath: String
    public let reason: Reason
}

public struct SourceListing: Sendable, Equatable {
    public let scope: SourceScope
    public let scanID: UUID?
    public let state: SourceScanState
    public let entries: [SourceEntry]
    public let issues: [SourceScanIssue]
    public let statistics: SourceScanStatistics?
    public var isComplete: Bool { state == .complete }
}


public struct SourceScanStatistics: Sendable, Equatable, Codable {
    public let directoryCount: Int
    public let fileCount: Int
    public let sizeBytes: Int64
    public let extensions: [String: Int]
}

public enum SourceProvider: String, Sendable {
    case local, oneDrive, fileProvider, iCloud, unknown
}
public enum SourceEntryState: String, Sendable {
    case present, missing, symlink, held
}

public struct SourceEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let rootID: UUID
    public let relativePath: String
    public let normalizedRelativePath: String
    public let state: SourceEntryState
    public let hydrationPending: Bool
    public let sourceVersion: Int64
    public let snapshotRevision: Int64
    public let provider: SourceProvider
    public let snapshotFingerprint: String
    public let sizeBytes: Int64?
    public let modificationTimeNanoseconds: Int64?
    public let sha256: String?
}

public struct SourceEvidence: Sendable {
    public let entry: SourceEntry
    public let status: EvidenceStatus
    public let items: [EvidenceItem]
    /// Digest of the bytes supplied to the extractor in this call, when available.
    public let sha256: String?
}
