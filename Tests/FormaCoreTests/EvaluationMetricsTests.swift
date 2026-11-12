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
    /// The record-level rates need a Profile to be meaningful, so the helper names
    /// one: `ProjectArchiveContract.id` is what every fixture record belongs to.
    private func rate(_ measure: EvaluationMeasure, _ cases: [CaseJudgement],
                      profile: String? = ProjectArchiveContract.id) -> EvaluationRate {
        var numerator = 0
        var denominator = 0
        for judgement in cases {
            let population = measure.population(in: judgement, runProfile: profile)
            numerator += population.numerator
            denominator += population.denominator
        }
        return EvaluationRate(numerator: numerator, denominator: denominator)
    }

    @Test("coverage is one record, once, if the policy would execute it")
    func coveragePopulation() throws {
        // PLAN §8.2: coverage = auto_mapped / total. A record is worth one, however
        // many of its twelve fields came out right, because the quantity being
        // thresholded is "how much of the corpus moves without a human" - not "how
        // much of each file did it guess".
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026", .department: "采购部"])
        let mapped = EvaluationFixtures.judgement(reference,
                                   entry: EvaluationFixtures.candidate([.completionyear: "2026", .department: "采购部"],
                                                                      gold: reference))
        #expect(rate(.coverage, [mapped]) == EvaluationRate(numerator: 1, denominator: 1))

        // Not eligible for auto execution, so nothing moves on its own - even with
        // every field correct. It stays in the denominator: coverage over a run that
        // auto-mapped nothing is 0%, not "unmeasured".
        let manual = EvaluationFixtures.judgement(reference,
                                   entry: EvaluationFixtures.candidate([.completionyear: "2026", .department: "采购部"],
                                                                      publishable: false, gold: reference))
        #expect(rate(.coverage, [manual]) == EvaluationRate(numerator: 0, denominator: 1))

        let absent = EvaluationFixtures.judgement(reference, entry: nil)
        #expect(rate(.coverage, [absent]) == EvaluationRate(numerator: 0, denominator: 1))
    }

    @Test("a contradicted slot stays in the field denominator and out of the numerator")
    func contradictedStaysCounted() throws {
        // The slot-level half, where contradiction actually shows up: the engine
        // asserted something, so the assertion is counted; it does not count as
        // right. (The conflict note has to be four characters or longer, since
        // `Bounded.text` discards shorter values as carrying no information.)
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026", .department: "采购部"])
        let judgement = EvaluationFixtures.judgement(reference,
                                      entry: EvaluationFixtures.candidate([.completionyear: "2026", .department: "采购部"],
                                                                         conflicted: [.department], gold: reference))
        let measured = rate(.fieldPrecision, [judgement])
        #expect(measured.denominator == 2)
        #expect(measured.numerator == 1)
        #expect(judgement.fields.first { $0.field == .department }?.verdict == .contradicted)
        // Both are expectation slots, so a contradiction still counts as a slot the
        // answer needed - `allowedUnknown` is the only verdict outside that set.
        #expect(rate(.missedFillRate, [judgement]).denominator == 2)
    }

    @Test("a file is correct only when Profile, project and category all match")
    func precisionAutoPopulation() throws {
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026"])
        let good = EvaluationFixtures.judgement(reference,
                                 entry: EvaluationFixtures.candidate([.completionyear: "2026"], gold: reference))
        #expect(good.isAutoMapped)
        #expect(good.mainDecisionIsCorrect(runProfile: ProjectArchiveContract.id))
        #expect(rate(.precisionAuto, [good]) == EvaluationRate(numerator: 1, denominator: 1))

        // Each component alone makes the file wrong, and each is a different bug: a
        // mis-filed document, an association pointing at the wrong job, a run under a
        // Profile the record was never annotated for.
        let misplaced = EvaluationFixtures.judgement(reference,
                                      entry: EvaluationFixtures.candidate([.completionyear: "2026"],
                                                                         wrongPlacement: true, gold: reference))
        #expect(!misplaced.matchesTargetCategory)
        #expect(rate(.precisionAuto, [misplaced]).numerator == 0)

        // Mis-attribution is expressed in the table, not in the entry: production's
        // manifest only ever carries the candidate reference.
        let wrongProject = EvaluationFixtures.judgement(reference,
                                                        entry: EvaluationFixtures.candidate([.completionyear: "2026"],
                                                                                             gold: reference),
                                                        wrongProject: true)
        #expect(!wrongProject.matchesProjectReference)
        #expect(rate(.precisionAuto, [wrongProject]).numerator == 0)

        let vendorOnly = try EvaluationFixtures.gold("g2", expected: [.completionyear: "2026"],
                                                    profiles: [VendorLibraryContract.id])
        let misplacedProfile = EvaluationFixtures.judgement(vendorOnly,
                                             entry: EvaluationFixtures.candidate([.completionyear: "2026"],
                                                                                 gold: vendorOnly))
        #expect(!misplacedProfile.mainDecisionIsCorrect(runProfile: ProjectArchiveContract.id))

        // A record the program would not execute is outside the population entirely:
        // 0 of 0, not 0 of 1 - precision over publishes that never happen is not a
        // measurement of this program.
        let manual = EvaluationFixtures.judgement(reference,
                                   entry: EvaluationFixtures.candidate([.completionyear: "2026"],
                                                                      publishable: false, gold: reference))
        #expect(rate(.precisionAuto, [manual]) == EvaluationRate(numerator: 0, denominator: 0))

        // With no Profile named for the run the first component is unanswerable, so
        // nothing counts as correct - the denominator stays, and the report shows the
        // precision as 0 rather than the measure quietly assuming the Profile matched.
        let unattributed = rate(.precisionAuto, [good], profile: nil)
        #expect(unattributed.denominator == 1)
        #expect(unattributed.numerator == 0)
    }

    @Test("high confidence errors are the records the model was sure about and got wrong")
    func highConfidenceError() throws {
        // PLAN §8.2 keeps this one about the model's own claim, and at file level:
        // the denominator is the records whose entry declared high confidence, the
        // numerator the ones of those whose main decision was wrong. A field being
        // wrong inside an otherwise correct placement is not what this measures -
        // that is `field_precision`'s business.
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026", .department: "采购部"])
        let confidentlyMisfiled = EvaluationFixtures.judgement(reference,
                                                entry: EvaluationFixtures.candidate([.completionyear: "2026"],
                                                                                   wrongPlacement: true,
                                                                                   gold: reference))
        #expect(confidentlyMisfiled.declaresHighConfidence)
        let measured = rate(.highConfidenceErrorRate, [confidentlyMisfiled])
        #expect(measured.numerator == 1)
        #expect(measured.denominator == 1)

        let confidentlyRight = EvaluationFixtures.judgement(reference,
                                             entry: EvaluationFixtures.candidate([.completionyear: "2026"],
                                                                                gold: reference))
        #expect(rate(.highConfidenceErrorRate, [confidentlyRight])
                == EvaluationRate(numerator: 0, denominator: 1))

        let modest = EvaluationFixtures.judgement(reference,
                                   entry: EvaluationFixtures.candidate([.completionyear: "2026"],
                                                                      confidence: .low, gold: reference))
        #expect(rate(.highConfidenceErrorRate, [modest]).denominator == 0)
    }

    @Test("field_precision counts every assertion, contradicted or invented included")
    func fieldPrecisionPopulation() throws {
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026"],
                                 allowUnknown: [.department])
        let entry = EvaluationFixtures.candidate([.completionyear: "2026", .department: "填了没有的依据"],
                              gold: reference)
        let judgement = EvaluationFixtures.judgement(reference, entry: entry)

        let measured = rate(.fieldPrecision, [judgement])
        #expect(measured.denominator == 2, "an assertion nobody asked for is still an assertion")
        #expect(measured.numerator == 1)
        #expect(judgement.fields.first { $0.field == .department }?.verdict == .invented)
        // The same slot through the empty-fill side of the contract.
        let invented = rate(.inventedFillRate, [judgement])
        #expect(invented.denominator == 11, "every slot the answer leaves empty, filled or not")
        #expect(invented.numerator == 1)
    }

    @Test("field precision is reported for each of the twelve fields")
    func perFieldRows() throws {
        // PLAN §8.2: "12 字段分别报告". A pooled number hides the one field that is
        // failing, and for these profiles the failing field is rarely the project
        // name everyone watches.
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026", .salesowner: "张三"])
        let cases = [EvaluationFixtures.judgement(reference,
                                   entry: EvaluationFixtures.candidate([.completionyear: "2026",
                                                                       .salesowner: "张三"], gold: reference))]
        let request = EvaluationMetrics.Request(resamples: 50)
        let slices = EvaluationMetrics.slices(for: cases, request: request)
        let rows = slices.filter { $0.measure == .fieldPrecision && $0.stratum == .field }
        #expect(rows.count == MetadataFieldID.allCases.count)

        let year = rows.first { $0.key == MetadataFieldID.completionyear.rawValue }
        #expect(year?.rate.denominator == 1)
        #expect(year?.rate.estimate == 1)
        // A field nobody asserted anything about has no population, and says so.
        let unused = rows.first { $0.key == MetadataFieldID.bidderentity.rawValue }
        #expect(unused?.rate.denominator == 0)
        #expect(unused?.rate.estimate == nil)
        // Field rows carry Wilson only: the cluster interval exists for the pooled
        // row, and a nil here is by construction rather than a verdict on thinness.
        #expect(year?.clusterInterval == nil)
        #expect(year?.clusterCount == 1)
        // The twelve denominators add up to the pooled one, so nothing is counted
        // twice and nothing is dropped on the way from field rows to the total.
        let pooled = slices.first { $0.measure == .fieldPrecision && $0.stratum == .overall }
        let summed = rows.reduce(0) { partial, row in partial + (row.rate.denominator ?? 0) }
        #expect(summed == pooled?.rate.denominator)
    }

    @Test("a whitespace-only value is a miss, not a wrong answer")
    func emptyValueIsNotAnAssertion() throws {
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026"])
        let blank = EvaluationFixtures.judgement(reference,
                                  entry: EvaluationFixtures.candidate([.completionyear: "   "], gold: reference))
        let verdict = blank.fields.first { $0.field == .completionyear }?.verdict
        #expect(verdict == .withheld)
        // It is not an assertion that could be scored right or wrong...
        #expect(rate(.fieldPrecision, [blank]).denominator == 0)
        // ...it is a miss, which is the other measure's numerator - and the two are
        // deliberately not summed.
        #expect(rate(.missedFillRate, [blank]).numerator == 1)
        // The file itself was still auto-mapped and still parked nowhere, so neither
        // file-level rate calls it a hold or an unanswered record.
        #expect(rate(.coverage, [blank]).numerator == 1)
        #expect(rate(.holdRate, [blank]).numerator == 0)
    }

    @Test("an entry parked in hold is one held record")
    func holdRateCountsStates() throws {
        // PLAN §8.2: hold_rate = held / total, one record at a time, with the
        // unknown / invalidated / request-failure counts reported beside it rather
        // than folded into the same number.
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026", .department: "采购部"])
        let held = EvaluationFixtures.judgement(reference,
                                 entry: EvaluationFixtures.candidate([.completionyear: "2026"], state: .hold,
                                                                     gold: reference))
        // One slot carries a value, yet the entry as a whole is parked: the reviewer
        // receives nothing usable from it, and the rate has to agree.
        #expect(rate(.holdRate, [held]) == EvaluationRate(numerator: 1, denominator: 1))
        // The same record's slots, seen through the slot-level measure instead.
        #expect(rate(.missedFillRate, [held]).numerator == 1)

        let partial = EvaluationFixtures.judgement(reference,
                                    entry: EvaluationFixtures.candidate([.completionyear: "2026"],
                                                                       gold: reference))
        #expect(rate(.holdRate, [partial]).numerator == 0)

        let absent = EvaluationFixtures.judgement(reference, entry: nil)
        #expect(rate(.holdRate, [absent]) == EvaluationRate(numerator: 1, denominator: 1))
    }

    @Test("the candidate-value gate counts records, not slots")
    func sparseStratum() throws {
        // Twenty-nine records, one expected slot each: twenty-nine of both, sparse
        // by either reading. The interesting case is below, where the two units
        // disagree - and that is the whole reason the gate is on `caseCount`.
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026"])
        let cases = try (1...29).map { _ in EvaluationFixtures.judgement(reference, entry: nil) }
        let found = try #require(EvaluationMetrics.slices(for: cases).first {
            $0.measure == .coverage && $0.stratum == .overall
        })
        #expect(found.caseCount == 29)
        #expect(found.isSparse)

        let dense = try (1...30).map { _ in EvaluationFixtures.judgement(reference, entry: nil) }
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
        let cases = try (0..<5).map { _ in EvaluationFixtures.judgement(reference, entry: nil) }
        // Read through a slot-level measure, which is where the mismatch lives:
        // thirty slot observations from five records.
        let slice = try #require(EvaluationMetrics.slices(for: cases).first {
            $0.measure == .missedFillRate && $0.stratum == .overall
        })
        #expect(slice.rate.denominator == 30)
        #expect(EvaluationMeasure.missedFillRate.unit == .slots)
        #expect(slice.caseCount == 5)
        #expect(slice.isSparse)
        #expect(!slice.isQuotableOnOwnMerits)
        // The record-level measures cannot be fooled this way: their denominator is
        // the record count itself, so five records is always five.
        let coverage = try #require(EvaluationMetrics.slices(for: cases).first {
            $0.measure == .coverage && $0.stratum == .overall
        })
        #expect(coverage.rate.denominator == 5)
    }

    @Test("the bootstrap resamples whole project clusters")
    func clusterResampling() throws {
        // One dominant cluster of forty records and four clusters of one. Record
        // level resampling would look tight; cluster level resampling has to say
        // that most of this measurement is one project's shape.
        var cases: [CaseJudgement] = []
        let dominant = try EvaluationFixtures.gold("dominant", expected: [.completionyear: "2026"], cluster: "big-project")
        for _ in 0..<40 { cases.append(EvaluationFixtures.judgement(dominant, entry: nil)) }
        for index in 1...4 {
            let singleton = try EvaluationFixtures.gold("s\(index)", expected: [.completionyear: "2026"], cluster: "single-\(index)")
            cases.append(EvaluationFixtures.judgement(singleton, entry: nil))
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
            cases.append(EvaluationFixtures.judgement(reference, entry: entry))
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
            cases.append(EvaluationFixtures.judgement(reference, entry: nil))
        }
        let summaries = ClusterBootstrap.summarize(populations: EvaluationFixtures.populations(cases),
                                                   indices: Array(cases.indices),
                                                   keys: EvaluationFixtures.keys(cases))
        #expect(summaries[.coverage]?.interval != nil)
        #expect(summaries[.precisionAuto]?.interval == nil)
        #expect(summaries[.highConfidenceErrorRate]?.interval == nil)
        // What the surviving interval is made of, rather than its exact percentiles:
        #expect(summaries[.coverage]?.rate.denominator == 12)
        #expect(summaries[.coverage]?.rate.estimate == 0)
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
            cases.append(EvaluationFixtures.judgement(reference, entry: entry))
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
            cases.append(EvaluationFixtures.judgement(reference, entry: entry))
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

    @Test("the wilson bounds are the standard ones")
    func wilsonBoundsTheStandardWay() throws {
        // Computed independently from the textbook interval, not from this code:
        // 5 of 20 is (0.1119, 0.4687), 1 of 10 is (0.0179, 0.4042), 0 of 20 is
        // (0, 0.1611), 20 of 20 is (0.8389, 1). The earlier version of this
        // calculation divided the spread by (1 + z^2/n) instead of by n, which made
        // every interval span the whole unit line while still passing any test that
        // only asked whether the bounds lay inside [0, 1] - which is the whole
        // reason the numbers are written down here.
        func bounds(_ numerator: Int, _ denominator: Int) -> (Double, Double)? {
            let rate = EvaluationRate(numerator: numerator, denominator: denominator)
            guard let low = rate.wilson95Lower, let high = rate.wilson95Upper else { return nil }
            return (low, high)
        }
        func near(_ actual: (Double, Double)?, _ expected: (Double, Double)) -> Bool {
            guard let actual else { return false }
            return abs(actual.0 - expected.0) < 0.0002 && abs(actual.1 - expected.1) < 0.0002
        }
        #expect(near(bounds(5, 20), (0.1119, 0.4687)))
        #expect(near(bounds(1, 10), (0.0179, 0.4042)))
        #expect(near(bounds(0, 20), (0.0000, 0.1611)))
        #expect(near(bounds(20, 20), (0.8389, 1.0000)))
        #expect(near(bounds(150, 600), (0.2170, 0.2862)))
        // No observations, no interval - and no estimate to put one around.
        #expect(bounds(0, 0) == nil)
        let empty = EvaluationRate(numerator: 0, denominator: 0)
        #expect(empty.estimate == nil)
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
        let variant = EvaluationFixtures.judgement(reference,
                                    entry: EvaluationFixtures.candidate([.projectname: "示例項目_2026"], gold: reference))
        #expect(variant.fields.first { $0.field == .projectname }?.verdict == .wrong)

        let suffixed = EvaluationFixtures.judgement(reference,
                                     entry: EvaluationFixtures.candidate([.projectname: "示例项目_2026年"], gold: reference))
        #expect(suffixed.fields.first { $0.field == .projectname }?.verdict == .wrong)

        // The same pairs through the definition the validator quotes with.
        #expect(ValueNormalization.equal("ＡＢＣ项目", "ABC项目"))
        #expect(!ValueNormalization.equal("示例項目_2026", "示例项目_2026"))
        #expect(!ValueNormalization.equal("示例项目_2026年", "示例项目_2026"))
        #expect(!ValueNormalization.equal("", "示例项目_2026"), "an empty value agrees with nothing")
    }

    @Test("refusals say why the run did not publish, in two separate units")
    func refusalsNameTheReasons() throws {
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026", .department: "采购部"])

        // Answered but parked: one record stopped in `hold`, and the two slots the
        // reference needed are unknown to the policy. The record count and the slot
        // count are different quantities about the same file, which is exactly why
        // they are two dictionaries and not one number.
        let parked = EvaluationMetrics.refusals([
            EvaluationFixtures.judgement(reference,
                                         entry: EvaluationFixtures.candidate([:], state: .hold, gold: reference))
        ])
        #expect(parked.byRecordState == [DecisionState.hold.rawValue: 1])
        #expect(parked.bySlotStatus == [FieldOutcome.Status.unknown.rawValue: 2])

        // No entry at all: the slot key is `absent` too, because the reason is the
        // missing candidate rather than a decision about a value.
        let blank = EvaluationMetrics.refusals([EvaluationFixtures.judgement(reference, entry: nil)])
        #expect(blank.byRecordState == ["absent": 1])
        #expect(blank.bySlotStatus["absent"] == 2)

        // What went out on its own contributes to neither half.
        let mapped = EvaluationMetrics.refusals([
            EvaluationFixtures.judgement(reference,
                                         entry: EvaluationFixtures.candidate([.completionyear: "2026",
                                                                              .department: "采购部"],
                                                                             gold: reference))
        ])
        #expect(mapped.byRecordState.isEmpty)
        #expect(mapped.bySlotStatus.isEmpty)
    }

    @Test("a run with no candidate for a source is confusion-visible")
    func confusionRecordsAbsence() throws {
        let reference = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026"])
        let cases = [EvaluationFixtures.judgement(reference, entry: nil),
                     EvaluationFixtures.judgement(reference,
                                   entry: EvaluationFixtures.candidate([.completionyear: "2026"], state: .hold, gold: reference))]
        let matrix = EvaluationMetrics.confusion(cases)
        #expect(matrix["mapped->absent"] == 1)
        #expect(matrix["mapped->hold"] == 1)
    }

    @Test("strata are reported per profile and per category")
    func strataEnumeration() throws {
        let both = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026"], category: .nearDuplicate,
                            profiles: [ProjectArchiveContract.id, VendorLibraryContract.id])
        let all = EvaluationMetrics.slices(for: [EvaluationFixtures.judgement(both, entry: nil)])
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

    @Test("a run that asks for one draw gets no band, and still a quotable rate")
    func singleDrawHasNoBand() throws {
        // §5's third nil cause. Without the published `clusterCount` and the
        // resample count recorded in the run identity, "nobody asked for a band"
        // would be indistinguishable from "this stratum is too thin to vary" - and
        // the second is a finding about the data while the first is a fact about the
        // request.
        let cases: [CaseJudgement] = try (0..<40).map { index in
            let reference = try EvaluationFixtures.gold("g\(index)", expected: [.completionyear: "2026"],
                                                        cluster: "cluster-\(index)")
            return EvaluationFixtures.judgement(reference,
                                                entry: EvaluationFixtures.candidate([.completionyear: "2026"],
                                                                                     gold: reference))
        }
        let slices = EvaluationMetrics.slices(for: cases,
                                              request: EvaluationMetrics.Request(resamples: 1))
        let coverage = try #require(slices.first { $0.measure == .coverage && $0.stratum == .overall })
        #expect(coverage.clusterCount == 40)
        #expect(coverage.rate.denominator == 40)
        #expect(coverage.clusterInterval == nil)
        // The rate itself is untouched: a missing band is not a missing measurement.
        #expect(coverage.isQuotableOnOwnMerits)

        let twice = EvaluationMetrics.slices(for: cases,
                                             request: EvaluationMetrics.Request(resamples: 2))
        let again = try #require(twice.first { $0.measure == .coverage && $0.stratum == .overall })
        #expect(again.clusterInterval != nil, "two draws are enough for the band to vary")
    }

    @Test("a profile cut judges files against the profile it names")
    func profileCutUsesItsOwnProfile() throws {
        let forVendor = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026"],
                                                    profiles: [VendorLibraryContract.id])
        let forArchive = try EvaluationFixtures.gold("g2", expected: [.completionyear: "2026"],
                                                     profiles: [ProjectArchiveContract.id])
        let vendorCase = EvaluationFixtures.judgement(
            forVendor, entry: EvaluationFixtures.candidate([.completionyear: "2026"], gold: forVendor))
        let archiveCase = EvaluationFixtures.judgement(
            forArchive, entry: EvaluationFixtures.candidate([.completionyear: "2026"], gold: forArchive))
        let request = EvaluationMetrics.Request(runProfileID: VendorLibraryContract.id)
        let slices = EvaluationMetrics.slices(for: [vendorCase, archiveCase], request: request)
        let archiveKey = ProjectArchiveContract.id
        let overall = try #require(slices.first { $0.measure == .precisionAuto && $0.stratum == .overall })
        let archive = try #require(slices.first { $0.stratum == .profile && $0.key == archiveKey
            && $0.measure == .precisionAuto })
        // Pooled, the run published one file whose Profile is not the one it was
        // annotated for.
        #expect(overall.rate.denominator == 2)
        #expect(overall.rate.numerator == 1)
        // Under the archive's own cut, that same file is right: the Profile
        // component is stated against the cut, not against whoever happened to run
        // the batch. Both numbers are true, and the second only exists because a
        // cut carries its own Profile.
        #expect(archive.rate.denominator == 1)
        #expect(archive.rate.numerator == 1)
    }
}
