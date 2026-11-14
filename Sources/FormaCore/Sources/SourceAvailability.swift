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

    /// Classifies the root without throwing: a probe that throws is exactly the
    /// case a person needs to be told about, not a reason to fail the screen.
    static func availability(of root: StoredSourceRoot) -> SourceRootAvailability {
        var stale = false
        let options: URL.BookmarkResolutionOptions = root.securityScoped
            ? [.withSecurityScope, .withoutUI] : [.withoutUI]
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: root.bookmark, options: options,
                          bookmarkDataIsStale: &stale)
        } catch {
            return classify(error)
        }
        guard !stale else { return .bookmarkStale }

        var accessing = false
        if root.securityScoped {
            accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard accessing else { return .permissionDenied }
        }

        do {
            let selected = try SourceRootAccess(url)
            guard selected.rootIdentity == root.identity,
                  selected.caseSensitive == root.caseSensitive else {
                return .identityChanged
            }
            return selected.metadata.isHydrationPending ? .hydrationPending : .accessible
        } catch let error as POSIXError {
            switch error.code {
            case .ENOENT, .ENOTDIR:
                return .missing
            case .EACCES, .EPERM:
                return .permissionDenied
            default:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    private static func classify(_ error: any Error) -> SourceRootAvailability {
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileReadNoSuchFile:
                return .missing
            case .fileReadNoPermission:
                return .permissionDenied
            default:
                return .bookmarkStale
            }
        }
        if let posix = error as? POSIXError {
            switch posix.code {
            case .ENOENT, .ENOTDIR:
                return .missing
            case .EACCES, .EPERM:
                return .permissionDenied
            default:
                return .bookmarkStale
            }
        }
        return .bookmarkStale
    }
}
