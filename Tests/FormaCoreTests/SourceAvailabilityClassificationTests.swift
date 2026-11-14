import Foundation
import Testing
@testable import FormaCore

/// Bookmark-failure classification.
///
/// The field run produced the case these tests exist for: a **deleted**
/// security-scoped bookmark fails resolution with `NSCocoaErrorDomain 259`, and
/// the folder is simply gone. The classifier must ask the filesystem rather than
/// translate the error code into "renew your permission".
@Suite("Source availability classification")
struct SourceAvailabilityClassificationTests {
    private static let identity = "volume:inode:birth"
    private static let lastPath = "/tmp/forma-availability-root"

    private func expectation(securityScoped: Bool = true) -> SourceWorkspace.RootExpectation {
        SourceWorkspace.RootExpectation(identity: Self.identity, caseSensitive: true,
                                        lastPath: Self.lastPath, securityScoped: securityScoped)
    }

    private func probed(identity: String = SourceAvailabilityClassificationTests.identity,
                        caseSensitive: Bool? = true,
                        hydration: Bool = false) -> SourceWorkspace.ProbedRoot {
        SourceWorkspace.ProbedRoot(identity: identity, caseSensitive: caseSensitive,
                                   hydrationPending: hydration)
    }

    private func classify(_ outcome: SourceWorkspace.BookmarkOutcome,
                          probe: @escaping (URL) throws -> SourceWorkspace.ProbedRoot)
        -> SourceRootAvailability {
        SourceWorkspace.classify(expectation: expectation(), resolution: outcome, probe: probe)
    }

    // MARK: - The regression

    @Test func aDeletedSecurityScopedBookmarkIsMissingNotStale() {
        // 259 says nothing about the folder; the filesystem does.
        let availability = classify(.failed(.unknown)) { _ in throw POSIXError(.ENOENT) }
        #expect(availability == .missing)
    }

    @Test func anUnknownBookmarkFailureWithTheSameFolderAsksForRenewal() {
        let availability = classify(.failed(.unknown)) { _ in self.probed() }
        #expect(availability == .bookmarkStale)
    }

    @Test func anUnknownBookmarkFailureWithADifferentFolderIsIdentityChanged() {
        let availability = classify(.failed(.unknown)) { _ in self.probed(identity: "other") }
        #expect(availability == .identityChanged)
    }

    @Test func anUnknownBookmarkFailureWithDeniedAccessIsDeniedNotMissing() {
        let availability = classify(.failed(.unknown)) { _ in throw POSIXError(.EACCES) }
        #expect(availability == .permissionDenied)
    }

    @Test func aBookmarkErrorAloneNeverDecidesMissing() {
        // The probe could not classify the path, and the error code is not one of
        // the two definite ones: the honest answer is "unavailable".
        let availability = classify(.failed(.unknown)) { _ in throw FormaError.invalidSource }
        #expect(availability == .unavailable)
    }

    @Test func aDefiniteNoSuchFileErrorSurvivesAnUnclassifiableProbe() {
        let availability = classify(.failed(.noSuchFile)) { _ in throw FormaError.invalidSource }
        #expect(availability == .missing)
    }

    @Test func aDefinitePermissionErrorIsDenied() {
        let availability = classify(.failed(.noPermission)) { _ in throw FormaError.invalidSource }
        #expect(availability == .permissionDenied)
    }

    // MARK: - Resolved bookmarks

    @Test func aResolvedStaleBookmarkOnTheSameFolderNeedsRenewal() {
        let availability = classify(.resolved(URL(fileURLWithPath: Self.lastPath), stale: true)) { _ in
            self.probed()
        }
        #expect(availability == .bookmarkStale)
    }

    @Test func aResolvedBookmarkForAnotherFolderIsIdentityChanged() {
        let availability = classify(.resolved(URL(fileURLWithPath: Self.lastPath), stale: false)) { _ in
            self.probed(identity: "other")
        }
        #expect(availability == .identityChanged)
    }

    @Test func aResolvedPlaceholderIsReportedAsHydrationPending() {
        let availability = classify(.resolved(URL(fileURLWithPath: Self.lastPath), stale: false)) { _ in
            self.probed(hydration: true)
        }
        #expect(availability == .hydrationPending)
    }

    @Test func aResolvedBookmarkOnADeletedFolderIsMissing() {
        let availability = classify(.resolved(URL(fileURLWithPath: Self.lastPath), stale: false)) { _ in
            throw POSIXError(.ENOENT)
        }
        #expect(availability == .missing)
    }

    // MARK: - Error-code mapping

    @Test func resolutionErrorsMapToTheThreeCoarseReasons() {
        #expect(SourceWorkspace.failure(from: CocoaError(.fileNoSuchFile)) == .noSuchFile)
        #expect(SourceWorkspace.failure(from: CocoaError(.fileReadNoSuchFile)) == .noSuchFile)
        #expect(SourceWorkspace.failure(from: CocoaError(.fileReadNoPermission)) == .noPermission)
        // 259 — the deleted security-scoped bookmark. It must not become "missing"
        // on its own, and it must not become "renew" on its own either.
        #expect(SourceWorkspace.failure(from: CocoaError(.fileReadCorruptFile)) == .unknown)
        #expect(SourceWorkspace.failure(from: POSIXError(.ENOENT)) == .noSuchFile)
        #expect(SourceWorkspace.failure(from: POSIXError(.EACCES)) == .noPermission)
        #expect(SourceWorkspace.failure(from: FormaError.invalidSource) == .unknown)
        #expect(SourceWorkspace.failure(from: NSError(domain: "synthetic", code: 1)) == .unknown)
    }
}
