import Foundation
import Testing

@testable import FormaCore

/// Preflight decides one record at a time, from supplied facts only.
///
/// The property that matters is not "it blocks bad input" — it is that each
/// failure has its own code, that transient failures are distinguishable from
/// blocking ones, and that a manifest can never authorize itself.
@Suite("Import preflight")
struct ImportPreflightTests {
    private let sourceID = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Base {
        var entry: ManifestEntry
        var manifest: ManifestEnvelope
        var expectations: ImportExpectations
        var authorization: ImportAuthorization?
        var source: ImportSourceFacts
        var target: ImportTargetFacts
        var capability: ImportCapabilityFacts
        var expectedSHA256: String?
        var now: Date
    }

    private func makeBase() throws -> Base {
        let profile = try MappingProfile.projectArchive()
        let pack = try CasePack.shipped()
        let fingerprint = String(repeating: "a", count: 64)
        let entry = ManifestEntry(
            sourceID: sourceID, snapshotFingerprint: fingerprint, snapshotRevision: 1, sourceVersion: 1,
            relativePath: "synthetic/tender.pdf", state: .validated,
            target: ManifestTarget(databaseName: "Project_Archive",
                                   groupPath: ["01_招标文件", "2026"], resolved: true),
            eligibleForAutoExecution: true)
        let manifest = ManifestEnvelope(
            manifestID: UUID(), revision: 3, supersedesRevision: 2, scopeID: UUID(), sourceRootID: UUID(),
            profile: profile, casePack: (id: pack.id, version: pack.version),
            modelProvider: "substitute", modelID: nil, contextRevision: 7,
            promptVersion: "p1", extractorVersion: "e1", redactionVersion: "r1",
            inputDigest: String(repeating: "1", count: 64),
            contextDigest: String(repeating: "2", count: 64),
            createdAt: now, state: .validated)
        return Base(
            entry: entry, manifest: manifest,
            expectations: ImportExpectations(profileID: profile.profileID,
                                             profileVersion: profile.profileVersion,
                                             schemaVersion: manifest.schemaVersion),
            authorization: ImportAuthorization(databaseName: "Project_Archive",
                                               groupPrefix: ["01_招标文件"],
                                               authorizedBy: "synthetic", issuedAt: now),
            source: ImportSourceFacts(state: .present, authorized: true, readable: true,
                                      hydrationPending: false, snapshotFingerprint: fingerprint, sha256: nil),
            target: ImportTargetFacts(exists: true, writable: true, availableBytes: 10_000,
                                      requiredBytes: 1_000),
            capability: ImportCapabilityFacts(writeToolsAvailable: true, readbackAvailable: true),
            expectedSHA256: nil, now: now)
    }

    private func evaluate(_ configure: (inout Base) throws -> Void = { _ in }) throws -> ImportPreflightResult {
        var base = try makeBase()
        try configure(&base)
        return ImportPreflight.evaluate(ImportPreflightInput(
            entry: base.entry, manifest: base.manifest, expectations: base.expectations,
            authorization: base.authorization, source: base.source, target: base.target,
            capability: base.capability, expectedSHA256: base.expectedSHA256, now: base.now))
    }

    private func codes(_ result: ImportPreflightResult) -> Set<ImportPreflightCode> {
        Set(result.failures.map(\.code))
    }

    // MARK: - Pass

    @Test("a fully evidenced record passes")
    func pass() throws {
        let result = try evaluate()
        #expect(result.verdict == .pass)
        #expect(result.failures.isEmpty)
    }

    // MARK: - Authorization

    @Test("eligibility alone is not import authorization")
    func eligibilityIsNotAuthorization() throws {
        let result = try evaluate { $0.authorization = nil }
        #expect(result.verdict == .blocked)
        #expect(codes(result) == [.authorizationMissing])
    }

    @Test("an expired authorization blocks")
    func expiredAuthorization() throws {
        let result = try evaluate { base in
            base.authorization = ImportAuthorization(databaseName: "Project_Archive",
                                                     groupPrefix: ["01_招标文件"],
                                                     authorizedBy: "synthetic", issuedAt: base.now,
                                                     expiresAt: base.now.addingTimeInterval(-1))
        }
        #expect(result.verdict == .blocked)
        #expect(codes(result).contains(.authorizationExpired))
    }

    @Test("a target outside the authorized scope blocks")
    func targetOutsideScope() throws {
        let result = try evaluate { base in
            base.authorization = ImportAuthorization(databaseName: "Project_Archive",
                                                     groupPrefix: ["09_其他"],
                                                     authorizedBy: "synthetic", issuedAt: base.now)
        }
        #expect(result.verdict == .blocked)
        #expect(codes(result) == [.targetOutsideAuthorization])
    }

    @Test("a different database is outside the scope even with a matching prefix")
    func databaseOutsideScope() throws {
        let result = try evaluate { base in
            base.authorization = ImportAuthorization(databaseName: "Other_Archive",
                                                     groupPrefix: ["01_招标文件"],
                                                     authorizedBy: "synthetic", issuedAt: base.now)
        }
        #expect(codes(result) == [.targetOutsideAuthorization])
    }

    // MARK: - Manifest and entry

    @Test("a manifest that claims execution authority is refused")
    func manifestExecutionClaim() throws {
        // No initializer can produce this: the flag is constant false. A file
        // that says otherwise is a contract violation, which is what this checks.
        let encoded = try JSONEncoder().encode(try makeBase().manifest)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["grants_execution"] = true
        let corrupted = try JSONDecoder().decode(
            ManifestEnvelope.self, from: try JSONSerialization.data(withJSONObject: object))

        let result = try evaluate { $0.manifest = corrupted }
        #expect(result.verdict == .blocked)
        #expect(codes(result).contains(.manifestExecutionClaim))
    }

    @Test("an unvalidated manifest or entry blocks")
    func unvalidated() throws {
        let manifestResult = try evaluate { base in
            base.manifest.state = .draft
        }
        #expect(codes(manifestResult).contains(.manifestNotValidated))

        let entryResult = try evaluate { base in
            base.entry.state = .mapped
        }
        #expect(codes(entryResult).contains(.entryInvalidated))
    }

    @Test("an entry that is not eligible for automatic execution blocks")
    func notEligible() throws {
        let result = try evaluate { $0.entry.eligibleForAutoExecution = false }
        #expect(result.verdict == .blocked)
        #expect(codes(result) == [.entryNotEligible])
    }

    @Test("profile and schema mismatches block")
    func profileAndSchema() throws {
        let profile = try evaluate { base in
            base.expectations = ImportExpectations(profileID: "other", profileVersion: "v9",
                                                   schemaVersion: base.manifest.schemaVersion)
        }
        #expect(codes(profile).contains(.profileMismatch))

        let schema = try evaluate { base in
            base.expectations = ImportExpectations(profileID: base.manifest.profileID,
                                                   profileVersion: base.manifest.profileVersion,
                                                   schemaVersion: "9.9")
        }
        #expect(codes(schema).contains(.schemaMismatch))
    }

    // MARK: - Source

    @Test("a changed snapshot blocks; it is not retried")
    func sourceChanged() throws {
        let result = try evaluate { base in
            base.source = ImportSourceFacts(state: .present, authorized: true, readable: true,
                                            hydrationPending: false,
                                            snapshotFingerprint: String(repeating: "b", count: 64),
                                            sha256: nil)
        }
        #expect(result.verdict == .blocked)
        #expect(codes(result) == [.sourceChanged])
    }

    @Test("a missing source blocks")
    func sourceMissing() throws {
        let result = try evaluate { base in
            base.source = ImportSourceFacts(state: .missing, authorized: true, readable: true,
                                            hydrationPending: false, snapshotFingerprint: "",
                                            sha256: nil)
        }
        #expect(codes(result) == [.sourceMissing])
    }

    @Test("permission, unreadable and hydration are transient, not skips")
    func transientSourceFailures() throws {
        let configures: [(inout Base) -> Void] = [
            { base in
                base.source = ImportSourceFacts(state: .present, authorized: false, readable: true,
                                                hydrationPending: false,
                                                snapshotFingerprint: base.entry.snapshotFingerprint,
                                                sha256: nil)
            },
            { base in
                base.source = ImportSourceFacts(state: .present, authorized: true, readable: false,
                                                hydrationPending: false,
                                                snapshotFingerprint: base.entry.snapshotFingerprint,
                                                sha256: nil)
            },
            { base in
                base.source = ImportSourceFacts(state: .present, authorized: true, readable: true,
                                                hydrationPending: true,
                                                snapshotFingerprint: base.entry.snapshotFingerprint,
                                                sha256: nil)
            },
        ]
        for configure in configures {
            let result = try evaluate(configure)
            #expect(result.verdict == .deferred)
            #expect(result.blockingCodes.isEmpty)
            #expect(result.failures.allSatisfy { $0.code.isTransient })
        }
    }

    @Test("a content digest that differs from the recorded evidence blocks")
    func shaMismatch() throws {
        let result = try evaluate { base in
            base.expectedSHA256 = String(repeating: "1", count: 64)
            base.source = ImportSourceFacts(state: .present, authorized: true, readable: true,
                                            hydrationPending: false,
                                            snapshotFingerprint: base.entry.snapshotFingerprint,
                                            sha256: String(repeating: "2", count: 64))
        }
        #expect(result.verdict == .blocked)
        #expect(codes(result) == [.sourceSHAMismatch])
    }

    @Test("an unverified digest is not a mismatch")
    func unverifiedDigestIsNotAMismatch() throws {
        let result = try evaluate { base in
            base.expectedSHA256 = String(repeating: "1", count: 64)
        }
        #expect(result.verdict == .pass)
    }

    // MARK: - Target and capability

    @Test("an unresolved, missing or read-only target blocks")
    func targetFailures() throws {
        let unresolved = try evaluate { base in
            base.entry.target = ManifestTarget(databaseName: "Project_Archive",
                                               groupPath: ["{{project}}"], resolved: false)
        }
        #expect(codes(unresolved).contains(.targetUnresolved))

        let missing = try evaluate { base in
            base.target = ImportTargetFacts(exists: false, writable: true)
        }
        #expect(codes(missing) == [.targetMissing])

        let readOnly = try evaluate { base in
            base.target = ImportTargetFacts(exists: true, writable: false)
        }
        #expect(codes(readOnly) == [.targetNotWritable])
    }

    @Test("insufficient space is transient")
    func insufficientSpace() throws {
        let result = try evaluate { base in
            base.target = ImportTargetFacts(exists: true, writable: true, availableBytes: 10,
                                            requiredBytes: 1_000)
        }
        #expect(result.verdict == .deferred)
        #expect(codes(result) == [.insufficientSpace])
    }

    @Test("a writer without an independent reader is not capable")
    func capability() throws {
        let result = try evaluate { base in
            base.capability = ImportCapabilityFacts(writeToolsAvailable: true, readbackAvailable: false)
        }
        #expect(result.verdict == .deferred)
        #expect(codes(result) == [.capabilityMissing])
    }

    @Test("a blocking failure outweighs a transient one")
    func mixedFailures() throws {
        let result = try evaluate { base in
            base.target = ImportTargetFacts(exists: false, writable: true)
            base.source = ImportSourceFacts(state: .present, authorized: true, readable: true,
                                            hydrationPending: true,
                                            snapshotFingerprint: base.entry.snapshotFingerprint,
                                            sha256: nil)
        }
        #expect(result.verdict == .blocked)
        #expect(codes(result) == [.targetMissing, .hydrationPending])
        #expect(result.blockingCodes == [.targetMissing])
    }

    @Test("evaluation is pure: the same input gives the same failures in the same order")
    func determinism() throws {
        let first = try evaluate { $0.target = ImportTargetFacts(exists: false, writable: false) }
        let second = try evaluate { $0.target = ImportTargetFacts(exists: false, writable: false) }
        #expect(first == second)
        #expect(first.failures.map(\.code) == [.targetMissing, .targetNotWritable])
    }
}
