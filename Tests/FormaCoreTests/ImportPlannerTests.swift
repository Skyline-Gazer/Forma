import Foundation
import Testing

@testable import FormaCore

/// The Alpha dry run has one job: tell a person what an import would target and
/// why it cannot run, without ever claiming an observation it did not make.
@Suite("Import plan (dry run)")
struct ImportPlannerTests {
    private func plan(entries: [ManifestEntry],
                      authorization: ImportAuthorization? = nil,
                      capability: ImportCapabilityFacts = .init(writeToolsAvailable: false,
                                                                 readbackAvailable: false),
                      targetObserved: Bool = false,
                      listing: SourceListing? = nil) throws -> ImportPlan {
        let profile = try MappingProfile.projectArchive()
        var envelope = try ImportFixtures.manifest(revision: 1)
        envelope.state = .validated
        let manifest = Manifest(envelope: envelope, entries: entries)
        return ImportPlanner.plan(manifest: manifest, profile: profile,
                                  observations: ImportPlanner.Observations(sourceRoot: nil, listing: listing),
                                  authorization: authorization, capability: capability,
                                  targetObserved: targetObserved, now: ImportFixtures.now)
    }

    @Test("a plan with no authorization and no write capability is dry by construction")
    func planIsDryByConstruction() throws {
        let entry = ImportFixtures.entry(sourceID: UUID())
        let result = try plan(entries: [entry])

        // No write path exists in this build, stated as data rather than as a
        // disabled button.
        #expect(result.writesInThisBuild == false)
        #expect(result.targetObserved == false)
        #expect(result.rows.count == 1)

        let row = try #require(result.rows.first)
        #expect(row.verdict == .blocked)
        // The only honest reason: nothing authorized this write. A plan may not
        // invent an authorization to look healthier.
        #expect(row.codes == [.authorizationMissing])
        #expect(result.passes == 0)
    }

    @Test("an unobserved target is unresolved, never missing or not writable")
    func unobservedTargetIsUnresolved() throws {
        let entry = ImportFixtures.entry(sourceID: UUID())
        // With an authorization present the preflight reaches the target checks,
        // which is exactly where a dry run could overstate what it knows.
        let result = try plan(entries: [entry], authorization: ImportFixtures.authorization(),
                              capability: .init(writeToolsAvailable: true, readbackAvailable: true),
                              targetObserved: false)

        let row = try #require(result.rows.first)
        #expect(row.codes.contains(.targetUnresolved))
        #expect(!row.codes.contains(.targetMissing))
        #expect(!row.codes.contains(.targetNotWritable))
        #expect(row.verdict == .blocked)
    }

    @Test("observed target facts keep their original meaning")
    func observedTargetStillReportsMissing() throws {
        let entry = ImportFixtures.entry(sourceID: UUID())
        let profile = try MappingProfile.projectArchive()
        var envelope = try ImportFixtures.manifest(revision: 1)
        envelope.state = .validated
        let input = ImportPreflightInput(
            entry: entry, manifest: envelope,
            expectations: ImportExpectations(profileID: profile.profileID,
                                            profileVersion: profile.profileVersion,
                                            schemaVersion: envelope.schemaVersion),
            authorization: ImportFixtures.authorization(),
            source: ImportSourceFacts(state: .present, authorized: true, readable: true,
                                      hydrationPending: false,
                                      snapshotFingerprint: entry.snapshotFingerprint, sha256: nil),
            // observed defaults to true: existing callers are unaffected.
            target: ImportTargetFacts(exists: false, writable: false),
            capability: .init(writeToolsAvailable: true, readbackAvailable: true),
            expectedSHA256: nil, now: ImportFixtures.now)
        let clearance = ImportPreflight.evaluate(input)
        #expect(clearance.failures.map(\.code).contains(.targetMissing))
        #expect(clearance.failures.map(\.code).contains(.targetNotWritable))
    }

    @Test("a record the last scan never saw is reported as missing, not as present")
    func unscannedRecordIsMissing() throws {
        let entry = ImportFixtures.entry(sourceID: UUID())
        let result = try plan(entries: [entry], authorization: ImportFixtures.authorization(),
                              capability: .init(writeToolsAvailable: true, readbackAvailable: true),
                              targetObserved: true)

        let row = try #require(result.rows.first)
        // No listing entry means the plan cannot vouch for the source, so it says
        // so instead of assuming the manifest is still current.
        #expect(row.codes.contains(.sourceMissing))
        #expect(row.codes.contains(.sourceUnauthorized))
    }

    @Test("the plan counts every reason so a person can read why nothing runs")
    func codeCountsExplainBlocking() throws {
        let first = ImportFixtures.entry(sourceID: UUID())
        let second = ImportFixtures.entry(sourceID: UUID())
        let result = try plan(entries: [first, second], authorization: ImportFixtures.authorization(),
                              capability: .init(writeToolsAvailable: false, readbackAvailable: false),
                              targetObserved: true)

        #expect(result.rows.count == 2)
        #expect(result.blocked == 2)
        let codes = result.codeCounts.map(\.code)
        #expect(codes.contains(.capabilityMissing))
        // Two rows, one shared reason: the count says so rather than repeating a
        // per-row list.
        #expect(result.codeCounts.first { $0.code == .capabilityMissing }?.count == 2)
    }

    @Test("the exported plan says it is a dry run and not an authorization")
    func exportCarriesDryRunContract() throws {
        let entry = ImportFixtures.entry(sourceID: UUID())
        let result = try plan(entries: [entry])

        let data = try FormaJSON.encoder(pretty: true).encode(result)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // A constant computed property is not evidence in a file: these keys must
        // physically be in the JSON someone reviews.
        #expect(object["dry_run"] as? Bool == true)
        #expect(object["writes_executed"] as? Bool == false)
        #expect(object["authorization_granted"] as? Bool == false)
        #expect((object["purpose"] as? String)?.contains("not an execution authorization") == true)
        #expect(object["schema_version"] as? String == ImportPlan.artifactSchemaVersion)
        #expect(object["manifest_revision"] as? Int == 1)
        #expect(object["target_observed"] as? Bool == false)
        #expect(object["source_observation"] as? String == "manifest only")

        // And it round-trips: the reader on the other machine can decode it.
        let decoded = try FormaJSON.decoder().decode(ImportPlan.self, from: data)
        #expect(decoded.rows.count == result.rows.count)
        #expect(decoded.manifestRevision == result.manifestRevision)
    }

    @Test("a plan that claims an execution is refused instead of trusted")
    func refusesPlanClaimingExecution() throws {
        let forged = Data("""
        {"schema_version":"1.0","dry_run":false,"writes_executed":true,
         "authorization_granted":false,"purpose":"x","manifest_revision":1,
         "manifest_schema_version":"1.0","profile_id":"p","source_observation":"scan",
         "target_observed":false,"generated_at":"2027-01-01T00:00:00Z","rows":[]}
        """.utf8)
        #expect(throws: FormaError.self) {
            _ = try FormaJSON.decoder().decode(ImportPlan.self, from: forged)
        }
    }

    @Test("a plan that is not this artifact is refused")
    func refusesPlansThatAreNotDryRunArtifacts() throws {
        // A file that claims it executed, is not a dry run, uses another schema
        // or states another purpose is not something this reader understands.
        // Each case is refused rather than repaired.
        let base = """
        {"schema_version":"1.0","dry_run":true,"writes_executed":false,
         "authorization_granted":false,"purpose":"review-only plan; not an execution authorization",
         "manifest_revision":1,"manifest_schema_version":"1.0","profile_id":"p",
         "source_observation":"scan","target_observed":false,
         "generated_at":"2027-01-01T00:00:00Z","rows":[]}
        """
        let variants: [String] = [
            base.replacingOccurrences(of: "\"dry_run\":true", with: "\"dry_run\":false"),
            base.replacingOccurrences(of: "\"schema_version\":\"1.0\"", with: "\"schema_version\":\"2.0\""),
            base.replacingOccurrences(of: "not an execution authorization", with: "authorized to import"),
            base.replacingOccurrences(of: "\"dry_run\":true,", with: ""),
        ]
        for variant in variants {
            #expect(throws: FormaError.self) {
                _ = try FormaJSON.decoder().decode(ImportPlan.self, from: Data(variant.utf8))
            }
        }
    }
}
