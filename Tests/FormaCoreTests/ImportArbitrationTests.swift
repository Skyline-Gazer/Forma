import Foundation
import Testing

@testable import FormaCore

/// The decision table, stated as facts in and a verdict out.
///
/// The order of the checks is the contract: an unknown request outcome outranks
/// any conclusion about absence, and a confirmed record outranks a candidate
/// match. Each test names one rule so a regression says which rule broke.
@Suite("Import arbitration")
struct ImportArbitrationTests {
    private func facts(
        observedUUID: String? = nil,
        candidates: Int = 0,
        conclusive: Bool = true,
        request: ImportFacts.RequestOutcome = .succeeded,
        corroboration: Set<BusinessRecordIdentity.Corroboration> = [],
        contentMatches: Bool = false,
        metadataMatches: Bool = false
    ) -> ImportFacts {
        ImportFacts(observedUUID: observedUUID, candidateCount: candidates,
                    lookupConclusive: conclusive, requestOutcome: request,
                    businessIdentity: BusinessRecordIdentity(observedUUID: observedUUID,
                                                             corroboration: corroboration),
                    contentMatchesManifest: contentMatches, metadataMatchesManifest: metadataMatches)
    }

    @Test("a conclusive empty search imports")
    func absentAndConclusive() {
        let decision = ImportArbitration.decide(facts())
        #expect(decision.outcome == .importRecord)
        #expect(decision.reason == .absentAndConclusive)
    }

    @Test("an inconclusive empty search does not")
    func absentButInconclusive() {
        let decision = ImportArbitration.decide(facts(conclusive: false))
        #expect(decision.outcome == .verifyRequired)
        #expect(decision.reason == .identityUnconfirmed)
    }

    @Test("an unknown request outcome outranks every conclusion")
    func unknownOutcome() {
        for request in [ImportFacts.RequestOutcome.timedOut, .disconnected, .failed] {
            let decision = ImportArbitration.decide(facts(
                observedUUID: "uuid-1", candidates: 1, request: request,
                corroboration: [.targetAssociationMatch, .attributesMatch],
                contentMatches: true, metadataMatches: true))
            #expect(decision.outcome == .verifyRequired)
            #expect(decision.reason == .outcomeUnknown)
        }
    }

    @Test("more than one candidate is ambiguity, not a choice")
    func ambiguousCandidates() {
        let decision = ImportArbitration.decide(facts(observedUUID: "uuid-1", candidates: 2))
        #expect(decision.outcome == .verifyRequired)
        #expect(decision.reason == .candidatesAmbiguous)
    }

    @Test("a confirmed record that matches is skipped as verified")
    func confirmedAndMatching() {
        let decision = ImportArbitration.decide(facts(
            observedUUID: "uuid-1", candidates: 1,
            corroboration: [.targetAssociationMatch, .attributesMatch],
            contentMatches: true, metadataMatches: true))
        #expect(decision.outcome == .skipVerified)
        #expect(decision.reason == .alreadyVerified)
    }

    @Test("a confirmed record that differs is held, never overwritten")
    func confirmedButDifferent() {
        for (content, metadata) in [(true, false), (false, true), (false, false)] {
            let decision = ImportArbitration.decide(facts(
                observedUUID: "uuid-1", candidates: 1,
                corroboration: [.targetAssociationMatch, .attributesMatch],
                contentMatches: content, metadataMatches: metadata))
            #expect(decision.outcome == .conflictHold)
            #expect(decision.reason == .confirmedButDiffers)
        }
    }

    @Test("an observed record without an anchor is unconfirmed")
    func observedWithoutAnchor() {
        let decision = ImportArbitration.decide(facts(
            observedUUID: "uuid-1", candidates: 1,
            corroboration: [.attributesMatch], contentMatches: true, metadataMatches: true))
        #expect(decision.outcome == .verifyRequired)
        #expect(decision.reason == .identityUnconfirmed)
        #expect(ImportArbitration.decide(facts(observedUUID: nil, candidates: 1,
                                               corroboration: [.attributesMatch]))
            .outcome == .verifyRequired)
    }

    @Test("an observed record the search cannot prove unique stays unknown")
    func observedButInconclusive() {
        let decision = ImportArbitration.decide(facts(
            observedUUID: "uuid-1", candidates: 1, conclusive: false,
            corroboration: [.targetAssociationMatch, .attributesMatch],
            contentMatches: true, metadataMatches: true))
        #expect(decision.outcome == .verifyRequired)
        #expect(decision.reason == .searchInconclusive)
    }

    @Test("skipping requires positive match in both directions")
    func skipNeedsBothDirections() {
        let decision = ImportArbitration.decide(facts(
            observedUUID: "uuid-1", candidates: 1,
            corroboration: [.targetAssociationMatch, .attributesMatch],
            contentMatches: true, metadataMatches: false))
        #expect(decision.outcome != .skipVerified)
    }
}
