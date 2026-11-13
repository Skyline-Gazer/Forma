import Foundation

@testable import FormaCore

/// Shared builders for the import suites.
///
/// The clearance is the permission to write, and it can only come from
/// `ImportPreflight.evaluate`. These helpers therefore build the *facts* — the
/// entry, the manifest, the authorization, the source — and let the real
/// preflight rules produce the clearance, so the tests exercise the same path
/// production would.
enum ImportFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let groupPath = ["01_招标文件", "2026"]
    static let database = "Project_Archive"
    static let association = "context revision 3 candidate cr-0001"
    static let snapshot = String(repeating: "a", count: 64)
    static let sha = String(repeating: "c", count: 64)

    static func authorization(groupPrefix: [String] = ["01_招标文件"],
                              database: String = ImportFixtures.database) -> ImportAuthorization {
        ImportAuthorization(databaseName: database, groupPrefix: groupPrefix,
                            authorizedBy: "synthetic", issuedAt: now)
    }

    static func sourceBinding(sourceID: UUID, snapshot: String = ImportFixtures.snapshot,
                              sha: String = ImportFixtures.sha,
                              relativePath: String = "synthetic/tender.pdf") -> ImportSourceBinding {
        ImportSourceBinding(sourceID: sourceID, scopeID: UUID(), relativePath: relativePath,
                             snapshotFingerprint: snapshot, contentSHA256: sha, byteCount: 1_024,
                             readSessionID: "session-synthetic")
    }

    static func entry(sourceID: UUID, snapshot: String = ImportFixtures.snapshot,
                      groupPath: [String] = ImportFixtures.groupPath,
                      database: String = ImportFixtures.database) -> ManifestEntry {
        ManifestEntry(sourceID: sourceID, snapshotFingerprint: snapshot, snapshotRevision: 1,
                      sourceVersion: 1, relativePath: "synthetic/tender.pdf", state: .validated,
                      target: ManifestTarget(databaseName: database, groupPath: groupPath, resolved: true),
                      eligibleForAutoExecution: true)
    }

    static func manifest(revision: Int) throws -> ManifestEnvelope {
        let profile = try MappingProfile.projectArchive()
        let pack = try CasePack.shipped()
        return ManifestEnvelope(
            manifestID: UUID(), revision: revision, supersedesRevision: revision > 1 ? revision - 1 : nil,
            scopeID: UUID(), sourceRootID: UUID(), profile: profile,
            casePack: (id: pack.id, version: pack.version), modelProvider: "substitute", modelID: nil,
            contextRevision: 7, promptVersion: "p1", extractorVersion: "e1", redactionVersion: "r1",
            inputDigest: String(repeating: "1", count: 64),
            contextDigest: String(repeating: "2", count: 64), createdAt: now, state: .validated)
    }

    static func intent(runID: UUID, sourceID: UUID = UUID(),
                       snapshot: String = ImportFixtures.snapshot,
                       sha: String = ImportFixtures.sha,
                       groupPath: [String] = ImportFixtures.groupPath,
                       database: String = ImportFixtures.database,
                       associationBasis: String? = ImportFixtures.association,
                       authorization: ImportAuthorization = ImportFixtures.authorization(),
                       metadata: [String: String?] = ["completion_year": "2026"],
                       revision: Int = 1) throws -> ImportIntent {
        let source = sourceBinding(sourceID: sourceID, snapshot: snapshot, sha: sha)
        let key = try ImportOperationKey(sourceID: sourceID, snapshotFingerprint: snapshot,
                                         manifestRevision: revision,
                                         targetAssociationID: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!)
        return ImportIntent(
            runID: runID, entry: entry(sourceID: sourceID, snapshot: snapshot, groupPath: groupPath,
                                       database: database),
            key: key, source: source, targetDatabase: database, groupPath: groupPath,
            associationBasis: associationBasis, metadata: metadata,
            authorizationDigest: authorization.digest)
    }

    /// A clearance decided for these facts.
    static func clearance(for intent: ImportIntent,
                          authorization: ImportAuthorization = ImportFixtures.authorization(),
                          sha: String? = ImportFixtures.sha) throws -> ImportPreflightClearance {
        let profile = try MappingProfile.projectArchive()
        let manifest = try manifest(revision: intent.key.manifestRevision)
        return ImportPreflight.evaluate(ImportPreflightInput(
            entry: entry(sourceID: intent.key.sourceID, snapshot: intent.key.snapshotFingerprint,
                         groupPath: intent.groupPath, database: intent.targetDatabase),
            manifest: manifest,
            expectations: ImportExpectations(profileID: profile.profileID,
                                             profileVersion: profile.profileVersion,
                                             schemaVersion: manifest.schemaVersion),
            authorization: authorization,
            source: ImportSourceFacts(state: .present, authorized: true, readable: true,
                                      hydrationPending: false,
                                      snapshotFingerprint: intent.key.snapshotFingerprint,
                                      sha256: sha),
            target: ImportTargetFacts(exists: true, writable: true, availableBytes: 10_000,
                                      requiredBytes: 1_000),
            capability: ImportCapabilityFacts(writeToolsAvailable: true, readbackAvailable: true),
            expectedSHA256: intent.source.contentSHA256, now: now))
    }

    /// The source facts a recovery sees now, including the read session and
    /// byte count that bind the observation to the intent's source.
    static func sourceFacts(snapshot: String = ImportFixtures.snapshot,
                            sha: String? = ImportFixtures.sha,
                            readSessionID: String? = "session-synthetic",
                            byteCount: Int64? = 1_024) -> ImportSourceFacts {
        ImportSourceFacts(state: .present, authorized: true, readable: true, hydrationPending: false,
                          snapshotFingerprint: snapshot, sha256: sha,
                          readSessionID: readSessionID, byteCount: byteCount)
    }
}
