import Foundation
import Testing

@testable import FormaCore

/// Who is allowed to say what about a measurement.
///
/// The rates themselves are computed elsewhere; this suite guards the gate in
/// front of them, because a run on synthetic rows or against a stand-in produces
/// perfectly well-formed numbers that mean nothing about any model. Without
/// these, the first honest-looking percentage in a summary becomes a claim about
/// product quality.
@Suite("Evaluation report claims")
struct EvaluationReportTests {
    private func dataset(reviewed: Int, countable: Int? = nil, overlaps: [String] = [],
                         unaccounted: [String] = [], pending: Int = 0) -> GoldDataset.Report {
        GoldDataset.Report(datasetRevision: "1.0.0", splitID: "split-a", casePackVersion: "1.0.0",
                           totalRecords: reviewed + pending, evaluationRecords: reviewed + pending,
                           countableRecords: countable ?? reviewed, reviewedCountable: reviewed,
                           pendingAdjudication: pending,
                           perProfileCountable: [ProjectArchiveContract.id: reviewed],
                           perCategoryCountable: [GoldRecord.Category.positive.rawValue: reviewed],
                           shortfalls: [], undeclaredOverlaps: overlaps, unaccountedRecords: unaccounted,
                           meetsIndependentTarget: reviewed >= GoldDataset.independentTarget,
                           requiredMinimum: GoldDataset.independentTarget)
    }

    private func identity(substitute: Bool) throws -> EvaluationRunIdentity {
        let pack = try CasePack.shipped()
        return EvaluationRunIdentity(goldRevision: "1.0.0", splitID: "split-a", casePackID: pack.id,
                                     casePackVersion: pack.version,
                                     profileVersionKeys: [ProjectArchiveContract.id: "v1"],
                                     provider: substitute ? "substitute" : "provider-x",
                                     modelID: substitute ? nil : "model-1", isSubstitute: substitute,
                                     bootstrapResamples: 200, bootstrapSeed: 7)
    }

    /// `count` reference answers in `count` separate projects, none of which the
    /// engine answered at all - the cheapest shape that gives a hold rate with a
    /// denominator worth naming.
    private func withheld(_ count: Int, category: GoldRecord.Category = .positive) throws -> [CaseJudgement] {
        try (0..<count).map { index in
            CaseJudgement(gold: try EvaluationFixtures.gold("g\(index)", expected: [.completionyear: "2026"],
                                                        category: category), entry: nil)
        }
    }

    private var healthy: GoldDataset.Report { dataset(reviewed: 160) }

    @Test("a stand-in's numbers cannot be read as model quality")
    func substituteIsRefused() throws {
        let report = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: true),
                                      dataset: healthy)
        #expect(!report.isQualityClaimAllowed)
        #expect(report.claimBlockers.map(\.kind) == [.substituteAnswers])
        // The run still measures something - it exercises the harness - and the
        // refusal is per number too, so nothing downstream can re-derive a pass.
        #expect(report.slice(.holdRate)?.rate.denominator == 40)
        #expect(!report.isQuotable(.holdRate))

        let real = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                    dataset: healthy)
        #expect(real.isQualityClaimAllowed)
        #expect(real.claimBlockers.isEmpty)
    }

    @Test("sixteen hundred synthetic rows are still not one hundred and fifty verified ones")
    func thinSampleIsRefused() throws {
        // The substitute is gone and the run is dense; the only thing missing is
        // independent verification of real material, which is exactly the
        // condition a report would most like to gloss over.
        // Sixteen hundred rows the harness can score, none of them independently
        // verified: the denominators are real, the authority is not.
        let synthetic = dataset(reviewed: 0, countable: 1_600)
        let report = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                      dataset: synthetic)
        #expect(synthetic.countableRecords == 1_600)
        #expect(!synthetic.meetsIndependentTarget)
        #expect(!report.isQualityClaimAllowed)
        #expect(report.claimBlockers.map(\.kind) == [.insufficientIndependentSamples])

        // One row short of the gate is one row short: the requirement is a count,
        // not a vibe, and rounding it up is how a gate stops being a gate.
        let almost = dataset(reviewed: GoldDataset.independentTarget - 1)
        let nearReport = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                          dataset: almost)
        #expect(!nearReport.isQualityClaimAllowed)
        #expect(!almost.meetsIndependentTarget)
    }

    @Test("excluded disputes are disclosed without voiding the run")
    func pendingAdjudicationOnlyDiscloses() throws {
        let report = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                      dataset: dataset(reviewed: 160, pending: 3))
        #expect(report.claimBlockers.map(\.kind) == [.pendingAdjudicationExcluded])
        #expect(report.isQualityClaimAllowed,
                "the run measured what it measured; the exclusion is context, not a defect")
        #expect(report.slice(.holdRate)?.rate.denominator == 40)
    }

    @Test("a leak or an unaccounted file voids the claim")
    func integrityFindingsVoid() throws {
        let leaked = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                      dataset: dataset(reviewed: 160, overlaps: ["g7~case-3:[prompt]"]))
        #expect(!leaked.isQualityClaimAllowed)
        #expect(leaked.claimBlockers.map(\.kind) == [.undeclaredPromptOverlap])

        let drifting = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                        dataset: dataset(reviewed: 160, unaccounted: ["g99"]))
        #expect(!drifting.isQualityClaimAllowed)
        #expect(drifting.claimBlockers.map(\.kind) == [.unaccountedRecords])
    }

    @Test("a candidate that should not exist voids the run")
    func eligibilityStateInconsistency() throws {
        // `ManifestExport.revalidate` reports an entry that claims auto-execution
        // while not `validated` as `eligibility_state`; the report layer refuses the
        // same shape instead of measuring it, because `precision_auto` over a
        // manifest the program would not write is not a rate about this program.
        let reference = try EvaluationFixtures.gold("x1", expected: [.completionyear: "2026"])
        let parked = EvaluationFixtures.candidate([.completionyear: "2026"], state: .mapped,
                                                  publishable: true, gold: reference)
        let cases = [CaseJudgement(gold: reference, entry: parked)]
        #expect(cases[0].candidateState == .mapped)
        #expect(cases[0].fields.contains { $0.autoPublishable })

        let report = EvaluationReport(cases: cases, identity: try identity(substitute: false),
                                      dataset: healthy)
        #expect(!report.isQualityClaimAllowed)
        #expect(report.claimBlockers.map(\.kind) == [.eligibilityStateInconsistent])
        // The judgement lives in the report; the measure itself is unchanged, so a
        // reader can still see what the run computed and why it does not count.
        #expect(report.slice(.precisionAuto)?.rate.denominator == 1)

        let validated = EvaluationFixtures.candidate([.completionyear: "2026"], state: .validated,
                                                     gold: reference)
        let clean = EvaluationReport(cases: [CaseJudgement(gold: reference, entry: validated)],
                                     identity: try identity(substitute: false), dataset: healthy)
        #expect(clean.claimBlockers.isEmpty)
    }

    @Test("a two-record stratum is refused even inside a clean run")
    func sparseStratumRefusedPerNumber() throws {
        var cases = try withheld(40)
        cases += try withheld(2, category: .nearDuplicate)
        let report = EvaluationReport(cases: cases, identity: try identity(substitute: false), dataset: healthy)
        #expect(report.isQualityClaimAllowed)

        // Overall: 42 expected slots, quotable. The counter-example category:
        // two, candidate only - and a category row is precisely where a summary
        // tends to quote the flattering number.
        #expect(report.isQuotable(.holdRate))
        let category = GoldRecord.Category.nearDuplicate.rawValue
        #expect(report.slice(.holdRate, stratum: .category, key: category)?.rate.denominator == 2)
        #expect(!report.isQuotable(.holdRate, stratum: .category, key: category))
        // Coverage IS quotable here, at 0%: the engine was asked about 42 slots
        // and answered none, which is a real measurement of a bad run. What is not
        // quotable is a measure with no population at all - `precision_auto` never
        // saw an auto-publishable assertion, so it has no denominator to quote.
        let coverage = report.slice(.coverage)
        #expect(coverage?.rate.denominator == 42)
        #expect(coverage?.rate.estimate == 0)
        #expect(report.isQuotable(.coverage))
        #expect(report.slice(.precisionAuto)?.rate.isSparse == true)
        #expect(!report.isQuotable(.precisionAuto))
        // The three measures this run has a population for. The other three never
        // saw a single assertion, so they stay out rather than reporting a zero.
        #expect(report.quotableMeasures == [.coverage, .holdRate, .inventedFillRate])
    }

    @Test("the report survives the JSON round trip that stores it")
    func codableRoundTrip() throws {
        let report = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                      dataset: healthy)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(EvaluationReport.self, from: data)
        #expect(decoded == report)
        #expect(decoded.isQualityClaimAllowed == report.isQualityClaimAllowed)
        #expect(decoded.claimBlockers == report.claimBlockers)
        // Identity has to survive byte-for-byte: two runs whose Profile versions
        // differ are two measurements, and a lost field would merge them.
        #expect(decoded.identity == report.identity)
    }
}
