import Foundation
import Testing

@testable import FormaCore

/// The measurement definitions.
///
/// Each rate here is a denominator somebody will quote in a decision, so these
/// tests pin the populations rather than arithmetic: which slots a measure is
/// allowed to see is the part that changes a conclusion without changing a line
/// of output.
@Suite("Evaluation metrics")
struct EvaluationMetricsTests {
    /// All twelve slots have to be present. Assigning `nil` into a
    /// `[Key: String?]` removes the key instead of storing a null, which is the
    /// trap the same helper fell into in `GoldDatasetTests`.
    private func rate(_ measure: EvaluationMeasure, _ cases: [CaseJudgement]) -> EvaluationRate {
        var numerator = 0
        var denominator = 0
        for judgement in cases {
            let population = measure.population(in: judgement)
            numerator += population.numerator
            denominator += population.denominator
        }
        return EvaluationRate(numerator: numerator, denominator: denominator)
    }

    @Test("coverage sees only the slots the answer expects, and not a contradicted one")
    func coveragePopulation() throws {
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026", .department: "采购部"])
        let answered = EvaluationFixtures.candidate([.completionyear: "2026", .department: "采购部"], conflicted: [.department], gold: reference)
        let judgement = CaseJudgement(gold: reference, entry: answered)

        let measured = rate(.coverage, [judgement])
        // Two expected slots; the contradicted one is outside the numerator, and
        // both still count in the denominator - a contradiction is a claim the
        // engine made, and coverage that ignored it would report reach it lacks.
        // (The conflict note has to be four characters or longer: `Bounded.text`
        // discards shorter values as carrying no information.)
        #expect(measured.denominator == 2)
        #expect(measured.numerator == 1)
        #expect(judgement.fields.first { $0.field == .department }?.verdict == .contradicted)
    }

    @Test("precision_auto is restricted to what the program would publish")
    func precisionAutoPopulation() throws {
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026", .department: "采购部"])
        let entry = EvaluationFixtures.candidate([.completionyear: "2026", .department: "错的"], status: .inherited,
                              publishable: false, gold: reference)
        let judgement = CaseJudgement(gold: reference, entry: entry)

        // Not eligible for auto execution, so neither slot enters the population:
        // quoting a precision for publishes that would never happen is how a
        // measurement ends up describing a path the app does not take.
        #expect(rate(.precisionAuto, [judgement]).denominator == 0)
        #expect(judgement.fields.allSatisfy { !$0.autoPublishable })

        let publishable = CaseJudgement(gold: reference,
                                        entry: EvaluationFixtures.candidate([.completionyear: "2026", .department: "错的"],
                                                         gold: reference))
        let measured = rate(.precisionAuto, [publishable])
        #expect(measured.denominator == 2)
        #expect(measured.numerator == 1)
    }

    @Test("high confidence errors are the wrong-but-confident share")
    func highConfidenceError() throws {
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026", .department: "采购部"])
        let judgement = CaseJudgement(gold: reference,
                                      entry: EvaluationFixtures.candidate([.completionyear: "2026", .department: "错的"],
                                                       gold: reference))
        let measured = rate(.highConfidenceErrorRate, [judgement])
        #expect(measured.numerator == 1)
        #expect(measured.denominator == 2)
        #expect(measured.estimate == 0.5)

        let modest = CaseJudgement(gold: reference,
                                   entry: EvaluationFixtures.candidate([.completionyear: "2026", .department: "错的"],
                                                    confidence: .low, gold: reference))
        #expect(rate(.highConfidenceErrorRate, [modest]).denominator == 0)
    }

    @Test("field_precision counts every assertion, contradicted or invented included")
    func fieldPrecisionPopulation() throws {
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026"],
                                 allowUnknown: [.department])
        let entry = EvaluationFixtures.candidate([.completionyear: "2026", .department: "填了没有的依据"],
                              gold: reference)
        let judgement = CaseJudgement(gold: reference, entry: entry)

        let measured = rate(.fieldPrecision, [judgement])
        #expect(measured.denominator == 2, "an assertion nobody asked for is still an assertion")
        #expect(measured.numerator == 1)
        #expect(judgement.fields.first { $0.field == .department }?.verdict == .invented)
        // The same slot through the empty-fill side of the contract.
        let invented = rate(.inventedFillRate, [judgement])
        #expect(invented.denominator == 11, "every slot the answer leaves empty, filled or not")
        #expect(invented.numerator == 1)
    }

    @Test("a whitespace-only value is a miss, not a wrong answer")
    func emptyValueIsNotAnAssertion() throws {
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026"])
        let blank = CaseJudgement(gold: reference,
                                  entry: EvaluationFixtures.candidate([.completionyear: "   "], gold: reference))
        let verdict = blank.fields.first { $0.field == .completionyear }?.verdict
        #expect(verdict == .withheld)
        // Both consequences follow: it is not an assertion that could be scored
        // right or wrong, and it is not auto-publishable material either.
        #expect(rate(.fieldPrecision, [blank]).denominator == 0)
        #expect(rate(.coverage, [blank]).numerator == 0)
        #expect(rate(.holdRate, [blank]).numerator == 1)
    }

    @Test("an entry parked in hold holds every expected value")
    func holdRateCountsStates() throws {
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026", .department: "采购部"])
        let held = CaseJudgement(gold: reference,
                                 entry: EvaluationFixtures.candidate([.completionyear: "2026"], state: .hold, gold: reference))
        let measured = rate(.holdRate, [held])
        // completionyear carries a value, yet the entry as a whole is parked: the
        // reviewer gets nothing usable from it, and the metric has to agree.
        #expect(measured.numerator == 2)
        #expect(measured.denominator == 2)

        let partial = CaseJudgement(gold: reference, entry: EvaluationFixtures.candidate([.completionyear: "2026"], gold: reference))
        #expect(rate(.holdRate, [partial]).numerator == 1)

        let absent = CaseJudgement(gold: reference, entry: nil)
        #expect(rate(.holdRate, [absent]).numerator == 2)
    }

    @Test("the candidate-value gate counts records, not slots")
    func sparseStratum() throws {
        // Twenty-nine records, one expected slot each: twenty-nine of both, sparse
        // by either reading. The interesting case is below, where the two units
        // disagree - and that is the whole reason the gate is on `caseCount`.
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026"])
        let cases = try (1...29).map { _ in CaseJudgement(gold: reference, entry: nil) }
        let found = try #require(EvaluationMetrics.slices(for: cases).first {
            $0.measure == .coverage && $0.stratum == .overall
        })
        #expect(found.caseCount == 29)
        #expect(found.isSparse)

        let dense = try (1...30).map { _ in CaseJudgement(gold: reference, entry: nil) }
        let denseSlice = try #require(EvaluationMetrics.slices(for: dense).first {
            $0.measure == .coverage && $0.stratum == .overall
        })
        #expect(!denseSlice.isSparse)
    }

    @Test("five records with sixty slot observations are still five records")
    func sparsityCountsRecords() throws {
        // The confusion this gate used to be vulnerable to: a field-heavy gold row
        // manufactures a slot denominator past any threshold while the number of
        // independently verified samples stays tiny. Quoting that as a rate would
        // let a five-record run look as solid as a five-hundred-record one.
        let fields: [MetadataFieldID: String?] = [
            .projectname: "示例项目", .completionyear: "2026", .department: "采购中心",
            .bidderentity: "中标单位甲", .salesowner: "销售乙", .tenderreference: "ZB-2026-001"
        ]
        let reference = try EvaluationFixtures.gold("heavy", expected: fields)
        let cases = try (0..<5).map { _ in CaseJudgement(gold: reference, entry: nil) }
        let slice = try #require(EvaluationMetrics.slices(for: cases).first {
            $0.measure == .coverage && $0.stratum == .overall
        })
        #expect(slice.rate.denominator == 30)
        #expect(slice.caseCount == 5)
        #expect(slice.isSparse)
        #expect(!slice.isQuotableOnOwnMerits)
    }

    @Test("the bootstrap resamples whole project clusters")
    func clusterResampling() throws {
        // One dominant cluster of forty records and four clusters of one. Record
        // level resampling would look tight; cluster level resampling has to say
        // that most of this measurement is one project's shape.
        var cases: [CaseJudgement] = []
        let dominant = try EvaluationFixtures.gold("dominant", expected: [.completionyear: "2026"], cluster: "big-project")
        for _ in 0..<40 { cases.append(CaseJudgement(gold: dominant, entry: nil)) }
        for index in 1...4 {
            let singleton = try EvaluationFixtures.gold("s\(index)", expected: [.completionyear: "2026"], cluster: "single-\(index)")
            cases.append(CaseJudgement(gold: singleton, entry: nil))
        }

        let populations = EvaluationFixtures.populations(cases)
        let keys = EvaluationFixtures.keys(cases)
        func hold(_ sample: [CaseJudgement]) -> ClosedRange<Double>? {
            ClusterBootstrap.summarize(measures: [.holdRate],
                                       populations: EvaluationFixtures.populations(sample),
                                       indices: Array(sample.indices),
                                       keys: EvaluationFixtures.keys(sample),
                                       resamples: 200, seed: 0x9E37_79B9_7F4A_7C15)[.holdRate]?.interval
        }
        let interval = try #require(hold(cases))
        #expect(interval.lowerBound <= interval.upperBound)
        #expect(interval == hold(cases), "the same seed has to reproduce the same interval")

        // Below five clusters there is nothing to vary, and an interval computed
        // anyway would be a width invented by the resampler. The count is published
        // beside the nil so a reader can tell that cause from the thin-measure one.
        let few = Array(cases.prefix(3))
        #expect(hold(few) == nil)
        let fewSummary = ClusterBootstrap.summarize(measures: [.holdRate],
                                                    populations: EvaluationFixtures.populations(few),
                                                    indices: Array(few.indices),
                                                    keys: EvaluationFixtures.keys(few))
        let fewClusters = try #require(fewSummary[.holdRate]?.clusterCount)
        #expect(fewClusters < ClusterBootstrap.minimumClusters)

        // Asking for one measure must not change its interval: the draws are shared
        // across the columns, so a subset request is a projection, not a resample.
        let all = ClusterBootstrap.summarize(populations: populations, indices: Array(cases.indices),
                                            keys: keys, resamples: 200,
                                            seed: 0x9E37_79B9_7F4A_7C15)
        #expect(all[.holdRate]?.interval == interval)
    }

    @Test("a voided measure does not take later measures' draws with it")
    func voidingIsOrderIndependent() throws {
        // `precision_auto` is second in `allCases` and `invented_fill_rate` last, so
        // an implementation that abandons the whole resample on the first empty
        // denominator - or clears the ratios it already collected - loses the later
        // measure's interval even though every one of its draws was defined.
        var cases: [CaseJudgement] = []
        for index in 0..<10 {
            let reference = try EvaluationFixtures.gold("o\(index)", expected: [.completionyear: "2026"],
                                                        cluster: "oc\(index)")
            // Not eligible for auto execution: no slot is publishable, so
            // `precision_auto` has no population in any resample.
            let entry = EvaluationFixtures.candidate([.completionyear: "2026"], publishable: false,
                                                     gold: reference)
            cases.append(CaseJudgement(gold: reference, entry: entry))
        }
        let summary = ClusterBootstrap.summarize(populations: EvaluationFixtures.populations(cases),
                                                 indices: Array(cases.indices),
                                                 keys: EvaluationFixtures.keys(cases))
        #expect(summary[.precisionAuto]?.interval == nil)
        #expect(summary[.coverage]?.interval != nil)
        #expect(summary[.inventedFillRate]?.interval != nil, "the last measure kept all of its draws")
        #expect(summary[.inventedFillRate]?.rate.denominator == 110)
        #expect(summary[.precisionAuto]?.rate.denominator == 0)
    }

    @Test("a measure with no population at all has no interval, its neighbours keep theirs")
    func measureWithoutPopulationHasNoInterval() throws {
        // No candidate entries at all: `precision_auto` has nothing to observe in
        // any draw, while `coverage` still sees one expected slot per record. This
        // is the "no population" case, not the "some draws are empty" case - the
        // next test is that one.
        var cases: [CaseJudgement] = []
        for index in 0..<12 {
            let reference = try EvaluationFixtures.gold("v\(index)", expected: [.completionyear: "2026"],
                                                        cluster: "vc\(index)")
            cases.append(CaseJudgement(gold: reference, entry: nil))
        }
        let summaries = ClusterBootstrap.summarize(populations: EvaluationFixtures.populations(cases),
                                                   indices: Array(cases.indices),
                                                   keys: EvaluationFixtures.keys(cases))
        #expect(summaries[.coverage]?.interval != nil)
        #expect(summaries[.precisionAuto]?.interval == nil)
        #expect(summaries[.highConfidenceErrorRate]?.interval == nil)
        // Every cluster withholds, so the only ratio the resample can produce is 0.
        #expect(summaries[.coverage]?.interval == 0...0)
    }

    @Test("one empty draw voids the interval instead of being skipped")
    func emptyDrawVoidsInsteadOfSkipping() throws {
        // Three clusters can produce an auto-publishable assertion and three cannot
        // (their entries are not eligible), so a resample that happens to pick only
        // the ineligible clusters has a zero denominator for `precision_auto`. The
        // old code skipped such a draw and reported percentiles over the rest - a
        // band computed from the clusters that answered, which is narrower than the
        // sample supports. Voiding says what is true: this stratum cannot give a
        // cluster interval for this measure.
        var cases: [CaseJudgement] = []
        for index in 0..<6 {
            let reference = try EvaluationFixtures.gold("m\(index)", expected: [.completionyear: "2026"],
                                                        cluster: "mc\(index)")
            let entry = EvaluationFixtures.candidate([.completionyear: "2026"],
                                                     publishable: index >= 3, gold: reference)
            cases.append(CaseJudgement(gold: reference, entry: entry))
        }
        let summaries = ClusterBootstrap.summarize(populations: EvaluationFixtures.populations(cases),
                                                   indices: Array(cases.indices),
                                                   keys: EvaluationFixtures.keys(cases))
        #expect(summaries[.precisionAuto]?.rate.denominator == 3)
        #expect(summaries[.precisionAuto]?.interval == nil,
                "a draw of only the ineligible clusters leaves no ratio to place a bound on")
        // The measures whose every draw was defined keep their intervals: voiding
        // one column does not take the others down with it.
        #expect(summaries[.coverage]?.interval != nil)
        #expect(summaries[.fieldPrecision]?.interval != nil)
        #expect(summaries[.holdRate]?.interval != nil)
        #expect(summaries[.precisionAuto]?.clusterCount == 6,
                "the sample had enough clusters to vary, so this nil means the measure was thin")
    }

    @Test("the interval brackets the estimate it belongs to")
    func intervalBracketsEstimate() throws {
        var cases: [CaseJudgement] = []
        for index in 0..<40 {
            let reference = try EvaluationFixtures.gold("g\(index)", expected: [.completionyear: "2026"], cluster: "c\(index)")
            // Half the clusters answer correctly, so the estimate sits near 0.5.
            let entry = index.isMultiple(of: 2)
                ? EvaluationFixtures.candidate([.completionyear: "2026"], gold: reference)
                : EvaluationFixtures.candidate([.completionyear: "2027"], gold: reference)
            cases.append(CaseJudgement(gold: reference, entry: entry))
        }
        // Half the clusters answer correctly, so the share of assertions that are
        // right sits at 0.5; coverage is 1.0 here, because the engine did reach
        // every expected slot either way - which is exactly the distinction the
        // two measures exist to keep apart.
        let reach = try #require(EvaluationMetrics.slices(for: cases).first {
            $0.measure == .coverage && $0.stratum == .overall
        })
        #expect(reach.rate.estimate == 1.0)
        let slice = try #require(EvaluationMetrics.slices(for: cases).first {
            $0.measure == .fieldPrecision && $0.stratum == .overall
        })
        let estimate = try #require(slice.rate.estimate)
        #expect(estimate == 0.5)
        let interval = try #require(slice.clusterInterval)
        #expect(interval.lowerBound <= estimate && estimate <= interval.upperBound)
        // Wilson on twenty of forty must be inside the unit interval, and not the
        // naive symmetric band that a small sample pushes past its ends.
        #expect(0...1 ~= slice.rate.wilson95Lower!)
        #expect(0...1 ~= slice.rate.wilson95Upper!)
    }

    @Test("agreement means the same thing here as in the validator")
    func equalityIsTheValidatorsOwn() throws {
        let reference = try EvaluationFixtures.gold("g1", expected: [.projectname: "示例项目_2026"])
        // Width and case folds agree - a full-width Latin run is the same value.
        let wide = CaseJudgement(gold: try EvaluationFixtures.gold("g2", expected: [.projectname: "ABC项目_2026"]),
                                 entry: EvaluationFixtures.candidate([.projectname: "ＡＢＣ项目_2026"],
                                                  gold: try EvaluationFixtures.gold("g2", expected: [.projectname: "ABC项目_2026"])))
        #expect(wide.fields.first { $0.field == .projectname }?.verdict == .correct)

        // Traditional and Simplified glyphs are different code points and are NOT
        // folded together: claiming otherwise here would quietly loosen what
        // counts as agreeing with the reference answer.
        let variant = CaseJudgement(gold: reference,
                                    entry: EvaluationFixtures.candidate([.projectname: "示例項目_2026"], gold: reference))
        #expect(variant.fields.first { $0.field == .projectname }?.verdict == .wrong)

        let suffixed = CaseJudgement(gold: reference,
                                     entry: EvaluationFixtures.candidate([.projectname: "示例项目_2026年"], gold: reference))
        #expect(suffixed.fields.first { $0.field == .projectname }?.verdict == .wrong)

        // The same pairs through the definition the validator quotes with.
        #expect(ValueNormalization.equal("ＡＢＣ项目", "ABC项目"))
        #expect(!ValueNormalization.equal("示例項目_2026", "示例项目_2026"))
        #expect(!ValueNormalization.equal("示例项目_2026年", "示例项目_2026"))
        #expect(!ValueNormalization.equal("", "示例项目_2026"), "an empty value agrees with nothing")
    }

    @Test("a run with no candidate for a source is confusion-visible")
    func confusionRecordsAbsence() throws {
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026"])
        let cases = [CaseJudgement(gold: reference, entry: nil),
                     CaseJudgement(gold: reference,
                                   entry: EvaluationFixtures.candidate([.completionyear: "2026"], state: .hold, gold: reference))]
        let matrix = EvaluationMetrics.confusion(cases)
        #expect(matrix["mapped->absent"] == 1)
        #expect(matrix["mapped->hold"] == 1)
    }

    @Test("strata are reported per profile and per category")
    func strataEnumeration() throws {
        let both = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026"], category: .nearDuplicate,
                            profiles: [ProjectArchiveContract.id, VendorLibraryContract.id])
        let all = EvaluationMetrics.slices(for: [CaseJudgement(gold: both, entry: nil)])
        let coverage = all.filter { $0.measure == .coverage }
        let vendorKey = VendorLibraryContract.id
        let duplicateCategory = GoldRecord.Category.nearDuplicate.rawValue

        let vendor = coverage.first { $0.stratum == .profile && $0.key == vendorKey }
        #expect(vendor != nil, "a record belonging to both profiles has to appear in both strata")
        let stratum = coverage.first { $0.stratum == .category && $0.key == duplicateCategory }
        #expect(stratum != nil)

        // One record counted in two profiles is still one record: the profile
        // slice carries a single record's slots, not twice the sample.
        #expect(vendor?.rate.denominator == 1)
        #expect(stratum?.rate.denominator == 1)
    }
}
