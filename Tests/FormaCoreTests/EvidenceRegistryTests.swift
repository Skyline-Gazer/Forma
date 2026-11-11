import Foundation
import Testing

@testable import FormaCore

/// The registry is the only place evidence identities are minted, so its
/// stability and its refusal to invent readable content are the properties the
/// validator's "does this citation exist" checks rest on.
@Suite("Evidence registry")
struct EvidenceRegistryTests {
    private let rootID = UUID(uuidString: "00000000-0000-4000-8000-000000000020")!

    private func entry(_ path: String, revision: Int64 = 3, fingerprint: String = "f3",
                       size: Int64? = 1_024) -> SourceEntry {
        SourceEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000021")!, rootID: rootID,
            relativePath: path, normalizedRelativePath: path.lowercased(), state: .present,
            hydrationPending: false, sourceVersion: 1, snapshotRevision: revision, provider: .local,
            snapshotFingerprint: fingerprint, sizeBytes: size, modificationTimeNanoseconds: 0, sha256: nil
        )
    }

    @Test("identifiers are reproducible for the same read and change with the snapshot")
    func identifiersAreStable() throws {
        let file = entry("示例项目/公告.pdf")
        let locator = EvidenceLocator.pdf(page: 1, characterRange: 0..<10)
        let first = try EvidenceRegistry.identifier(sourceID: file.id, snapshotRevision: 3, source: .content,
                                                    locator: locator, relativePath: nil)
        let again = try EvidenceRegistry.identifier(sourceID: file.id, snapshotRevision: 3, source: .content,
                                                    locator: locator, relativePath: nil)
        #expect(first == again)
        let newer = try EvidenceRegistry.identifier(sourceID: file.id, snapshotRevision: 4, source: .content,
                                                    locator: locator, relativePath: nil)
        #expect(first != newer, "an older citation must not resolve against a new snapshot")
        let otherPage = try EvidenceRegistry.identifier(sourceID: file.id, snapshotRevision: 3, source: .content,
                                                        locator: .pdf(page: 2, characterRange: 0..<10),
                                                        relativePath: nil)
        #expect(first != otherPage)
        #expect(first.hasPrefix("ev_"))
    }

    @Test("a successful read yields filename, path, content and size evidence")
    func successfulRead() throws {
        let file = entry("示例项目/招标/公告.pdf")
        let items = [
            EvidenceItem(locator: .pdf(page: 1, characterRange: 0..<6), text: "采购公告"),
            EvidenceItem(locator: .pdf(page: 2, characterRange: 0..<4), text: "项目编号"),
        ]
        let capture = SourceEvidence(entry: file, status: .ok, items: items, sha256: nil)
        let records = try EvidenceRegistry.records(for: file, capture: capture)
        let sources = records.map(\.source)
        #expect(Set(sources).contains(.filename))
        #expect(Set(sources).contains(.path))
        #expect(Set(sources).contains(.fsMetadata))
        #expect(records.filter { $0.source == .content }.count == 2)
        let filename = try #require(records.first { $0.source == .filename })
        #expect(filename.excerpt == "公告.pdf")
        let path = try #require(records.first { $0.source == .path })
        #expect(path.excerpt == "示例项目/招标")
        #expect(records.allSatisfy { $0.snapshotRevision == 3 && $0.snapshotFingerprint == "f3" })
        #expect(records.allSatisfy { $0.isUsable })
    }

    @Test("an unreadable file produces a record that can never support a value")
    func failedRead() throws {
        let file = entry("示例项目/加密.pdf")
        let capture = SourceEvidence(entry: file, status: .encrypted, items: [], sha256: nil)
        let records = try EvidenceRegistry.records(for: file, capture: capture)
        let content = records.filter { $0.source == .content }
        #expect(content.count == 1)
        #expect(content[0].extractionStatus == .encrypted)
        #expect(content[0].excerpt == nil)
        #expect(!content[0].isUsable)
        // Filename evidence still exists: the name was observed even though the
        // body was not, and the interface must show that difference.
        #expect(records.contains { $0.source == .filename && $0.isUsable })
    }

    @Test("a formula cell without a cached value is recorded as a formula, not as blank")
    func formulaWithoutCache() throws {
        let file = entry("示例项目/报价.xlsx")
        let item = EvidenceItem(locator: .xlsx(sheet: "报价表", cell: "D5"), text: nil,
                                cellType: "n", formula: "C5*1.13", cachedValue: nil)
        let capture = SourceEvidence(entry: file, status: .ok, items: [item], sha256: nil)
        let records = try EvidenceRegistry.records(for: file, capture: capture)
        let content = try #require(records.first { $0.source == .content })
        #expect(content.excerpt?.contains("formula=C5*1.13") == true)
        #expect(content.excerpt?.contains("cached=none") == true)
    }

    @Test("excerpts are bounded for storage and shorter for prompts")
    func excerptBounds() throws {
        let long = String(repeating: "字", count: 5_000)
        let file = entry("示例项目/长文.pdf")
        let item = EvidenceItem(locator: .pdf(page: 1, characterRange: 0..<long.utf16.count), text: long)
        let capture = SourceEvidence(entry: file, status: .truncated, items: [item], sha256: nil)
        let records = try EvidenceRegistry.records(for: file, capture: capture)
        let content = try #require(records.first { $0.source == .content })
        #expect(content.excerpt?.count == EvidenceRegistry.maximumExcerptCharacters)
        #expect(content.extractionStatus == .truncated)
        #expect(EvidenceRegistry.promptExcerpt(content)?.count == EvidenceRegistry.maximumPromptExcerptCharacters)
    }
    @Test("inherited values name the membership they came from")
    func inheritanceRecord() throws {
        let file = entry("示例项目/彩页.pdf")
        let record = try EvidenceRegistry.inheritance(
            sourceID: file.id, snapshotRevision: 3, snapshotFingerprint: "f3",
            value: "示例项目", siblingPath: "示例项目/公告.pdf", candidateID: "c1", createdAt: .now
        )
        #expect(record.source == .sibling)
        #expect(record.contextCandidateID == "c1")
        #expect(record.relativePath == "示例项目/公告.pdf")
        #expect(record.excerpt == "inherited from 示例项目/公告.pdf: 示例项目")
        #expect(record.isUsable)
    }

    @Test("a history value records the database and record it came from")
    func historyRecord() throws {
        let file = entry("示例项目/彩页.pdf")
        let database = UUID(uuidString: "00000000-0000-4000-8000-000000000030")!
        let record = try EvidenceRegistry.history(
            sourceID: file.id, snapshotRevision: 3, snapshotFingerprint: "f3",
            databaseID: database, recordID: UUID(uuidString: "00000000-0000-4000-8000-000000000031")!,
            property: "tenderreference", value: "ZB-DEMO-2026-014", queriedAt: .now
        )
        #expect(record.source == .mcp)
        #expect(record.relativePath?.contains(database.sourceKey) == true)
        #expect(record.relativePath?.contains("property=tenderreference") == true)
        let same = try EvidenceRegistry.identifier(sourceID: file.id, snapshotRevision: 3, source: .mcp,
                                                   locator: nil, relativePath: record.relativePath)
        #expect(same == record.id)
    }

    @Test("re-running the registry for the same read reproduces the same ids")
    func wholeSetIsReproducible() throws {
        let file = entry("示例项目/公告.pdf")
        let items = [EvidenceItem(locator: .pdf(page: 1, characterRange: 0..<4), text: "公告")]
        let capture = SourceEvidence(entry: file, status: .ok, items: items, sha256: nil)
        let first = try EvidenceRegistry.records(for: file, capture: capture, createdAt: .now)
        let second = try EvidenceRegistry.records(for: file, capture: capture, createdAt: .now)
        #expect(first.map(\.id) == second.map(\.id))
    }
}
