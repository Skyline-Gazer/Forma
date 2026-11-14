import CryptoKit
import Foundation

public struct DEVONthinkToolCapability: Sendable, Equatable {
    public let name: String
    public let inputSchema: Data
    public let inputSchemaSHA256: String
    public let outputSchema: Data?
    public let outputSchemaSHA256: String?
    public let readOnlyHint: Bool
}

public struct DEVONthinkCapabilities: Sendable, Equatable {
    public let protocolVersion: String
    public let serverName: String
    public let serverVersion: String
    public let probedAt: Date
    public let tools: [DEVONthinkToolCapability]
    /// Advertised tools with a supported input contract. This does not assert live query verification.
    public let availableReadOnlyTools: [String]
    public var hasRecordParents: Bool { availableReadOnlyTools.contains("get_record_parents") }
}

/// The database ID is supplied by the operator for the authorized isolated database.
/// Direct record queries are further limited to the selected record IDs.
public struct DEVONthinkReadScope: Sendable {
    public let databaseID: UUID
    public let recordIDs: Set<UUID>
    /// Field definitions are app-wide. Enable only when the running instance is isolated.
    public let permitsGlobalFieldDefinitions: Bool

    public init(databaseID: UUID, recordIDs: Set<UUID> = [], permitsGlobalFieldDefinitions: Bool = false) {
        self.databaseID = databaseID
        self.recordIDs = recordIDs
        self.permitsGlobalFieldDefinitions = permitsGlobalFieldDefinitions
    }
}

public struct DEVONthinkDatabase: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let rootGroupID: UUID
}

public struct DEVONthinkRecord: Sendable, Equatable {
    public let id: UUID
    public let databaseID: UUID
    public let name: String
    public let type: String
    public let location: String?
}

public struct DEVONthinkRecordPage: Sendable, Equatable {
    public let records: [DEVONthinkRecord]
    public let offset: Int
    public let total: Int
}

public struct DEVONthinkRecordParents: Sendable, Equatable {
    public let recordID: UUID
    public let primaryParentID: UUID?
    public let parents: [DEVONthinkRecord]
}

public enum DEVONthinkMetadataField: String, CaseIterable, Sendable {
    case projectname, completionyear, bidderentity, department, salesowner, endcustomer
    case biddeadline, tenderreference, bsdcode, documentcategory, documenttype, issuer
}

public enum DEVONthinkMetadataValue: Sendable, Equatable {
    case missing
    case null
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case strings([String])
}

public struct DEVONthinkMetadataFieldDefinition: Sendable, Equatable {
    public let field: DEVONthinkMetadataField
    public let title: String?
    public let nativeType: String
    public let isDisabled: Bool
    public let allowedValues: [String]?
}

private enum ReadTool: String {
    case database = "get_databases"
    case search = "search_records"
    case properties = "get_record_properties"
    case parents = "get_record_parents"
    case children = "get_record_children"
    case customMetadata = "get_record_custom_metadata"
    case fieldDefinitions = "list_custom_metadata_fields"

    func accepts(_ schema: MCPValue) -> Bool {
        let id = MCPValue.string("00000000-0000-4000-8000-000000000001")
        let page = ["offset": MCPValue.integer(0), "limit": .integer(1)]
        let record = ["uuid": id, "database_uuid": id]
        let batch = ["uuids": MCPValue.array([id]), "database_uuid": id]
        let sample: [String: MCPValue]
        switch self {
        case .database: sample = ["uuid": id]
        case .search: sample = page.merging(["database_uuid": id, "query": .string("test")]) { first, _ in first }
        case .properties: sample = record
        case .parents: sample = batch.merging(["kind": .string("groups")]) { first, _ in first }
        case .children: sample = page.merging(["uuid": id]) { first, _ in first }
        case .customMetadata: sample = batch
        case .fieldDefinitions: sample = ["include_disabled": .boolean(true)]
        }
        return InputSchema.accepts(sample, schema: schema)
    }
}

public actor DEVONthinkReadOnlyClient {
    private static let preferredVersion = "2025-06-18"
    private static let supportedVersions: Set = [preferredVersion, "2025-03-26", "2024-11-05"]

    private struct Discovery {
        let capabilities: DEVONthinkCapabilities
        let schemas: [ReadTool: MCPValue]
    }

    private let configuration: MCPConfiguration
    private var connection: MCPStdio?
    private var discovery: Discovery?
    private var observedInputDigests: [ReadTool: String] = [:]

    public init() { configuration = .devonThink }
    init(configuration: MCPConfiguration) { self.configuration = configuration }

    public func discover() async throws -> DEVONthinkCapabilities {
        if let connection {
            guard let discovery else { throw FormaError.unavailable }
            do {
                try await connection.checkOpen()
                guard self.connection === connection else { throw FormaError.disconnected }
                return discovery.capabilities
            } catch {
                guard self.connection === connection else { throw error }
                self.connection = nil
                self.discovery = nil
            }
        }
        guard !Task.isCancelled else { throw FormaError.cancelled }
        let connection = MCPStdio(configuration: configuration)
        self.connection = connection
        do {
            let initialized = try await connection.request("initialize", parameters: [
                "protocolVersion": .string(Self.preferredVersion),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("Forma"), "version": .string("0.1.0")])
            ])
            guard let version = initialized.object?["protocolVersion"]?.string,
                  let server = initialized.object?["serverInfo"]?.object,
                  let name = server["name"]?.string, !name.isEmpty,
                  let serverVersion = server["version"]?.string, !serverVersion.isEmpty,
                  let capabilities = initialized.object?["capabilities"]?.object else {
                throw FormaError.invalidResponse
            }
            guard Self.supportedVersions.contains(version), capabilities["tools"]?.object != nil else {
                throw FormaError.incompatible
            }
            try await connection.initialized()
            let discovery = try await Self.listTools(
                connection, version: version, name: name, serverVersion: serverVersion,
                observedInputDigests: observedInputDigests
            )
            try await connection.checkOpen()
            guard !Task.isCancelled else { throw FormaError.cancelled }
            guard self.connection === connection else { throw FormaError.disconnected }
            self.discovery = discovery
            for tool in discovery.capabilities.tools {
                if let readTool = ReadTool(rawValue: tool.name), discovery.schemas[readTool] != nil {
                    observedInputDigests[readTool] = tool.inputSchemaSHA256
                }
            }
            return discovery.capabilities
        } catch {
            if self.connection === connection {
                self.connection = nil
                discovery = nil
            }
            await connection.close()
            throw error
        }
    }

    public func close() async {
        let connection = connection
        self.connection = nil
        discovery = nil
        await connection?.close()
    }

    public func database(in scope: DEVONthinkReadScope) async throws -> DEVONthinkDatabase {
        let result = try await call(.database, ["uuid": .string(scope.databaseID.uuidString)])
        guard let rows = result.array, rows.count == 1, let row = rows.first?.object,
              let id = Self.uuid(row["uuid"]), let rootID = Self.uuid(row["rootUUID"]),
              let name = row["name"]?.string else { throw FormaError.invalidResponse }
        guard id == scope.databaseID else { throw FormaError.unauthorized }
        return DEVONthinkDatabase(id: id, name: name, rootGroupID: rootID)
    }

    public func search(_ query: String, in scope: DEVONthinkReadScope, limit: Int = 50, offset: Int = 0) async throws -> DEVONthinkRecordPage {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf8.count <= 2_048 else { throw FormaError.invalidSource }
        try Self.validatePage(limit: limit, offset: offset)
        let result = try await call(.search, [
            "query": .string(query), "database_uuid": .string(scope.databaseID.uuidString),
            "limit": .integer(limit), "offset": .integer(offset)
        ])
        return try Self.page(result, key: "results", scope: scope, limit: limit, offset: offset)
    }

    public func record(_ id: UUID, in scope: DEVONthinkReadScope) async throws -> DEVONthinkRecord {
        try await properties(id, in: scope).record
    }

    public func children(of id: UUID, in scope: DEVONthinkReadScope, limit: Int = 50, offset: Int = 0) async throws -> DEVONthinkRecordPage {
        try Self.validatePage(limit: limit, offset: offset)
        guard scope.recordIDs.contains(id) else { throw FormaError.unauthorized }
        let arguments: [String: MCPValue] = ["uuid": .string(id.uuidString), "limit": .integer(limit), "offset": .integer(offset)]
        let session = try validatedConnection(for: .children, arguments)
        let group = try await record(id, in: scope)
        guard group.type == "group" else { throw FormaError.invalidSource }
        guard connection === session else { throw FormaError.disconnected }
        let result = try await call(.children, arguments)
        return try Self.page(result, key: "items", scope: scope, limit: limit, offset: offset)
    }

    public func parents(of id: UUID, in scope: DEVONthinkReadScope) async throws -> DEVONthinkRecordParents {
        guard scope.recordIDs.contains(id) else { throw FormaError.unauthorized }
        // The single-record payload of this tool carries no record UUID of its own, so the
        // batch form is used: its per-entry `uuid` is what binds the answer to the record
        // that was asked for. See docs/I1-B1-CAPABILITY-DISCOVERY.md for the live shapes.
        var arguments: [String: MCPValue] = ["uuids": .array([.string(id.uuidString)])]
        arguments["database_uuid"] = .string(scope.databaseID.uuidString)
        arguments["kind"] = .string("groups")
        let session = try validatedConnection(for: .parents, arguments)
        // The relation payload can omit the source database even when its UUID is echoed.
        _ = try await record(id, in: scope)
        guard connection === session else { throw FormaError.disconnected }
        let result = try await call(.parents, arguments)
        guard let envelope = result.object, let rows = envelope["results"]?.array, rows.count == 1,
              envelope["succeeded"]?.integer == 1, envelope["failed"]?.integer == 0,
              let row = rows.first?.object, let recordID = Self.uuid(row["uuid"]),
              row["kind"]?.string == "groups", let entries = row["parents"]?.array,
              row["count"]?.integer == entries.count else { throw FormaError.invalidResponse }
        guard recordID == id else { throw FormaError.unauthorized }
        if let database = row["databaseUUID"], Self.uuid(database) != scope.databaseID {
            throw FormaError.unauthorized
        }
        let parents = try entries.map { try Self.parseRecord($0, databaseID: scope.databaseID) }
        let primaryParentID: UUID?
        if let primary = row["primary_parent"], primary != .null {
            let parent = try Self.parseRecord(primary, databaseID: scope.databaseID)
            guard parents.contains(where: { $0.id == parent.id }) else { throw FormaError.invalidResponse }
            primaryParentID = parent.id
        } else {
            primaryParentID = nil
        }
        return DEVONthinkRecordParents(recordID: id, primaryParentID: primaryParentID, parents: parents)
    }

    public func metadata(of id: UUID, in scope: DEVONthinkReadScope) async throws -> [DEVONthinkMetadataField: DEVONthinkMetadataValue] {
        // The record properties bind the UUID to the authorized database; the metadata tool
        // reports the field values. Its single-record payload carries no database identity,
        // so the batch form is used and the returned UUID is checked against the record read.
        _ = try await record(id, in: scope)
        let arguments: [String: MCPValue] = [
            "uuids": .array([.string(id.uuidString)]),
            "database_uuid": .string(scope.databaseID.uuidString),
        ]
        let session = try validatedConnection(for: .customMetadata, arguments)
        guard connection === session else { throw FormaError.disconnected }
        let result = try await call(.customMetadata, arguments)
        guard let envelope = result.object, let rows = envelope["results"]?.array, rows.count == 1,
              envelope["succeeded"]?.integer == 1, envelope["failed"]?.integer == 0,
              let row = rows.first?.object, let recordID = Self.uuid(row["uuid"]), recordID == id,
              let metadata = row["metadata"]?.object else { throw FormaError.invalidResponse }
        return try Dictionary(uniqueKeysWithValues: DEVONthinkMetadataField.allCases.map { field in
            (field, try Self.metadataValue(metadata[field.rawValue]))
        })
    }

    public func metadataFieldDefinitions(in scope: DEVONthinkReadScope) async throws -> [DEVONthinkMetadataFieldDefinition] {
        guard scope.permitsGlobalFieldDefinitions else { throw FormaError.unauthorized }
        let arguments = ["include_disabled": MCPValue.boolean(true)]
        let session = try validatedConnection(for: .fieldDefinitions, arguments)
        _ = try await database(in: scope)
        guard connection === session else { throw FormaError.disconnected }
        let result = try await call(.fieldDefinitions, arguments)
        guard let rows = result.array else { throw FormaError.invalidResponse }
        var fields: [DEVONthinkMetadataField: DEVONthinkMetadataFieldDefinition] = [:]
        for value in rows {
            guard let row = value.object, let identifier = row["identifier"]?.string else { throw FormaError.invalidResponse }
            guard let field = DEVONthinkMetadataField(rawValue: identifier) else { continue }
            guard fields[field] == nil, let type = row["type"]?.string, !type.isEmpty,
                  let disabled = row["disabled"]?.boolean else { throw FormaError.invalidResponse }
            fields[field] = DEVONthinkMetadataFieldDefinition(
                field: field, title: try Self.optionalString(row["title"]), nativeType: type,
                isDisabled: disabled, allowedValues: try row["values"].map(Self.stringArray)
            )
        }
        return DEVONthinkMetadataField.allCases.compactMap { fields[$0] }
    }

    private func properties(_ id: UUID, in scope: DEVONthinkReadScope) async throws -> (record: DEVONthinkRecord, row: [String: MCPValue]) {
        let result = try await call(.properties, Self.recordArguments(id, scope: scope))
        let record = try Self.parseRecord(result, databaseID: scope.databaseID)
        guard record.id == id else { throw FormaError.unauthorized }
        guard let row = result.object else { throw FormaError.invalidResponse }
        return (record, row)
    }

    private static func listTools(
        _ connection: MCPStdio, version: String, name: String, serverVersion: String,
        observedInputDigests: [ReadTool: String]
    ) async throws -> Discovery {
        var seenCursors: Set<String> = []
        var tools: [String: DEVONthinkToolCapability] = [:]
        var schemas: [ReadTool: MCPValue] = [:]
        var cursor: String?
        var schemaBytes = 0
        for _ in 0..<32 {
            let result = try await connection.request("tools/list", parameters: cursor.map { ["cursor": .string($0)] } ?? [:])
            guard let page = result.object, let rows = page["tools"]?.array,
                  rows.count <= 256 - tools.count else { throw FormaError.invalidResponse }
            for value in rows {
                guard let row = value.object, let toolName = row["name"]?.string, !toolName.isEmpty,
                      toolName.utf8.count <= 256, tools[toolName] == nil,
                      let input = row["inputSchema"], input.object?["type"]?.string == "object" else {
                    throw FormaError.invalidResponse
                }
                let output = row["outputSchema"]
                if let output, output.object?["type"]?.string != "object" { throw FormaError.invalidResponse }
                let inputData = try input.canonicalData()
                let outputData = try output?.canonicalData()
                schemaBytes += inputData.count + (outputData?.count ?? 0)
                guard schemaBytes <= 4 * 1024 * 1024 else { throw FormaError.invalidResponse }
                let readOnly = row["annotations"]?.object?["readOnlyHint"]?.boolean == true
                let inputDigest = digest(inputData)
                tools[toolName] = DEVONthinkToolCapability(
                    name: toolName, inputSchema: inputData, inputSchemaSHA256: inputDigest,
                    outputSchema: outputData, outputSchemaSHA256: outputData.map(digest), readOnlyHint: readOnly
                )
                if readOnly, let tool = ReadTool(rawValue: toolName), tool.accepts(input),
                   observedInputDigests[tool, default: inputDigest] == inputDigest {
                    schemas[tool] = input
                }
            }
            guard let next = page["nextCursor"] else {
                return Discovery(capabilities: DEVONthinkCapabilities(
                    protocolVersion: version, serverName: name, serverVersion: serverVersion, probedAt: Date(),
                    tools: tools.values.sorted { $0.name < $1.name }, availableReadOnlyTools: schemas.keys.map(\.rawValue).sorted()
                ), schemas: schemas)
            }
            guard let nextCursor = next.string, !nextCursor.isEmpty, nextCursor.utf8.count <= 1024,
                  seenCursors.insert(nextCursor).inserted else { throw FormaError.invalidResponse }
            cursor = nextCursor
        }
        throw FormaError.invalidResponse
    }

    private func validatedConnection(for tool: ReadTool, _ arguments: [String: MCPValue]) throws -> MCPStdio {
        guard let connection, let discovery else { throw FormaError.unavailable }
        guard let schema = discovery.schemas[tool], InputSchema.accepts(arguments, schema: schema) else {
            throw FormaError.incompatible
        }
        return connection
    }

    private func call(_ tool: ReadTool, _ arguments: [String: MCPValue]) async throws -> MCPValue {
        let connection = try validatedConnection(for: tool, arguments)
        let response = try await connection.request("tools/call", parameters: [
            "name": .string(tool.rawValue), "arguments": .object(arguments)
        ])
        guard self.connection === connection else { throw FormaError.disconnected }
        guard !Task.isCancelled else { throw FormaError.cancelled }
        guard let result = response.object else { throw FormaError.invalidResponse }
        if let isError = result["isError"] {
            guard let failure = isError.boolean else { throw FormaError.invalidResponse }
            if failure { throw FormaError.refused }
        }
        if let structured = result["structuredContent"] {
            guard structured.object != nil else { throw FormaError.invalidResponse }
            return structured
        }
        guard let content = result["content"]?.array, content.count == 1,
              let item = content.first?.object, item["type"]?.string == "text",
              let text = item["text"]?.string else { throw FormaError.invalidResponse }
        do { return try JSONDecoder().decode(MCPValue.self, from: Data(text.utf8)) }
        catch { throw FormaError.invalidResponse }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validatePage(limit: Int, offset: Int) throws {
        guard (1...100).contains(limit), offset >= 0, offset <= Int.max - limit else { throw FormaError.invalidSource }
    }

    private static func recordArguments(_ id: UUID, scope: DEVONthinkReadScope) throws -> [String: MCPValue] {
        guard scope.recordIDs.contains(id) else { throw FormaError.unauthorized }
        return ["uuid": .string(id.uuidString), "database_uuid": .string(scope.databaseID.uuidString)]
    }

    private static func uuid(_ value: MCPValue?) -> UUID? {
        value?.string.flatMap(UUID.init(uuidString:))
    }

    private static func parseRecord(_ value: MCPValue, databaseID: UUID) throws -> DEVONthinkRecord {
        guard let row = value.object, let id = uuid(row["uuid"]), let database = uuid(row["databaseUUID"]),
              let name = row["name"]?.string, let type = row["type"]?.string else { throw FormaError.invalidResponse }
        guard database == databaseID else { throw FormaError.unauthorized }
        return DEVONthinkRecord(id: id, databaseID: database, name: name, type: type, location: try optionalString(row["location"]))
    }

    private static func page(_ value: MCPValue, key: String, scope: DEVONthinkReadScope, limit: Int, offset: Int) throws -> DEVONthinkRecordPage {
        guard let page = value.object, let rows = page[key]?.array, rows.count <= limit,
              let total = page["total"]?.integer, total >= 0, page["offset"]?.integer == offset,
              rows.isEmpty || offset + rows.count <= total else { throw FormaError.invalidResponse }
        let records = try rows.map { try parseRecord($0, databaseID: scope.databaseID) }
        return DEVONthinkRecordPage(records: records, offset: offset, total: total)
    }

    private static func optionalString(_ value: MCPValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let text = value.string else { throw FormaError.invalidResponse }
        return text
    }

    private static func stringArray(_ value: MCPValue) throws -> [String] {
        guard let values = value.array else { throw FormaError.invalidResponse }
        return try strings(values)
    }

    private static func strings(_ values: [MCPValue]) throws -> [String] {
        return try values.map {
            guard let string = $0.string else { throw FormaError.invalidResponse }
            return string
        }
    }

    private static func metadataValue(_ value: MCPValue?) throws -> DEVONthinkMetadataValue {
        switch value {
        case nil: .missing
        case .null?: .null
        case .string(let text)?: .string(text)
        case .boolean(let flag)?: .boolean(flag)
        case .integer(let number)?: .integer(number)
        case .number(let number)?: .number(number)
        case .array(let values)?: .strings(try strings(values))
        case .object?: throw FormaError.invalidResponse
        }
    }
}

/// Validate only the argument forms this client emits. Unsupported constraints on those forms fail closed.
private enum InputSchema {
    private static let annotations: Set<String> = ["title", "description", "default", "examples", "$schema", "$comment"]

    static func accepts(_ arguments: [String: MCPValue], schema: MCPValue) -> Bool {
        guard let schema = schema.object, schema["type"] == .string("object"),
              Set(schema.keys).isSubset(of: annotations.union(["type", "properties", "required", "additionalProperties"])),
              let properties = schema["properties"]?.object else { return false }
        if let required = schema["required"] {
            guard let keys = required.array,
                  keys.allSatisfy({ $0.string.map { arguments[$0] != nil } == true }) else { return false }
        }
        return arguments.allSatisfy { key, value in
            guard let constraints = properties[key]?.object else { return false }
            return accepts(value, constraints: constraints)
        }
    }

    private static func accepts(_ value: MCPValue, constraints: [String: MCPValue]) -> Bool {
        if let allowed = constraints["enum"], allowed.array?.contains(value) != true { return false }
        let base = annotations.union(["type", "enum"])
        switch value {
        case .string(let string):
            return constraints["type"] == .string("string")
                && Set(constraints.keys).isSubset(of: base.union(["minLength", "maxLength"]))
                && meetsBounds(string.unicodeScalars.count, constraints["minLength"], constraints["maxLength"])
        case .integer(let number):
            return constraints["type"] == .string("integer")
                && Set(constraints.keys).isSubset(of: base.union(["minimum", "maximum"]))
                && meetsBounds(number, constraints["minimum"], constraints["maximum"])
        case .boolean:
            return constraints["type"] == .string("boolean") && Set(constraints.keys).isSubset(of: base)
        case .array(let elements):
            // Only a homogeneous array of strings is emitted by this client, so only that
            // shape is accepted; anything else fails closed before the request is sent.
            guard constraints["type"] == .string("array"),
                  Set(constraints.keys).isSubset(of: base.union(["items", "minItems", "maxItems"])),
                  let items = constraints["items"]?.object,
                  Set(items.keys).isSubset(of: base.union(["minLength", "maxLength"])) else { return false }
            if let maximum = constraints["maxItems"]?.integer, elements.count > maximum { return false }
            if let minimum = constraints["minItems"]?.integer, elements.count < minimum { return false }
            return elements.allSatisfy { element in
                guard case .string(let text) = element else { return false }
                return accepts(.string(text), constraints: items)
            }
        default: return false
        }
    }

    private static func meetsBounds(_ value: Int, _ minimum: MCPValue?, _ maximum: MCPValue?) -> Bool {
        if let minimum, minimum.integer.map({ value >= $0 }) != true { return false }
        if let maximum, maximum.integer.map({ value <= $0 }) != true { return false }
        return true
    }
}
