import Foundation
import Testing

@testable import FormaCore

/// The exported bundle is the artifact a reviewer re-checks later, possibly on
/// another machine, so its own integrity is part of the contract.
@Suite("Manifest export")
struct ManifestExportTests {
    private func manifest(profile: MappingProfile, entries: [ManifestEntry], state: ManifestEnvelope.ManifestState)
        -> Manifest
    {
        let envelope = ManifestEnvelope(
            manifestID: UUID(), revision: 1, supersedesRevision: nil,
            scopeID: UUID(uuidString: "00000000-0000-4000-8000-000000000060")!,
            sourceRootID: UUID(uuidString: "00000000-0000-4000-8000-000000000061")!,
            profile: profile, casePack: ("forma-governance-cases", "1.0"), modelProvider: "anthropic",
            modelID: "claude-haiku-4-5-20251001", contextRevision: 2, promptVersion: MappingPrompt.version,
            extractorVersion: EvidenceRegistry.extractorVersion, redactionVersion: nil,
            inputDigest: String(repeating: "1", count: 64), contextDigest: String(repeating: "2", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), state: state
        )
        return Manifest(envelope: envelope, entries: entries)
    }

    private func entry(id: UUID, evidenceIDs: [String], state: DecisionState = .validated, eligible: Bool = true)
        -> ManifestEntry
    {
        var fields: [FieldOutcome] = []
        for field in MetadataFieldID.allCases {
            fields.append(FieldOutcome(field: field, value: nil, status: .unknown))
        }
        fields[fields.firstIndex { $0.field == .documentcategory }!] = FieldOutcome(
            field: .documentcategory, value: "01_招标文件", status: .evidenced, evidenceIDs: evidenceIDs
        )
        var metadata = MetadataValues.allUnknown
        metadata[.documentcategory] = "01_招标文件"
        return ManifestEntry(
            sourceID: id, snapshotFingerprint: String(repeating: "a", count: 64), snapshotRevision: 2,
            sourceVersion: 1, relativePath: "示例项目_2026/01_招标/公告.pdf", state: state,
            target: ManifestTarget(databaseName: "Project_Archive",
                                   groupPath: ["2026", "示例项目_2026", "01_招标文件"], resolved: true),
            metadata: metadata, fields: fields, eligibleForAutoExecution: eligible
        )
    }

    private func record(id: String, sourceID: UUID) -> EvidenceRecord {
        EvidenceRecord(id: id, sourceID: sourceID, snapshotRevision: 2,
                       snapshotFingerprint: String(repeating: "a", count: 64), source: .content,
                       locator: .pdf(page: 1, characterRange: 0..<12), relativePath: nil,
                       excerpt: "招标公告", extractionStatus: .ok,
                       extractorVersion: EvidenceRegistry.extractorVersion, createdAt: .now)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a clean bundle revalidates offline and grants nothing")
    func cleanRoundTrip() throws {
        let profile = try MappingProfile.projectArchive()
        let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000062")!
        let item = manifest(profile: profile, entries: [entry(id: sourceID, evidenceIDs: ["ev_1"])],
                            state: .validated)
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let summary = try ManifestExport.export(manifest: item, evidence: [record(id: "ev_1", sourceID: sourceID)],
                                                to: base)
        let bundle = base.appendingPathComponent(item.envelope.manifestID.sourceKey, isDirectory: true)
        for name in summary.files {
            #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(name).path),
                    "\(name) must be written")
        }
        let revalidation = try ManifestExport.revalidate(at: bundle)
        #expect(revalidation.artifactConsistent, "violations: \(revalidation.violations.map(\.code))")
        #expect(revalidation.digestMismatch.isEmpty)
        #expect(revalidation.grantsExecution == false)
        #expect(revalidation.missingEvidence.isEmpty)
    }

    @Test("editing an exported file is detected by the digest list")
    func tamperingDetected() throws {
        let profile = try MappingProfile.projectArchive()
        let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000063")!
        let item = manifest(profile: profile, entries: [entry(id: sourceID, evidenceIDs: ["ev_1"])],
                            state: .validated)
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try ManifestExport.export(manifest: item, evidence: [record(id: "ev_1", sourceID: sourceID)], to: base)
        let bundle = base.appendingPathComponent(item.envelope.manifestID.sourceKey, isDirectory: true)
        let path = bundle.appendingPathComponent(ManifestExport.exceptionsFile)
        try Data("[]".utf8).write(to: path)
        let revalidation = try ManifestExport.revalidate(at: bundle)
        #expect(revalidation.digestMismatch == [ManifestExport.exceptionsFile])
    }

    @Test("a cited evidence row missing from the bundle is reported")
    func missingEvidenceRow() throws {
        let profile = try MappingProfile.projectArchive()
        let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000064")!
        let item = manifest(profile: profile, entries: [entry(id: sourceID, evidenceIDs: ["ev_1", "ev_absent"])],
                            state: .validated)
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try ManifestExport.export(manifest: item, evidence: [record(id: "ev_1", sourceID: sourceID)], to: base)
        let bundle = base.appendingPathComponent(item.envelope.manifestID.sourceKey, isDirectory: true)
        let revalidation = try ManifestExport.revalidate(at: bundle)
        #expect(revalidation.missingEvidence == ["ev_absent"])
        #expect(!revalidation.artifactConsistent)
    }

    @Test("the shareable copy exists only with a redaction plan and carries no source path")
    func redactedShareIsOptional() throws {
        let profile = try MappingProfile.projectArchive()
        let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000065")!
        let item = manifest(profile: profile, entries: [entry(id: sourceID, evidenceIDs: ["ev_1"])],
                            state: .validated)
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let bundle = base.appendingPathComponent(item.envelope.manifestID.sourceKey, isDirectory: true)

        // One evidence array for both exports. `record` stamps `createdAt` with
        // the current time, so building it twice hands the exporter two
        // different rows claiming the same evidence id - and the exporter is
        // right to refuse that, which is what the next test asserts on purpose.
        let records = [record(id: "ev_1", sourceID: sourceID)]
        _ = try ManifestExport.export(manifest: item, evidence: records, to: base)
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent(ManifestExport.redactedDirectory,
                                                                                      isDirectory: true).path),
                "an unredacted file must never appear under a shareable name")

        let plan = RedactionPlan(terms: ["示例项目_2026": .project], salt: "s")
        _ = try ManifestExport.export(manifest: item, evidence: records, to: base, redaction: plan)
        let shareURL = bundle.appendingPathComponent(ManifestExport.redactedDirectory)
            .appendingPathComponent(ManifestExport.manifestFile)
        let share = String(decoding: try Data(contentsOf: shareURL), as: UTF8.self)
        #expect(share.contains("«项目1»"))
        #expect(!share.contains("示例项目_2026"),
                "the shareable copy must not carry the project name anywhere")
        // The name lives in more than one place - the relative path, the
        // resolved target's group path, the association basis, the projectname
        // field - and redacting only the first is the mistake these assertions
        // prevent. Each carrier is checked where it is written, rather than by
        // counting placeholders, because the number of carriers depends on what
        // the entry happens to carry.
        let shared = try FormaJSON.decode(Manifest.self, from: Data(share.utf8))
        let sharedEntry = try #require(shared.entries.first)
        #expect(!sharedEntry.relativePath.contains("示例项目_2026"),
                "the relative path is redacted: \(sharedEntry.relativePath)")
        #expect(sharedEntry.target.groupPath.allSatisfy { !$0.contains("示例项目_2026") },
                "the group path is redacted: \(sharedEntry.target.groupPath)")
        #expect(sharedEntry.metadata[.projectname].map { !$0.contains("示例项目_2026") } ?? true,
                "the project name field is redacted")
        #expect(sharedEntry.associations.allSatisfy { !$0.basis.contains("示例项目_2026") },
                "the association basis is redacted: \(sharedEntry.associations.map(\.basis))")
        // The local copy keeps the real path: it is the working record, and a
        // redacted working copy would make the bundle useless to its owner.
        let local = String(decoding: try Data(contentsOf: bundle.appendingPathComponent(ManifestExport.manifestFile)),
                           as: UTF8.self)
        #expect(local.contains("示例项目_2026"))
        #expect(!local.contains("«项目"), "the working record keeps the real names")
    }

    @Test("an export never silently replaces different bytes")
    func conflictingRewriteRefused() throws {
        let profile = try MappingProfile.projectArchive()
        let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000066")!
        let item = manifest(profile: profile, entries: [entry(id: sourceID, evidenceIDs: ["ev_1"])],
                            state: .validated)
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let evidence = [record(id: "ev_1", sourceID: sourceID)]
        _ = try ManifestExport.export(manifest: item, evidence: evidence, to: base)
        // Identical bytes again: allowed, nothing is lost.
        _ = try ManifestExport.export(manifest: item, evidence: evidence, to: base)
        // A different revision of the same decision must not overwrite the first.
        var changed = item
        changed.entries[0].state = .hold
        #expect(throws: (any Error).self) {
            try ManifestExport.export(manifest: changed, evidence: evidence, to: base)
        }
    }

    @Test("exceptions list every blocked entry with its program-side reason")
    func exceptionRows() throws {
        let profile = try MappingProfile.projectArchive()
        let held = UUID(uuidString: "00000000-0000-4000-8000-000000000067")!
        var entry = self.entry(id: held, evidenceIDs: [], state: .hold, eligible: false)
        entry.invalidatedReason = "hydration_pending"
        let item = manifest(profile: profile, entries: [entry], state: .partiallyValidated)
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try ManifestExport.export(manifest: item, evidence: [], to: base)
        let bundle = base.appendingPathComponent(item.envelope.manifestID.sourceKey, isDirectory: true)
        let data = try Data(contentsOf: bundle.appendingPathComponent(ManifestExport.exceptionsFile))
        let exceptions = try FormaJSON.decode(ManifestExport.Exceptions.self, from: data)
        #expect(exceptions.rows.count == 1)
        #expect(exceptions.rows[0].reason == "hydration_pending")
        #expect(exceptions.rows[0].state == "hold")
    }

    @Test("reconciling a moved snapshot invalidates only the affected entries")
    func reconcilerScopesInvalidation() throws {
        let profile = try MappingProfile.projectArchive()
        let movedID = UUID(uuidString: "00000000-0000-4000-8000-000000000068")!
        let stableID = UUID(uuidString: "00000000-0000-4000-8000-000000000069")!
        let item = manifest(profile: profile, entries: [entry(id: movedID, evidenceIDs: ["ev_1"]),
                                                         entry(id: stableID, evidenceIDs: ["ev_2"])],
                            state: .validated)
        let scopeID = UUID(uuidString: "00000000-0000-4000-8000-000000000060")!
        func source(_ id: UUID, revision: Int64, fingerprint: String) -> SourceEntry {
            SourceEntry(id: id, rootID: UUID(uuidString: "00000000-0000-4000-8000-000000000061")!,
                        relativePath: "示例项目_2026/01_招标/公告.pdf",
                        normalizedRelativePath: "示例项目_2026/01_招标/公告.pdf", state: .present,
                        hydrationPending: false, sourceVersion: 1, snapshotRevision: revision, provider: .local,
                        snapshotFingerprint: fingerprint, sizeBytes: 10, modificationTimeNanoseconds: 0,
                        sha256: nil)
        }
        let current = [
            source(movedID, revision: 3, fingerprint: String(repeating: "c", count: 64)),
            source(stableID, revision: 2, fingerprint: String(repeating: "a", count: 64)),
        ]
        let context = ProjectContext(revision: 2, scopeID: scopeID, profileID: profile.profileID,
                                     profileVersion: profile.profileVersion,
                                     inputDigest: String(repeating: "1", count: 64), candidates: [],
                                     unassignedSourceIDs: [], conflictedSourceIDs: [], builtAt: .now)
        let decision = ManifestReconciler.decide(manifest: item, currentEntries: current, previousContext: context,
                                                 currentContext: context)
        #expect(decision.invalidatedSourceIDs == [movedID])
        #expect(decision.reason == "snapshot_changed")

        let unchanged = [
            source(movedID, revision: 2, fingerprint: String(repeating: "a", count: 64)),
            source(stableID, revision: 2, fingerprint: String(repeating: "a", count: 64)),
        ]
        let same = ManifestReconciler.decide(manifest: item, currentEntries: unchanged, previousContext: context,
                                            currentContext: context)
        #expect(same.invalidatedSourceIDs.isEmpty)
        #expect(same.reason == "unchanged")
    }
}
