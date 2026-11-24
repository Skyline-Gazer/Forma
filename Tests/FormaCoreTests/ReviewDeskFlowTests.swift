import Foundation
import Testing

@testable import FormaCore

/// The deterministic contract surface of the business Review Desk (#144,
/// reworked under the #148 decision): the stage machine, the Save & Next
/// gate, the refusal buckets, the chips and the triage buckets. Every case
/// here is what the Owner's field run could not exercise on Linux; the GUI
/// itself remains #153.
@Suite("Review Desk flow")
struct ReviewDeskFlowTests {

    // MARK: - Stage machine (UI contract §5 state matrix)

    @Test("an unselected source offers exactly the one choosing action")
    func chooseSourceStage() {
        let flow = ReviewDeskFlow.evaluate(.init())
        #expect(flow.stage == .chooseSource)
        #expect(flow.next == .chooseSource)
        #expect(flow.allowed == [.chooseSource, .addSource])
        #expect(!flow.guidance.isEmpty)
    }

    @Test("a selected unscanned source offers the scan")
    func scanStage() {
        let flow = ReviewDeskFlow.evaluate(.init(hasScope: true))
        #expect(flow.stage == .scan)
        #expect(flow.next == .scan)
        #expect(flow.allowed.contains(.scan))
        #expect(!flow.allowed.contains(.aiUnderstanding))
    }

    @Test("a scanned source without context gates on profile first, then project identification")
    func contextStage() {
        let noProfile = ReviewDeskFlow.evaluate(.init(hasScope: true, hasListing: true))
        #expect(noProfile.stage == .projectContext)
        #expect(noProfile.next == .configureProfile)
        let noContext = ReviewDeskFlow.evaluate(.init(hasScope: true, hasProfile: true, hasListing: true))
        #expect(noContext.stage == .projectContext)
        #expect(noContext.next == .buildContext)
    }

    @Test("the AI understanding stage defaults to the semantic path, with the manual draft only as an allowed fallback")
    func aiStageDefaultsToProvider() {
        let flow = ReviewDeskFlow.evaluate(.init(hasScope: true, hasProfile: true, hasListing: true,
                                                 hasContext: true))
        #expect(flow.stage == .aiUnderstanding)
        // #148: the LLM path is the default next action; OfflinePlanner is
        // reachable but never the default and never the next action.
        #expect(flow.next == .aiUnderstanding)
        #expect(flow.allowed.contains(.manualDraft))
        #expect(flow.allowed.contains(.openSettings))
        #expect(flow.guidance == DeskGuidance.aiNeedsConsent)
    }

    @Test("a busy phase replaces the pipeline action with cancel and allows nothing else")
    func busyReplacesWithCancel() {
        for inputs in [
            ReviewDeskFlow.Inputs(hasScope: true, hasListing: true),
            ReviewDeskFlow.Inputs(hasScope: true, hasProfile: true, hasListing: true, hasContext: true),
            ReviewDeskFlow.Inputs(hasScope: true, hasProfile: true, hasListing: true, hasContext: true,
                                  hasManifest: true),
        ] {
            var busy = inputs
            busy.isBusy = true
            let flow = ReviewDeskFlow.evaluate(busy)
            #expect(flow.next == .cancel)
            #expect(flow.allowed == [.cancel])
        }
    }

    @Test("reviewing files is the stage a published manifest opens, and invalidated files route to rescan")
    func fileReviewStage() {
        let flow = ReviewDeskFlow.evaluate(.init(hasScope: true, hasProfile: true, hasListing: true,
                                                 hasContext: true, hasManifest: true))
        #expect(flow.stage == .fileReview)
        #expect(flow.next == .reviewFiles)
        var changed = ReviewDeskFlow.Inputs(hasScope: true, hasProfile: true, hasListing: true,
                                            hasContext: true, hasManifest: true)
        changed.hasInvalidatedFiles = true
        let recovery = ReviewDeskFlow.evaluate(changed)
        // Matrix row "Snapshot changed: explicit recovery; no stale correction".
        #expect(recovery.next == .scan)
        #expect(recovery.guidance == DeskGuidance.recoverySnapshot)
        #expect(!recovery.allowed.contains(.buildPlan))
    }

    @Test("the archive preview stage offers the export and keeps the plan non-destructive")
    func archiveStage() {
        let flow = ReviewDeskFlow.evaluate(.init(hasScope: true, hasProfile: true, hasListing: true,
                                                 hasContext: true, hasManifest: true, hasPlan: true))
        #expect(flow.stage == .archivePreview)
        #expect(flow.next == .exportBundle)
        #expect(flow.allowed.contains(.buildPlan))
        #expect(flow.guidance == DeskGuidance.dryRunOnly)
        // No verb in the desk's vocabulary is a write: the action grammar has
        // no execution action at all, at any stage.
        #expect(!DeskAction.allCases.contains { $0.rawValue.contains("execute") })
    }

    @Test("stage numbering is the pipeline order and every stage has business copy")
    func stageVocabulary() {
        #expect(DeskStage.allCases.map(\.number) == [1, 2, 3, 4, 5, 6])
        for stage in DeskStage.allCases {
            #expect(!stage.title.isEmpty)
            #expect(stage.title.contains(where: { $0.isCJKPresentation }))
        }
        for action in DeskAction.allCases {
            #expect(!action.title.isEmpty)
            #expect(!action.systemImage.isEmpty)
        }
        // The fallback label says what it is NOT, exactly as #148 requires.
        #expect(DeskAction.manualDraft.title.contains("非 AI"))
    }

    // MARK: - Save & Next gate

    @Test("no publish, no advance: the cursor moves only across a revision FormaCore published")
    func advanceOnlyAcrossPublishedRevision() {
        // Missing either side is never a success.
        #expect(!ReviewDeskFlow.advances(baselineRevision: nil, currentRevision: nil))
        #expect(!ReviewDeskFlow.advances(baselineRevision: 4, currentRevision: nil))
        #expect(!ReviewDeskFlow.advances(baselineRevision: nil, currentRevision: 5))
        // A refused correction leaves the revision alone: the file stays.
        #expect(!ReviewDeskFlow.advances(baselineRevision: 4, currentRevision: 4))
        // The published revision moves the cursor.
        #expect(ReviewDeskFlow.advances(baselineRevision: 4, currentRevision: 5))
    }

    @Test("the cursor walks the visible queue and wraps at its end")
    func cursorOrder() {
        #expect(ReviewDeskFlow.nextAfter("b", in: ["a", "b", "c"]) == "c")
        #expect(ReviewDeskFlow.nextAfter("c", in: ["a", "b", "c"]) == "a")
        #expect(ReviewDeskFlow.nextAfter("gone", in: ["a", "b"]) == "a")
        #expect(ReviewDeskFlow.nextAfter("a", in: ["a"]) == "a")
        #expect(ReviewDeskFlow.nextAfter("a", in: []) == nil)
    }

    // MARK: - Refusal buckets (P0: the error beside the edit)

    @Test("the four actionable buckets exist and the stale bucket catches the #147 code by literal")
    func refusalBuckets() {
        #expect(deskRefusalKind(forCode: "evidence_missing") == .missingEvidence)
        #expect(deskRefusalKind(forCode: "evidence_not_found") == .missingEvidence)
        // `evidence_snapshot_mismatch` is emitted by PR #147's branch only;
        // the desk matches the string, not a symbol that would not compile.
        #expect(deskRefusalKind(forCode: "evidence_snapshot_mismatch") == .evidenceStale)
        #expect(deskRefusalKind(forCode: "snapshot_changed") == .evidenceStale)
        #expect(deskRefusalKind(forCode: "conflicting_evidence") == .conflict)
        #expect(deskRefusalKind(forCode: "source_not_allowed") == .permission)
        #expect(deskRefusalKind(forCode: "authorization_expired") == .permission)
        // Anything else is still answered, in the user's language.
        #expect(deskRefusalKind(forCode: "brand_new_reason") == .other)
        for kind in DeskRefusalKind.allCases {
            #expect(!kind.rawValue.isEmpty)
            #expect(kind.sentence.contains(where: { $0.isCJKPresentation }))
        }
        // The inline line carries the bucket word first; the raw code never
        // leaks into the sentence itself.
        let line = deskRefusalSentence(forCode: "evidence_snapshot_mismatch")
        #expect(line.hasPrefix("证据过期"))
        #expect(!line.contains("evidence_snapshot_mismatch"))
    }

    // MARK: - Chips and triage (P1/P2 vocabularies)

    @Test("every decision state maps to one of the four desk chips, with the #144 words")
    func chipMappingIsTotal() {
        let states: [DecisionState] = [.unknown, .hold, .mapped, .validated, .invalidated]
        #expect(deskChip(for: .unknown) == .pendingReview)
        #expect(deskChip(for: .mapped) == .pendingReview)
        #expect(deskChip(for: .hold) == .insufficientInformation)
        #expect(deskChip(for: .validated) == .validated)
        #expect(deskChip(for: .invalidated) == .sourceChanged)
        let titles = Set(states.map { deskChip(for: $0).title })
        #expect(titles.isSubset(of: ["待审核", "信息不足", "已验证", "来源已变化"]))
        #expect(deskChip(for: .validated).title == "已验证")
        #expect(deskChip(for: .invalidated).title == "来源已变化")
        for state in states {
            #expect(!deskChip(for: state).systemImage.isEmpty)
        }
    }

    @Test("the triage buckets partition the states: pending, validated, attention")
    func triageMappingIsTotal() {
        #expect(deskTriage(for: .unknown) == .pending)
        #expect(deskTriage(for: .hold) == .pending)
        #expect(deskTriage(for: .mapped) == .pending)
        #expect(deskTriage(for: .validated) == .validated)
        #expect(deskTriage(for: .invalidated) == .attention)
        #expect(DeskTriage.allCases.map(\.title) == ["待处理", "已验证", "需关注"])
    }

    // MARK: - Field and evidence vocabulary

    @Test("all twelve metadata fields read in business Chinese, never as raw ids")
    func fieldLabelsAreTotal() {
        for field in MetadataFieldID.allCases {
            let label = metadataFieldLabel(field)
            #expect(!label.isEmpty)
            #expect(label.contains(where: { $0.isCJKPresentation }), "\(field.rawValue) leaked")
            #expect(!label.contains("_"))
        }
        #expect(metadataFieldLabel(.projectname) == "项目名称")
        #expect(metadataFieldLabel(.completionyear) == "归档完成年份")
        #expect(metadataFieldLabel(.documentcategory) == "文件分类")
        #expect(MetadataFieldID.allCases.count == 12)
    }

    @Test("evidence provenance labels cover every source and locator shape, with a total fallback")
    func evidenceLabelsAreTotal() {
        for source in EvidenceSource.allCases {
            #expect(!deskEvidenceSourceLabel(source).isEmpty)
        }
        #expect(deskEvidenceLocatorLabel(EvidenceLocator.pdf(page: 3, characterRange: 10..<40))
                == "第 3 页 · 字符 10–40")
        #expect(deskEvidenceLocatorLabel(EvidenceLocator.docx(part: "word/document.xml", paragraph: 7,
                                                              characterRange: 0..<12))
                == "段落 7 · 字符 0–12")
        #expect(deskEvidenceLocatorLabel(EvidenceLocator.xlsx(sheet: "Sheet1", cell: "B4"))
                == "工作表 Sheet1 · 单元格 B4")
        // Path/filename evidence has no locator; it still names its place.
        #expect(!deskEvidenceLocatorLabel(nil).isEmpty)
    }

    // MARK: - Plan copy

    @Test("the plan target line names the symbols and says undecided when nothing resolved")
    func planTargetLines() {
        #expect(deskPlanTargetLine(databaseName: "档案", groupPath: ["Forma", "r1"]) == "档案 · Forma / r1")
        #expect(deskPlanTargetLine(databaseName: nil, groupPath: []).contains("尚未确定"))
    }

    // MARK: - Default landing (area contract tested with the shell grammar)

    @Test("the desk is the default landing area and its toolbar set obeys the shell swap contract")
    func deskAreaIsDefaultAndStable() {
        #expect(AppArea.restored(from: nil) == .reviewDesk)
        let idle = ShellCommands.commands(for: .reviewDesk, phase: .idle, planner: .ai)
        let busy = ShellCommands.commands(for: .reviewDesk, phase: .busy, planner: .ai)
        #expect(idle.contains { $0.id == "scan-source" })
        #expect(busy.contains { $0.id == "cancel-work" })
        #expect(!idle.contains { $0.id == "cancel-work" })
        // The desk never offers the engineering-only or offline-branded verbs.
        for command in idle {
            #expect(command.id != "assess-local" && command.id != "reprocess-selected")
        }
    }
}

private extension Character {
    var isCJKPresentation: Bool {
        unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
