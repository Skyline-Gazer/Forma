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
        // the measure has no population at all. Not "0 of 1": that would publish an
        // observed 0% precision for the fact that the run forgot to say who executed
        // it, and `isQuotableOnOwnMerits` would call such a row quotable. PLAN §8.2
        // marks every zero denominator N/A, and a per-Profile cut is where the number
        // is available at all - see `profileCutUsesItsOwnProfile`.
        let unattributed = rate(.precisionAuto, [good], profile: nil)
        #expect(unattributed == EvaluationRate(numerator: 0, denominator: 0),
                "no records counted in either half")
        #expect(unattributed.estimate == nil)
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
        // The field rows belong to the overall cut only (PLAN §8.2 puts "12 字段分别
        // 报告" under `field_precision` and "每 Profile/类别" under 分层; the crossing
        // grid is nobody's requirement).
        #expect(slices.filter { $0.stratum == .field }.count == MetadataFieldID.allCases.count,
                "one row per field in the whole table, not one per field per stratum")
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

    @Test("the grouping of records into projects changes the band")
    func resamplingDependsOnClusterIdentity() throws {
        // The same six rows, two ways of saying which project they came from. A
        // bootstrap that treated `keys` as decoration would answer identically both
        // times; the content of clustering is that a draw takes a project's fields
        // with it, so one project carrying three empty rows drags every draw that
        // includes it. This pins that the structure is read rather than merely
        // published - nothing here noticed when that accumulation was rewritten.
        // `populations` is full-width by contract - one column per measure, in
        // `EvaluationMeasure.allCases` order - even when only one measure is requested.
        let field = EvaluationMeasure.allCases.firstIndex(of: .fieldPrecision)!
        func columns(_ numerator: Int, _ denominator: Int) -> [(numerator: Int, denominator: Int)] {
            EvaluationMeasure.allCases.indices.map { $0 == field ? (numerator, denominator) : (0, 0) }
        }
        let populations = [columns(4, 4), columns(0, 4), columns(0, 4),
                           columns(0, 4), columns(4, 4), columns(4, 4)]
        let indices = Array(populations.indices)
        // Five projects for six rows, so both requests clear `minimumClusters` and
        // the only difference between them is where the split falls.
        let byProject = ["p1", "p2", "p2", "p3", "p4", "p5"]
        let oneEach = ["p1", "p2", "p3", "p4", "p5", "p6"]
        let clustered = ClusterBootstrap.summarize(measures: [.fieldPrecision],
                                                   rows: EvaluationFixtures.rows(populations, keys: byProject),
                                                   indices: indices, resamples: 400, seed: 11)
        let scattered = ClusterBootstrap.summarize(measures: [.fieldPrecision],
                                                   rows: EvaluationFixtures.rows(populations, keys: oneEach),
                                                   indices: indices, resamples: 400, seed: 11)
        let tight = try #require(clustered[.fieldPrecision]?.interval)
        let wide = try #require(scattered[.fieldPrecision]?.interval)
        #expect(tight != wide, "grouping decides what a draw can contain")
        #expect(clustered[.fieldPrecision]?.clusterCount == 5)
        #expect(scattered[.fieldPrecision]?.clusterCount == 6)
        // Twelve of twenty-four either way: the rate is blind to the structure, the
        // band is not, which is the division PLAN §8.2 draws.
        #expect(clustered[.fieldPrecision]?.rate == scattered[.fieldPrecision]?.rate)
        #expect(clustered[.fieldPrecision]?.rate.estimate == 0.5)
        #expect(tight.lowerBound < 0.5 && tight.upperBound > 0.5)
    }

    @Test("indices selects rows of the table, not positions within the cut")
    func indicesAddressTheCorpusNotTheStratum() throws {
        // Every other bootstrap case in this file hands `indices` as the identity
        // array, where the two index domains coincide and mixing them up is invisible.
        // Here nine rows sit in the table and only the last six form the stratum: the
        // first three projects are correct and outside the cut, so reading
        // `rows[offset]` where `rows[indices[offset]]` belongs would charge the stratum
        // with rows that are not in it - 24/36 pooled rather than 12/24 - and the band
        // would quietly be drawn from the wrong projects.
        let field = EvaluationMeasure.allCases.firstIndex(of: .fieldPrecision)!
        func columns(_ numerator: Int, _ denominator: Int) -> [(numerator: Int, denominator: Int)] {
            EvaluationMeasure.allCases.indices.map { $0 == field ? (numerator, denominator) : (0, 0) }
        }
        let right = columns(4, 4)
        let wrong = columns(0, 4)
        // The first three rows deliberately share their cluster names with the first
        // three rows of the cut. Charging by position instead of by row therefore
        // collapses six clusters into three and puts a right row and a wrong row in
        // each of them - every draw then yields exactly the pooled rate, so the band
        // collapses to a point. Both of those are asserted below, because the pooled
        // sum alone cannot tell the two readings apart.
        let table = EvaluationFixtures.rows(
            [right, right, right, right, right, right, wrong, wrong, wrong],
            keys: ["d", "e", "f", "d", "e", "f", "g", "h", "i"])
        let summary = ClusterBootstrap.summarize(measures: [.fieldPrecision], rows: table,
                                                 indices: Array(3..<9), resamples: 400, seed: 5)
        let row = try #require(summary[.fieldPrecision])
        #expect(row.rate.numerator == 12 && row.rate.denominator == 24)
        #expect(row.rate.estimate == 0.5)
        #expect(row.clusterCount == 6, "d, e, f once each, then g, h, i: the cut's own rows")
        #expect(row.interval!.lowerBound < 0.5 && row.interval!.upperBound > 0.5,
                "three projects right and three wrong is a stratum that varies")
        // Same table, whole corpus: `d`, `e` and `f` now hold two right rows apiece,
        // so nine rows make six clusters and a different pooled rate.
        let everything = ClusterBootstrap.summarize(measures: [.fieldPrecision], rows: table,
                                                    indices: Array(0..<9), resamples: 400, seed: 5)
        #expect(everything[.fieldPrecision]?.rate.estimate == 24.0 / 36.0)
        #expect(everything[.fieldPrecision]?.clusterCount == 6)
    }

    @Test("the band reads what each project contains, not only how many there are")
    func resamplingReflectsClusterComposition() throws {
        // Ten rows, five clusters of two, pooled ratio 20/40 either way. The balanced
        // partition gives every project one right row and one wrong row, so each
        // cluster is 4/8 and no draw - however it repeats clusters - can leave 0.5:
        // its band collapses to a point, which is the honest reading of "no project
        // here differs from another". The clumped partition parks two whole projects
        // at 8/8 and 0/8, so a draw can lean either way and the band opens. Had the
        // per-cluster totals been accumulated per row, or the grouping been ignored,
        // both partitions would return the same width and nothing here would say so.
        let field = EvaluationMeasure.allCases.firstIndex(of: .fieldPrecision)!
        func columns(_ numerator: Int, _ denominator: Int) -> [(numerator: Int, denominator: Int)] {
            EvaluationMeasure.allCases.indices.map { $0 == field ? (numerator, denominator) : (0, 0) }
        }
        let right = columns(4, 4)
        let wrong = columns(0, 4)
        let balancedRows = [right, wrong, right, wrong, right, wrong, right, wrong, right, wrong]
        let balancedKeys = ["b0", "b0", "b1", "b1", "b2", "b2", "b3", "b3", "b4", "b4"]
        let clumpedRows = [right, right, wrong, wrong, right, wrong, right, wrong, right, wrong]
        let clumpedKeys = ["c0", "c0", "c1", "c1", "c2", "c2", "c3", "c3", "c4", "c4"]
        let indices = Array(0..<10)
        let balanced = ClusterBootstrap.summarize(measures: [.fieldPrecision],
                                                  rows: EvaluationFixtures.rows(balancedRows, keys: balancedKeys),
                                                  indices: indices, resamples: 400, seed: 23)
        let clumped = ClusterBootstrap.summarize(measures: [.fieldPrecision],
                                                rows: EvaluationFixtures.rows(clumpedRows, keys: clumpedKeys),
                                                indices: indices, resamples: 400, seed: 23)
        let point = try #require(balanced[.fieldPrecision]?.interval)
        let spread = try #require(clumped[.fieldPrecision]?.interval)
        #expect(balanced[.fieldPrecision]?.rate == clumped[.fieldPrecision]?.rate)
        #expect(balanced[.fieldPrecision]?.clusterCount == 5)
        #expect(clumped[.fieldPrecision]?.clusterCount == 5)
        #expect(point == 0.5...0.5, "every cluster is the pooled rate, so every draw is too")
        #expect(spread.upperBound - spread.lowerBound > 0)
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

        let table = EvaluationFixtures.rows(cases, runProfile: ProjectArchiveContract.id)
        func hold(_ sample: [CaseJudgement]) -> ClosedRange<Double>? {
            ClusterBootstrap.summarize(measures: [.holdRate],
                                       rows: EvaluationFixtures.rows(sample, runProfile: ProjectArchiveContract.id),
                                       indices: Array(sample.indices),
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
                                                    rows: EvaluationFixtures.rows(few, runProfile: ProjectArchiveContract.id),
                                                    indices: Array(few.indices))
        let fewClusters = try #require(fewSummary[.holdRate]?.clusterCount)
        #expect(fewClusters < ClusterBootstrap.minimumClusters)

        // Asking for one measure must not change its interval: the draws are shared
        // across the columns, so a subset request is a projection, not a resample.
        let all = ClusterBootstrap.summarize(rows: table, indices: Array(cases.indices),
                                            resamples: 200, seed: 0x9E37_79B9_7F4A_7C15)
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
        let summary = ClusterBootstrap.summarize(
            rows: EvaluationFixtures.rows(cases, runProfile: ProjectArchiveContract.id),
            indices: Array(cases.indices))
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
        let summaries = ClusterBootstrap.summarize(
            rows: EvaluationFixtures.rows(cases, runProfile: ProjectArchiveContract.id),
            indices: Array(cases.indices))
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
        let summaries = ClusterBootstrap.summarize(
            rows: EvaluationFixtures.rows(cases, runProfile: ProjectArchiveContract.id),
            indices: Array(cases.indices))
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

        // A record that went out on its own is not a refusal at file level, so the
        // record half stays empty - but the fields it left unfilled are still the
        // reviewer's work, so the slot half counts them. That asymmetry is the point:
        // the incomplete auto-publish is exactly the case a reason table exists for,
        // and skipping it would make these totals disagree with `missed_fill_rate`.
        let mapped = EvaluationFixtures.judgement(reference,
                                                  entry: EvaluationFixtures.candidate([.completionyear: "2026"],
                                                                                       gold: reference))
        #expect(mapped.isAutoMapped)
        let refusal = EvaluationMetrics.refusals([mapped])
        #expect(refusal.byRecordState.isEmpty)
        #expect(refusal.bySlotStatus == [FieldOutcome.Status.unknown.rawValue: 1])
        // The totals have to agree, or the two tables describe different runs.
        let missed = try #require(EvaluationMetrics.slices(for: [mapped])
            .first { $0.measure == .missedFillRate && $0.stratum == .overall })
        #expect(missed.rate.numerator == refusal.bySlotStatus.values.reduce(0, +))
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

        // Two draws are a worse case than one, not a better one: the 2.5th and 97.5th
        // percentile of two samples are the same sample under the index arithmetic, so
        // a run of two would publish a zero-width band as a confidence band. The floor
        // is what separates "no band" from a band that is an artefact of rounding, and
        // it is harness policy (§5), not a clause from SPEC or PLAN.
        let few = EvaluationMetrics.slices(for: cases,
                                           request: EvaluationMetrics.Request(resamples: 2))
        let thin = try #require(few.first { $0.measure == .coverage && $0.stratum == .overall })
        #expect(thin.clusterInterval == nil)
        #expect(thin.rate.denominator == 40, "the rate itself is still measured")

        let atTheFloor = ClusterBootstrap.minimumResamples
        let enough = EvaluationMetrics.slices(for: cases,
                                             request: EvaluationMetrics.Request(resamples: atTheFloor))
        let broad = try #require(enough.first { $0.measure == .coverage && $0.stratum == .overall })
        #expect(broad.clusterInterval != nil, "at the floor the two indices land apart")
    }

    @Test("a multi-profile run leaves the overall precision unmeasured rather than zero")
    func unattributedRunHasNoPrecisionRow() throws {
        // The consequence of the previous test, at the table level: a run that mixed
        // two Profiles never said which one its files were judged under, so the
        // pooled row must not read as an observed 0%. The per-Profile cuts do have
        // the number, which is what they exist for.
        let forVendor = try EvaluationFixtures.gold("g1", expected: [.completionyear: "2026"],
                                                    profiles: [VendorLibraryContract.id])
        let forArchive = try EvaluationFixtures.gold("g2", expected: [.completionyear: "2026"],
                                                     profiles: [ProjectArchiveContract.id])
        let vendorCase = EvaluationFixtures.judgement(
            forVendor, entry: EvaluationFixtures.candidate([.completionyear: "2026"], gold: forVendor))
        let archiveCase = EvaluationFixtures.judgement(
            forArchive, entry: EvaluationFixtures.candidate([.completionyear: "2026"], gold: forArchive))
        let slices = EvaluationMetrics.slices(for: [vendorCase, archiveCase])
        let overall = try #require(slices.first { $0.measure == .precisionAuto && $0.stratum == .overall })
        #expect(overall.rate.denominator == 0)
        #expect(overall.rate.estimate == nil, "N/A, per PLAN §8.2")
        #expect(!overall.isQuotableOnOwnMerits, "an unmeasured row is never quotable")
        #expect(overall.clusterCount == 2, "two records, so cause (a) applies to the band too")
        #expect(overall.clusterInterval == nil)

        let archive = try #require(slices.first { $0.measure == .precisionAuto && $0.stratum == .profile
            && $0.key == ProjectArchiveContract.id })
        #expect(archive.rate == EvaluationRate(numerator: 1, denominator: 1))
        // `coverage` does not depend on attribution, so it keeps its population: the
        // run really did say how many files went out on their own.
        let coverage = try #require(slices.first { $0.measure == .coverage && $0.stratum == .overall })
        #expect(coverage.rate.denominator == 2)
    }

    @Test("a field row is sparse on its own evidence, not on the run's size")
    func fieldRowSparsityFollowsItsEvidence() throws {
        // Forty records make the cut look ample; the field where only two files
        // asserted anything is not measured forty times. `isSparse` and quotability
        // have to follow the row, or `sparseCaseLimit` guards nothing here.
        let cases: [CaseJudgement] = try (0..<40).map { index in
            let reference = try EvaluationFixtures.gold("f\(index)", expected: [.completionyear: "2026"])
            let set: [MetadataFieldID: String?] = index < 2 ? [.completionyear: "2026", .tenderreference: "TB-\(index)"]
                : [.completionyear: "2026"]
            return EvaluationFixtures.judgement(reference,
                                                entry: EvaluationFixtures.candidate(set, gold: reference))
        }
        let slices = EvaluationMetrics.slices(for: cases)
        let tender = try #require(slices.first { $0.measure == .fieldPrecision && $0.stratum == .field
            && $0.key == MetadataFieldID.tenderreference.rawValue })
        #expect(tender.rate.denominator == 2)
        #expect(tender.caseCount == 2)
        #expect(tender.clusterCount == 2, "the row's clusters are the projects behind its own assertions")
        #expect(tender.isSparse)
        #expect(!tender.isQuotableOnOwnMerits)

        let year = try #require(slices.first { $0.measure == .fieldPrecision && $0.stratum == .field
            && $0.key == MetadataFieldID.completionyear.rawValue })
        #expect(year.caseCount == 40)
        #expect(!year.isSparse)
        #expect(year.isQuotableOnOwnMerits)

        let pooled = try #require(slices.first { $0.measure == .fieldPrecision && $0.stratum == .overall })
        #expect(pooled.caseCount == 40, "the pooled row keeps the cut's record count")
        #expect(pooled.rate.denominator == 42)
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
