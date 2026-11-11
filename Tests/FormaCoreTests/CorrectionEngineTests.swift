import Foundation
import GRDB
import Testing

@testable import FormaCore

/// Correction Capture: a human decision is a new revision under the same rules
/// as a model answer, and a teaching case only exists after review.
@Suite("Correction capture")
struct CorrectionEngineTests {
    private let scopeID = UUID(uuidString: "00000000-0000-4000-8000-000000000070")!
    private let rootID = UUID(uuidString: "00000000-0000-4000-8000-000000000071")!
    private let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000072")!
    private let fingerprint = String(repeating: "a", count: 64)

    private func source(revision: Int64 = 2) -> SourceEntry {
        SourceEntry(id: sourceID, rootID: rootID, relativePath: "示例项目_2026/01_招标/公告.pdf",
                    normalizedRelativePath: "示例项目_2026/01_招标/公告.pdf", state: .present,
                    hydrationPending: false, sourceVersion: 1, snapshotRevision: revision, provider: .local,
                    snapshotFingerprint: fingerprint, sizeBytes: 10, modificationTimeNanoseconds: 0, sha256: nil)
    }

    private func record(id: String, excerpt: String, source: EvidenceSource = .content) -> EvidenceRecord {
        EvidenceRecord(id: id, sourceID: sourceID, snapshotRevision: 2, snapshotFingerprint: fingerprint,
                       source: source, locator: source == .content ? .pdf(page: 1, characterRange: 0..<12) : nil,
                       relativePath: source == .content ? nil : "示例项目_2026/01_招标", excerpt: excerpt,
                       extractionStatus: .ok, extractorVersion: EvidenceRegistry.extractorVersion,
                       createdAt: .now)
    }

    private func context(profile: MappingProfile) -> ProjectContext {
        ProjectContext(revision: 2, scopeID: scopeID, profileID: profile.profileID,
                       profileVersion: profile.profileVersion, inputDigest: String(repeating: "1", count: 64),
                       candidates: [ContextCandidate(id: "c1", projectKey: "示例项目_2026", displayName: nil,
                                                      basis: [.directory], memberSourceIDs: [sourceID],
                                                      confidence: .medium)],
                       unassignedSourceIDs: [], conflictedSourceIDs: [], builtAt: .now)
    }

    private func manifest(_ profile: MappingProfile, state: DecisionState) -> Manifest {
        let envelope = ManifestEnvelope(
            manifestID: UUID(), revision: 1, supersedesRevision: nil, scopeID: scopeID, sourceRootID: rootID,
            profile: profile, casePack: ("forma-governance-cases", "1.0"), modelProvider: "anthropic",
            modelID: "claude-haiku-4-5-20251001", contextRevision: 2, promptVersion: MappingPrompt.version,
            extractorVersion: EvidenceRegistry.extractorVersion, redactionVersion: nil,
            inputDigest: String(repeating: "2", count: 64), contextDigest: String(repeating: "3", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), state: .draft
        )
        var metadata = MetadataValues.allUnknown
        metadata[.documentcategory] = "01_招标文件"
        metadata[.projectname] = "示例项目_2026"
        metadata[.completionyear] = "2026"
        // The outcomes have to agree with the values. A manifest whose fields
        // say "unknown" while its metadata carries values is not a shape the
        // validator can produce, and a correction reading `previousValue` from
        // the outcomes would be measuring the fixture rather than the engine.
        let citations: [MetadataFieldID: [String]] = [
            .documentcategory: ["ev_cat"],
            .projectname: ["ev_name", "ev_path"],
            .completionyear: ["ev_year"],
        ]
        var fields: [FieldOutcome] = []
        for field in MetadataFieldID.allCases {
            let value = metadata[field]
            fields.append(FieldOutcome(field: field, value: value,
                                       status: value == nil ? .unknown : .evidenced,
                                       evidenceIDs: citations[field] ?? []))
        }
        let entry = ManifestEntry(
            sourceID: sourceID, snapshotFingerprint: fingerprint, snapshotRevision: 2, sourceVersion: 1,
            relativePath: "示例项目_2026/01_招标/公告.pdf", state: state,
            target: ManifestTarget(databaseName: "Project_Archive",
                                   groupPath: ["2026", "示例项目_2026", "01_招标文件"], resolved: true),
            metadata: metadata, fields: fields
        )
        return Manifest(envelope: envelope, entries: [entry])
    }

    private func evidence() -> [UUID: [EvidenceRecord]] {
        [sourceID: [
            record(id: "ev_cat", excerpt: "01_招标文件 招标公告"),
            record(id: "ev_name", excerpt: "示例项目_2026 智能化项目"),
            record(id: "ev_year", excerpt: "归档完成 2026 年"),
            record(id: "ev_path", excerpt: "示例项目_2026/01_招标", source: .path),
        ]]
    }

    @Test("a supported correction produces a new revision and leaves the old one")
    func correctionCreatesRevision() throws {
        let profile = try MappingProfile.projectArchive()
        let original = manifest(profile, state: .hold)
        let engine = CorrectionEngine(profile: profile)
        let applied = engine.apply(to: original, sourceID: sourceID, field: .completionyear,
                                   correctedValue: "2026", evidenceIDs: ["ev_year"], origin: .manual,
                                   context: context(profile: profile), evidence: evidence(),
                                   currentEntries: [source()])
        #expect(applied.violations.isEmpty, "violations: \(applied.violations.map(\.code))")
        #expect(applied.manifest.envelope.revision == 2)
        #expect(applied.manifest.envelope.supersedesRevision == 1)
        #expect(applied.manifest.entries[0].metadata[.completionyear] == "2026")
        #expect(applied.correction.reviewState == .evidenceVerified)
        #expect(applied.correction.previousValue == "2026")
        // The revision being corrected is untouched: history is not rewritten.
        #expect(original.envelope.revision == 1)
        #expect(original.entries[0].metadata[.completionyear] == "2026")
    }

    @Test("an unsupported correction is recorded as rejected and changes nothing")
    func unsupportedCorrection() throws {
        let profile = try MappingProfile.projectArchive()
        let original = manifest(profile, state: .hold)
        var changed = original
        changed.entries[0].metadata[.completionyear] = nil
        changed.entries[0].setOutcome(FieldOutcome(field: .completionyear, value: nil, status: .unknown))
        let engine = CorrectionEngine(profile: profile)
        let applied = engine.apply(to: changed, sourceID: sourceID, field: .issuer, correctedValue: "示例品牌A",
                                   evidenceIDs: [], origin: .manual, context: context(profile: profile),
                                   evidence: evidence(), currentEntries: [source()])
        #expect(applied.violations.contains { $0.code == "evidence_not_found" })
        #expect(applied.correction.reviewState == .rejected)
        #expect(applied.manifest.entries[0].metadata[.issuer] == nil)
    }

    @Test("clearing a value needs no evidence")
    func clearingIsSupported() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        let applied = engine.apply(to: manifest(profile, state: .hold), sourceID: sourceID, field: .issuer,
                                   correctedValue: nil, evidenceIDs: [], origin: .manual,
                                   context: context(profile: profile), evidence: evidence(),
                                   currentEntries: [source()])
        #expect(applied.violations.isEmpty)
        #expect(applied.correction.isSupported)
        #expect(applied.manifest.entries[0].metadata[.issuer] == nil)
    }

    @Test("a corrected category must still belong to the profile")
    func categoryVocabularyApplies() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        let applied = engine.apply(to: manifest(profile, state: .hold), sourceID: sourceID,
                                   field: .documentcategory, correctedValue: "07_其他", evidenceIDs: ["ev_cat"],
                                   origin: .manual, context: context(profile: profile), evidence: evidence(),
                                   currentEntries: [source()])
        #expect(applied.violations.contains { $0.code == "category_unknown" })
        #expect(applied.manifest.entries[0].metadata[.documentcategory] == "01_招标文件")
    }

    @Test("a value that breaks the field's declared shape is refused")
    func malformedValueRefused() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        // completionyear is typed as a year; a full date is the mistake the
        // historical archive actually made, and a human click does not excuse it.
        let applied = engine.apply(to: manifest(profile, state: .hold), sourceID: sourceID,
                                   field: .completionyear, correctedValue: "2026-01-01",
                                   evidenceIDs: ["ev_year"], origin: .manual,
                                   context: context(profile: profile), evidence: evidence(),
                                   currentEntries: [source()])
        #expect(applied.violations.contains { $0.code == "value_type" },
                "violations: \(applied.violations.map(\.code))")
        #expect(applied.correction.reviewState == .rejected)
        #expect(applied.manifest.entries[0].metadata[.completionyear] == "2026",
                "a refused correction changes nothing")
        #expect(applied.manifest.envelope.revision == 1,
                "a refused attempt must not publish a revision that supersedes the one it changed nothing in")
        #expect(applied.manifest.envelope.supersedesRevision == nil)
    }

    @Test("a rejected attempt publishes nothing and keeps the old revision authoritative")
    func rejectedAttemptPublishesNothing() throws {
        let profile = try MappingProfile.projectArchive()
        let original = manifest(profile, state: .hold)
        let engine = CorrectionEngine(profile: profile)
        // A citation that names no evidence at all: the value is an opinion.
        let applied = engine.apply(to: original, sourceID: sourceID, field: .issuer,
                                   correctedValue: "示例厂商乙", evidenceIDs: [], origin: .manual,
                                   context: context(profile: profile), evidence: evidence(),
                                   currentEntries: [source()])
        #expect(applied.violations.contains { $0.code == "evidence_not_found" })
        #expect(applied.correction.reviewState == .rejected)
        #expect(applied.manifest.envelope.revision == original.envelope.revision)
        #expect(applied.manifest.entries == original.entries)
    }

    @Test("a citation from another snapshot is not evidence for this one")
    func staleSnapshotCitationRefused() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        // The row exists and is usable; it describes revision 3 of the file,
        // while the entry under correction is bound to revision 2 - the same
        // binding the validator enforces for a model answer.
        let stale = EvidenceRecord(id: "ev_year", sourceID: sourceID, snapshotRevision: 3,
                                   snapshotFingerprint: String(repeating: "9", count: 64), source: .content,
                                   locator: .pdf(page: 1, characterRange: 0..<12), relativePath: nil,
                                   excerpt: "归档完成 2026 年", extractionStatus: .ok,
                                   extractorVersion: EvidenceRegistry.extractorVersion, createdAt: .now)
        let applied = engine.apply(to: manifest(profile, state: .hold), sourceID: sourceID,
                                   field: .completionyear, correctedValue: "2027",
                                   evidenceIDs: ["ev_year"], origin: .manual,
                                   context: context(profile: profile), evidence: [sourceID: [stale]],
                                   currentEntries: [source()])
        #expect(applied.violations.contains { $0.code == "evidence_not_found" },
                "violations: \(applied.violations.map(\.code))")
        #expect(applied.manifest.entries[0].metadata[.completionyear] == "2026")
    }

    @Test("a stored row naming a field the enum cannot is refused on read")
    func storedUnknownFieldRefused() async throws {
        // The engine's parameter type cannot name a thirteenth field, so the
        // reachable way to meet one is a row written by a different build. It
        // must fail to load rather than be dropped or guessed at.
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.write("notice", at: "示例项目_2026/01_招标/公告.pdf")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let file = try await workspace.scan(scope).entries[0]
        let store = try SourceStore(url: fixture.database)
        let manifestID = UUID()
        try fixture.execute("""
            INSERT INTO corrections (id, manifest_id, manifest_revision, supersedes_revision, source_id,
                                     field, previous_value, corrected_value, evidence_ids,
                                     snapshot_fingerprint, context_revision, origin, review_state,
                                     case_candidate_id, created_at)
            VALUES ('c_bad', '\(manifestID.uuidString.lowercased())', 2, 1, '\(file.id.sourceKey)',
                    'thirteenth_field', NULL, 'x', '[]', '\(file.snapshotFingerprint)', 1,
                    'manual', 'pending', NULL, 1780000000)
            """)
        var refused = false
        do {
            _ = try await store.database.read { db in
                try MappingStore.corrections(manifestID: manifestID, in: db)
            }
        } catch {
            refused = true
        }
        #expect(refused, "a correction naming a field the twelve cannot is not silently ignorable")
    }

    @Test("a candidate case starts unreviewed and only becomes admissible after review")
    func candidateLifecycle() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        let applied = engine.apply(to: manifest(profile, state: .hold), sourceID: sourceID, field: .completionyear,
                                   correctedValue: "2026", evidenceIDs: ["ev_year"], origin: .manual,
                                   context: context(profile: profile), evidence: evidence(),
                                   currentEntries: [source()])
        let plan = RedactionPlan(terms: ["示例项目_2026": .project], salt: "s")
        let candidate = CorrectionEngine.candidate(from: [applied.correction], profile: profile,
                                                   scenario: "归档完成年来自正文落款而非封面年", redaction: plan)
        #expect(candidate.status == .candidate)
        #expect(candidate.redactionChecked)
        #expect(!candidate.isAdmissible, "an unreviewed candidate may not enter the pack")

        let leaking = CorrectionEngine.candidate(from: [applied.correction], profile: profile,
                                                 scenario: "示例项目_2026 的归档完成年", redaction: plan)
        #expect(!leaking.redactionChecked, "a scenario that still contains a redacted term is not admissible")

        var reviewed = candidate
        reviewed.status = .accepted
        reviewed.reviewedAt = .now
        #expect(reviewed.isAdmissible)
    }

    @Test("a rejected correction produces no candidate")
    func rejectedProducesNothing() throws {
        let profile = try MappingProfile.projectArchive()
        let correction = CorrectionRecord(
            manifestID: UUID(), manifestRevision: 2, supersedesRevision: 1, sourceID: sourceID, field: .issuer,
            previousValue: nil, correctedValue: "示例品牌A", evidenceIDs: [], snapshotFingerprint: fingerprint,
            contextRevision: 2, origin: .manual, reviewState: .rejected
        )
        let candidate = CorrectionEngine.candidate(from: [correction], profile: profile, scenario: "无证据主体",
                                                   redaction: RedactionPlan.none)
        #expect(candidate.correctionIDs.isEmpty)
        #expect(candidate.status == .rejected)
    }

    @Test("duplicate detection keys on source, field and scenario")
    func duplicateKey() {
        let a = CorrectionEngine.duplicateKey(sourceID: sourceID, field: .issuer, scenario: "same")
        let b = CorrectionEngine.duplicateKey(sourceID: sourceID, field: .issuer, scenario: "same")
        let c = CorrectionEngine.duplicateKey(sourceID: sourceID, field: .issuer, scenario: "other")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("corrections and candidates round-trip through storage")
    func storageRoundTrip() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.write("notice", at: "示例项目_2026/01_招标/公告.pdf")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let entries = try await workspace.scan(scope).entries
        let store = try SourceStore(url: fixture.database)
        let file = entries[0]
        let record = EvidenceRecord(id: "ev_1", sourceID: file.id, snapshotRevision: Int(file.snapshotRevision),
                                    snapshotFingerprint: file.snapshotFingerprint, source: .content,
                                    locator: .pdf(page: 1, characterRange: 0..<4), relativePath: nil,
                                    excerpt: "归档完成 2026 年", extractionStatus: .ok,
                                    extractorVersion: EvidenceRegistry.extractorVersion, createdAt: .now)
        let candidate = CaseCandidate(correctionIDs: [], status: .candidate, scenario: "归档完成年证据",
                                      profiles: ["project-archive"], redactionChecked: false)
        let correction = CorrectionRecord(
            manifestID: UUID(), manifestRevision: 2, supersedesRevision: 1, sourceID: file.id,
            field: .completionyear, previousValue: nil, correctedValue: "2026", evidenceIDs: ["ev_1"],
            snapshotFingerprint: file.snapshotFingerprint, contextRevision: 1, origin: .manual,
            reviewState: .pending, caseCandidateID: candidate.id
        )
        try await store.database.write { db in
            try MappingStore.insertEvidence([record], in: db)
            try MappingStore.insertCaseCandidate(candidate, in: db)
            try MappingStore.insertCorrection(correction, in: db)
        }
        let loaded = try await store.database.read { db in try MappingStore.corrections(manifestID: correction.manifestID, in: db) }
        #expect(loaded.count == 1)
        #expect(loaded[0].field == .completionyear)
        #expect(loaded[0].evidenceIDs == ["ev_1"])
        #expect(loaded[0].caseCandidateID == candidate.id)
        #expect(loaded[0].reviewState == .pending)

        try await store.database.write { db in
            try MappingStore.updateCaseCandidate(id: candidate.id, status: .accepted, reviewedAt: .now,
                                                 redactionChecked: true, in: db)
        }
        let candidates = try await store.database.read { db in try MappingStore.caseCandidates(in: db) }
        #expect(candidates.count == 1)
        #expect(candidates[0].status == .accepted)
        #expect(candidates[0].redactionChecked)
        #expect(candidates[0].reviewedAt != nil)
        #expect(candidates[0].isAdmissible)
    }

    @Test("a correction may not cite a source that does not exist")
    func correctionForeignKey() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.write("notice", at: "示例项目_2026/公告.pdf")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        _ = try await workspace.register(fixture.root)
        _ = try await workspace.scan(try await workspace.scopes()[0])
        let store = try SourceStore(url: fixture.database)
        let invented = CorrectionRecord(
            manifestID: UUID(), manifestRevision: 1, supersedesRevision: nil, sourceID: UUID(),
            field: .issuer, previousValue: nil, correctedValue: nil, evidenceIDs: [],
            snapshotFingerprint: fingerprint, contextRevision: 1, origin: .manual
        )
        var failure: (any Error)?
        do {
            try await store.database.write { db in try MappingStore.insertCorrection(invented, in: db) }
        } catch {
            failure = error
        }
        #expect(failure != nil, "a correction must reference a real source entry")
    }
}
