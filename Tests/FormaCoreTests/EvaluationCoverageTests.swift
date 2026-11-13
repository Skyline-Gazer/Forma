import Foundation
import Testing

@testable import FormaCore

/// The coverage census: which scenarios a run measured, beside the ones the
/// split holds, and how a re-issued artifact names the run it came from.
///
/// Everything is synthetic. A pass proves the census is derived from the two
/// sources it claims and that an older artifact still decodes; it says nothing
/// about whether any scenario is adequately covered in a real run.
@Suite("Evaluation coverage")
struct EvaluationCoverageTests {
    private let profileID = ProjectArchiveContract.id

    private func dataset(perCategory: [String: Int], reviewed: Int = 3,
                         ids: [String] = ["g0", "g1", "g2"]) throws -> GoldDataset.Report {
        GoldDataset.Report(datasetRevision: "1.0.0", splitID: "split-a",
                           casePackVersion: try CasePack.shipped().version,
                           totalRecords: reviewed, evaluationRecords: reviewed,
                           countableRecords: reviewed, countableRecordIDs: ids,
                           reviewedCountable: reviewed, pendingAdjudication: 0,
                           perProfileCountable: [profileID: reviewed],
                           perCategoryCountable: perCategory, shortfalls: [],
                           undeclaredOverlaps: [], unaccountedRecords: [],
                           meetsIndependentTarget: reviewed >= GoldDataset.independentTarget,
                           requiredMinimum: GoldDataset.independentTarget)
    }

    private func judgement(_ id: String, category: GoldRecord.Category) throws -> CaseJudgement {
        let gold = try EvaluationFixtures.gold(id, expected: [.completionyear: "2026"], category: category)
        return CaseJudgement(gold: gold, entry: nil)
    }

    private func identity() throws -> EvaluationRunIdentity {
        EvaluationRunIdentity(
            goldRevision: "1.0.0", splitID: "split-a", casePackID: try CasePack.shipped().id,
            casePackVersion: try CasePack.shipped().version, profileVersionKeys: [profileID: "v1"],
            provider: "substitute", modelID: nil, isSubstitute: true,
            bootstrapResamples: 200, bootstrapSeed: 7)
    }

    private func cases(_ count: Int, category: GoldRecord.Category,
                       prefix: String) throws -> [CaseJudgement] {
        try (0..<count).map { try judgement("\(prefix)\($0)", category: category) }
    }

    // MARK: - Census

    @Test("both sides of the census come from their own source")
    func countsComeFromBothSides() throws {
        let dataset = try dataset(perCategory: [GoldRecord.Category.positive.rawValue: 2,
                                                GoldRecord.Category.conflict.rawValue: 1],
                                  reviewed: 3, ids: ["g0", "g1", "c0"])
        let judged = try cases(2, category: .positive, prefix: "g")
            + cases(1, category: .conflict, prefix: "c")
        let coverage = EvaluationCoverage.compute(cases: judged, dataset: dataset)

        let positive = try #require(coverage.cells.first { $0.category == "positive" })
        #expect(positive.countable == 2)
        #expect(positive.evaluated == 2)
        let conflict = try #require(coverage.cells.first { $0.category == "conflict" })
        #expect(conflict.countable == 1)
        #expect(conflict.evaluated == 1)
        // The census is a partition of the cases, not a new population.
        #expect(coverage.cells.reduce(0) { $0 + $1.evaluated } == judged.count)
        #expect(coverage.unreached.isEmpty)
        #expect(coverage.partial.isEmpty)
    }

    @Test("a scenario the split does not count is named, not omitted")
    func untestedScenariosAreNamed() throws {
        let coverage = EvaluationCoverage.compute(
            cases: try cases(1, category: .positive, prefix: "g"),
            dataset: try dataset(perCategory: [GoldRecord.Category.positive.rawValue: 1], reviewed: 1,
                                 ids: ["g0"]))

        #expect(coverage.untested.contains(GoldRecord.Category.refusal.rawValue))
        #expect(coverage.untested.contains(GoldRecord.Category.nearDuplicate.rawValue))
        #expect(!coverage.untested.contains(GoldRecord.Category.positive.rawValue))
        #expect(coverage.cells.count == GoldRecord.Category.allCases.count)
    }

    @Test("a scenario with countable records but no judgement is unreached")
    func unreachedScenarioIsNamed() throws {
        let coverage = EvaluationCoverage.compute(
            cases: try cases(1, category: .positive, prefix: "g"),
            dataset: try dataset(perCategory: [GoldRecord.Category.positive.rawValue: 1,
                                               GoldRecord.Category.templateFamily.rawValue: 2],
                                 reviewed: 3, ids: ["g0", "t0", "t1"]))

        #expect(coverage.unreached == [GoldRecord.Category.templateFamily.rawValue])
        let family = try #require(coverage.cells.first {
            $0.category == GoldRecord.Category.templateFamily.rawValue
        })
        #expect(family.countable == 2)
        #expect(family.evaluated == 0)
    }

    @Test("a scenario with some records judged is partial, with both numbers")
    func partialScenarioIsNamed() throws {
        let coverage = EvaluationCoverage.compute(
            cases: try cases(1, category: .positive, prefix: "g"),
            dataset: try dataset(perCategory: [GoldRecord.Category.positive.rawValue: 3],
                                 reviewed: 3, ids: ["g0", "g1", "g2"]))

        #expect(coverage.partial == [GoldRecord.Category.positive.rawValue])
        #expect(coverage.unreached.isEmpty)
        let positive = try #require(coverage.cells.first { $0.category == "positive" })
        #expect(positive.countable == 3)
        #expect(positive.evaluated == 1)
    }

    @Test("a category key the schema does not declare is reported, not dropped")
    func undeclaredKeyIsReported() throws {
        let coverage = EvaluationCoverage.compute(
            cases: try cases(1, category: .positive, prefix: "g"),
            dataset: try dataset(perCategory: [GoldRecord.Category.positive.rawValue: 1,
                                               "legacy_category": 4],
                                 reviewed: 5, ids: ["g0"]))

        #expect(coverage.undeclared == ["legacy_category"])
        let legacy = try #require(coverage.cells.first { $0.category == "legacy_category" })
        #expect(legacy.countable == 4)
        #expect(legacy.evaluated == 0)
        #expect(coverage.unreached.contains("legacy_category"))
    }

    // MARK: - Artifact

    private func artifact(coverage: EvaluationCoverage?, parentRunID: String?,
                          schemaVersion: String = "1.2") throws -> EvaluationArtifact {
        let judged = try cases(2, category: .positive, prefix: "g")
        let report = EvaluationReport(cases: judged, identity: try identity(),
                                      dataset: try dataset(perCategory: [GoldRecord.Category.positive.rawValue: 2],
                                                           reviewed: 2, ids: ["g0", "g1"]))
        return EvaluationArtifact(
            schemaVersion: schemaVersion, runID: "run-1", identity: try identity(),
            boundary: EvaluationBoundary(datasetRecords: 2, countable: 2, evaluated: 2,
                                         promptSideRecords: 0, withdrawnRecords: 0,
                                         pendingAdjudication: 0, unaccountedRecords: []),
            telemetry: EvaluationTelemetry(
                sampleCount: 2, requestCount: 1, issuedRequestCount: 1, attemptCount: 1,
                providerRequestCount: 1, retryCount: 0, timedOutAttempts: 0, cancelledAttempts: 0,
                succeededRequests: 1, failedRequests: 0, maximumConcurrency: 1, observedConcurrency: 1,
                wallClockMilliseconds: 10, throughputSamplesPerSecond: nil,
                usage: .unavailable, latency: LatencyDistribution(samples: [], kind: .measured),
                firstToken: FirstTokenLatency(samples: [], kind: .unavailable),
                cost: .estimate(usage: .unavailable, pricing: nil, sampleCount: 2), cancelled: false),
            report: report, stages: nil, coverage: coverage, parentRunID: parentRunID)
    }

    @Test("the export carries the census and a declared parent")
    func artifactCarriesCoverageAndLineage() throws {
        let census = EvaluationCoverage.compute(
            cases: try cases(2, category: .positive, prefix: "g"),
            dataset: try dataset(perCategory: [GoldRecord.Category.positive.rawValue: 2],
                                 reviewed: 2, ids: ["g0", "g1"]))
        let data = try FormaJSON.encode(try artifact(coverage: census, parentRunID: "run-0"), pretty: true)
        let decoded = try FormaJSON.decode(EvaluationArtifact.self, from: data)

        #expect(decoded.coverage == census)
        #expect(decoded.parentRunID == "run-0")
        #expect(decoded.schemaVersion == "1.2")
        #expect(String(decoding: data, as: UTF8.self).contains("\"parent_run_id\""))
    }

    @Test("an artifact without a declared parent says so by omission")
    func artifactWithoutLineage() throws {
        let decoded = try FormaJSON.decode(
            EvaluationArtifact.self,
            from: try FormaJSON.encode(try artifact(coverage: nil, parentRunID: nil), pretty: false))
        #expect(decoded.coverage == nil)
        #expect(decoded.parentRunID == nil)
    }

    @Test("a pre-1.2 export still decodes, with no fabricated census")
    func olderExportStillDecodes() throws {
        let encoded = try FormaJSON.encode(try artifact(coverage: nil, parentRunID: nil), pretty: false)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "coverage")
        object.removeValue(forKey: "parent_run_id")
        object["schema_version"] = "1.1"
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try FormaJSON.decode(EvaluationArtifact.self, from: legacy)
        #expect(decoded.schemaVersion == "1.1")
        #expect(decoded.coverage == nil)
        #expect(decoded.parentRunID == nil)
    }
}
