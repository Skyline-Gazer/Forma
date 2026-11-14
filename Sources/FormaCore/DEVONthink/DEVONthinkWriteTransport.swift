import Foundation

/// The DEVONthink MCP write surface, as a transport the boundary can wrap.
///
/// This type does no policy. It builds the exact arguments for the three
/// authorized tools, calls them, and reports what came back — including "the
/// answer did not name exactly one record", which the caller must treat as an
/// unknown outcome rather than a failure with no side effect.
///
/// It is deliberately the only place in the app that names a write tool: the
/// boundary above it decides whether a call may happen, and this type only knows
/// how to send the calls the boundary approved.
public actor DEVONthinkMCPWriteTransport: ImportWriteSurface {
    private let connection: MCPStdio
    private let sourceRoot: URL
    /// Tools invoked, in order, for the run's audit. Arguments are not logged:
    /// the caller already holds the canonical request digests.
    private(set) var transcript: [String] = []
    private var ready = false

    static let preferredVersion = "2025-06-18"
    static let supportedVersions: Set<String> = [preferredVersion, "2025-03-26", "2024-11-05"]

    public init(sourceRoot: URL) {
        self.init(configuration: .devonThink, sourceRoot: sourceRoot)
    }

    init(configuration: MCPConfiguration, sourceRoot: URL) {
        self.connection = MCPStdio(configuration: configuration)
        self.sourceRoot = sourceRoot
    }

    // MARK: - Reads used by the import contract

    /// Resolves the group path by walking the root's children, then lists that
    /// group's children. `search_records` is not used: it excludes trashed
    /// records, so an empty search would not be evidence of absence.
    public func lookup(_ query: ImportLookupQuery) async throws -> ImportLookupResult {
        guard let group = try await resolveGroup(database: query.database, path: query.groupPath) else {
            return ImportLookupResult(records: [], conclusive: true)
        }
        let page = try await children(of: group, database: query.database, limit: 1000, offset: 0)
        var records: [ImportRecordSnapshot] = []
        for item in page {
            guard let database = item.databaseUUID else { throw FormaError.invalidResponse }
            records.append(ImportRecordSnapshot(
                uuid: item.uuid, database: database, parentPath: query.groupPath,
                metadata: [:], standardSHA256: nil, shaVerified: false,
                associationBasis: nil))
        }
        return ImportLookupResult(records: records, conclusive: true)
    }

    // MARK: - Writes

    public func createGroup(database: String, path: [String]) async throws -> String {
        let location = path.joined(separator: "/")
        let result = try await call("create_group_path", [
            "location": .string(location),
            "database_uuid": .string(database),
        ])
        // The tool's return shape is not documented; a UUID is only reported when
        // the payload names exactly one. The caller verifies the group by reading
        // the parent's children regardless.
        return Self.uniqueUUID(in: result) ?? ""
    }

    public func create(_ request: ImportCreateRequest) async throws -> String {
        let result = try await call("import_file", Self.importFileArguments(request, sourceRoot: sourceRoot))
        return Self.uniqueUUID(in: result) ?? ""
    }

    public func writeMetadata(_ request: ImportMetadataRequest) async throws {
        var metadata: [String: MCPValue] = [:]
        for (key, value) in request.metadata {
            metadata[key] = value.map { MCPValue.string($0) } ?? .null
        }
        _ = try await call("set_record_custom_metadata", [
            "uuid": .string(request.uuid),
            "metadata": .object(metadata),
            "mode": .string("merge"),
        ])
    }

    public func close() async {
        await connection.close()
    }

    public func transcriptLines() -> [String] { transcript }

    // MARK: - Argument construction

    /// The exact arguments this adapter sends. The tests assert this shape; the
    /// run records it. Values are strings (or nil for a cleared field) so the
    /// shape can be inspected without exposing the internal JSON value type.
    public nonisolated static func importFileArguments(_ request: ImportCreateRequest,
                                                       sourceRoot: URL) -> [String: String] {
        [
            "path": sourceRoot.appendingPathComponent(request.source.relativePath)
                .standardizedFileURL.path,
            "destination": request.groupPath.joined(separator: "/"),
            "database_uuid": request.database,
            "mode": "import",
        ]
    }

    // MARK: - Transport

    struct Child: Decodable {
        let uuid: String
        let name: String?
        let type: String?
        let databaseUUID: String?
    }

    private func resolveGroup(database: String, path: [String]) async throws -> String? {
        var current: String?
        for component in path {
            let parent = current ?? database
            let items = try await children(of: parent, database: database, limit: 1000, offset: 0)
            guard let match = items.first(where: { $0.name == component && $0.type == "group" }) else {
                return nil
            }
            current = match.uuid
        }
        return current
    }

    private func children(of uuid: String, database: String, limit: Int, offset: Int) async throws -> [Child] {
        let result = try await call("get_record_children", [
            "uuid": .string(uuid), "limit": .integer(limit), "offset": .integer(offset),
        ])
        guard let object = result.object, let rows = object["items"]?.array else {
            throw FormaError.invalidResponse
        }
        do {
            return try JSONDecoder().decode([Child].self,
                                            from: JSONEncoder().encode(MCPValue.array(rows)))
        } catch {
            throw FormaError.invalidResponse
        }
    }

    /// The server refuses `tools/call` before the handshake, so the adapter does
    /// it once and validates the negotiated protocol the same way the read client
    /// does. Nothing here is a write.
    private func ensureReady() async throws {
        if ready { return }
        let initialized = try await connection.request("initialize", parameters: [
            "protocolVersion": .string(Self.preferredVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Forma"), "version": .string("0.1.0")]),
        ])
        guard let object = initialized.object,
              let version = object["protocolVersion"]?.string,
              Self.supportedVersions.contains(version),
              object["capabilities"]?.object?["tools"]?.object != nil else {
            throw FormaError.incompatible
        }
        try await connection.initialized()
        ready = true
    }

    private func call(_ tool: String, _ arguments: [String: MCPValue]) async throws -> MCPValue {
        try await ensureReady()
        let response = try await connection.request("tools/call", parameters: [
            "name": .string(tool), "arguments": .object(arguments),
        ])
        transcript.append(tool)
        guard let result = response.object else { throw FormaError.invalidResponse }
        if let isError = result["isError"]?.boolean, isError { throw FormaError.refused }
        if let structured = result["structuredContent"], structured.object != nil {
            return structured
        }
        guard let content = result["content"]?.array, content.count == 1,
              let item = content.first?.object, item["type"]?.string == "text",
              let text = item["text"]?.string else { throw FormaError.invalidResponse }
        do { return try JSONDecoder().decode(MCPValue.self, from: Data(text.utf8)) }
        catch { throw FormaError.invalidResponse }
    }

    private func call(_ tool: String, _ arguments: [String: String]) async throws -> MCPValue {
        try await call(tool, arguments.mapValues { MCPValue.string($0) })
    }

    /// A UUID is only reported when the payload names exactly one: two or more
    /// would make "which record did this create?" a guess.
    nonisolated static func uniqueUUID(in value: MCPValue) -> String? {
        var found: Set<String> = []
        collectUUIDs(value, into: &found)
        return found.count == 1 ? found.first : nil
    }

    private nonisolated static func collectUUIDs(_ value: MCPValue, into found: inout Set<String>) {
        switch value {
        case .string(let text):
            if UUID(uuidString: text) != nil { found.insert(text.uppercased()) }
        case .array(let items):
            for item in items { collectUUIDs(item, into: &found) }
        case .object(let object):
            for (_, item) in object { collectUUIDs(item, into: &found) }
        default:
            break
        }
    }
}
