import CryptoKit
import Foundation

/// Builds the evidence the program is willing to stand behind.
///
/// The extractor reads a file; the registry turns what it read into addressable
/// records with stable identifiers, so a model can only ever cite something that
/// was actually observed. Identifiers are derived from the source, the snapshot
/// revision and the locator, which means re-reading an unchanged file reproduces
/// the same ids: a mapping stays citable after a rescan, and a changed file
/// produces different ids that no older citation can point at.
public enum EvidenceRegistry {
    /// Excerpts are stored locally and only a bounded prefix is ever sent out.
    public static let maximumExcerptCharacters = 2_000
    public static let maximumPromptExcerptCharacters = 400

    /// The identity of the source that produced a record, kept beside it so a
    /// later reader can tell which extractor version was authoritative.
    public static var extractorVersion: String { EvidenceExtraction.extractorVersion }

    public static func identifier(sourceID: UUID, snapshotRevision: Int, source: EvidenceSource,
                                  locator: EvidenceLocator?, relativePath: String?) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data("evidence.v1|\(sourceID.sourceKey)|\(snapshotRevision)|\(source.rawValue)".utf8))
        if let locator {
            // Sorted-key encoding keeps the digest stable across encoder changes.
            hasher.update(data: try FormaJSON.encode(locator))
        }
        if let relativePath { hasher.update(data: Data("|\(relativePath)".utf8)) }
        return "ev_" + String(hasher.finalize().hexadecimalDigest.prefix(20))
    }

    static func excerpt(_ value: String) -> String {
        value.count <= maximumExcerptCharacters ? value : String(value.prefix(maximumExcerptCharacters))
    }

    /// The excerpt a prompt may carry: shorter than the stored one, because the
    /// model only needs enough text to reason about, not the whole document.
    public static func promptExcerpt(_ record: EvidenceRecord) -> String? {
        guard let text = record.excerpt else { return nil }
        return String(text.prefix(maximumPromptExcerptCharacters))
    }

    /// All records for one file read.
    ///
    /// A failed read still produces one record: the fact that a file is
    /// encrypted, unreadable or a cloud placeholder is itself evidence, and the
    /// Exceptions view must be able to say why a field stayed unknown. It is
    /// never *usable* evidence, so it cannot support a value.
    public static func records(for entry: SourceEntry, capture: SourceEvidence,
                               createdAt: Date = .now) throws -> [EvidenceRecord] {
        var records: [EvidenceRecord] = []

        let name = (entry.relativePath as NSString).lastPathComponent
        records.append(try record(entry: entry, source: .filename, locator: nil,
                                  relativePath: entry.relativePath, excerpt: name,
                                  status: .ok, createdAt: createdAt))

        let directory = directory(of: entry.relativePath)
        if !directory.isEmpty {
            records.append(try record(entry: entry, source: .path, locator: nil,
                                      relativePath: entry.relativePath, excerpt: directory,
                                      status: .ok, createdAt: createdAt))
        }

        if capture.status == .ok || capture.status == .truncated {
            for item in capture.items {
                let text = contentExcerpt(item)
                guard !text.isEmpty else { continue }
                records.append(try record(entry: entry, source: .content, locator: item.locator,
                                          relativePath: nil, excerpt: text,
                                          status: capture.status, createdAt: createdAt))
            }
        } else {
            // One record describing the failure, so the reason is queryable.
            records.append(try record(entry: entry, source: .content, locator: nil,
                                      relativePath: entry.relativePath, excerpt: nil,
                                      status: capture.status, createdAt: createdAt))
        }

        if let size = entry.sizeBytes {
            records.append(try record(entry: entry, source: .fsMetadata, locator: nil,
                                      relativePath: entry.relativePath, excerpt: "size_bytes=\(size)",
                                      status: .ok, createdAt: createdAt))
        }
        return records
    }

    /// An inherited project field: the value came from another member of the
    /// same confirmed candidate, so the record names both the sibling and the
    /// membership that justifies the inheritance.
    public static func inheritance(sourceID: UUID, snapshotRevision: Int, snapshotFingerprint: String,
                                   value: String, siblingPath: String, candidateID: String,
                                   createdAt: Date = .now) throws -> EvidenceRecord {
        let id = try identifier(sourceID: sourceID, snapshotRevision: snapshotRevision, source: .sibling,
                                locator: nil, relativePath: siblingPath)
        return EvidenceRecord(
            id: id, sourceID: sourceID, snapshotRevision: snapshotRevision,
            snapshotFingerprint: snapshotFingerprint, source: .sibling, locator: nil,
            // The quote says where the value came from, so a reviewer can see
            // that this field was inherited rather than read from this file.
            relativePath: siblingPath, excerpt: excerpt("inherited from \(siblingPath): \(value)"),
            extractionStatus: .ok, extractorVersion: extractorVersion, createdAt: createdAt,
            contextCandidateID: candidateID
        )
    }

    /// A value obtained from an authorized read-only MCP query. The locator is
    /// the database and record identity plus the property that was read.
    public static func history(sourceID: UUID, snapshotRevision: Int, snapshotFingerprint: String,
                               databaseID: UUID, recordID: UUID, property: String, value: String,
                               queriedAt: Date, createdAt: Date = .now) throws -> EvidenceRecord {
        let locatorText = "database=\(databaseID.sourceKey);record=\(recordID.sourceKey);property=\(property)"
        let id = try identifier(sourceID: sourceID, snapshotRevision: snapshotRevision, source: .mcp,
                                locator: nil, relativePath: locatorText)
        return EvidenceRecord(
            id: id, sourceID: sourceID, snapshotRevision: snapshotRevision,
            snapshotFingerprint: snapshotFingerprint, source: .mcp, locator: nil,
            relativePath: locatorText, excerpt: excerpt(value), extractionStatus: .ok,
            extractorVersion: extractorVersion, createdAt: createdAt
        )
    }

    private static func record(entry: SourceEntry, source: EvidenceSource, locator: EvidenceLocator?,
                               relativePath: String?, excerpt text: String?, status: EvidenceStatus,
                               createdAt: Date) throws -> EvidenceRecord {
        let id = try identifier(sourceID: entry.id, snapshotRevision: Int(entry.snapshotRevision),
                                source: source, locator: locator, relativePath: relativePath)
        return EvidenceRecord(
            id: id, sourceID: entry.id, snapshotRevision: Int(entry.snapshotRevision),
            snapshotFingerprint: entry.snapshotFingerprint, source: source, locator: locator,
            relativePath: relativePath, excerpt: text.map { excerpt($0) }, extractionStatus: status,
            extractorVersion: extractorVersion, createdAt: createdAt
        )
    }

    private static func contentExcerpt(_ item: EvidenceItem) -> String {
        if let text = item.text, !text.isEmpty { return text }
        // A cell with a formula but no cached value is a fact about the sheet:
        // it must not be presented as an empty, and therefore "blank", quote.
        if let formula = item.formula {
            let cached = item.cachedValue.map { "cached=\($0)" } ?? "cached=none"
            return "formula=\(formula);\(cached)"
        }
        return ""
    }

    static func directory(of path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }
}
