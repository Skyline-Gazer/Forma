import Foundation
import Testing
@testable import FormaCore

/// A source root's readiness, and the only operation that may replace its grant.
///
/// These tests use real temporary directories and real bookmarks (macOS only),
/// because a bookmark that never had to resolve proves nothing. What they cannot
/// prove — a revoked sandbox grant, a stale security-scoped bookmark, a volume
/// that disappears — is listed in the Batch 2A report as real-macOS work.
@Suite("Source availability")
struct SourceAvailabilityTests {
    @Test func aFreshlyRegisteredRootIsAccessible() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.write("one", at: "Report.txt")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)

        let status = try await workspace.status(of: scope)
        #expect(status.availability == .accessible)
        #expect(status.needsReauthorization == false)
        #expect(status.isUnreadable == false)
        #expect(status.lastKnownPath == fixture.root.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    @Test func aRemovedRootIsMissingRatherThanDenied() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        try FileManager.default.removeItem(at: fixture.root)

        let status = try await workspace.status(of: scope)
        // The two are different answers: one needs a new grant, the other needs a
        // rescan that is allowed to conclude the files are gone.
        #expect(status.availability == .missing)
        #expect(status.needsReauthorization == false)
        #expect(status.isUnreadable)
    }

    @Test func aLostRootDoesNotMarkHistoricalEntriesMissing() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.write("document", at: "Report.txt")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let first = try await workspace.scan(scope)
        #expect(first.isComplete)
        let before = try #require(first.entries.first)
        #expect(before.state == .present)

        try FileManager.default.removeItem(at: fixture.root)
        let second = try await workspace.scan(scope)

        // The scan cannot prove absence when the root itself is unreachable: it
        // must stay incomplete and leave the entry as it was.
        #expect(second.state == .incomplete)
        #expect(second.issues.contains { $0.reason == .authorization })
        let after = try #require(second.entries.first)
        #expect(after.state == .present)
        #expect(after.id == before.id)
    }

    @Test func reauthorizingWithTheSameFolderUpdatesTheGrant() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)

        let result = try await workspace.reauthorize(scope: scope, with: fixture.root)
        guard case .updated(let status) = result else {
            Issue.record("expected an updated grant, got \(result)")
            return
        }
        #expect(status.availability == .accessible)
    }

    @Test func reauthorizingWithAnotherFolderIsRefusedAndChangesNothing() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let other = fixture.base.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try fixture.write("mine", at: "Mine.txt")
        try Data("theirs".utf8).write(to: other.appendingPathComponent("Theirs.txt"))

        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)

        let result = try await workspace.reauthorize(scope: scope, with: other)
        #expect(result == .identityMismatch)

        // The original grant is untouched, and no second root appeared.
        #expect(try await workspace.status(of: scope).availability == .accessible)
        #expect(try await workspace.scopes().count == 1)
    }

    @Test func reauthorizingAnUnknownScopeReportsIt() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let missing = SourceScope(id: UUID(), rootID: UUID(), relativePath: "",
                                  displayName: "gone")
        #expect(try await workspace.reauthorize(scope: missing, with: fixture.root) == .unknownScope)
    }

    @Test func everyScopeReportsItsOwnStatus() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let second = fixture.base.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        _ = try await workspace.register(fixture.root)
        _ = try await workspace.register(second)

        let statuses = try await workspace.scopeStatuses()
        #expect(statuses.count == 2)
        #expect(statuses.allSatisfy { $0.availability == .accessible })
        #expect(statuses.allSatisfy { $0.needsReauthorization == false })
    }
}
