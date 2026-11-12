import Foundation
import Testing

@testable import FormaCore

/// One scanned file, its body evidence registered, and a stored manifest that
/// cites rows the registry can resolve - the smallest state in which a reviewer
/// decision can be judged end to end.
///
/// Shared by the suites that need a live workspace rather than an engine call: a
/// second copy of this builder would drift from the first the moment the manifest
/// envelope or the snapshot binding rule changes.
struct MappingContext {
    let fixture: SourceFixture
    let workspace: SourceWorkspace
    let scope: SourceScope
    let profile: MappingProfile
    let manifest: Manifest
    let sourceID: UUID
    let yearRow: String
    /// The registered body rows of the entry's current snapshot, so a test can
    /// cite more than one without re-deriving the registry.
    let rows: [EvidenceRecord]
    let entry: SourceEntry
}

func preparedMapping() async throws -> MappingContext {
    let fixture = try SourceFixture()
    // A real PDF, because a correction has to cite body evidence: text under a
    // `.pdf` name yields no content rows, and the test would then be judging a
    // citation to a filename.
    let body = try makePDF(["示例项目_2026 招标公告 归档完成 2027 年"])
    let url = fixture.root.appendingPathComponent("示例项目_2026/01_招标/公告.pdf")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try body.write(to: url)
    let workspace = try SourceWorkspace(databaseURL: fixture.database)
    let scope = try await workspace.register(fixture.root)
    let listing = try await workspace.scan(scope)
    let profile = try MappingProfile.projectArchive()
    // The context a manifest was decided from has to exist in the store, because
    // that is the context the correction is revalidated against. Building it here
    // is what makes the fixture describe a real revision instead of inventing one.
    let context = try await workspace.buildContext(scope: scope, profile: profile)
    let registered = try await workspace.captureEvidence(for: listing.entries)
    // Re-read the listing after capturing: registering a body can advance the
    // snapshot revision, and a manifest built from the pre-capture revision would
    // be blocked by its own snapshot binding before the correction is judged.
    let current = try await workspace.scan(scope)
    let entry = try #require(current.entries.first)
    let rows = (registered[entry.id] ?? []).filter { $0.snapshotRevision == entry.snapshotRevision }
    // The body says 2027; the stored manifest claims 2026. That is the mistake a
    // reviewer corrects, and the row that supports the fix.
    let year = try #require(rows.first { ($0.excerpt ?? "").contains("2027") && $0.isUsable })
    let category = try #require(rows.first { ($0.excerpt ?? "").contains("招标") && $0.isUsable })

    var metadata = MetadataValues.allUnknown
    metadata[.documentcategory] = "01_招标文件"
    metadata[.projectname] = "示例项目_2026"
    metadata[.completionyear] = "2026"
    var fields: [FieldOutcome] = []
    for field in MetadataFieldID.allCases {
        let value = metadata[field]
        let citations: [String]
        switch field {
        case .documentcategory: citations = [category.id]
        case .completionyear: citations = [year.id]
        default: citations = []
        }
        fields.append(FieldOutcome(field: field, value: value,
                                   status: value == nil ? .unknown : .evidenced,
                                   evidenceIDs: citations))
    }
    let manifest = Manifest(
        envelope: ManifestEnvelope(
            manifestID: UUID(), revision: 1, supersedesRevision: nil, scopeID: scope.id,
            sourceRootID: scope.rootID, profile: profile,
            casePack: ("forma-governance-cases", "1.0"), modelProvider: "anthropic",
            modelID: "fake", contextRevision: context.revision, promptVersion: MappingPrompt.version,
            extractorVersion: EvidenceRegistry.extractorVersion, redactionVersion: nil,
            inputDigest: context.inputDigest, contextDigest: MappingEngine.contextDigest(context),
            createdAt: .now, state: .draft
        ),
        entries: [ManifestEntry(
            sourceID: entry.id, snapshotFingerprint: entry.snapshotFingerprint,
            snapshotRevision: Int(entry.snapshotRevision), sourceVersion: Int(entry.sourceVersion),
            relativePath: entry.relativePath, state: .validated,
            target: ManifestTarget(databaseName: "Project_Archive",
                                   groupPath: ["2026", "示例项目_2026", "01_招标文件"], resolved: true),
            metadata: metadata, fields: fields, associations: [],
            eligibleForAutoExecution: false, invalidatedReason: nil, confidence: .medium,
            providerReasoning: nil
        )]
    )
    let stored = try await workspace.saveManifest(manifest, scopeID: scope.id)
    return MappingContext(fixture: fixture, workspace: workspace, scope: scope, profile: profile,
                          manifest: stored, sourceID: entry.id, yearRow: year.id, rows: rows, entry: entry)
}
