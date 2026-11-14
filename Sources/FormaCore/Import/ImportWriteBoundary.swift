import CryptoKit
import Foundation

/// The only DEVONthink write tools I1-B2 may reach.
///
/// A tool is *named* here and dispatched from this enum. There is no string
/// parameter anywhere on the boundary, so a tool name the scope has never heard
/// of cannot travel to the server: it cannot even be expressed.
public enum ImportWriteTool: String, CaseIterable, Sendable, Equatable {
    case createGroupPath = "create_group_path"
    case importFile = "import_file"
    case setRecordCustomMetadata = "set_record_custom_metadata"
}

/// What one write request claims, in the shape the boundary decides on.
///
/// `.setMetadata` deliberately has no database argument: the live
/// `set_record_custom_metadata` schema has no `database_uuid` parameter, so a
/// database claim on this request could not be sent and must not be believed.
/// Database binding for a metadata write is proven by the record having been
/// verified in scope first (see `recordVerified(uuid:database:)`).
public enum ImportWriteRequest: Sendable, Equatable {
    case createGroup(location: String, database: String)
    case importFile(path: String, destination: String, database: String, mode: String)
    case setMetadata(recordUUID: String, metadata: [String: String?])

    public var tool: ImportWriteTool {
        switch self {
        case .createGroup: .createGroupPath
        case .importFile: .importFile
        case .setMetadata: .setRecordCustomMetadata
        }
    }
}

/// Why a request was refused. Every case is reachable *before* any transport
/// call; the boundary never learns an answer from the server.
public enum ImportWriteDenial: String, Sendable, Equatable {
    case toolNotInScope
    case databaseNotInScope
    case groupPathOutsideScope
    case modeNotInScope
    case metadataIdentifierNotInScope
    case metadataValueNotString
    case sourcePathNotInScope
    case recordNotProvenInScope
    case recordBudgetExhausted
    case groupBudgetExhausted
    case malformedRequest
}

public struct ImportWriteRefusal: Error, Equatable, Sendable {
    public let code: ImportWriteDenial
    public let tool: ImportWriteTool
    public let detail: String

    public init(code: ImportWriteDenial, tool: ImportWriteTool, detail: String) {
        self.code = code
        self.tool = tool
        self.detail = detail
    }
}

/// One approved write. Produced only by `ImportWriteAuthorization`, and it
/// records the exact canonical request so the adapter has nothing left to
/// choose.
public struct ImportWriteGrant: Sendable, Equatable {
    public let tool: ImportWriteTool
    public let digest: String
    public let issuedAt: Date

    init(tool: ImportWriteTool, digest: String, issuedAt: Date) {
        self.tool = tool
        self.digest = digest
        self.issuedAt = issuedAt
    }
}

/// The exact envelope a B2 run is allowed to act inside.
///
/// Default-deny is structural: a scope is built from explicit values, an empty
/// set authorizes nothing, and every dimension below has to match before a
/// request becomes a grant.
public struct ImportWriteScope: Sendable, Equatable {
    public let databaseID: String
    /// Fixed path prefix, e.g. `["Forma_I1B2", "<run-id>"]`. A path is in scope
    /// only when it equals the prefix itself or extends it — never when it
    /// merely shares a string prefix.
    public let groupPrefix: [String]
    public let tools: Set<ImportWriteTool>
    public let metadataIdentifiers: Set<String>
    /// Canonical absolute paths of the synthetic files. Nothing else is
    /// importable, even if a caller hands over a plausible-looking path.
    public let sourcePaths: Set<String>
    public let recordLimit: Int
    public let groupLimit: Int

    public init(databaseID: String, groupPrefix: [String], tools: Set<ImportWriteTool>,
                metadataIdentifiers: Set<String>, sourcePaths: Set<String>,
                recordLimit: Int, groupLimit: Int) {
        self.databaseID = databaseID
        self.groupPrefix = groupPrefix
        self.tools = tools
        self.metadataIdentifiers = metadataIdentifiers
        self.sourcePaths = Set(sourcePaths.map(Self.canonical))
        self.recordLimit = recordLimit
        self.groupLimit = groupLimit
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    func contains(path: [String]) -> Bool {
        path.count >= groupPrefix.count && Array(path.prefix(groupPrefix.count)) == groupPrefix
    }
}

/// Default-deny authorization state for one B2 run.
///
/// Budget is consumed by *granting*, not by executing: a grant that is never
/// acted on still cannot be replaced by another one for free, so a crash loop
/// cannot quietly exceed the approved record count. There is no API to return
/// budget or to widen the scope after construction.
public actor ImportWriteAuthorization {
    private let scope: ImportWriteScope
    private let clock: @Sendable () -> Date
    private var grantsUsed = 0
    private var groupsUsed = 0
    private var provenRecords: Set<String> = []
    private var issued: [ImportWriteGrant] = []

    public init(scope: ImportWriteScope, clock: @escaping @Sendable () -> Date = Date.init) {
        self.scope = scope
        self.clock = clock
    }

    public var databaseID: String { scope.databaseID }
    public var grantedCount: Int { grantsUsed }
    public var createdGroups: Int { groupsUsed }
    public var log: [ImportWriteGrant] { issued }
    public var provenRecordIDs: Set<String> { provenRecords }

    /// Decides one request. Throws a refusal with a stable code; nothing is
    /// reserved when the request is refused.
    public func permit(_ request: ImportWriteRequest) throws -> ImportWriteGrant {
        guard scope.tools.contains(request.tool) else {
            throw ImportWriteRefusal(code: .toolNotInScope, tool: request.tool,
                                     detail: "tool is not in the authorized set")
        }
        switch request {
        case let .createGroup(location, database):
            guard database.uppercased() == scope.databaseID.uppercased() else {
                throw ImportWriteRefusal(code: .databaseNotInScope, tool: request.tool,
                                         detail: "database is not the authorized database")
            }
            let path = Self.split(location)
            guard !path.isEmpty, scope.contains(path: path) else {
                throw ImportWriteRefusal(code: .groupPathOutsideScope, tool: request.tool,
                                         detail: "group path is outside the authorized prefix")
            }
            guard groupsUsed < scope.groupLimit else {
                throw ImportWriteRefusal(code: .groupBudgetExhausted, tool: request.tool,
                                         detail: "group budget exhausted")
            }
            groupsUsed += 1
            return record(request, detail: location)

        case let .importFile(path, destination, database, mode):
            guard database.uppercased() == scope.databaseID.uppercased() else {
                throw ImportWriteRefusal(code: .databaseNotInScope, tool: request.tool,
                                         detail: "database is not the authorized database")
            }
            guard mode == "import" else {
                throw ImportWriteRefusal(code: .modeNotInScope, tool: request.tool,
                                         detail: "only mode=import is authorized")
            }
            let destinationPath = Self.split(destination)
            guard !destinationPath.isEmpty, scope.contains(path: destinationPath) else {
                throw ImportWriteRefusal(code: .groupPathOutsideScope, tool: request.tool,
                                         detail: "destination is outside the authorized prefix")
            }
            guard scope.sourcePaths.contains(ImportWriteScope.canonical(path)) else {
                throw ImportWriteRefusal(code: .sourcePathNotInScope, tool: request.tool,
                                         detail: "source path is not one of the approved synthetic files")
            }
            guard grantsUsed < scope.recordLimit else {
                throw ImportWriteRefusal(code: .recordBudgetExhausted, tool: request.tool,
                                         detail: "record budget exhausted")
            }
            grantsUsed += 1
            return record(request, detail: path)

        case let .setMetadata(recordUUID, metadata):
            guard !metadata.isEmpty else {
                throw ImportWriteRefusal(code: .malformedRequest, tool: request.tool,
                                         detail: "metadata is empty")
            }
            for (identifier, value) in metadata {
                guard scope.metadataIdentifiers.contains(identifier) else {
                    // The server auto-creates unknown identifiers; a typo would
                    // permanently widen the field table.
                    throw ImportWriteRefusal(code: .metadataIdentifierNotInScope, tool: request.tool,
                                             detail: "identifier \(identifier) is not authorized")
                }
                if let value, !value.isEmpty, value.utf8.count > 512 {
                    throw ImportWriteRefusal(code: .metadataValueNotString, tool: request.tool,
                                             detail: "value for \(identifier) exceeds the accepted length")
                }
            }
            guard provenRecords.contains(recordUUID.uppercased()) else {
                throw ImportWriteRefusal(code: .recordNotProvenInScope, tool: request.tool,
                                         detail: "record has not been verified in the authorized database")
            }
            return record(request, detail: recordUUID)
        }
    }

    /// Marks a record as belonging to this run, using an *observed* database
    /// UUID — normally from the independent readback, never from a request
    /// parameter the server merely echoed.
    public func recordVerified(uuid: String, database: String) throws {
        guard database.uppercased() == scope.databaseID.uppercased() else {
            throw ImportWriteRefusal(code: .databaseNotInScope, tool: .setRecordCustomMetadata,
                                     detail: "observed database is not the authorized database")
        }
        provenRecords.insert(uuid.uppercased())
    }

    public func isProven(_ uuid: String) -> Bool {
        provenRecords.contains(uuid.uppercased())
    }

    private func record(_ request: ImportWriteRequest, detail: String) -> ImportWriteGrant {
        let grant = ImportWriteGrant(tool: request.tool, digest: Self.digest(request, detail: detail),
                                     issuedAt: clock())
        issued.append(grant)
        return grant
    }

    static func split(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
    }

    static func digest(_ request: ImportWriteRequest, detail: String) -> String {
        let text: String
        switch request {
        case let .createGroup(location, database):
            text = "\(request.tool.rawValue)|\(database.uppercased())|\(location)"
        case let .importFile(path, destination, database, mode):
            text = "\(request.tool.rawValue)|\(database.uppercased())|\(destination)|\(mode)|\(ImportWriteScope.canonical(path))"
        case let .setMetadata(recordUUID, metadata):
            let body = metadata.keys.sorted().map { "\($0)=\(metadata[$0].flatMap { $0 } ?? "")" }
                .joined(separator: "\n")
            text = "\(request.tool.rawValue)|\(recordUUID.uppercased())|\(body)"
        }
        _ = detail
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Wraps the write transport so that every call passes the authorization first.
///
/// The decorator exists so "denied before the call" is a property of the type
/// system's ordinary path rather than a convention: there is exactly one place
/// that invokes the wrapped transport, and it is downstream of `permit`.
public actor GuardedImportWriteTransport: ImportWriteTransport {
    private let base: any ImportWriteTransport
    private let authorization: ImportWriteAuthorization
    /// Maps a source binding to the absolute path the adapter is about to send.
    /// Returning nil refuses the import instead of guessing a path.
    private let sourcePath: @Sendable (ImportSourceBinding) -> String?
    private(set) var deniedCalls = 0

    public init(base: any ImportWriteTransport, authorization: ImportWriteAuthorization,
                sourcePath: @escaping @Sendable (ImportSourceBinding) -> String?) {
        self.base = base
        self.authorization = authorization
        self.sourcePath = sourcePath
    }

    public func lookup(_ query: ImportLookupQuery) async throws -> ImportLookupResult {
        let database = await authorization.databaseID
        guard query.database.uppercased() == database.uppercased() else {
            deniedCalls += 1
            throw ImportWriteRefusal(code: .databaseNotInScope, tool: .importFile,
                                     detail: "lookup database is not the authorized database")
        }
        let result = try await base.lookup(query)
        // A returned record proves its own database; the request parameter does not.
        for record in result.records {
            guard record.database.uppercased() == database.uppercased() else {
                deniedCalls += 1
                throw ImportWriteRefusal(code: .databaseNotInScope, tool: .importFile,
                                         detail: "lookup returned a record from another database")
            }
            try await authorization.recordVerified(uuid: record.uuid, database: record.database)
        }
        return result
    }

    public func create(_ request: ImportCreateRequest) async throws -> String {
        guard let path = sourcePath(request.source) else {
            deniedCalls += 1
            throw ImportWriteRefusal(code: .sourcePathNotInScope, tool: .importFile,
                                     detail: "source binding did not resolve to a path")
        }
        _ = try await authorization.permit(.importFile(
            path: path, destination: request.groupPath.joined(separator: "/"),
            database: request.database, mode: "import"))
        return try await base.create(request)
    }

    public func writeMetadata(_ request: ImportMetadataRequest) async throws {
        _ = try await authorization.permit(.setMetadata(recordUUID: request.uuid,
                                                        metadata: request.metadata))
        try await base.writeMetadata(request)
    }
}
