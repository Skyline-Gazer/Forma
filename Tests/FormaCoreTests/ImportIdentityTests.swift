import Foundation
import Testing

@testable import FormaCore

/// The three identities the ledger must keep apart.
///
/// The failure these tests exist for is subtle: a hash that matches is read as
/// "same record", and two documents with identical bytes but different business
/// meaning collapse into one. Every assertion here is about *not* letting one
/// kind of evidence answer another kind of question.
@Suite("Import identity")
struct ImportIdentityTests {
    private let sourceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let associationID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let fingerprint = String(repeating: "a", count: 64)

    private func key(snapshot: String? = nil, revision: Int = 1, association: UUID? = nil,
                     kind: ImportOperationKind = .createRecord) throws -> ImportOperationKey {
        try ImportOperationKey(sourceID: sourceID, snapshotFingerprint: snapshot ?? fingerprint,
                               manifestRevision: revision,
                               targetAssociationID: association ?? associationID,
                               operationKind: kind)
    }

    // MARK: - Operation key

    @Test("the key is stable, and every component changes it")
    func keyComponents() throws {
        let base = try key()
        #expect(try key() == base)
        #expect(try key().digest == base.digest)
        #expect(base.digest.count == 64)

        #expect(try key(snapshot: String(repeating: "b", count: 64)).digest != base.digest)
        #expect(try key(revision: 2).digest != base.digest)
        #expect(try key(association: UUID()).digest != base.digest)
        #expect(try key(kind: .createRecord).digest == base.digest)
    }

    @Test("a new manifest revision is a new intent, not a retry of the old one")
    func revisionIsPartOfTheKey() throws {
        #expect(try key(revision: 1) != (try key(revision: 2)))
    }

    @Test("a key that could not have been constructed cannot be decoded either")
    func decodingValidates() throws {
        let data = try JSONEncoder().encode(try key())
        #expect(try JSONDecoder().decode(ImportOperationKey.self, from: data) == (try key()))

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["snapshot_fingerprint"] = "aa|bb"
        let corrupted = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: FormaError.self) {
            _ = try JSONDecoder().decode(ImportOperationKey.self, from: corrupted)
        }
    }

    @Test("an empty or separator-bearing fingerprint is refused at construction")
    func invalidComponents() {
        #expect(throws: FormaError.self) {
            _ = try ImportOperationKey(sourceID: sourceID, snapshotFingerprint: "",
                                       manifestRevision: 1, targetAssociationID: associationID)
        }
        #expect(throws: FormaError.self) {
            _ = try ImportOperationKey(sourceID: sourceID, snapshotFingerprint: "a|b",
                                       manifestRevision: 1, targetAssociationID: associationID)
        }
        #expect(throws: FormaError.self) {
            _ = try ImportOperationKey(sourceID: sourceID, snapshotFingerprint: fingerprint,
                                       manifestRevision: 0, targetAssociationID: associationID)
        }
    }

    @Test("the canonical string is unambiguous across adjacent components")
    func canonicalEncoding() throws {
        // A fingerprint that merely *looks* like it continues into the revision
        // must not collide with a different key.
        let one = try ImportOperationKey(sourceID: sourceID, snapshotFingerprint: "ab",
                                         manifestRevision: 12, targetAssociationID: associationID)
        let two = try ImportOperationKey(sourceID: sourceID, snapshotFingerprint: "ab1",
                                         manifestRevision: 2, targetAssociationID: associationID)
        #expect(one.canonicalString != two.canonicalString)
        #expect(one.digest != two.digest)
    }

    // MARK: - Source bytes

    @Test("source identity needs a verified digest on both sides")
    func sourceBytes() {
        let sha = String(repeating: "c", count: 64)
        let verified = SourceBytesIdentity(sourceID: sourceID, snapshotFingerprint: fingerprint, sha256: sha)
        #expect(verified.isVerified)
        #expect(verified.matches(verified))
        #expect(!verified.matches(SourceBytesIdentity(sourceID: sourceID, snapshotFingerprint: fingerprint,
                                                      sha256: nil)))
        #expect(!verified.matches(SourceBytesIdentity(sourceID: sourceID, snapshotFingerprint: fingerprint,
                                                      sha256: String(repeating: "d", count: 64))))
        #expect(!SourceBytesIdentity(sourceID: sourceID, snapshotFingerprint: fingerprint, sha256: "short")
            .isVerified)
    }

    // MARK: - Business record

    @Test("a hash match alone never confirms a business record")
    func hashAloneIsNotIdentity() {
        // Nothing but a candidate observation: no UUID, no anchor.
        let hashOnly = BusinessRecordIdentity(observedUUID: nil, corroboration: [])
        #expect(!hashOnly.isConfirmed)
        #expect(hashOnly.isCandidateOnly)

        // Attributes and project agree, but no anchor ties it to this source.
        let unattached = BusinessRecordIdentity(observedUUID: "uuid-1",
                                                corroboration: [.projectAndUsageMatch, .attributesMatch])
        #expect(!unattached.isConfirmed)
        #expect(unattached.isCandidateOnly)
    }

    @Test("confirmation needs an observed UUID, an anchor and a second fact")
    func confirmationNeedsCorroboration() {
        let anchorOnly = BusinessRecordIdentity(observedUUID: "uuid-1", corroboration: [.sourceLedgerMatch])
        #expect(!anchorOnly.isConfirmed)

        let confirmed = BusinessRecordIdentity(observedUUID: "uuid-1",
                                               corroboration: [.sourceLedgerMatch, .attributesMatch])
        #expect(confirmed.isConfirmed)
        #expect(!confirmed.isCandidateOnly)

        let associationConfirmed = BusinessRecordIdentity(
            observedUUID: "uuid-2", corroboration: [.targetAssociationMatch, .projectAndUsageMatch])
        #expect(associationConfirmed.isConfirmed)
    }

    @Test("two non-anchor facts still do not confirm identity")
    func nonAnchorsDoNotConfirm() {
        let record = BusinessRecordIdentity(
            observedUUID: "uuid-3", corroboration: [.projectAndUsageMatch, .attributesMatch])
        #expect(!record.isConfirmed)
    }
}
