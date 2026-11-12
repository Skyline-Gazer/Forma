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
    /// The ids this suite judges: `withheld` produces `g0...` and the
    /// counter-example batch `nd0...`. Listing them beside the generator is what
    /// lets a test say "one of these is not in the split" without lying about the
    /// rest.
    private var allowedIDs: [String] { (0..<40).map { "g\($0)" } + ["nd0", "nd1"] }

    private func dataset(reviewed: Int, revision: String = "1.0.0", countable: Int? = nil,
                         overlaps: [String] = [], unaccounted: [String] = [], pending: Int = 0,
                         shortfalls: [GoldDataset.Shortfall] = [],
                         allowed: [String]? = nil) throws -> GoldDataset.Report {
        // `casePackVersion` is not a free label here: `GoldDataset.load` fills it from
        // `split.casePack.version`, and the report layer compares the two. `revision`
        // exists so one test can name a different dataset than it judged.
        let pack = try CasePack.shipped()
        return GoldDataset.Report(datasetRevision: revision, splitID: "split-a", casePackVersion: pack.version,
                           totalRecords: reviewed + pending, evaluationRecords: reviewed + pending,
                           countableRecords: countable ?? reviewed,
                           countableRecordIDs: allowed ?? allowedIDs,
                           reviewedCountable: reviewed,
                           pendingAdjudication: pending,
                           perProfileCountable: [ProjectArchiveContract.id: reviewed],
                           perCategoryCountable: [GoldRecord.Category.positive.rawValue: reviewed],
                           shortfalls: shortfalls, undeclaredOverlaps: overlaps, unaccountedRecords: unaccounted,
                           meetsIndependentTarget: reviewed >= GoldDataset.independentTarget,
                           requiredMinimum: GoldDataset.independentTarget)
    }

    private func identity(substitute: Bool, resamples: Int = 200,
                          profiles: [String: String]? = nil) throws -> EvaluationRunIdentity {
        let pack = try CasePack.shipped()
        return EvaluationRunIdentity(goldRevision: "1.0.0", splitID: "split-a", casePackID: pack.id,
                                     casePackVersion: pack.version,
                                     profileVersionKeys: profiles ?? [ProjectArchiveContract.id: "v1"],
                                     provider: substitute ? "substitute" : "provider-x",
                                     modelID: substitute ? nil : "model-1", isSubstitute: substitute,
                                     bootstrapResamples: resamples, bootstrapSeed: 7)
    }

    /// `count` reference answers in `count` separate projects, none of which the
    /// engine answered at all - the cheapest shape that gives a hold rate with a
    /// denominator worth naming. `prefix` keeps a second batch of records distinct,
    /// because reusing ids across batches would trip the duplicate check in
    /// `casesMustComeFromTheCountableSplit` for the wrong reason.
    private func withheld(_ count: Int, category: GoldRecord.Category = .positive,
                          prefix: String = "g") throws -> [CaseJudgement] {
        try (0..<count).map { index in
            CaseJudgement(gold: try EvaluationFixtures.gold("\(prefix)\(index)",
                                                            expected: [.completionyear: "2026"],
                                                            category: category), entry: nil)
        }
    }

    private var healthy: GoldDataset.Report { get throws { try dataset(reviewed: 160) } }

    @Test("a stand-in's numbers cannot be read as model quality")
    func substituteIsRefused() throws {
        let report = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: true),
                                      dataset: try healthy)
        #expect(!report.isQualityClaimAllowed)
        #expect(report.claimBlockers.map(\.kind) == [.substituteAnswers])
        // The run still measures something - it exercises the harness - and the
        // refusal is per number too, so nothing downstream can re-derive a pass.
        #expect(report.slice(.holdRate)?.rate.denominator == 40)
        #expect(!report.isQuotable(.holdRate))

        let real = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                    dataset: try healthy)
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
        let synthetic = try dataset(reviewed: 0, countable: 1_600)
        let report = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                      dataset: synthetic)
        #expect(synthetic.countableRecords == 1_600)
        #expect(!synthetic.meetsIndependentTarget)
        #expect(!report.isQualityClaimAllowed)
        #expect(report.claimBlockers.map(\.kind) == [.insufficientIndependentSamples])

        // One row short of the gate is one row short: the requirement is a count,
        // not a vibe, and rounding it up is how a gate stops being a gate.
        let almost = try dataset(reviewed: GoldDataset.independentTarget - 1)
        let nearReport = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                          dataset: almost)
        #expect(!nearReport.isQualityClaimAllowed)
        #expect(!almost.meetsIndependentTarget)
    }

    @Test("excluded disputes are disclosed without voiding the run")
    func pendingAdjudicationOnlyDiscloses() throws {
        let report = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                      dataset: try dataset(reviewed: 160, pending: 3))
        #expect(report.claimBlockers.map(\.kind) == [.pendingAdjudicationExcluded])
        #expect(report.isQualityClaimAllowed,
                "the run measured what it measured; the exclusion is context, not a defect")
        #expect(report.slice(.holdRate)?.rate.denominator == 40)
    }

    @Test("a leak or an unaccounted file voids the claim")
    func integrityFindingsVoid() throws {
        let leaked = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                      dataset: try dataset(reviewed: 160, overlaps: ["g7~case-3:[prompt]"]))
        #expect(!leaked.isQualityClaimAllowed)
        #expect(leaked.claimBlockers.map(\.kind) == [.undeclaredPromptOverlap])

        let drifting = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                        dataset: try dataset(reviewed: 160, unaccounted: ["g99"]))
        #expect(!drifting.isQualityClaimAllowed)
        #expect(drifting.claimBlockers.map(\.kind) == [.unaccountedRecords])
    }

    @Test("a candidate that should not exist voids the run")
    func eligibilityStateInconsistency() throws {
        // `ManifestExport.revalidate` reports an entry that claims auto-execution
        // while not `validated` as `eligibility_state`; the report layer refuses the
        // same shape instead of measuring it, because `precision_auto` over a
        // manifest the program would not write is not a rate about this program.
        // "g5" is inside `allowedIDs`: this test is about the eligibility shape, and
        // an off-split id would trip the case-set blocker before the one under test.
        let reference = try EvaluationFixtures.gold("g5", expected: [.completionyear: "2026"])
        let parked = EvaluationFixtures.candidate([.completionyear: "2026"], state: .mapped,
                                                  publishable: true, gold: reference)
        let cases = [EvaluationFixtures.judgement(reference, entry: parked)]
        #expect(cases[0].candidateState == .mapped)
        #expect(cases[0].fields.contains { $0.autoPublishable })

        let report = EvaluationReport(cases: cases, identity: try identity(substitute: false),
                                      dataset: try healthy)
        #expect(!report.isQualityClaimAllowed)
        #expect(report.claimBlockers.map(\.kind) == [.eligibilityStateInconsistent])
        // The judgement lives in the report; the measures themselves are unchanged,
        // so a reader can still see what the run computed and why it does not count.
        // Note the pair: the record is in `coverage`'s denominator (one record was
        // judged) but not in `precision_auto`'s, because an entry that is not
        // `validated` is not one the program would auto-map.
        #expect(report.slice(.coverage)?.rate.denominator == 1)
        #expect(report.slice(.precisionAuto)?.rate.denominator == 0)

        let validated = EvaluationFixtures.candidate([.completionyear: "2026"], state: .validated,
                                                     gold: reference)
        let clean = EvaluationReport(cases: [EvaluationFixtures.judgement(reference, entry: validated)],
                                     identity: try identity(substitute: false), dataset: try healthy)
        #expect(clean.claimBlockers.isEmpty)
    }

    @Test("cases have to come out of the split the report names")
    func casesMustComeFromTheCountableSplit() throws {
        // The dataset withholds disputed and withdrawn records from its countable
        // set; a report that never checked which records it was handed would say
        // "disputed records excluded" about a run that included them.
        let leaked = EvaluationReport(cases: try withheld(1, prefix: "leak") + withheld(39),
                                      identity: try identity(substitute: false),
                                      dataset: try dataset(reviewed: 160))
        #expect(leaked.claimBlockers.map(\.kind) == [.caseSetNotDerivedFromSplit])
        #expect(!leaked.isQualityClaimAllowed)
        #expect(leaked.cases == 40, "the measurement is still reported, with the reason it does not count")

        // Judging one record twice rewrites every denominator, so it is the same
        // failure: the numbers are no longer derived from the versioned split.
        var doubled = try withheld(40)
        doubled.append(doubled[0])
        let duplicate = EvaluationReport(cases: doubled, identity: try identity(substitute: false),
                                         dataset: try dataset(reviewed: 160))
        #expect(duplicate.claimBlockers.map(\.kind) == [.caseSetNotDerivedFromSplit])
        #expect(!duplicate.isQualityClaimAllowed)

        // A record still marked `adjudication_pending` is refused even when the id
        // list says it is countable. The disclosure that disputed material stayed out
        // of the denominators cannot rest on the caller having built the id list and
        // the review statuses the same way twice - that is the shape of a check that
        // passes only while nobody is careless.
        let pendingGold = try EvaluationFixtures.gold("g7", expected: [.completionyear: "2026"],
                                                     reviewStatus: .adjudicationPending)
        let pendingCase = EvaluationFixtures.judgement(pendingGold, entry: nil)
        #expect(pendingCase.pendingAdjudication)
        let others = try withheld(39)
        let mixed = EvaluationReport(cases: [pendingCase] + others,
                                     identity: try identity(substitute: false),
                                     dataset: try dataset(reviewed: 160, pending: 1))
        #expect(!mixed.isQualityClaimAllowed)
        #expect(mixed.claimBlockers.map(\.kind).contains(.caseSetNotDerivedFromSplit))
        #expect(mixed.claimBlockers.map(\.kind).contains(.pendingAdjudicationExcluded))
        // The numbers stay visible with the reason they do not count: 40 records were
        // fed in, and the report says so rather than quietly measuring 39.
        #expect(mixed.cases == 40)

        // And the clean path stays clean, including the disclosure row next door:
        // the exclusion is the dataset's doing, and this check is what makes the
        // disclosure mean something.
        let clean = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                     dataset: try dataset(reviewed: 160, pending: 3))
        #expect(clean.claimBlockers.map(\.kind) == [.pendingAdjudicationExcluded])
        #expect(clean.isQualityClaimAllowed)
    }

    @Test("a two-record stratum is refused even inside a clean run")
    func sparseStratumRefusedPerNumber() throws {
        var cases = try withheld(40)
        cases += try withheld(2, category: .nearDuplicate, prefix: "nd")
        let report = EvaluationReport(cases: cases, identity: try identity(substitute: false), dataset: try healthy)
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
        // No record parked a value in an auto-publishable slot, so the measure has
        // no population - and an unobserved measure is not quotable at 0/0, however
        // many records were judged.
        #expect(report.slice(.precisionAuto)?.rate.denominator == 0)
        #expect(report.slice(.precisionAuto)?.caseCount == 42)
        #expect(!report.isQuotable(.precisionAuto))
        // The three measures this run has a population for. The other three never
        // saw a single assertion, so they stay out rather than reporting a zero.
        #expect(report.quotableMeasures == [.coverage, .holdRate, .missedFillRate, .inventedFillRate])
    }

    @Test("the report survives the JSON round trip that stores it")
    func codableRoundTrip() throws {
        let report = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                      dataset: try healthy)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(EvaluationReport.self, from: data)
        #expect(decoded == report)
        #expect(decoded.isQualityClaimAllowed == report.isQualityClaimAllowed)
        #expect(decoded.claimBlockers == report.claimBlockers)
        // Identity has to survive byte-for-byte: two runs whose Profile versions
        // differ are two measurements, and a lost field would merge them.
        #expect(decoded.identity == report.identity)
    }

    @Test("the pending disclosure states both halves of its own claim")
    func pendingDisclosureIsAuditable() throws {
        // The row says disputed records are in no denominator. That is only a fact
        // about this run if the cases actually exclude them, so the row publishes
        // both counts: what the dataset left out, and how many judged records were
        // still disputed. The second is the number nobody had to check before.
        let report = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                      dataset: try dataset(reviewed: 160, pending: 3))
        let row = try #require(report.claimBlockers.first { $0.kind == .pendingAdjudicationExcluded })
        #expect(row.detail.contains("3 条争议记录"))
        #expect(row.detail.contains("40 条记录中有 0 条"))
        #expect(row.detail.contains("已全部排除争议记录"))
        #expect(report.isQualityClaimAllowed, "a disclosure still never vetoes by itself")

        // A runner whose split disagrees with the review states gets the veto from
        // `caseSetNotDerivedFromSplit`, and the disclosure is not allowed to keep
        // claiming the exclusion happened.
        let disputed = try EvaluationFixtures.gold("g0", expected: [.completionyear: "2026"],
                                                   reviewStatus: .adjudicationPending)
        let dirty = EvaluationReport(cases: [EvaluationFixtures.judgement(disputed, entry: nil)],
                                     identity: try identity(substitute: false),
                                     dataset: try dataset(reviewed: 160, pending: 1))
        #expect(!dirty.isQualityClaimAllowed)
        let line = try #require(dirty.claimBlockers.first { $0.kind == .pendingAdjudicationExcluded })
        #expect(line.detail.contains("1 条仍为 adjudication_pending"))
        #expect(!line.detail.contains("已全部排除争议记录"))
        #expect(line.detail.contains("caseSetNotDerivedFromSplit"))

        // The other way to lose the case set: every judged record is confirmed, but
        // one of them was judged twice. `pending` is zero, so a tail that read only
        // that counter would still print "everything disputed is excluded" beside a
        // report refusing any conclusion at all.
        let clean = try withheld(40)
        let doubled = EvaluationReport(cases: clean + [try #require(clean.first)],
                                       identity: try identity(substitute: false),
                                       dataset: try dataset(reviewed: 160, pending: 3))
        #expect(!doubled.isQualityClaimAllowed, "the duplicate is what the veto is about")
        let quiet = try #require(doubled.claimBlockers.first { $0.kind == .pendingAdjudicationExcluded })
        #expect(quiet.detail.contains("0 条仍为 adjudication_pending"))
        #expect(!quiet.detail.contains("已全部排除争议记录"), "no reassurance beside a refusal")
        #expect(quiet.detail.contains("不为排除是否完整作保"))
    }

    @Test("a dataset that misses its quota cells says so without losing the run")
    func quotaShortfallsAreDisclosed() throws {
        let gaps = [GoldDataset.Shortfall(profile: ProjectArchiveContract.id, category: .nearDuplicate,
                                          count: 3, required: GoldDataset.stratumTarget),
                    GoldDataset.Shortfall(profile: VendorLibraryContract.id, category: .templateFamily,
                                          count: 0, required: GoldDataset.stratumTarget)]
        let report = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                      dataset: try dataset(reviewed: 160, shortfalls: gaps))
        let row = try #require(report.claimBlockers.first { $0.kind == .stratumQuotasUnmet })
        #expect(row.detail.contains("2 个 Profile x 类别格"))
        #expect(row.detail.contains("near_duplicate=3"), "the cell is named by its raw value")
        // Disclosure only, for the reason §6 states: the quota cells (2 x every
        // category at 10) cannot all be filled inside a 150-record dataset, and a cell
        // that thin is already uncitable through §5's floor. Refusing here would make
        // the claim unreachable for reasons the sampling plan itself creates.
        #expect(report.isQualityClaimAllowed)
        let clean = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                     dataset: try dataset(reviewed: 160))
        #expect(!clean.claimBlockers.contains { $0.kind == .stratumQuotasUnmet })
    }

    @Test("an identity that describes another dataset loses the claim")
    func identityMustMatchTheDatasetItMeasured() throws {
        // PLAN §8.2 states the gate over provider/model/prompt/schema/dataset
        // revision/split being consistent; the dataset side of that pair is checkable
        // right here, and nowhere else - a judged case carries a record id, not a
        // revision. Without this the layer would happily publish one revision's
        // denominators under another revision's label.
        let clean = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                     dataset: try dataset(reviewed: 160))
        #expect(!clean.claimBlockers.contains { $0.kind == .identityDisagreesWithDataset })
        #expect(clean.isQualityClaimAllowed)

        let mislabelled = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                           dataset: try dataset(reviewed: 160, revision: "1.0.1"))
        #expect(!mislabelled.isQualityClaimAllowed)
        let row = try #require(mislabelled.claimBlockers.first { $0.kind == .identityDisagreesWithDataset })
        #expect(row.detail.contains("goldRevision/datasetRevision"))
        // The numbers survive the veto: the run is reported as measured, it just
        // cannot be quoted as a quality conclusion.
        #expect(mislabelled.slice(.coverage)?.rate.denominator == 40)
    }

    @Test("the run identity is what governs the bands")
    func resamplesComeFromTheRunIdentity() throws {
        // §5's third nil cause is only honest while a reader can tell it apart from
        // "too thin" using the report alone - which requires the published number to
        // be the number that was used. There is no parameter left that could say
        // otherwise, so the two reports below differ in their identity alone.
        let cases = try withheld(40)
        let short = EvaluationReport(cases: cases,
                                     identity: try identity(substitute: false, resamples: 1),
                                     dataset: try dataset(reviewed: 160))
        let coverage = try #require(short.slice(.coverage))
        #expect(coverage.clusterInterval == nil)
        #expect(coverage.clusterCount >= 5, "so thinness is not the reason there is no band")
        #expect(coverage.isQuotableOnOwnMerits, "a missing band is not a missing measurement")
        #expect(short.identity.bootstrapResamples == 1)
        #expect(short.isQuotable(.coverage))

        let long = EvaluationReport(cases: cases,
                                    identity: try identity(substitute: false, resamples: 2_000),
                                    dataset: try dataset(reviewed: 160))
        // Same cases, same clusters, same gate: only the draws differ. A report that
        // ignored the identity would return nil here as well, and the first half
        // above would then have passed for the wrong reason.
        #expect(long.slice(.coverage)?.clusterInterval != nil)
        #expect(long.clusters == short.clusters)
        #expect(long.cases == short.cases)
    }

    @Test("PLAN §8.2's suggestions are published with the gap they measure")
    func targetsCarryTheirOwnGap() throws {
        let report = EvaluationReport(cases: try withheld(40), identity: try identity(substitute: false),
                                      dataset: try dataset(reviewed: 160))
        #expect(report.targets.map(\.measure) == [.precisionAuto, .coverage, .fieldPrecision,
                                                 .highConfidenceErrorRate, .holdRate, .inventedFillRate])
        #expect(report.targets.map(\.suggested) == [0.95, 0.70, 0.98, 0.02, 0.30, 0.0])
        #expect(report.targets.map(\.direction) == [.atLeast, .atLeast, .atLeast, .atMost, .atMost, .atMost])
        for target in report.targets {
            let slice = try #require(report.slice(target.measure))
            #expect(target.actual == slice.rate.estimate)
            #expect(target.population == slice.rate.denominator)
            #expect(target.caseCount == slice.caseCount)
            #expect(target.clusterCount == slice.clusterCount)
            #expect(target.interval == slice.clusterInterval)
            switch (target.direction, target.actual) {
            case (.atLeast, let value?): #expect(target.shortfall == target.suggested - value)
            case (.atMost, let value?): #expect(target.shortfall == value - target.suggested)
            case (_, nil): #expect(target.shortfall == nil)
            }
        }
        // Nothing in this run was answered: the floors are missed by their whole
        // distance, the ceiling on hold rate is passed by 100%. The claim survives
        // regardless, because PLAN §8.2 keeps these as suggestions until the Owner
        // adopts them and the gate is `claimBlockers`, not this table.
        let coverage = try #require(report.targets.first { $0.measure == .coverage })
        #expect(coverage.actual == 0)
        #expect(coverage.shortfall == 0.70)
        #expect(coverage.isMet == false)
        let held = try #require(report.targets.first { $0.measure == .holdRate })
        #expect(held.isMet == false, "a 100% hold rate is over the 30% ceiling")
        #expect(report.isQualityClaimAllowed, "a missed suggestion is not a blocker")
    }

    @Test("a target with no population is not a missed target")
    func targetsWithoutPopulationStayBlank() throws {
        // PLAN §8.2 marks every zero denominator N/A. A run that mixed two Profiles
        // never said which one its files were judged under, so its precision row has
        // no population: it must not arrive as 0% - neither met nor unmet, just not
        // measured - or a reader would see a failed floor where nothing failed.
        let answered = try (0..<40).map { index -> CaseJudgement in
            let gold = try EvaluationFixtures.gold("g\(index)", expected: [.completionyear: "2026"])
            return EvaluationFixtures.judgement(
                gold, entry: EvaluationFixtures.candidate([.completionyear: "2026"], gold: gold))
        }
        let single = EvaluationReport(cases: answered, identity: try identity(substitute: false),
                                      dataset: try healthy)
        let named = try #require(single.targets.first { $0.measure == .precisionAuto })
        #expect(named.actual != nil, "one Profile named: the row has a population")
        #expect(named.actual == single.slice(.precisionAuto)?.rate.estimate)

        let mixed = EvaluationReport(
            cases: answered,
            identity: try identity(substitute: false,
                                   profiles: [ProjectArchiveContract.id: "v1", VendorLibraryContract.id: "v1"]),
            dataset: try healthy)
        let blank = try #require(mixed.targets.first { $0.measure == .precisionAuto })
        #expect(blank.actual == nil, "N/A, not 0%")
        #expect(blank.shortfall == nil)
        #expect(blank.isMet == nil, "an unmeasurable row cannot fail a floor")
        #expect(blank.population == 0, "nothing was evaluable as correct-or-wrong")
        #expect(blank.caseCount == 40, "and the gap between the two is the disclosure")
        // The per-Profile cuts still carry the number, which is why the row is blank
        // rather than the run being silent.
        #expect(mixed.slice(.precisionAuto, stratum: .profile, key: ProjectArchiveContract.id)?.rate.estimate != nil)
        #expect(mixed.isQualityClaimAllowed)
    }
}
