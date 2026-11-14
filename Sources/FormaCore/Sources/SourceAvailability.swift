import Foundation

/// Why a registered source root can or cannot be read right now.
///
/// These are deliberately different answers. "The bookmark went stale" needs a
/// new grant; "the folder is gone" needs a rescan that is allowed to mark entries
/// missing; "the cloud has not downloaded it" needs neither. Collapsing them into
/// one `unauthorized` is what makes a permission problem look like data loss.
public enum SourceRootAvailability: String, Sendable, Equatable, Codable, CaseIterable {
    case accessible
    /// The stored bookmark no longer resolves to a usable grant.
    case bookmarkStale = "bookmark_stale"
    /// The grant resolved but access was refused (revoked, or sandbox denial).
    case permissionDenied = "permission_denied"
    /// The root is genuinely not there any more.
    case missing
    /// The root exists but its content is not on this device yet.
    case hydrationPending = "hydration_pending"
    /// Something else occupies the stored path: the same path, a different folder.
    case identityChanged = "identity_changed"
    /// Anything the probe could not classify. Never treated as "missing".
    case unavailable
}

/// One scope's readiness, as the UI needs to show it.
public struct SourceScopeStatus: Sendable, Equatable {
    public let scope: SourceScope
    public let availability: SourceRootAvailability
    /// The last path the root was seen at. Shown so a person can find the folder
    /// again; it is not used to grant anything.
    public let lastKnownPath: String

    public init(scope: SourceScope, availability: SourceRootAvailability, lastKnownPath: String) {
        self.scope = scope
        self.availability = availability
        self.lastKnownPath = lastKnownPath
    }

    /// True when the only fix is a fresh grant for the same folder.
    public var needsReauthorization: Bool {
        switch availability {
        case .bookmarkStale, .permissionDenied:
            return true
        default:
            return false
        }
    }

    /// True when the source cannot be read at all. `hydrationPending` is not one
    /// of these: metadata can still be read, so a scan is allowed to proceed.
    public var isUnreadable: Bool {
        switch availability {
        case .accessible, .hydrationPending:
            return false
        default:
            return true
        }
    }
}

/// The result of handing Forma a folder again for an existing scope.
public enum SourceReauthorization: Sendable, Equatable {
    /// The bookmark was replaced and the scope is readable again.
    case updated(SourceScopeStatus)
    /// The selected folder is not the folder this scope was registered from.
    /// Nothing was changed: a different folder is a new source, not a new grant.
    case identityMismatch
    case unknownScope
    /// The scope could not be updated (busy workspace, unreadable selection).
    case unusable(FormaError)
}

extension SourceWorkspace {
    /// Probes every scope. Read-only: it resolves bookmarks and stats the root,
    /// and never writes to the database or to the filesystem.
    public func scopeStatuses() throws -> [SourceScopeStatus] {
        let scopes = try self.scopes()
        return try scopes.map { try status(of: $0) }
    }

    public func status(of scope: SourceScope) throws -> SourceScopeStatus {
        let root = try store.database.read { db in try SourceStore.root(db, id: scope.rootID) }
        return SourceScopeStatus(scope: scope, availability: Self.availability(of: root),
                                 lastKnownPath: root.lastPath)
    }

    /// Replaces the stored bookmark for `scope`, but only when the selected
    /// folder is provably the same folder.
    ///
    /// The identity check is the whole point: a reauthorization that silently
    /// accepted a different folder would attach this scope's history, snapshots
    /// and evidence to somebody else's files.
    public func reauthorize(scope: SourceScope, with url: URL) throws -> SourceReauthorization {
        guard !scanInProgress, !readInProgress else { return .unusable(.unavailable) }
        guard let root = try store.database.read({ db in
            try? SourceStore.root(db, id: scope.rootID)
        }) else { return .unknownScope }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let selected: SourceRootAccess
        do { selected = try SourceRootAccess(url) }
        catch let error as FormaError { return .unusable(error) }
        catch { return .unusable(.invalidSource) }

        guard selected.rootIdentity == root.identity,
              selected.caseSensitive == root.caseSensitive else {
            return .identityMismatch
        }
        do {
            try store.database.write { db in
                try Self.updateBookmark(in: db, id: root.id, selected: selected,
                                        authorizedURL: url, insert: false)
            }
        } catch let error as FormaError {
            return .unusable(error)
        }
        let updated = try store.database.read { db in try SourceStore.root(db, id: root.id) }
        return .updated(SourceScopeStatus(scope: scope, availability: Self.availability(of: updated),
                                          lastKnownPath: updated.lastPath))
    }

    // MARK: - Probe

    /// What the probe knows about a registered root, without the bookmark.
    ///
    /// Split out so the classification can be tested against synthetic resolution
    /// failures. A field machine produced the one that matters: a **deleted**
    /// security-scoped bookmark fails with `NSCocoaErrorDomain 259`
    /// (`NSFileReadUnknownError`), which says nothing about whether the folder
    /// exists. Only the filesystem can answer that.
    struct RootExpectation: Sendable, Equatable {
        let identity: String
        let caseSensitive: Bool?
        let lastPath: String
        let securityScoped: Bool
    }

    struct ProbedRoot: Sendable, Equatable {
        let identity: String
        let caseSensitive: Bool?
        let hydrationPending: Bool

        init(identity: String, caseSensitive: Bool?, hydrationPending: Bool) {
            self.identity = identity
            self.caseSensitive = caseSensitive
            self.hydrationPending = hydrationPending
        }

        init(_ url: URL) throws {
            let access = try SourceRootAccess(url)
            self.init(identity: access.rootIdentity, caseSensitive: access.caseSensitive,
                      hydrationPending: access.metadata.isHydrationPending)
        }
    }

    /// Why a stored bookmark could not produce a URL. Deliberately coarse: the
    /// filesystem probe, not the error code, decides between "gone" and "not
    /// allowed", because the same deletion produces different codes depending on
    /// whether the bookmark is security-scoped.
    enum BookmarkFailure: Sendable, Equatable {
        case noSuchFile
        case noPermission
        /// Anything the error code cannot decide — includes `NSCocoaErrorDomain
        /// 259` for a deleted security-scoped bookmark.
        case unknown
    }

    enum BookmarkOutcome: Sendable, Equatable {
        case resolved(URL, stale: Bool)
        case failed(BookmarkFailure)
    }

    /// Classifies the root without throwing: a probe that throws is exactly the
    /// case a person needs to be told about, not a reason to fail the screen.
    static func availability(of root: StoredSourceRoot) -> SourceRootAvailability {
        let expectation = RootExpectation(identity: root.identity,
                                          caseSensitive: root.caseSensitive,
                                          lastPath: root.lastPath,
                                          securityScoped: root.securityScoped)
        var stale = false
        let options: URL.BookmarkResolutionOptions = root.securityScoped
            ? [.withSecurityScope, .withoutUI] : [.withoutUI]
        let outcome: BookmarkOutcome
        do {
            let url = try URL(resolvingBookmarkData: root.bookmark, options: options,
                              bookmarkDataIsStale: &stale)
            outcome = .resolved(url, stale: stale)
        } catch {
            outcome = .failed(failure(from: error))
        }

        if case .resolved(let url, _) = outcome, root.securityScoped {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if !accessing {
                // The bookmark resolved but the grant did not: let the path probe
                // decide between a revoked grant and a folder that is simply gone.
                return classify(expectation: expectation, resolution: .failed(.noPermission),
                                probe: probe)
            }
        }
        return classify(expectation: expectation, resolution: outcome, probe: probe)
    }

    static func probe(_ url: URL) throws -> ProbedRoot { try ProbedRoot(url) }

    /// Decides the availability from the resolution result and the filesystem.
    ///
    /// The order is the point: when the bookmark cannot be used, the **path** is
    /// asked first. "Missing" is only concluded from the filesystem, never from a
    /// bookmark error, and "renew your grant" is only said when the folder is
    /// there and is provably the same folder.
    static func classify(expectation: RootExpectation, resolution: BookmarkOutcome,
                         probe: (URL) throws -> ProbedRoot) -> SourceRootAvailability {
        switch resolution {
        case .resolved(let url, let stale):
            do {
                let selected = try probe(url)
                guard selected.identity == expectation.identity,
                      selected.caseSensitive == expectation.caseSensitive else {
                    return .identityChanged
                }
                if stale { return .bookmarkStale }
                return selected.hydrationPending ? .hydrationPending : .accessible
            } catch let error as POSIXError {
                switch error.code {
                case .ENOENT, .ENOTDIR:
                    return .missing
                case .EACCES, .EPERM:
                    return stale ? .bookmarkStale : .permissionDenied
                default:
                    return stale ? .bookmarkStale : .unavailable
                }
            } catch {
                return stale ? .bookmarkStale : .unavailable
            }

        case .failed(let failure):
            let path = URL(fileURLWithPath: expectation.lastPath)
            do {
                let selected = try probe(path)
                guard selected.identity == expectation.identity,
                      selected.caseSensitive == expectation.caseSensitive else {
                    return .identityChanged
                }
                return .bookmarkStale
            } catch let error as POSIXError {
                switch error.code {
                case .ENOENT, .ENOTDIR:
                    return .missing
                case .EACCES, .EPERM:
                    return .permissionDenied
                default:
                    break
                }
            } catch {
                // A probe that cannot classify the path tells us nothing about the
                // filesystem; fall through to what the bookmark error itself said.
            }
            switch failure {
            case .noSuchFile: return .missing
            case .noPermission: return .permissionDenied
            case .unknown: return .unavailable
            }
        }
    }

    static func failure(from error: any Error) -> BookmarkFailure {
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return .noSuchFile
            case .fileReadNoPermission:
                return .noPermission
            default:
                return .unknown
            }
        }
        if let posix = error as? POSIXError {
            switch posix.code {
            case .ENOENT, .ENOTDIR:
                return .noSuchFile
            case .EACCES, .EPERM:
                return .noPermission
            default:
                return .unknown
            }
        }
        return .unknown
    }
}
