import Foundation
import Testing

@testable import FormaCore

/// The review screen has to know, before the reviewer ticks a row, whether
/// that row still describes the file in front of them. A row read from an
/// older snapshot is not wrong - it describes an older version faithfully -
/// but it cannot support a value about the current one, and offering it as if
/// it could is what the field reported as a failed correction.
@Suite("Evidence currency for the review screen")
struct EvidenceCurrencyPresentationTests {
    private let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000090")!
    private let fingerprint = String(repeating: "a", count: 64)

    private func record(revision: Int, snapshotFingerprint: String? = nil,
                        status: EvidenceStatus = .ok) -> EvidenceRecord {
        EvidenceRecord(id: "row-\(revision)", sourceID: sourceID, snapshotRevision: revision,
                       snapshotFingerprint: snapshotFingerprint ?? fingerprint, source: .content,
                       locator: .pdf(page: 1, characterRange: 0..<12), relativePath: nil,
                       excerpt: "归档完成 2026 年", extractionStatus: status,
                       extractorVersion: EvidenceRegistry.extractorVersion, createdAt: .now)
    }

    @Test("a row of the snapshot under correction is current")
    func currentRow() {
        let binding = EvidenceSnapshotBinding(revision: 2, fingerprint: fingerprint)
        #expect(EvidenceCurrency.currency(of: record(revision: 2), against: binding) == .current)
    }

    @Test("a row of an older snapshot is expired")
    func expiredRow() {
        let binding = EvidenceSnapshotBinding(revision: 2, fingerprint: fingerprint)
        #expect(EvidenceCurrency.currency(of: record(revision: 1), against: binding) == .expired)
        // The same revision under another fingerprint is another snapshot: the
        // file was read again and hashed, and the two reads do not describe
        // the same bytes.
        #expect(EvidenceCurrency.currency(of: record(revision: 2, snapshotFingerprint: String(repeating: "b", count: 64)),
                                          against: binding) == .expired)
    }

    @Test("a row the program could not read is unusable")
    func unusableRow() {
        let binding = EvidenceSnapshotBinding(revision: 2, fingerprint: fingerprint)
        #expect(EvidenceCurrency.currency(of: record(revision: 2, status: .corrupt), against: binding) == .unusable)
    }

    @Test("the copy names the state in plain words")
    func copyIsPlain() {
        #expect(EvidenceCurrencyCopy.expiredBadge == "已过期")
        #expect(EvidenceCurrencyCopy.expiredSentence.contains(where: { $0.isHan }))
        #expect(!EvidenceCurrencyCopy.expiredSentence.contains("snapshot"))
        #expect(EvidenceCurrencyCopy.rereadAction == "重新读取证据")
        #expect(EvidenceCurrencyCopy.rereadHint.contains(where: { $0.isHan }))
    }
}

private extension Character {
    /// Whether the character is a Han ideograph: the copy under test is
    /// Chinese, and the assertion is about the language, not about one
    /// particular string.
    var isHan: Bool {
        (0x4E00...0x9FFF).contains(unicodeScalars.first?.value ?? 0)
    }
}
