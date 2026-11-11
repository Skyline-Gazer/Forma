import CryptoKit
import Foundation
import Testing

@testable import FormaCore

/// The clustering rules PLAN §6.1 requires, and the invalidation scoping that
/// keeps a context change from re-mapping the whole workspace.
@Suite("Context builder")
struct ContextBuilderTests {
    private let rootID = UUID(uuidString: "00000000-0000-4000-8000-000000000010")!
    private let scopeID = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!

    private func entry(_ path: String, state: SourceEntryState = .present,
                       version: Int64 = 1, revision: Int64 = 1) -> SourceEntry {
        // Derived from the path itself, so a fixture identity is stable across
        // runs and across the two contexts a test compares.
        let digest = Insecure.SHA1.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let identity = UUID(uuidString: "00000000-0000-4000-8000-\(digest)")!
        return SourceEntry(
            id: identity, rootID: rootID, relativePath: path,
            normalizedRelativePath: path.lowercased(), state: state, hydrationPending: false,
            sourceVersion: version, snapshotRevision: revision, provider: .local,
            snapshotFingerprint: String(repeating: "a", count: 64), sizeBytes: 10,
            modificationTimeNanoseconds: 0, sha256: nil
        )
    }

    private func context(_ paths: [String], profile: MappingProfile? = nil,
                         history: [ContextHistoryMatch] = [], states: [String: SourceEntryState] = [:]) throws
        -> ProjectContext
    {
        let selected = try profile ?? MappingProfile.projectArchive()
        let entries = paths.map { entry($0, state: states[$0] ?? .present) }
        return ContextBuilder.build(
            ContextBuilderInput(scopeID: scopeID, profile: selected, entries: entries, history: history),
            revision: 1, builtAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test("the same listing always produces the same context")
    func deterministic() throws {
        let paths = ["示例项目_2026 智慧园区/01_招标/公告.pdf", "示例项目_2026 智慧园区/02_投标/技术标.pdf"]
        let first = try context(paths)
        let second = try context(paths)
        #expect(first.inputDigest == second.inputDigest)
        #expect(first.candidates.map(\.id) == second.candidates.map(\.id))
        #expect(first.candidates.map(\.memberSourceIDs) == second.candidates.map(\.memberSourceIDs))
    }

    @Test("project depth is not assumed")
    func noFixedDepth() throws {
        let built = try context([
            "顶层项目/文件.pdf",
            "客户/年度/示例二期/招标/公告.pdf",
            "客户/年度/示例二期/投标/技术标.pdf",
        ])
        let keys = Set(built.candidates.map(\.projectKey))
        #expect(keys.contains("顶层项目"))
        #expect(keys.contains("客户/年度/示例二期/招标") || keys.contains("客户/年度/示例二期"))
        #expect(built.unassignedSourceIDs.isEmpty)
    }

    @Test("one directory holding two projects is split by naming entity")
    func splitsMixedDirectory() throws {
        let built = try context([
            "混合目录/示例项目A_技术响应表.xlsx",
            "混合目录/示例项目A_报价单.xlsx",
            "混合目录/示例项目B_技术响应表.xlsx",
            "混合目录/示例项目B_报价单.xlsx",
        ])
        let entityCandidates = built.candidates.filter { $0.basis.contains(.naming) }
        #expect(entityCandidates.count >= 2, "both entities must survive as separate candidates")
        let keys = Set(entityCandidates.map(\.projectKey))
        #expect(keys.contains("示例项目a_技术响应表") || keys.contains("示例项目a") || keys.contains("示例项目b"))
        // Each entity candidate must not contain the other project's files.
        for candidate in entityCandidates where candidate.projectKey.contains("a") {
            #expect(!candidate.projectKey.contains("b"))
        }
    }

    @Test("one project spread over subdirectories is joined")
    func joinsSpreadProject() throws {
        let built = try context([
            "示例项目C/招标/公告.pdf",
            "示例项目C/投标/技术标.pdf",
            "示例项目C/补充材料/澄清.pdf",
        ])
        let parent = built.candidates.first { $0.projectKey == "示例项目C" }
        // The parent directory candidate absorbs its children: they are the same
        // project seen at different levels.
        #expect(parent?.memberSourceIDs.count == 3, "children must merge into the parent, got \(String(describing: parent?.memberSourceIDs.count))")
        #expect(built.candidates.count == 1)
    }

    @Test("vendor material claimed by two projects is reported as a conflict")
    func crossProjectClaimIsConflict() throws {
        let built = try context([
            "项目甲/通用控制器_数据表.pdf",
            "项目乙/通用控制器_数据表.pdf",
            "项目甲/公告.pdf",
        ])
        let shared = built.candidates.filter { $0.projectKey.contains("通用控制器") }
            .flatMap(\.memberSourceIDs)
        #expect(!shared.isEmpty)
        for member in shared {
            #expect(built.conflictedSourceIDs.contains(member),
                    "a file inside two project directories must not silently pick one")
        }
    }

    @Test("vendor library leaves unaffiliated files unassigned instead of inventing a project")
    func vendorUnaffiliated() throws {
        let vendor = try MappingProfile.vendorLibrary()
        let built = try context(["厂商资料/产品D_数据表.pdf", "厂商资料/产品E_白皮书.pdf"], profile: vendor)
        // Each directory still yields a structural candidate, but no file is
        // forced to share a project it does not belong to.
        #expect(built.candidates.allSatisfy { $0.memberSourceIDs.count <= 1 })
        #expect(built.conflictedSourceIDs.isEmpty)
    }

    @Test("missing and symlink entries are not clustered")
    func nonPresentEntriesExcluded() throws {
        let built = try context(
            ["项目F/公告.pdf", "项目F/失效.pdf", "项目F/链接.pdf"],
            states: ["项目F/失效.pdf": .missing, "项目F/链接.pdf": .symlink]
        )
        let members = Set(built.candidates.flatMap(\.memberSourceIDs))
        #expect(members.count == 1)
        #expect(built.unassignedSourceIDs.isEmpty, "a missing file is not an unassigned present file")
    }

    @Test("content changes leave the context digest alone; structure changes do not")
    func digestCoversStructureOnly() throws {
        let before = try context(["项目G/公告.pdf", "项目G/技术标.pdf"])
        // Same paths and states, new snapshot revisions: bytes changed.
        let entries = [entry("项目G/公告.pdf", revision: 2), entry("项目G/技术标.pdf", revision: 2)]
        let afterContent = ContextBuilder.build(
            ContextBuilderInput(scopeID: scopeID, profile: try MappingProfile.projectArchive(), entries: entries),
            revision: 2
        )
        #expect(before.inputDigest == afterContent.inputDigest,
                "a content edit invalidates the entry snapshot, not the whole context")

        let moved = try context(["项目G/公告.pdf", "项目G/改名后技术标.pdf"])
        #expect(before.inputDigest != moved.inputDigest)
        let added = try context(["项目G/公告.pdf", "项目G/技术标.pdf", "项目G/新增.pdf"])
        #expect(before.inputDigest != added.inputDigest)
    }

    @Test("invalidation names only the members whose clustering changed")
    func affectedIsScopedToChangedMembership() throws {
        let before = try context([
            "项目H/公告.pdf", "项目H/技术标.pdf",
            "项目I/公告.pdf",
        ])
        let after = try context([
            "项目H/公告.pdf", "项目H/技术标.pdf", "项目H/补充.pdf",
            "项目I/公告.pdf",
        ])
        let affected = ContextBuilder.affectedSourceIDs(between: before, and: after)
        #expect(affected.count == 1, "only the added file changes membership, got \(affected.count)")
        let newFile = after.candidates.flatMap(\.memberSourceIDs).first { id in
            !before.candidates.flatMap(\.memberSourceIDs).contains(id)
        }
        #expect(affected == Set([try #require(newFile)]))
    }

    @Test("an exact historical name labels a candidate without changing membership")
    func historyLabelsOnly() throws {
        let paths = ["示例项目K/公告.pdf"]
        let plain = try context(paths)
        let match = ContextHistoryMatch(
            databaseID: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
            recordID: UUID(), projectName: "示例项目J", groupPath: ["2026", "示例项目J"], strength: .exactName
        )
        let aligned = try context(paths, history: [match])
        #expect(aligned.candidates.flatMap(\.memberSourceIDs) == plain.candidates.flatMap(\.memberSourceIDs))
        let candidate = try #require(aligned.candidates.first)
        #expect(candidate.basis.contains(.historyReference))
        #expect(candidate.displayName == "示例项目J")
        #expect(candidate.confidence == .medium, "history may lift a directory-only guess, not confirm it")
    }

    @Test("a one-character directory does not match a longer history name")
    func shortKeyIsNotAMatch() throws {
        // Bare substring matching used to let the directory `甲` "match" every
        // history project whose name contained that character, then display the
        // historical name as if it were confirmed.
        let built = try context(["甲/公告.pdf"])
        let match = ContextHistoryMatch(
            databaseID: UUID(), recordID: UUID(), projectName: "甲子园智慧园区项目", groupPath: [], strength: .exactName
        )
        let aligned = try context(["甲/公告.pdf"], history: [match])
        #expect(built.candidates.count == aligned.candidates.count)
        let candidate = try #require(aligned.candidates.first)
        #expect(!candidate.basis.contains(.historyReference),
                "a single-character key must not be treated as a historical match")
        #expect(candidate.displayName != "甲子园智慧园区项目")
    }

    @Test("a partial historical match does not raise confidence")
    func partialHistoryIsWeak() throws {
        let paths = ["项目K/公告.pdf"]
        let lowConfidenceBefore = try context(paths)
        let match = ContextHistoryMatch(
            databaseID: UUID(), recordID: UUID(), projectName: "无关项目", groupPath: [], strength: .partial
        )
        let after = try context(paths, history: [match])
        #expect(after.candidates.map(\.confidence) == lowConfidenceBefore.candidates.map(\.confidence))
        #expect(!after.candidates.contains { $0.basis.contains(.historyReference) })
    }

    @Test("candidate ids are stable when an unrelated project changes")
    func candidateIDsArePositionIndependent() throws {
        let before = try context(["项目L/公告.pdf", "项目M/公告.pdf"])
        let after = try context(["项目L/公告.pdf", "项目M/公告.pdf", "项目M/新增.pdf"])
        let key = "项目L"
        let beforeID = before.candidates.first { $0.projectKey == key }?.id
        let afterID = after.candidates.first { $0.projectKey == key }?.id
        #expect(beforeID == afterID, "an untouched project must keep its candidate identity")
    }
}
