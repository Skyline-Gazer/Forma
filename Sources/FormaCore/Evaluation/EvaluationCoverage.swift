import Foundation

/// Which scenarios this run actually measured, beside the ones the split holds.
///
/// This is a census, not a rate: it adds no numerator and no denominator to
/// §3, and `EvaluationReport.slices` remains the only place a scenario is
/// measured. What it adds is the case a rate table cannot show — a scenario with
/// no row at all looks exactly like a scenario nobody needed, and the difference
/// is the whole point of publishing coverage.
///
/// A gap is stated, never inferred from silence: `untested` means the split does
/// not count that scenario, `unreached` means it counts records but none of them
/// produced a judgement, and `partial` means some countable records were not
/// judged. Which of those is acceptable is a review decision, not this type's.
public struct EvaluationCoverage: Codable, Sendable, Equatable {
    public struct Cell: Codable, Sendable, Equatable {
        /// `GoldRecord.Category`'s raw value.
        public let category: String
        /// Countable records the dataset report attributes to this scenario.
        public let countable: Int
        /// Cases in this run whose reference answer carries this scenario.
        public let evaluated: Int

        public init(category: String, countable: Int, evaluated: Int) {
            self.category = category
            self.countable = countable
            self.evaluated = evaluated
        }
    }

    /// One row per declared scenario, in the schema's own order.
    public let cells: [Cell]
    /// Declared scenarios this split does not count at all.
    public let untested: [String]
    /// Scenarios with countable records but no judged case in this run.
    public let unreached: [String]
    /// Scenarios where some countable records produced no judgement.
    public let partial: [String]
    /// Category keys found in the dataset report that the record schema does not
    /// declare. Reported rather than dropped: an unknown key is a schema
    /// mismatch, not an empty scenario.
    public let undeclared: [String]

    public init(cells: [Cell], untested: [String], unreached: [String], partial: [String],
                undeclared: [String]) {
        self.cells = cells
        self.untested = untested
        self.unreached = unreached
        self.partial = partial
        self.undeclared = undeclared
    }

    /// Counts judged cases per scenario and pairs them with the dataset's own
    /// countable counts. The two numbers come from different places on purpose:
    /// `evaluated` is what this run did, `countable` is what the split allows.
    public static func compute(cases: [CaseJudgement], dataset: GoldDataset.Report) -> EvaluationCoverage {
        var evaluated: [String: Int] = [:]
        for judgement in cases {
            evaluated[judgement.category.rawValue, default: 0] += 1
        }

        let declared = GoldRecord.Category.allCases.map(\.rawValue)
        var cells = declared.map { raw in
            Cell(category: raw,
                 countable: dataset.perCategoryCountable[raw] ?? 0,
                 evaluated: evaluated[raw] ?? 0)
        }
        let undeclared = dataset.perCategoryCountable.keys.filter { !declared.contains($0) }.sorted()
        cells += undeclared.map { Cell(category: $0, countable: dataset.perCategoryCountable[$0] ?? 0,
                                       evaluated: evaluated[$0] ?? 0) }

        return EvaluationCoverage(
            cells: cells,
            untested: cells.filter { $0.countable == 0 }.map(\.category),
            unreached: cells.filter { $0.countable > 0 && $0.evaluated == 0 }.map(\.category),
            partial: cells.filter { $0.evaluated > 0 && $0.evaluated < $0.countable }.map(\.category),
            undeclared: undeclared)
    }
}
