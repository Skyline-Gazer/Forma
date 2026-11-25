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
