import Foundation

/// Synthetic, read-only acceptance for `MACOS-VALIDATION-BACKLOG` M11.
///
/// Every case builds its own files in a fresh temporary directory, runs the
/// real scan / probe / classifier / context / manifest / report code, and
/// reports `PASS`, `FAIL` or `NOT_VERIFIED` with the evidence a reviewer needs.
///
/// What this deliberately does **not** do: it never reads a business
/// directory, never writes DEVONthink, never calls a provider, and never
/// enables the eligibility filter by default. A synthetic PASS is not a
/// real-directory measurement and must not be reported as one.
public enum M11SyntheticAcceptance {
    public enum Status: String, Codable, Sendable {
        case pass = "PASS"
        case fail = "FAIL"
        case notVerified = "NOT_VERIFIED"
    }

    public struct CaseResult: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let status: Status
        public let detail: String
    }

    public struct Report: Codable, Sendable, Equatable {
        public let schemaVersion: String
        public let generatedAt: Date
        public let host: String
        public let policyID: String
        public let policyVersion: String
        public let policyDigest: String
        public let decisionsDigest: String
        public let cases: [CaseResult]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", generatedAt = "generated_at", host
            case policyID = "policy_id", policyVersion = "policy_version"
            case policyDigest = "policy_digest", decisionsDigest = "decisions_digest", cases
        }

        public var passed: Int { cases.filter { $0.status == .pass }.count }
        public var failed: Int { cases.filter { $0.status == .fail }.count }
        public var notVerified: Int { cases.filter { $0.status == .notVerified }.count }
        /// True only when every case actually ran and passed. A skipped case is
        /// not a pass.
        public var allPassed: Bool { !cases.isEmpty && failed == 0 && notVerified == 0 }

        public var summary: String {
            "\(passed) PASS · \(failed) FAIL · \(notVerified) NOT_VERIFIED"
        }
    }

    /// Runs every case and returns the report. The synthetic tree is removed
    /// before returning; nothing outside the temporary directory is touched.
    public static func run() async throws -> Report {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("forma-m11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        return try await run(in: base)
    }

    /// `base` exists so a reviewer can rerun the same tree; the caller owns it.
    public static func run(in base: URL) async throws -> Report {
        let root = base.appendingPathComponent("source", isDirectory: true)
        let database = base.appendingPathComponent("workspace.sqlite")
        var builder = SyntheticTree(root: root)
        try builder.build()
        defer { builder.restorePermissions() }

        let workspace = try SourceWorkspace(databaseURL: database)
        let scope = try await workspace.register(root)
        let firstScan = try await workspace.scan(scope)
        let secondScan = try await workspace.scan(scope)
        // A11: the file changes after the scan it was listed in, so the probe
        // has something real to notice.
        try builder.mutateAfterScan()
        let profile = try MappingProfile.projectArchive()
        let policy = try EligibilityPolicy.shipped()
        let probe = try await workspace.probeEligibilityFacts(scope)
        let view = EligibilityViewBuilder.build(EligibilityViewRequest(
            listing: secondScan, profile: profile, policy: policy,
            facts: probe.factsBySource, kind: .simulated))

        var cases: [CaseResult] = []
        cases.append(contentsOf: scanCases(first: firstScan, second: secondScan))
        cases.append(contentsOf: factCases(view: view, probe: probe, listing: secondScan))
        cases.append(contentsOf: await isolationCases(workspace: workspace, scope: scope,
                                                      listing: secondScan, view: view, profile: profile))
        cases.append(contentsOf: contractCases(view: view, profile: profile, listing: secondScan))

        let binding = view.contextBinding
        return Report(schemaVersion: "1.0", generatedAt: Date(),
                      host: ProcessInfo.processInfo.operatingSystemVersionString,
                      policyID: view.policyID, policyVersion: view.policyVersion,
                      policyDigest: view.policyDigest, decisionsDigest: binding.decisionsDigest,
                      cases: cases)
    }

    // MARK: - A1: scan identity

    private static func scanCases(first: SourceListing, second: SourceListing) -> [CaseResult] {
        let firstIDs = Set(first.entries.map(\.id))
        let secondIDs = Set(second.entries.map(\.id))
        let sameIDs = firstIDs == secondIDs
        let sameSnapshots = Dictionary(uniqueKeysWithValues: first.entries.map { ($0.id, $0.snapshotFingerprint) })
            .allSatisfy { id, fingerprint in
                second.entries.first { $0.id == id }?.snapshotFingerprint == fingerprint
            }
        return [CaseResult(
            id: "A1", title: "两次扫描的身份与快照稳定",
            status: sameIDs && sameSnapshots ? .pass : .fail,
            detail: "entries=\(second.entries.count) same_ids=\(sameIDs) same_snapshots=\(sameSnapshots) "
                + "scan_state=\(second.state.rawValue)")]
    }

    // MARK: - A2–A9: facts and decisions

    private static func factCases(view: EligibilityView, probe: EligibilityProbeReport,
                                  listing: SourceListing) -> [CaseResult] {
        var cases: [CaseResult] = []
        func entry(_ path: String) -> SourceEntry? {
            listing.entries.first { $0.normalizedRelativePath == path.lowercased() }
        }
        func decided(_ path: String) -> EligibilityEntryView? {
            entry(path).flatMap { view.entry(for: $0.id) }
        }
        func facts(_ path: String) -> EligibilityFacts? {
            entry(path).flatMap { probe.factsBySource[$0.id] }
        }

        cases.append(result("A2", "Git tracked 的 build 文件不被排除",
                            decided("build/tracked.pdf"), expect: { $0.decision == .review }))
        cases.append(result("A3", "Git untracked 的 dist 文件为 REVIEW",
                            decided("dist/untracked.pdf"), expect: { $0.decision == .review }))
        cases.append(result("A4", "嵌套仓库内容为 REVIEW 且事实已确认",
                            decided("vendor/nested/notes.pdf"), expect: { $0.decision == .review }))
        cases.append(result("A5", "`.git` 文件指向授权根内 → 嵌套仓库确认",
                            decided("gitfile-inside/plan.pdf"), expect: { $0.decision == .review }))
        // A symlinked `.git` is never followed, so the fact stays unknown and
        // no rule fires: the record keeps the default decision rather than
        // being misread as "not a repository" or "definitely nested".
        cases.append(result("A6", "`.git` 符号链接不被跟随（事实 unknown → 默认 INCLUDE）",
                            decided("symlinked/link.pdf"), expect: { $0.decision == .include }))
        cases.append(result("A7", "有效 CACHEDIR.TAG 排除其下文件",
                            decided("cache-valid/artifact.pdf"), expect: { $0.decision == .exclude }))
        cases.append(result("A8", "无签名 CACHEDIR.TAG 不产生排除",
                            decided("cache-invalid/notes.pdf"), expect: { $0.decision != .exclude }))
        cases.append(result("A8b", "超大 CACHEDIR.TAG 不读入内存且不排除",
                            decided("cache-oversized/big.pdf"), expect: { $0.decision != .exclude }))
        cases.append(result("A8c", "符号链接 CACHEDIR.TAG 不跟随且不排除",
                            decided("cache-symlink/link.pdf"), expect: { $0.decision != .exclude }))
        cases.append(result("A9", "build/dist/vendor 中的业务样本不被排除",
                            decided("build/公告.pdf"), expect: { $0.decision != .exclude }))
        cases.append(result("A9b", "vendor 中的业务样本不被排除",
                            decided("vendor/datasheet.xlsx"), expect: { $0.decision != .exclude }))
        cases.append(result("A12", "缓存目录内的 tracked 文件受保护（REVIEW）",
                            decided("cache-tracked/tracked.pdf"), expect: { $0.decision == .review }))

        // Fact-level assertions that a decision alone would hide.
        if let cacheFacts = facts("cache-valid/artifact.pdf") {
            cases.append(CaseResult(
                id: "A7b", title: "cacheMarker 记录为 verified",
                status: cacheFacts.cacheMarker == .verifiedSignature ? .pass : .fail,
                detail: "cacheMarker=\(cacheFacts.cacheMarker.rawValue)"))
        } else {
            cases.append(CaseResult(id: "A7b", title: "cacheMarker 记录为 verified",
                                    status: .notVerified, detail: "缓存样本未被扫描到"))
        }
        if let trackedFacts = facts("build/tracked.pdf") {
            cases.append(CaseResult(
                id: "A2b", title: "gitTracked 对已提交文件为 yes",
                status: trackedFacts.gitTracked == .yes ? .pass : .fail,
                detail: "gitTracked=\(trackedFacts.gitTracked.rawValue)"))
        } else {
            cases.append(CaseResult(id: "A2b", title: "gitTracked 对已提交文件为 yes",
                                    status: .notVerified, detail: "Git 夹具缺失"))
        }
        if let nestedFacts = facts("vendor/nested/notes.pdf") {
            cases.append(CaseResult(
                id: "A4b", title: "nestedRepository 对嵌套仓库内文件为 yes",
                status: nestedFacts.nestedRepository == .yes ? .pass : .fail,
                detail: "nestedRepository=\(nestedFacts.nestedRepository.rawValue)"))
        } else {
            cases.append(CaseResult(id: "A4b", title: "nestedRepository 对嵌套仓库内文件为 yes",
                                    status: .notVerified, detail: "嵌套仓库夹具缺失"))
        }
        if let outside = facts("gitfile-outside/plan.pdf") {
            // A gitdir pointing outside the authorized root must be unknown, not "not nested".
            cases.append(CaseResult(
                id: "A5b", title: "`.git` 指向授权根外 → nestedRepository=unknown",
                status: outside.nestedRepository == .unknown ? .pass : .fail,
                detail: "nestedRepository=\(outside.nestedRepository.rawValue)"))
        } else {
            cases.append(CaseResult(id: "A5b", title: "`.git` 指向授权根外 → nestedRepository=unknown",
                                    status: .notVerified, detail: "该样本未被扫描到"))
        }
        if let link = facts("symlinked/link.pdf") {
            cases.append(CaseResult(
                id: "A6b", title: "符号链接 `.git` → nestedRepository=unknown",
                status: link.nestedRepository == .unknown ? .pass : .fail,
                detail: "nestedRepository=\(link.nestedRepository.rawValue)"))
        } else {
            cases.append(CaseResult(id: "A6b", title: "符号链接 `.git` → nestedRepository=unknown",
                                    status: .notVerified, detail: "该样本未被扫描到"))
        }

        // A10: an unreadable directory is an issue, never a silent absence.
        let lockIssue = listing.issues.contains {
            $0.reason == .unreadable && $0.relativePath.lowercased().hasPrefix("locked")
        }
        cases.append(CaseResult(
            id: "A10", title: "权限不足的子目录记为 unreadable issue",
            status: lockIssue ? .pass : .fail,
            detail: "issues=\(listing.issues.map { "\($0.relativePath):\($0.reason.rawValue)" })"))

        // A11: a file that changed after the scan is reported as changed.
        if let entry = entry("changing/changing.txt"),
           let result = probe.results.first(where: { $0.sourceID == entry.id }) {
            let snapshotStatus = result.provenance(for: "snapshot")?.status
            cases.append(CaseResult(
                id: "A11", title: "扫描后变化的文件记为 changed 并 DEFER",
                status: snapshotStatus == .changed && view.entry(for: entry.id)?.decision == .defer
                    ? .pass : .fail,
                detail: "snapshot=\(snapshotStatus?.rawValue ?? "none") "
                    + "decision=\(view.entry(for: entry.id)?.decision.rawValue ?? "none")"))
        } else {
            cases.append(CaseResult(id: "A11", title: "扫描后变化的文件记为 changed 并 DEFER",
                                    status: .notVerified, detail: "该样本未被扫描到"))
        }
        return cases
    }

    private static func result(_ id: String, _ title: String, _ decided: EligibilityEntryView?,
                               expect: (EligibilityEntryView) -> Bool) -> CaseResult {
        guard let decided else {
            return CaseResult(id: id, title: title, status: .notVerified, detail: "样本未被扫描到")
        }
        return CaseResult(
            id: id, title: title, status: expect(decided) ? .pass : .fail,
            detail: "decision=\(decided.decision.rawValue) rule=\(decided.decidedByRuleID ?? "none") "
                + "reason=\(decided.explanationCode)")
    }

    // MARK: - Filtering isolation (Context / default behaviour)

    private static func isolationCases(workspace: SourceWorkspace, scope: SourceScope,
                                       listing: SourceListing, view: EligibilityView,
                                       profile: MappingProfile) async -> [CaseResult] {
        var cases: [CaseResult] = []
        let candidates = view.mappingCandidates()
        let candidateIDs = Set(candidates.map(\.id))
        let listingIDs = Set(listing.entries.map(\.id))

        cases.append(CaseResult(
            id: "C1", title: "过滤只移除记录，候选是已发现集合的子集",
            status: candidateIDs.isSubset(of: listingIDs) ? .pass : .fail,
            detail: "discovered=\(listingIDs.count) candidates=\(candidateIDs.count)"))

        do {
            let full = try await workspace.buildContext(scope: scope, profile: profile)
            let filtered = try await workspace.buildContext(scope: scope, profile: profile,
                                                            eligibility: view.selection)
            let legacyDigest = ContextBuilder.inputDigest(scopeID: scope.id, profile: profile,
                                                          entries: listing.entries)
            cases.append(CaseResult(
                id: "C2", title: "完整清单模式摘要与 v0.1.1 公式一致（默认未启用过滤）",
                status: full.inputDigest == legacyDigest ? .pass : .fail,
                detail: "digest=\(full.inputDigest.prefix(12))…"))
            cases.append(CaseResult(
                id: "C3", title: "过滤模式的 Context 摘要独立失效",
                status: filtered.inputDigest != full.inputDigest ? .pass : .fail,
                detail: "full=\(full.inputDigest.prefix(12))… filtered=\(filtered.inputDigest.prefix(12))…"))
            let filteredMembers = Set(filtered.candidates.flatMap(\.memberSourceIDs))
            cases.append(CaseResult(
                id: "C4", title: "过滤后的 Context 只含候选",
                status: filteredMembers.isSubset(of: candidateIDs) ? .pass : .fail,
                detail: "members=\(filteredMembers.count) candidates=\(candidateIDs.count)"))
        } catch {
            cases.append(CaseResult(id: "C2", title: "完整清单模式摘要与 v0.1.1 公式一致（默认未启用过滤）",
                                    status: .notVerified, detail: "context build failed: \(error)"))
            cases.append(CaseResult(id: "C3", title: "过滤模式的 Context 摘要独立失效",
                                    status: .notVerified, detail: "context build failed: \(error)"))
            cases.append(CaseResult(id: "C4", title: "过滤后的 Context 只含候选",
                                    status: .notVerified, detail: "context build failed: \(error)"))
        }

        // The report must name every record that did not enter Mapping.
        let report = view.report(mappedSourceIDs: candidateIDs)
        cases.append(CaseResult(
            id: "C5", title: "资格报告守恒且逐条可追踪",
            status: report.isConserved && report.unmapped == listingIDs.count - candidateIDs.count
                ? .pass : .fail,
            detail: "discovered=\(report.discovered) mapped=\(report.mapped) unmapped=\(report.unmapped)"))
        let excludedNamed = report.records.allSatisfy { record in
            record.mapped || !record.explanationCode.isEmpty
        }
        cases.append(CaseResult(
            id: "C6", title: "被排除记录在报告中具名（决策 + 规则 + 原因）",
            status: excludedNamed ? .pass : .fail,
            detail: "records=\(report.records.count)"))
        return cases
    }

    // MARK: - Manifest versions (B1–B4)

    private static func contractCases(view: EligibilityView, profile: MappingProfile,
                                      listing: SourceListing) -> [CaseResult] {
        var cases: [CaseResult] = []
        let digest = String(repeating: "a", count: 64)

        func envelope(eligibility: ManifestEligibility?) -> ManifestEnvelope {
            ManifestEnvelope(
                manifestID: UUID(), revision: 1, supersedesRevision: nil, scopeID: UUID(),
                sourceRootID: UUID(), profile: profile, casePack: ("forma-governance-cases", "1.0"),
                modelProvider: "none", modelID: nil, contextRevision: 1, promptVersion: "mapping.v1",
                extractorVersion: "evidence.v1", redactionVersion: nil,
                inputDigest: digest, contextDigest: digest,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000), state: .draft,
                eligibility: eligibility)
        }

        let scanned = listing.entries.first
        let entries = scanned.map { entry in
            [ManifestEntry(
                sourceID: entry.id, snapshotFingerprint: entry.snapshotFingerprint,
                snapshotRevision: Int(entry.snapshotRevision), sourceVersion: Int(entry.sourceVersion),
                relativePath: entry.relativePath, state: .hold,
                target: ManifestTarget(databaseName: "库", groupPath: ["组"], resolved: false),
                metadata: MetadataValues.allUnknown,
                fields: MetadataFieldID.allCases.map { FieldOutcome(field: $0, value: nil, status: .unknown, conflicts: []) },
                associations: [], invalidatedReason: nil, providerReasoning: nil)]
        } ?? []

        let legacy = Manifest(envelope: envelope(eligibility: nil), entries: entries)
        let filtered = Manifest(
            envelope: envelope(eligibility: ManifestEligibility(
                policyID: view.policyID, policyVersion: view.policyVersion,
                policyDigest: view.policyDigest, decisionsDigest: view.contextBinding.decisionsDigest,
                discoveredCount: listing.entries.count, mappedCount: view.mappingCandidates().count,
                unmappedCount: listing.entries.count - view.mappingCandidates().count)),
            entries: entries)

        func validate(_ manifest: Manifest) -> [String] {
            do {
                let data = try FormaJSON.encode(manifest)
                let schema = try ArtifactSchemaValidator.manifest(forSchemaVersion: manifest.schemaVersion)
                return try schema.violations(data).map(\.logSummary)
            } catch {
                return ["throws: \(error)"]
            }
        }

        let legacyViolations = validate(legacy)
        let filteredViolations = validate(filtered)
        cases.append(CaseResult(
            id: "B1", title: "Manifest 1.0 工件通过 1.0 schema",
            status: legacyViolations.isEmpty && legacy.schemaVersion == "1.0" ? .pass : .fail,
            detail: "version=\(legacy.schemaVersion) violations=\(legacyViolations)"))
        cases.append(CaseResult(
            id: "B2", title: "Manifest 1.1 工件通过 1.1 schema 且带资格块",
            status: filteredViolations.isEmpty && filtered.schemaVersion == "1.1"
                && filtered.envelope.eligibility != nil ? .pass : .fail,
            detail: "version=\(filtered.schemaVersion) violations=\(filteredViolations)"))
        let legacyKeys = (try? FormaJSON.encode(legacy)).flatMap {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["envelope"] as? [String: Any]
        }
        cases.append(CaseResult(
            id: "B3", title: "1.0 工件不携带资格块",
            status: (legacyKeys?.keys.contains("eligibility") ?? true) ? .fail : .pass,
            detail: "envelope_keys_include_eligibility=\(legacyKeys?.keys.contains("eligibility") ?? true)"))
        let unknownVersionRefused = (try? ArtifactSchemaValidator.manifest(forSchemaVersion: "9.9")) == nil
        cases.append(CaseResult(
            id: "B4", title: "未知 schema 版本被拒绝",
            status: unknownVersionRefused ? .pass : .fail,
            detail: "unknown_version_threw=\(unknownVersionRefused)"))
        return cases
    }
}

// MARK: - Synthetic tree

/// Builds the file system cases. Nothing here writes outside `root`.
private struct SyntheticTree {
    let root: URL
    private var lockedDirectory: URL?

    init(root: URL) { self.root = root }

    mutating func build() throws {
        try write("示例项目 招标公告 2027", at: "build/公告.pdf")
        try write("datasheet", at: "vendor/datasheet.xlsx")
        try write("release", at: "dist/untracked.pdf")
        try write("tracked", at: "build/tracked.pdf")
        try write("nested notes", at: "vendor/nested/notes.pdf")
        try write("plan", at: "gitfile-inside/plan.pdf")
        try write("outside plan", at: "gitfile-outside/plan.pdf")
        try write("link", at: "symlinked/link.pdf")
        try write("artifact", at: "cache-valid/artifact.pdf")
        try write("notes", at: "cache-invalid/notes.pdf")
        try write("big", at: "cache-oversized/big.pdf")
        try write("linked cache", at: "cache-symlink/link.pdf")
        try write("tracked cache", at: "cache-tracked/tracked.pdf")
        try write("changing", at: "changing/changing.txt")
        try write("denied", at: "locked/denied.txt")

        // A7: the standard 43-byte cache directory tag.
        try write("Signature: 8a477f597d28d172789f06886806bc55\n",
                  at: "cache-valid/CACHEDIR.TAG")
        try write("Signature: 8a477f597d28d172789f06886806bc55\n",
                  at: "cache-tracked/CACHEDIR.TAG")
        // A8: a marker with the wrong signature.
        try write("not a cache tag\n", at: "cache-invalid/CACHEDIR.TAG")
        // A8b: a correctly signed marker that is far past the read limit.
        try write("Signature: 8a477f597d28d172789f06886806bc55\n"
                  + String(repeating: "x", count: 96 * 1_024), at: "cache-oversized/CACHEDIR.TAG")
        // A8c: a marker that is a symlink, which must never be followed.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("cache-symlink/CACHEDIR.TAG"),
            withDestinationURL: root.appendingPathComponent("cache-valid/CACHEDIR.TAG"))

        try write("gitdir: \(root.appendingPathComponent(".git").path)\n", at: "gitfile-inside/.git")
        try write("gitdir: /tmp/forma-outside-\(UUID().uuidString)\n", at: "gitfile-outside/.git")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("symlinked/.git"),
            withDestinationURL: root.appendingPathComponent(".git"))

        // Git: the root repository (A2/A3), a nested repository (A4), and the
        // tracked content inside a cache directory (A12).
        _ = try git(["init", "-q", root.path])
        _ = try git(["-C", root.path, "config", "user.email", "m11@forma.local"])
        _ = try git(["-C", root.path, "config", "user.name", "M11 Acceptance"])
        _ = try git(["-C", root.path, "add", "build/tracked.pdf", "cache-tracked/tracked.pdf"])
        _ = try git(["-C", root.path, "commit", "-q", "-m", "fixture"])
        _ = try git(["init", "-q", root.appendingPathComponent("vendor/nested").path])

        // A11: change a file after it was written; the scan happens after this,
        // so the probe compares against the *scanned* size only if we mutate
        // between the two: the runner mutates it below, after the first scan.
        // A10: an unreadable directory. Restored in `restorePermissions`.
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        lockedDirectory = locked
    }

    /// Mutates a file after the scan so the probe sees a different size.
    func mutateAfterScan() throws {
        try write("changing text that grew after the scan", at: "changing/changing.txt")
    }

    func restorePermissions() {
        if let lockedDirectory {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: lockedDirectory.path)
        }
    }

    private func write(_ text: String, at path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func git(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
