import Foundation
import Testing

@testable import FormaCore

/// Slice 4 of the approved Contract Delta (ELIGIBILITY-CONTRACT-DELTA §5.4,
/// SPEC v0.1.2 §10.1-5): the eligibility decision produces a report a person
/// can act on — how many records were discovered, how many entered Mapping,
/// and per record why the rest did not — plus the capability to export it
/// without leaking the directory it describes.
@Suite("Eligibility report")
struct EligibilityReportTests {
    private let rootID = UUID(uuidString: "00000000-0000-4000-8000-0000000000F4")!
    private let scopeID = UUID(uuidString: "00000000-0000-4000-8000-000000000013")!

    private func entry(_ path: String, id: UUID? = nil) -> SourceEntry {
        SourceEntry(id: id ?? UUID(), rootID: rootID, relativePath: path,
                    normalizedRelativePath: path.lowercased(), state: .present,
                    hydrationPending: false, sourceVersion: 1, snapshotRevision: 1,
                    provider: .local, snapshotFingerprint: String(repeating: "a", count: 64),
                    sizeBytes: 10, modificationTimeNanoseconds: 0, sha256: nil)
    }

    private func profile() throws -> MappingProfile { try MappingProfile.projectArchive() }

    private func listing(_ entries: [SourceEntry]) -> SourceListing {
        SourceListing(scope: SourceScope(id: scopeID, rootID: rootID, relativePath: "",
                                         displayName: "Synthetic"),
                      scanID: UUID(), state: .complete, entries: entries, issues: [], statistics: nil)
    }

    private func view(_ entries: [SourceEntry]) throws -> EligibilityView {
        EligibilityViewBuilder.build(EligibilityViewRequest(
            listing: listing(entries), profile: try profile(), policy: try EligibilityPolicy.shipped(),
            kind: .simulated))
    }

    // MARK: - Content

    @Test("the report names what was held back, and why")
    func reportExplainsWhatWasHeldBack() throws {
        let business = entry("Project/公告.pdf")
        let noise = entry("Project/.DS_Store")
        let built = try view([business, noise])
        let report = built.report(mappedSourceIDs: [business.id])
        #expect(report.discovered == 2)
        #expect(report.mapped == 1)
        #expect(report.unmapped == 1)
        #expect(report.isConserved)
        let held = try #require(report.records.first { !$0.mapped })
        #expect(held.sourceID == noise.id)
        #expect(held.decision == .exclude)
        #expect(held.decidedByRuleID == "technical-noise-ds-store")
        #expect(held.explanationCode == "technical_noise_ds_store")
        #expect(report.perDecision["EXCLUDE"] == 1)
        #expect(report.perDecision["INCLUDE"] == 1)
        #expect(report.perRule["technical-noise-ds-store"] == 1)
    }

    @Test("every discovered record is accounted for exactly once")
    func reportCountsConserve() throws {
        let entries = [entry("A/one.pdf"), entry("A/.DS_Store"), entry("vendor/two.pdf"),
                       entry("build/three.docx"), entry("B/four.xlsx")]
        let built = try view(entries)
        let report = built.report(mappedSourceIDs: Set(built.mappingCandidates().map(\.id)))
        #expect(report.records.count == entries.count)
        #expect(report.discovered == report.records.count)
        #expect(report.mapped + report.unmapped == report.discovered)
        #expect(report.perDecision.values.reduce(0, +) == report.discovered)
        #expect(report.perRule.values.reduce(0, +) == report.discovered)
        #expect(report.mapped == built.mappingCandidates().count)
    }

    @Test("the report carries no path or file name")
    func reportIsPathFree() throws {
        let built = try view([entry("客户名称/技术标.docx"), entry("客户名称/.DS_Store")])
        let report = built.report(mappedSourceIDs: [])
        let data = try FormaJSON.encode(report)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("客户名称"))
        #expect(!text.contains(".DS_Store"))
        #expect(!text.contains(".docx"))
        // The identities it may carry are ids and rule names, nothing else.
        #expect(text.contains("technical-noise-ds-store"))
    }

    // MARK: - Export

    @Test("export writes once, reports the digest, and refuses different bytes")
    func exportWritesOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forma-eligibility-report-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try view([entry("Project/公告.pdf"), entry("Project/.DS_Store")])
        let report = built.report(mappedSourceIDs: [])
        let written = try EligibilityReportExport.write(report, to: directory)
        #expect(written.bytes > 0)
        #expect(written.sha256.count == 64)
        let url = directory.appendingPathComponent(EligibilityReportExport.reportFile)
        #expect(try Data(contentsOf: url) == FormaJSON.encode(report, pretty: true))
        // Rewriting identical bytes is harmless; different bytes are refused.
        _ = try EligibilityReportExport.write(report, to: directory)
        let different = built.report(mappedSourceIDs: Set(built.mappingCandidates().map(\.id)))
        #expect(throws: FormaError.self) { try EligibilityReportExport.write(different, to: directory) }
    }

    // MARK: - The run

    @Test("a filtered run carries its report; a full-listing run does not")
    func engineOutcomeCarriesTheReport() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        try fixture.write("示例项目 招标公告 2026 公告", at: "示例项目_2026/01_招标/公告.pdf")
        try fixture.write("", at: "示例项目_2026/01_招标/.DS_Store")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let listing = try await workspace.scan(scope)
        let selected = try profile()
        let profileView = EligibilityViewBuilder.build(EligibilityViewRequest(
            listing: listing, profile: selected, policy: try EligibilityPolicy.shipped(), kind: .simulated))
        let selection = profileView.selection
        #expect(selection.view.mappingCandidates().count == 1, "the noise record must not be a candidate")
        let context = try await workspace.buildContext(scope: scope, profile: selected, eligibility: selection)
        let answerer = FakeAnswerer { batch, _ in
            MappingAttempt(proposal: decodedProposal(proposalText(batch: batch)), modelID: "fake-model", requests: 1)
        }
        let engine = MappingEngine(profile: selected, casePack: try CasePack.shipped(),
                                   answerer: answerer, workspace: workspace)
        let filtered = await engine.run(MappingRunRequest(
            scope: scope, profile: selected, context: context, entries: listing.entries, evidence: [:],
            provider: .anthropic, model: "fake", allowCloud: true, eligibility: selection))
        let report = try #require(filtered.eligibilityReport)
        #expect(report.discovered == listing.entries.count)
        #expect(report.mapped == 1)
        #expect(report.unmapped == listing.entries.count - 1)
        #expect(report.isConserved)
        #expect(filtered.manifest.envelope.eligibility?.unmappedCount == report.unmapped)

        let fullContext = try await workspace.buildContext(scope: scope, profile: selected)
        let full = await engine.run(MappingRunRequest(
            scope: scope, profile: selected, context: fullContext, entries: listing.entries, evidence: [:],
            provider: .anthropic, model: "fake", allowCloud: true))
        #expect(full.eligibilityReport == nil)
        #expect(full.manifest.envelope.eligibility == nil)
    }
}
