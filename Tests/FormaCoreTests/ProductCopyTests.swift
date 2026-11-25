import Foundation
import Testing

@testable import FormaCore

/// M0-R2 (#153): the ordinary workflow must not require engineering English.
/// The Review Desk spoke Chinese while the status strip, Workspace, the
/// archive plan and the recovery dialogs spoke English - "Scanning…",
/// "Blocked", "Exported 6 files…", "Bundle is self-consistent". Product copy
/// now lives in `ProductCopy` (one place, testable), and workflow labels are
/// Chinese; machine codes and provider/product names stay verbatim, exactly
/// like the other tested presentation contracts.
struct ProductCopyTests {
    /// The same Han predicate `EvidenceCurrencyPresentationTests` uses.
    private func containsChinese(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    @Test("every workflow phase label is Chinese business copy")
    func phaseLabelsAreChinese() {
        let labels = [
            ProductCopy.Work.idle, ProductCopy.Work.scanning, ProductCopy.Work.buildingContext,
            ProductCopy.Work.capturingEvidence(done: 3, total: 9), ProductCopy.Work.mapping,
            ProductCopy.Work.exporting, ProductCopy.Work.revalidating, ProductCopy.Work.reconciling,
            ProductCopy.Work.loadingManifest, ProductCopy.Work.correcting,
            ProductCopy.Work.readingEvidence, ProductCopy.Work.discoveringMCP, ProductCopy.Work.previewing,
        ]
        for label in labels {
            #expect(containsChinese(label), "phase label left in engineering English: \(label)")
            #expect(!label.isEmpty)
        }
    }

    @Test("the archive plan's decision words are Chinese, like the desk's")
    func archiveWordsAreChinese() {
        #expect(ProductCopy.Archive.blocked == "受阻")
        #expect(ProductCopy.Archive.deferred == "暂缓")
        #expect(ProductCopy.Archive.ready == "就绪")
        #expect(ProductCopy.Archive.records == "记录")
        #expect(containsChinese(ProductCopy.Archive.dryRunBanner))
        // The safety promise survives the translation verbatim: DEVONthink is
        // named, and no write path is implied.
        #expect(ProductCopy.Archive.dryRunBanner.contains("DEVONthink"))
        #expect(ProductCopy.Archive.dryRunBanner.contains("不会被写入"))
    }

    @Test("review vocabulary matches the desk's existing words")
    func reviewVocabularyAgreesWithTheDesk() {
        // One reviewer's screen must not call the same state two things.
        #expect(ProductCopy.ReviewVocabulary.hold == "暂缓")
        #expect(ProductCopy.ReviewVocabulary.validated == "已验证")
        #expect(ProductCopy.ReviewVocabulary.invalidated == "已作废")
        #expect(ProductCopy.ReviewVocabulary.unknown == "未知")
        #expect(containsChinese(ProductCopy.ReviewVocabulary.state))
        #expect(containsChinese(ProductCopy.ReviewVocabulary.violations))
    }

    @Test("outcome notices keep their revision numbers and lose the English prose")
    func noticesCarryTheirNumbers() {
        #expect(ProductCopy.Notice.exported(files: 6, revision: 4) == "已导出 6 个文件（修订 4）。")
        #expect(ProductCopy.Notice.bundleConsistent(revision: 4) == "归档包自洽 · 修订 4。")
        #expect(ProductCopy.Notice.bundleViolations(count: 2, revision: 4).contains("修订 4"))
        #expect(containsChinese(ProductCopy.Notice.buildContextBeforeMapping))
        #expect(ProductCopy.Notice.buildContextBeforeMapping.contains("FormaCore"))
        #expect(containsChinese(ProductCopy.Notice.runCancelled(batches: 3)))
        #expect(ProductCopy.Notice.runCancelled(batches: 3).contains("3"))
    }

    @Test("the ordinary-workflow status strip is Chinese and keeps its counts")
    func ordinaryWorkflowNotices() {
        // #175 / CopyGate finding 1: the scan -> context -> run -> load path
        // is what a person sees every session; none of it may stay English.
        for value in [ProductCopy.Notice.scanComplete(files: 6),
                      ProductCopy.Notice.scanIncomplete(issues: 2),
                      ProductCopy.Notice.reconciled(count: 3, reason: "source_changed"),
                      ProductCopy.Notice.contextBuilt(revision: 4, candidates: 9,
                                                      unassigned: 2, conflicted: 1),
                      ProductCopy.Notice.runFinished(runID: "abc", batches: 3,
                                                     requests: 5, failures: 1,
                                                     refused: 2, unread: 4),
                      ProductCopy.Notice.bundleLoaded(revision: 4, path: "/x.bundle",
                                                      entries: 40, rows: 12),
                      ProductCopy.Notice.selectBundleFirst,
                      ProductCopy.Notice.keySaved(provider: "OpenAI")] {
            #expect(containsChinese(value), "\(value)")
        }
        #expect(ProductCopy.Notice.scanComplete(files: 6).contains("6"))
        #expect(ProductCopy.Notice.runFinished(runID: "abc", batches: 3, requests: 5,
                                               failures: 1, refused: 2, unread: 4)
                    .contains("abc"))
        #expect(ProductCopy.Notice.keySaved(provider: "OpenAI").contains("OpenAI"),
                "provider names stay machine")
        // Rejection notices keep the path or filename that identifies the bundle.
        #expect(ProductCopy.Notice.bundleFolderMissingManifest(path: "/tmp/b",
                                                               manifestFile: "manifest.json")
                    .contains("manifest.json"))
        #expect(ProductCopy.Notice.bundleManifestUndecodable(name: "manifest.json")
                    .contains("manifest.json"))
        // CopyGate finding 4: the identity-changed detail names the folder.
        #expect(ProductCopy.Notice.folderNotRegistered(path: "/old/place",
                                                       pathHint: "H")
                    .contains("/old/place"))
    }

    @Test("FormaError sentences are Chinese while codes stay machine")
    func errorDescriptions() {
        // CopyGate finding 2: the alert content was English under Chinese chrome.
        for error in [FormaError.unavailable, .cancelled, .timeout, .network,
                      .credentialMissing, .hydrationPending, .refused, .invalidOutput] {
            #expect(containsChinese(error.errorDescription ?? ""), "\(error)")
        }
        #expect(FormaError.remoteStatus(429).errorDescription?.contains("429") == true)
    }

    @Test("recovery outcome labels translate but keep raw codes")
    func recoveryOutcomes() {
        // CopyGate finding 5: the banner reads 已验证 now; rawValue persists for logs.
        #expect(ImportRecoveryReviewResult.Outcome.verified.productLabel == "已验证")
        #expect(ImportRecoveryReviewResult.Outcome.outsideScope.productLabel == "超出范围")
        #expect(ImportRecoveryReviewResult.Outcome.outsideScope.rawValue == "outside_scope")
        #expect(ImportRecoveryReviewResult.Outcome.unverifiable.rawValue == "unverifiable")
    }

    @Test("machine codes and provider names are never translated")
    func machineVocabularySurvives() {
        // The recovery prose quotes the stable code; the copy keeps it.
        #expect(ProductCopy.Shell.needsScopeExplanation.contains("VERIFY_REQUIRED"))
        #expect(ProductCopy.Workspace.noExtension == "无扩展名")
        #expect(ProductCopy.Workspace.fileProvider == "File Provider")
        #expect(ProductCopy.Workspace.computeHash.contains("SHA-256"))
        #expect(ProductCopy.Shell.databaseUUID.contains("UUID"),
                "the label translates but keeps the machine identifier term")
    }
}
