import Foundation
import Testing

@testable import FormaCore

/// The indexed presentation layer #151 audit item 3 replaces.
///
/// Each test here compares the new indexed computation against the previous
/// one, restated in full, over the three fixture sizes the issue asks for:
/// empty, six files, and a thousand synthetic entries. The old code is written
/// out rather than remembered, because the claim being protected is not "the
/// new code is fast" but "the new code answers the same questions" - and a row
/// that silently changed order, dropped a `Conflicted` label or re-sorted the
/// exception list would be a correctness regression dressed as a performance
/// fix.
///
/// Cost is asserted as counted work (`ProjectionCost`), never as elapsed time:
/// a duration in CI measures the runner, a pass count measures the algorithm.
struct WorkspaceProjectionTests {
    // MARK: - Fixtures

    private func source(_ index: Int, revision: Int64 = 1, path: String? = nil) -> SourceEntry {
        let relativePath = path ?? "示例项目_2026/\(String(format: "%04d", index))/文件\(index).pdf"
        return SourceEntry(id: UUID(uuidString: Self.uuid(index))!, rootID: UUID(),
                           relativePath: relativePath,
                           normalizedRelativePath: relativePath.lowercased(), state: .present,
                           hydrationPending: false, sourceVersion: 1, snapshotRevision: revision,
                           provider: .local, snapshotFingerprint: String(repeating: "a", count: 64),
                           sizeBytes: 1_024, modificationTimeNanoseconds: 1, sha256: nil)
    }

    private func entry(_ index: Int, state: DecisionState = .validated, revision: Int = 1,
                       reason: String? = nil, conflictField: MetadataFieldID? = nil) -> ManifestEntry {
        var fields: [FieldOutcome] = []
        if let conflictField {
            fields = [FieldOutcome(field: conflictField, value: "x", status: .conflict,
                                   evidenceIDs: [], conflicts: ["两个来源"])]
        }
        return ManifestEntry(sourceID: UUID(uuidString: Self.uuid(index))!,
                             snapshotFingerprint: String(repeating: "a", count: 64),
                             snapshotRevision: revision, sourceVersion: 1,
                             relativePath: "示例项目_2026/\(String(format: "%04d", index))/文件\(index).pdf",
                             state: state,
                             target: ManifestTarget(databaseName: "Project_Archive",
                                                    groupPath: ["2026", "示例项目_2026"], resolved: true),
                             metadata: .allUnknown, fields: fields, associations: [],
                             eligibleForAutoExecution: state == .validated,
                             invalidatedReason: reason, confidence: .high, providerReasoning: nil)
    }

    /// A deterministic identifier, so two runs of the same fixture compare
    /// against each other instead of against random ids.
    private static func uuid(_ index: Int) -> String {
        let hex = String(format: "%012x", index)
        return "00000000-0000-4000-8000-\(hex)"
    }

    private func manifest(_ entries: [ManifestEntry], violations: [ValidationViolation] = []) throws -> Manifest {
        let envelope = ManifestEnvelope(
            manifestID: UUID(), revision: 1, supersedesRevision: nil, scopeID: UUID(),
            sourceRootID: UUID(), profile: try MappingProfile.projectArchive(),
            casePack: ("forma-governance-cases", "1.0"), modelProvider: "anthropic",
            modelID: "claude-haiku-4-5-20251001", contextRevision: 1,
            promptVersion: MappingPrompt.version, extractorVersion: EvidenceRegistry.extractorVersion,
            redactionVersion: nil, inputDigest: String(repeating: "2", count: 64),
            contextDigest: String(repeating: "3", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), state: .draft)
        var report = ValidationReport()
        if !violations.isEmpty {
            report.record(ValidationGroupResult(group: .evidence, status: .failed, violations: violations))
        }
        return Manifest(envelope: envelope, entries: entries, report: report)
    }

    private func candidate(_ id: String, key: String, members: [Int],
                           confidence: DecisionConfidence = .high) -> ContextCandidate {
        ContextCandidate(id: id, projectKey: key, displayName: nil,
                         basis: [.directory, .naming],
                         memberSourceIDs: Set(members.map { UUID(uuidString: Self.uuid($0))! }),
                         confidence: confidence)
    }

    private func context(_ candidates: [ContextCandidate], unassigned: [Int] = [],
                         conflicted: [Int] = []) -> ProjectContext {
        ProjectContext(revision: 7, scopeID: UUID(), profileID: "project-archive", profileVersion: "1.0",
                       inputDigest: String(repeating: "4", count: 64), candidates: candidates,
                       unassignedSourceIDs: Set(unassigned.map { UUID(uuidString: Self.uuid($0))! }),
                       conflictedSourceIDs: Set(conflicted.map { UUID(uuidString: Self.uuid($0))! }),
                       builtAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func record(_ index: Int, sourceID: Int, revision: Int = 1) -> EvidenceRecord {
        EvidenceRecord(id: "e\(index)-r\(revision)", sourceID: UUID(uuidString: Self.uuid(sourceID))!,
                       snapshotRevision: revision,
                       snapshotFingerprint: String(repeating: "a", count: 64),
                       source: .content, locator: nil, relativePath: "f\(index).txt",
                       excerpt: "excerpt \(index)", extractionStatus: .ok,
                       extractorVersion: EvidenceRegistry.extractorVersion,
                       createdAt: Date(timeIntervalSince1970: 1))
    }

    // MARK: - The listing index, and the linear scan it replaced

    /// `WorkspaceModel.entry(with:)` used to be
    /// `listing.entries.first { $0.id == sourceID }`.
    private func naiveEntry(_ entries: [SourceEntry], _ id: UUID) -> (SourceEntry?, comparisons: Int) {
        var comparisons = 0
        for candidate in entries {
            comparisons += 1
            if candidate.id == id { return (candidate, comparisons) }
        }
        return (nil, comparisons)
    }

    private func naiveFiles(_ entries: [SourceEntry], in ids: Set<UUID>) -> [SourceEntry] {
        entries.filter { ids.contains($0.id) }.sorted { $0.relativePath < $1.relativePath }
    }

    @Test func lookupsMatchTheLinearScanAtEveryFixtureSize() throws {
        for size in [0, 1, 6, 1_000] {
            let entries: [SourceEntry] = size == 0 ? [] : (1 ... size).map { source($0) }
            let index = ListingProjection(entries: entries)
            #expect(index.entry(entries.first?.id ?? UUID()) == (size == 0 ? nil : entries.first))
            for entry in entries {
                #expect(index.entry(entry.id) == entry)
            }
            // A source that is not in this listing answers nil, exactly as the
            // scan did - it must not fall through to some other file's entry.
            #expect(index.entry(UUID()) == nil)

            let half = Set(entries.dropFirst(entries.count / 2).map(\.id))
            #expect(index.files(in: half) == naiveFiles(entries, in: half))
            #expect(index.files(in: []) == [])
            #expect(index.files(in: Set(entries.map(\.id))) == naiveFiles(entries, in: Set(entries.map(\.id))))
        }
    }

    @Test func lookupCostIsOneProbeWhileTheScanGrowsWithTheListing() throws {
        let entries = (1 ... 1_000).map { source($0) }
        let index = ListingProjection(entries: entries)
        var scanComparisons = 0
        for entry in entries { scanComparisons += naiveEntry(entries, entry.id).comparisons }
        var probed = 0
        for entry in entries {
            let (_, cost) = index.measuredEntry(entry.id)
            probed += cost.probes
        }
        // The old rebuild of a thousand-entry table cost on the order of half a
        // million comparisons. It now costs one probe per row, so the second
        // number is the size of the table and the first is its square.
        #expect(probed == 1_000)
        #expect(scanComparisons > 500_000)
        #expect(index.cost.sorts == 1, "the path order is established once, not per call")
        #expect(index.cost.listPasses == 1)
    }

    @Test func membershipListsTakeOnePassAndNoSort() throws {
        let entries = (1 ... 1_000).map { source($0) }
        let index = ListingProjection(entries: entries)
        let ids = Set(entries.map(\.id))
        let (files, cost) = index.measuredFiles(in: ids)
        #expect(files.count == 1_000)
        #expect(cost.sorts == 0, "the filtered list comes out of a copy that was already ordered")
        #expect(cost.listPasses == 1)
        #expect(files == naiveFiles(entries, in: ids))
    }

    // MARK: - Mapping rows

    /// The previous construction, restated: one manifest entry at a time, each
    /// asking the listing for its source by scanning, and the candidate list by
    /// filtering.
    private func naiveMappingRows(manifest: Manifest, listing: [SourceEntry],
                                  failures: [UUID: FormaError],
                                  context: ProjectContext?) -> [MappingRow] {
        manifest.entries.map { entry in
            MappingRow(sourceID: entry.sourceID, entry: entry,
                       source: listing.first { $0.id == entry.sourceID },
                       failure: failures[entry.sourceID],
                       candidates: context?.candidate(for: entry.sourceID) ?? [])
        }
    }

    @Test func mappingRowsAreIdenticalToThePerEntryScan() throws {
        for size in [0, 1, 6, 1_000] {
            let entries: [ManifestEntry] = size == 0 ? [] : (1 ... size).map { entry($0, state: $0.isMultiple(of: 3) ? .hold : .validated) }
            let trimmed = size == 0 ? [] : entries
            let manifest = try manifest(trimmed)
            let sources = trimmed.indices.map { source($0 + 1) }
            let members = trimmed.indices.map { $0 + 1 }
            let context = size == 0 ? nil
                : self.context([candidate("c1", key: "示例项目_2026", members: Array(members.prefix(3))),
                                candidate("c2", key: "另一项目", members: Array(members.suffix(3)))])
            let projection = ListingProjection(entries: sources)
            let failures: [UUID: FormaError] = trimmed.first.map { [$0.sourceID: .storage] } ?? [:]

            let actual = WorkspaceProjection.mappingRows(manifest: size == 0 ? nil : manifest,
                                                         failures: failures, listing: projection,
                                                         context: context.map { ContextProjection(context: $0) })
            let expected = size == 0 ? []
                : naiveMappingRows(manifest: manifest, listing: sources, failures: failures, context: context)
            #expect(actual.count == expected.count)
            for (a, b) in zip(actual, expected) {
                #expect(a.sourceID == b.sourceID)
                #expect(a.entry.relativePath == b.entry.relativePath)
                #expect(a.source == b.source)
                #expect(a.candidates.map(\.id) == b.candidates.map(\.id))
                #expect(a.failure == b.failure)
            }
            // Order is the manifest's own, not a sort - the table's row order
            // is what the selection and the export both refer to.
            #expect(actual.map(\.sourceID) == trimmed.map(\.sourceID))
        }
    }

    @Test func mappingRowRebuildWalksEachCollectionOnce() throws {
        let manifest = try manifest((1 ... 1_000).map { entry($0) })
        let projection = ListingProjection(entries: (1 ... 1_000).map { source($0) })
        let context = ContextProjection(context: self.context(
            [candidate("c1", key: "示例项目_2026", members: Array(1 ... 500)),
             candidate("c2", key: "另一项目", members: Array(501 ... 1_000))]))
        let (_, cost) = WorkspaceProjection.measuredMappingRows(manifest: manifest, failures: [:],
                                                               listing: projection, context: context)
        // One pass over the manifest; the sources and the candidates are asked
        // by key. The shape, not the clock: on any machine this is linear.
        #expect(cost.elementsSeen == 1_000)
        #expect(cost.listPasses == 1)
        #expect(cost.sorts == 0)
    }

    // MARK: - Exceptions

    /// The previous construction, restated from the code it replaced.
    private func naiveExceptionRows(manifest: Manifest?) -> [ExceptionRow] {
        guard let manifest else { return [] }
        let byPath = Dictionary(grouping: manifest.report.allViolations) { $0.instancePath }
        return manifest.entries
            .filter { $0.state == .hold || $0.state == .unknown || $0.state == .invalidated }
            .sorted { $0.relativePath < $1.relativePath }
            .map { row in
                let violations = byPath[row.relativePath] ?? []
                let conflicting = row.fields.first { $0.status == .conflict }?.field
                let reason = row.invalidatedReason
                    ?? conflicting.map { "conflict:\($0.rawValue)" }
                    ?? "evidence_incomplete"
                return ExceptionRow(sourceID: row.sourceID, relativePath: row.relativePath,
                                    state: row.state, reason: reason,
                                    codes: Array(Set(violations.map(\.code))).sorted(),
                                    violations: violations)
            }
    }

    @Test func exceptionRowsMatchIncludingReasonAndCodeOrder() throws {
        let blocked = [
            entry(1, state: .hold, reason: nil, conflictField: .projectname),
            entry(2, state: .unknown),
            entry(3, state: .invalidated, reason: "replaced by a new decision"),
            entry(4, state: .validated),
            entry(5, state: .hold),
        ]
        let violations = [
            ValidationViolation(code: "missing_evidence", instancePath: blocked[0].relativePath, detail: "a"),
            ValidationViolation(code: "anchor_not_found", instancePath: blocked[0].relativePath, detail: "b"),
            ValidationViolation(code: "target_unresolved", instancePath: blocked[4].relativePath, detail: "c"),
            // A violation on a path no blocked row owns stays out of the table,
            // exactly as the grouping always did.
            ValidationViolation(code: "orphan", instancePath: "另一个/文件.txt", detail: "d"),
        ]
        let manifest = try manifest(blocked, violations: violations)
        let actual = WorkspaceProjection.exceptionRows(manifest: manifest)
        let expected = naiveExceptionRows(manifest: manifest)
        #expect(actual.count == expected.count)
        for (a, b) in zip(actual, expected) {
            #expect(a.sourceID == b.sourceID)
            #expect(a.relativePath == b.relativePath)
            #expect(a.state == b.state)
            #expect(a.reason == b.reason)
            #expect(a.codes == b.codes)
            #expect(a.codeList == b.codeList)
            #expect(a.violations.map(\.code) == b.violations.map(\.code))
        }
        #expect(actual.map(\.relativePath) == actual.map(\.relativePath).sorted())
        #expect(WorkspaceProjection.exceptionRows(manifest: nil) == [])
        // The path a violation carries is what decides its rows: a row with no
        // violations of its own still appears, with the honest reason.
        #expect(actual.first { $0.sourceID == blocked[1].sourceID }?.codes == [])
        #expect(actual.first { $0.sourceID == blocked[1].sourceID }?.reason == "evidence_incomplete")
        #expect(actual.first { $0.sourceID == blocked[0].sourceID }?.codes
                == ["anchor_not_found", "missing_evidence"])
    }

    @Test func exceptionRebuildGroupsOnceRatherThanPerRow() throws {
        let entries = (1 ... 1_000).map { entry($0, state: $0.isMultiple(of: 2) ? .hold : .validated) }
        let violations = entries.filter { $0.state == .hold }.map {
            ValidationViolation(code: "missing_evidence", instancePath: $0.relativePath, detail: "d")
        }
        let manifest = try manifest(entries, violations: violations)
        let (rows, cost) = WorkspaceProjection.measuredExceptionRows(manifest: manifest)
        #expect(rows.count == 500)
        // One grouping pass over the violations plus one pass over the entries.
        // The previous code was the same two passes - this assertion is here so
        // a future "convenient" per-row `first(where:)` inside the map shows up
        // as a growing `listPasses` instead of as a slow Mac.
        #expect(cost.listPasses == 1)
        #expect(cost.elementsSeen == violations.count + entries.count)
        #expect(rows == naiveExceptionRows(manifest: manifest))
    }

    @Test func codesAndFiltersFollowThePanelRule() throws {
        let blocked = [entry(1, state: .hold), entry(2, state: .unknown), entry(3, state: .invalidated)]
        let manifest = try manifest(blocked, violations: [
            ValidationViolation(code: "zeta", instancePath: blocked[0].relativePath, detail: ""),
            ValidationViolation(code: "alpha", instancePath: blocked[0].relativePath, detail: ""),
            ValidationViolation(code: "alpha", instancePath: blocked[1].relativePath, detail: ""),
        ])
        let rows = WorkspaceProjection.exceptionRows(manifest: manifest)
        #expect(WorkspaceProjection.exceptionCodes(rows: rows) == ["alpha", "zeta"])
        #expect(WorkspaceProjection.exceptionCodes(rows: []) == [])

        let byState = WorkspaceProjection.filteredExceptions(rows, state: .hold, code: nil)
        #expect(byState.map(\.sourceID) == [blocked[0].sourceID])
        let byCode = WorkspaceProjection.filteredExceptions(rows, state: nil, code: "alpha")
        #expect(byCode.count == 2)
        #expect(WorkspaceProjection.filteredExceptions(rows, state: nil, code: nil).count == rows.count)
        #expect(WorkspaceProjection.filteredExceptions(rows, state: .validated, code: nil).isEmpty)
        // Both filters together, the way the panel applies them.
        #expect(WorkspaceProjection.filteredExceptions(rows, state: .hold, code: "alpha")
                .map(\.sourceID) == [blocked[0].sourceID])
    }

    // MARK: - Cluster labels and rows

    /// The previous per-call computation, restated from the code it replaced.
    private func naiveClusterLabel(_ sourceID: UUID, context: ProjectContext) -> String {
        var labels = context.candidate(for: sourceID).map(\.projectKey)
        if context.conflictedSourceIDs.contains(sourceID) { labels.append("Conflicted") }
        if labels.isEmpty { return "Unassigned" }
        return labels.sorted().joined(separator: " · ")
    }

    private func naiveClusterRows(context: ProjectContext) -> [ClusterRow] {
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

    @Test func labelsMatchForAssignedConflictedAndUnassignedFiles() {
        let members = Array(1 ... 6)
        let conflictedOnly = 7
        let unassigned = 8
        let context = self.context(
            [candidate("c1", key: "示例项目_2026", members: [1, 2, 3]),
             candidate("c2", key: "另一项目", members: [3, 4]),
             candidate("c3", key: "示例项目_2026", members: [5])],
            unassigned: [unassigned, conflictedOnly],
            conflicted: [3, conflictedOnly])
        let projection = ContextProjection(context: context)

        for index in members + [conflictedOnly, unassigned] {
            let id = UUID(uuidString: Self.uuid(index))!
            let expected = naiveClusterLabel(id, context: context)
            let actual = projection.label(for: id) ?? "Unassigned"
            #expect(actual == expected, "source \(index) read \(actual) instead of \(expected)")
        }
        // The three cases the table shows for the same file, each of which the
        // old code produced by re-deriving it: two candidates sorted and
        // joined, a candidate plus a conflict, and a conflict with no
        // candidate at all (which must NOT read "Unassigned").
        let dual = projection.label(for: UUID(uuidString: Self.uuid(3))!) ?? ""
        #expect(dual.split(separator: " · ").count == 3)
        // Only "sorted" is promised about the order, not which string wins, so
        // the assertion is membership rather than a pinned literal.
        #expect(Set(dual.split(separator: " · ")) == ["另一项目", "示例项目_2026", "Conflicted"])
        #expect(projection.label(for: UUID(uuidString: Self.uuid(conflictedOnly))!) == "Conflicted")
        #expect(projection.label(for: UUID(uuidString: Self.uuid(unassigned))!) == nil)
        // A duplicate candidate key stays duplicated, because the old code
        // appended rather than set-ified: two candidates that share a key
        // showed that key twice.
        let shared = self.context([candidate("a", key: "同一项目", members: [1]),
                                   candidate("b", key: "同一项目", members: [1])])
        #expect(ContextProjection(context: shared).label(for: UUID(uuidString: Self.uuid(1))!)
                == "同一项目 · 同一项目")
    }

    @Test func clusterRowsMatchAndIncludeTheTwoCategories() {
        for size in [0, 6, 1_000] {
            let members = size == 0 ? [] : Array(1 ... size)
            let context = self.context(
                size == 0 ? [] : [candidate("c1", key: "示例项目_2026", members: Array(members.prefix(400))),
                                  candidate("c2", key: "另一项目", members: Array(members.suffix(400)))],
                unassigned: members.filter { $0 % 7 == 0 },
                conflicted: members.filter { $0 % 11 == 0 })
            let projection = ContextProjection(context: context)
            #expect(projection.rows == naiveClusterRows(context: context))
            #expect(projection.rows.count == (size == 0 ? 2 : 4))
            #expect(projection.rows.last?.kind == .conflicted)
            #expect(projection.rows[projection.rows.count - 2].kind == .unassigned)
        }
    }

    @Test func labelRebuildCostDoesNotDependOnHowManyRowsAskForIt() {
        let members = Array(1 ... 1_000)
        let context = self.context([candidate("c1", key: "示例项目_2026", members: Array(members.prefix(600))),
                                    candidate("c2", key: "另一项目", members: Array(members.suffix(600)))])
        let projection = ContextProjection(context: context)
        // The table asks twice per row. Building the answers cost one pass over
        // the candidates plus one over each candidate's members; answering all
        // 2,000 asks afterwards costs nothing that scales with the candidate
        // list, which is the whole point of the projection.
        #expect(projection.cost.listPasses == 0)
        #expect(projection.cost.sorts == 0)
        #expect(projection.cost.elementsSeen == 2 + 600 + 600, "one pass per candidate plus one per member")
        for index in members {
            #expect(projection.label(for: UUID(uuidString: Self.uuid(index))!) != nil)
        }
    }

    // MARK: - The evidence read cache

    @Test func aSecondAppearanceOfTheSameRevisionDoesNotReadAgain() {
        var cache = EvidenceCache()
        let id = UUID(uuidString: Self.uuid(1))!
        let key = EvidenceCacheKey(sourceID: id, snapshotRevision: 3)
        guard case .read(let ticket) = cache.claim(key) else { Issue.record("first claim must read"); return }
        #expect(cache.misses == 1)
        #expect(cache.pendingReads == 1)
        let rows = (1 ... 6).map { record($0, sourceID: 1, revision: 3) }
        let published = cache.publish(rows, against: ticket)
        #expect(published)
        #expect(cache.pendingReads == 0)

        if case .cached(let held) = cache.claim(key) {
            #expect(held.map(\.id) == rows.map(\.id))
        } else { Issue.record("a published key must be served from the cache") }
        #expect(cache.hits == 1)
        #expect(cache.misses == 1, "the second appearance read nothing")

        // A hundred area switches and revisits, the #151 acceptance case: the
        // registry is still read once.
        for _ in 0 ..< 100 { _ = cache.claim(key) }
        #expect(cache.hits == 101)
        #expect(cache.misses == 1)
    }

    @Test func aConcurrentAppearanceIsCoalescedNotDuplicated() {
        var cache = EvidenceCache()
        let key = EvidenceCacheKey(sourceID: UUID(), snapshotRevision: 1)
        guard case .read = cache.claim(key) else { Issue.record("first claim must read"); return }
        if case .coalesced = cache.claim(key) {} else { Issue.record("a second claim must coalesce") }
        #expect(cache.coalesced == 1)
        #expect(cache.misses == 1, "coalescing must not count as a read")
        #expect(cache.pendingReads == 1)
    }

    @Test func aRescanMovesTheKeyRatherThanReusingOldRows() {
        var cache = EvidenceCache()
        let id = UUID(uuidString: Self.uuid(2))!
        let before = EvidenceCacheKey(sourceID: id, snapshotRevision: 1)
        let after = EvidenceCacheKey(sourceID: id, snapshotRevision: 2)
        guard case .read(let ticket) = cache.claim(before) else { Issue.record("first claim must read"); return }
        cache.publish([record(1, sourceID: 2, revision: 1)], against: ticket)
        // The listing now says revision 2: a different question, so a real read,
        // and the revision-1 answer is not what the new row cites.
        if case .read = cache.claim(after) {} else { Issue.record("a moved revision must read") }
        #expect(cache.storedKeys == 1)
    }

    @Test func anInvalidateLandingDuringAReadDropsThatRead() {
        // The race the original no-cache comment described, tested.
        var cache = EvidenceCache()
        let id = UUID(uuidString: Self.uuid(3))!
        let key = EvidenceCacheKey(sourceID: id, snapshotRevision: 5)
        guard case .read(let ticket) = cache.claim(key) else { Issue.record("first claim must read"); return }
        let staleRows = (1 ... 3).map { record($0, sourceID: 3, revision: 5) }
        cache.invalidate(sourceID: id)
        let publishedAfterInvalidate = cache.publish(staleRows, against: ticket)
        #expect(!publishedAfterInvalidate)
        #expect(cache.stale == 1)
        #expect(cache.rows(for: key) == nil, "a stale read stores nothing")
        #expect(cache.pendingReads == 0, "and it does not leave the key claimed forever")
        if case .read = cache.claim(key) {} else { Issue.record("after a dropped read the next one must read") }
    }

    @Test func captureAndCorrectionInvalidationForceTheNextRead() {
        var cache = EvidenceCache()
        let id = UUID(uuidString: Self.uuid(4))!
        let key = EvidenceCacheKey(sourceID: id, snapshotRevision: 1)
        guard case .read(let first) = cache.claim(key) else { Issue.record("first claim must read"); return }
        cache.publish([record(1, sourceID: 4)], against: first)
        let reclamed = cache.claim(key)
        #expect(reclamed.isCached)

        // A mapping run registered a row at the same revision: the key did not
        // move, so only the explicit invalidation can make the next chip read
        // the new set.
        cache.invalidate(sourceID: id)
        #expect(cache.invalidations == 1)
        let afterInvalidate = cache.claim(key)
        #expect(!afterInvalidate.isCached)
        #expect(cache.storedKeys == 0)
    }

    @Test func aFailedReadIsRetriedAndNotStored() {
        var cache = EvidenceCache()
        let key = EvidenceCacheKey(sourceID: UUID(), snapshotRevision: 9)
        guard case .read(let ticket) = cache.claim(key) else { Issue.record("first claim must read"); return }
        cache.abandon(ticket)
        #expect(cache.pendingReads == 0)
        #expect(cache.storedKeys == 0)
        if case .read = cache.claim(key) {} else { Issue.record("an abandoned key must be readable again") }
    }

    @Test func invalidateAllClearsEverySourceAndKeepsNoKeys() {
        var cache = EvidenceCache()
        var tickets: [EvidenceReadTicket] = []
        for index in 1 ... 50 {
            let key = EvidenceCacheKey(sourceID: UUID(uuidString: Self.uuid(index))!, snapshotRevision: 1)
            guard case .read(let ticket) = cache.claim(key) else { Issue.record("claim must read"); return }
            tickets.append(ticket)
        }
        for (offset, ticket) in tickets.enumerated() {
            cache.publish([record(offset + 1, sourceID: offset + 1)], against: ticket)
        }
        #expect(cache.storedKeys == 50)
        cache.invalidateAll()
        #expect(cache.storedKeys == 0)
        #expect(cache.pendingReads == 0)
        for index in 1 ... 50 {
            let claim = cache.claim(EvidenceCacheKey(sourceID: UUID(uuidString: Self.uuid(index))!,
                                                     snapshotRevision: 1))
            #expect(!claim.isCached)
        }
    }

    @Test func aThousandKeysStayAddressableAndShrinkOnDemand() {
        var cache = EvidenceCache()
        for index in 1 ... 1_000 {
            let key = EvidenceCacheKey(sourceID: UUID(uuidString: Self.uuid(index))!, snapshotRevision: 2)
            guard case .read(let ticket) = cache.claim(key) else { Issue.record("claim must read"); return }
            cache.publish((1 ... 4).map { record($0, sourceID: index, revision: 2) }, against: ticket)
        }
        #expect(cache.storedKeys == 1_000)
        #expect(cache.misses == 1_000)
        #expect(cache.hits == 0)
        // Re-asking every one of them reads nothing.
        for index in 1 ... 1_000 {
            let claim = cache.claim(EvidenceCacheKey(sourceID: UUID(uuidString: Self.uuid(index))!,
                                                     snapshotRevision: 2))
            #expect(claim.isCached)
        }
        #expect(cache.hits == 1_000)
        #expect(cache.misses == 1_000)
        cache.invalidate(sourceID: UUID(uuidString: Self.uuid(500))!)
        #expect(cache.storedKeys == 999)
    }
}

private extension EvidenceReadClaim {
    /// The test's way of asking "did this appearance have to read?" without
    /// pattern-matching at every call site.
    var isCached: Bool {
        if case .cached = self { return true }
        return false
    }
}
