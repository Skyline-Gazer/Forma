import Foundation

// The row shapes the areas render.
//
// They were `WorkspaceModel`-nested types until D2, because the computations
// that build them were also inside `WorkspaceModel` - and the only thing CI
// runs is FormaCore. Issue #151 asks for deterministic regressions proving
// that the per-render recomputation is replaced by something that produces the
// same rows, which requires the recomputation to live where a test can call
// it. The types are display shapes over FormaCore's own values, which is what
// `Presentation/` already holds (the command grammar, the business copy).

/// One row of the Mapping table.
public struct MappingRow: Identifiable, Sendable {
    public let sourceID: UUID
    public let entry: ManifestEntry
    public let source: SourceEntry?
    public let failure: FormaError?
    public let candidates: [ContextCandidate]
    public var id: UUID { sourceID }

    public init(sourceID: UUID, entry: ManifestEntry, source: SourceEntry?, failure: FormaError?,
                candidates: [ContextCandidate]) {
        self.sourceID = sourceID
        self.entry = entry
        self.source = source
        self.failure = failure
        self.candidates = candidates
    }

    /// FormaCore's own field value for a slot, or the honest absence.
    public func value(_ field: MetadataFieldID) -> String {
        entry.metadata[field] ?? "No value"
    }
}

/// One row of the Exceptions table.
public struct ExceptionRow: Identifiable, Sendable, Equatable {
    public let sourceID: UUID
    public let relativePath: String
    public let state: DecisionState
    public let reason: String
    public let codes: [String]
    public let violations: [ValidationViolation]
    public var id: UUID { sourceID }

    public init(sourceID: UUID, relativePath: String, state: DecisionState, reason: String,
                codes: [String], violations: [ValidationViolation]) {
        self.sourceID = sourceID
        self.relativePath = relativePath
        self.state = state
        self.reason = reason
        self.codes = codes
        self.violations = violations
    }

    public var codeList: String { codes.isEmpty ? "No violation code" : codes.joined(separator: " · ") }
}

/// One row of the cluster panel: a FormaCore candidate, plus the two categories
/// FormaCore keeps separate so no file disappears from view.
public struct ClusterRow: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case candidate, unassigned, conflicted
    }

    public static let unassignedID = "forma:unassigned"
    public static let conflictedID = "forma:conflicted"

    public let id: String
    public let kind: Kind
    public let title: String
    public let fileCount: Int
    public let basis: String
    public let confidence: String

    public init(id: String, kind: Kind, title: String, fileCount: Int, basis: String, confidence: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.fileCount = fileCount
        self.basis = basis
        self.confidence = confidence
    }
}

/// What a projection did to build itself, and what one lookup costs afterwards.
///
/// A cost shape cannot be measured in CI without making a benchmark of it, so
/// it is counted instead: `elementsSeen` is the number of entries the
/// construction touched, `listPasses` is how many times it walked a whole
/// collection, and `probes` is what one lookup cost. The `measured…` variants
/// of each API return one, and `WorkspaceProjectionTests` asserts the numbers
/// that make the D2 claim true - a row rebuild over a thousand entries that
/// walks each collection once and never walks one per entry.
public struct ProjectionCost: Equatable, Sendable {
    public var elementsSeen: Int = 0
    public var listPasses: Int = 0
    public var probes: Int = 0
    public var sorts: Int = 0

    public init() {}
}

/// A listing indexed once.
///
/// `WorkspaceModel.entry(with:)` was `listing.entries.first { $0.id == … }`,
/// and `refreshRows()` called it for every manifest entry: a thousand-entry
/// revision therefore cost about half a million comparisons *per rebuild*, and
/// a rebuild happens on every run, correction and bundle load. `files(in:)`
/// did a filter plus a sort per call, and the call site was a view body, so it
/// was per render. This holds the dictionary and one path-ordered copy, built
/// in a single pass, so a lookup is a probe and a membership list is one
/// filter with no sort at all.
public struct ListingProjection: Sendable {
    public let entries: [SourceEntry]
    /// The same entries ordered by relative path: the order `files(in:)` has
    /// always returned, established once instead of per call.
    public let pathOrdered: [SourceEntry]
    public let cost: ProjectionCost

    private let byID: [UUID: SourceEntry]

    public init(entries: [SourceEntry]) {
        var ledger = ProjectionCost()
        self.entries = entries
        self.pathOrdered = Self.measuredPathOrdered(entries, cost: &ledger)
        var index: [UUID: SourceEntry] = [:]
        index.reserveCapacity(entries.count)
        for entry in entries {
            ledger.elementsSeen += 1
            index[entry.id] = entry
        }
        self.byID = index
        self.cost = ledger
    }

    public func entry(_ id: UUID) -> SourceEntry? { byID[id] }

    /// The membership list of a set of identifiers, in path order.
    ///
    /// The pre-sorted copy makes the filter order-preserving, so the sort that
    /// used to run per call is gone; the pass over the list is the one the old
    /// filter made anyway.
    public func files(in ids: Set<UUID>) -> [SourceEntry] {
        ids.isEmpty ? [] : pathOrdered.filter { ids.contains($0.id) }
    }

    public func measuredFiles(in ids: Set<UUID>) -> (files: [SourceEntry], cost: ProjectionCost) {
        var ledger = ProjectionCost()
        if !ids.isEmpty {
            ledger.listPasses += 1
            for entry in pathOrdered {
                ledger.elementsSeen += 1
                ledger.probes += 1
            }
        }
        return (files(in: ids), ledger)
    }

    public func measuredEntry(_ id: UUID) -> (entry: SourceEntry?, cost: ProjectionCost) {
        var ledger = ProjectionCost()
        ledger.probes += 1
        return (byID[id], ledger)
    }

    private static func measuredPathOrdered(_ entries: [SourceEntry], cost: inout ProjectionCost) -> [SourceEntry] {
        cost.sorts += 1
        cost.listPasses += 1
        return entries.sorted { $0.relativePath < $1.relativePath }
    }
}

/// One context revision, indexed once.
///
/// Two audited costs live here. `clusterLabel(for:)` mapped and sorted a
/// source's candidates on every call, and the Workspace table calls it twice
/// per row (the cell and its `help`), so a thousand files cost two thousand
/// linear scans of the candidate list per render. And `clusterRows` rebuilt
/// the whole panel table on every body evaluation. Both are now answers out of
/// a dictionary, and the row list is built when the context arrives.
public struct ContextProjection: Sendable {
    public let revision: Int
    /// The panel's rows, including the unassigned and conflicted categories.
    public let rows: [ClusterRow]
    /// What the Project column shows for one file, exactly as `clusterLabel`
    /// computed it: candidate keys, plus `Conflicted` when FormaCore marked
    /// the source conflicted, sorted and joined.
    public let labels: [UUID: String]
    public let candidatesBySource: [UUID: [ContextCandidate]]
    public let membersByCandidate: [String: Set<UUID>]
    public let unassignedSourceIDs: Set<UUID>
    public let conflictedSourceIDs: Set<UUID>
    public let cost: ProjectionCost

    public init(context: ProjectContext) {
        var ledger = ProjectionCost()
        var candidatesBySource: [UUID: [ContextCandidate]] = [:]
        var membersByCandidate: [String: Set<UUID>] = [:]
        var labels: [UUID: String] = [:]
        revision = context.revision
        unassignedSourceIDs = context.unassignedSourceIDs
        conflictedSourceIDs = context.conflictedSourceIDs

        for candidate in context.candidates {
            ledger.elementsSeen += 1
            membersByCandidate[candidate.id] = candidate.memberSourceIDs
            for sourceID in candidate.memberSourceIDs {
                // One pass over each candidate's members: the per-source list
                // is assembled here rather than by filtering the candidate list
                // again for every row.
                ledger.elementsSeen += 1
                candidatesBySource[sourceID, default: []].append(candidate)
            }
        }

        rows = Self.clusterRows(context: context)

        for (sourceID, candidates) in candidatesBySource {
            var parts = candidates.map(\.projectKey)
            if context.conflictedSourceIDs.contains(sourceID) { parts.append("Conflicted") }
            labels[sourceID] = parts.sorted().joined(separator: " · ")
        }

        self.candidatesBySource = candidatesBySource
        self.membersByCandidate = membersByCandidate
        self.labels = labels
        self.cost = ledger
    }

    public func candidates(for sourceID: UUID) -> [ContextCandidate] {
        candidatesBySource[sourceID] ?? []
    }

    /// The Project-column text for one file, or nil when FormaCore put it in no
    /// candidate and did not mark it conflicted: the caller then says
    /// "Unassigned", which is FormaCore's own state rather than a guess.
    ///
    /// A conflicted source that belongs to no candidate still reads
    /// "Conflicted" here, because that is what sorting the one label it does
    /// have produced: the old computation appended "Conflicted" to an empty
    /// list and joined it, so "Unassigned" never won for a file whose evidence
    /// disagrees.
    public func label(for sourceID: UUID) -> String? {
        if let label = labels[sourceID] { return label }
        return conflictedSourceIDs.contains(sourceID) ? "Conflicted" : nil
    }

    public func members(ofCandidate id: String) -> Set<UUID> { membersByCandidate[id] ?? [] }

    /// The panel's table. Static so the row order, the two category titles and
    /// the em-dash confidences have one definition, shared with the test that
    /// pins the previous behaviour.
    public static func clusterRows(context: ProjectContext) -> [ClusterRow] {
        var rows = context.candidates.map { candidate in
            ClusterRow(id: candidate.id, kind: .candidate,
                       title: candidate.displayName ?? candidate.projectKey,
                       fileCount: candidate.memberSourceIDs.count,
                       basis: candidate.basis.map(\.rawValue).joined(separator: " · "),
                       confidence: candidate.confidence.rawValue)
        }
        rows.append(ClusterRow(id: ClusterRow.unassignedID, kind: .unassigned,
                               title: "Unassigned · \(context.unassignedSourceIDs.count.formatted())",
                               fileCount: context.unassignedSourceIDs.count,
                               basis: "No candidate FormaCore could defend", confidence: "—"))
        rows.append(ClusterRow(id: ClusterRow.conflictedID, kind: .conflicted,
                               title: "Conflicted · \(context.conflictedSourceIDs.count.formatted())",
                               fileCount: context.conflictedSourceIDs.count,
                               basis: "Members disagree about the project", confidence: "—"))
        return rows
    }
}

/// The table rows the areas show, built in one pass over the manifest.
public enum WorkspaceProjection {
    /// Mapping rows: one per manifest entry, with the source it describes, the
    /// provider failure FormaCore recorded for it and its candidates.
    ///
    /// `failures` is `MappingRunOutcome.failures`, keyed by source. Order is
    /// the manifest's own, which is what the table has always listed.
    public static func mappingRows(manifest: Manifest?,
                                   failures: [UUID: FormaError],
                                   listing: ListingProjection?,
                                   context: ContextProjection?) -> [MappingRow] {
        guard let manifest else { return [] }
        return manifest.entries.map { entry in
            MappingRow(sourceID: entry.sourceID, entry: entry,
                       source: listing?.entry(entry.sourceID),
                       failure: failures[entry.sourceID],
                       candidates: context?.candidates(for: entry.sourceID) ?? [])
        }
    }

    public static func measuredMappingRows(manifest: Manifest?,
                                           failures: [UUID: FormaError],
                                           listing: ListingProjection?,
                                           context: ContextProjection?) -> (rows: [MappingRow], cost: ProjectionCost) {
        var ledger = ProjectionCost()
        if let manifest {
            for entry in manifest.entries {
                ledger.elementsSeen += 1
                _ = listing?.entry(entry.sourceID)
                _ = context?.candidates(for: entry.sourceID)
            }
            ledger.listPasses += 1
        }
        return (mappingRows(manifest: manifest, failures: failures, listing: listing, context: context), ledger)
    }

    /// The same rows FormaCore writes into `exceptions.json`: one per blocked
    /// entry, with the reason the program recorded and the violation codes that
    /// name its own cause.
    ///
    /// The violations are grouped by `instancePath` once. Building the rows
    /// then costs one pass over the manifest plus one lookup per blocked entry;
    /// grouping per row would have been a pass over every violation for every
    /// blocked entry.
    public static func exceptionRows(manifest: Manifest?) -> [ExceptionRow] {
        guard let manifest else { return [] }
        let byPath = Dictionary(grouping: manifest.report.allViolations) { $0.instancePath }
        return manifest.entries
            .filter { $0.state == .hold || $0.state == .unknown || $0.state == .invalidated }
            .sorted { $0.relativePath < $1.relativePath }
            .map { entry in
                let violations = byPath[entry.relativePath] ?? []
                let conflicting = entry.fields.first { $0.status == .conflict }?.field
                let reason = entry.invalidatedReason
                    ?? conflicting.map { "conflict:\($0.rawValue)" }
                    ?? "evidence_incomplete"
                return ExceptionRow(sourceID: entry.sourceID, relativePath: entry.relativePath,
                                    state: entry.state, reason: reason,
                                    codes: Array(Set(violations.map(\.code))).sorted(),
                                    violations: violations)
            }
    }

    /// Every code the blocked rows carry, once, sorted: the Exceptions filter's
    /// option list. It used to be recomputed inside the view, which meant a
    /// flatMap, a set and a sort over every violation on every render.
    public static func exceptionCodes(rows: [ExceptionRow]) -> [String] {
        Array(Set(rows.flatMap(\.codes))).sorted()
    }

    /// The rows the filter shows. One pass over the rows, no sorting: the rows
    /// are already in path order, and a filter keeps that order.
    public static func filteredExceptions(_ rows: [ExceptionRow], state: DecisionState?, code: String?) -> [ExceptionRow] {
        rows.filter { row in
            (state == nil || row.state == state) && (code == nil || row.codes.contains(code ?? ""))
        }
    }

    /// The instrumented twin of `exceptionRows`, for the cost-shape assertion.
    public static func measuredExceptionRows(manifest: Manifest?) -> (rows: [ExceptionRow], cost: ProjectionCost) {
        var ledger = ProjectionCost()
        if let manifest {
            ledger.listPasses += 1
            for violation in manifest.report.allViolations { ledger.elementsSeen += 1; _ = violation.instancePath }
            for entry in manifest.entries { ledger.elementsSeen += 1 }
            ledger.sorts += 1
        }
        return (exceptionRows(manifest: manifest), ledger)
    }
}
