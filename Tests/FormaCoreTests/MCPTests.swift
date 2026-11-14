import CryptoKit
import Foundation
import Testing
@testable import FormaCore

private let databaseID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
private let recordID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
private let groupID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
private let scope = DEVONthinkReadScope(databaseID: databaseID, recordIDs: [recordID, groupID])

private let peerPrelude = #"""
next() {
    IFS= read -r line || exit 1
    id=${line#*\"id\":}
    id=${id%%,*}
}
expect() {
    case "$line" in *"$1"*) ;; *) exit 2 ;; esac
}
respond() {
    printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"
}
initialize() {
    next
    expect '"method":"initialize"'
    expect '"protocolVersion":"2025-06-18"'
    respond "$id" '{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1.0"}}'
    next
    expect '"method":"notifications/initialized"'
    next
    expect '"method":"tools/list"'
}
keep_open() {
    while IFS= read -r extra; do exit 3; done
}
"""#

/// The fixture peer is a `/bin/sh` process, and CI runners start one in well
/// over a second under load, so the default budget is generous. A test that
/// needs a timeout must create one deliberately - never by racing the clock.
private func fake(_ script: String, timeout: Duration = .seconds(15), frameLimit: Int = 2 * 1024 * 1024) -> MCPConfiguration {
    MCPConfiguration(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", peerPrelude + "\n" + script],
                     timeout: timeout, maximumFrameBytes: frameLimit)
}

@Test func mcpDiscoveryNegotiatesAndCollectsPaginatedSchemas() async throws {
    let client = DEVONthinkReadOnlyClient(configuration: fake(#"""
    initialize
    respond "$id" '{"tools":[{"name":"set_record_name","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object"}}],"nextCursor":"page-2"}'
    next
    expect '"method":"tools/list"'
    expect '"cursor":"page-2"'
    respond "$id" '{"tools":[{"name":"get_record_parents","annotations":{"readOnlyHint":true},"outputSchema":{"type":"object"},"inputSchema":{"type":"object","properties":{"uuids":{"type":"array","items":{"type":"string"},"maxItems":500},"database_uuid":{"type":"string"},"kind":{"type":"string","enum":["groups","tags","both"]}}}}]}'
    keep_open
    """#))
    let discovery = try await client.discover()
    #expect(discovery.serverName == "fixture")
    #expect(discovery.serverVersion == "1.0")
    #expect(discovery.protocolVersion == "2025-06-18")
    #expect(discovery.tools.map(\.name) == ["get_record_parents", "set_record_name"])
    #expect(discovery.availableReadOnlyTools == ["get_record_parents"])
    #expect(discovery.hasRecordParents)
    let parent = try #require(discovery.tools.first)
    let expected = Data(#"{"properties":{"database_uuid":{"type":"string"},"kind":{"enum":["groups","tags","both"],"type":"string"},"uuids":{"items":{"type":"string"},"maxItems":500,"type":"array"}},"type":"object"}"#.utf8)
    #expect(parent.inputSchema == expected)
    #expect(parent.inputSchemaSHA256 == SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined())
    #expect(parent.outputSchema == Data(#"{"type":"object"}"#.utf8))
    #expect(parent.outputSchemaSHA256?.count == 64)
    await client.close()
}

@Test func mcpRejectsUnsupportedVersionAndRepeatingCursor() async {
    let unsupported = DEVONthinkReadOnlyClient(configuration: fake(#"""
    next
    respond "$id" '{"protocolVersion":"2999-01-01","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1.0"}}'
    keep_open
    """#))
    await #expect(throws: FormaError.incompatible) { try await unsupported.discover() }
    let repeated = DEVONthinkReadOnlyClient(configuration: fake(#"""
    initialize
    respond "$id" '{"tools":[],"nextCursor":"loop"}'
    next
    expect '"cursor":"loop"'
    respond "$id" '{"tools":[],"nextCursor":"loop"}'
    keep_open
    """#))
    await #expect(throws: FormaError.invalidResponse) { try await repeated.discover() }
}

@Test func mcpRejectsUnauthorizedAndIncompatibleInputsBeforeSending() async throws {
    let client = DEVONthinkReadOnlyClient(configuration: fake(#"""
    initialize
    respond "$id" '{"tools":[{"name":"get_record_properties","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"uuid":{"type":"string"}}}},{"name":"search_records","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"query":{"type":"string","maxLength":5},"database_uuid":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":10},"offset":{"type":"integer","minimum":0}},"required":["query"]}}]}'
    next
    expect '"name":"search_records"'
    expect '"query":"ok"'
    expect '"database_uuid":"00000000-0000-4000-8000-000000000001"'
    respond "$id" '{"structuredContent":{"results":[],"offset":0,"total":0}}'
    keep_open
    """#))
    let discovery = try await client.discover()
    #expect(discovery.availableReadOnlyTools == ["search_records"])
    await #expect(throws: FormaError.unauthorized) {
        try await client.record(recordID, in: DEVONthinkReadScope(databaseID: databaseID))
    }
    await #expect(throws: FormaError.unauthorized) { try await client.metadataFieldDefinitions(in: scope) }
    await #expect(throws: FormaError.incompatible) { try await client.record(recordID, in: scope) }
    await #expect(throws: FormaError.incompatible) { try await client.search("too long", in: scope, limit: 1) }
    await #expect(throws: FormaError.invalidSource) { try await client.search("ok", in: scope, limit: 0) }
    let page = try await client.search("ok", in: scope, limit: 1)
    #expect(page.records.isEmpty)
    await client.close()
}

@Test func mcpReadsOnlyScopedPropertiesParentsChildrenAndMetadata() async throws {
    let client = DEVONthinkReadOnlyClient(configuration: fake(#"""
    initialize
    respond "$id" '{"tools":[{"name":"get_record_properties","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"uuid":{"type":"string"},"database_uuid":{"type":"string"}}}},{"name":"get_record_custom_metadata","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"uuids":{"type":"array","items":{"type":"string"},"maxItems":500},"database_uuid":{"type":"string"}}}},{"name":"get_record_parents","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"uuids":{"type":"array","items":{"type":"string"},"maxItems":500},"database_uuid":{"type":"string"},"kind":{"type":"string","enum":["groups","tags","both"]}}}},{"name":"get_record_children","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"uuid":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"}}}},{"name":"get_databases","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"uuid":{"type":"string"}}}},{"name":"list_custom_metadata_fields","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"include_disabled":{"type":"boolean"}}}}]}'
    record='{"uuid":"00000000-0000-4000-8000-000000000002","databaseUUID":"00000000-0000-4000-8000-000000000001","name":"Fixture document","type":"pdf"}'
    group='{"uuid":"00000000-0000-4000-8000-000000000003","databaseUUID":"00000000-0000-4000-8000-000000000001","name":"Fixture group","type":"group"}'
    next
    expect '"name":"get_record_properties"'
    expect '"uuid":"00000000-0000-4000-8000-000000000002"'
    expect '"database_uuid":"00000000-0000-4000-8000-000000000001"'
    respond "$id" "{\"structuredContent\":$record}"
    next
    expect '"name":"get_record_custom_metadata"'
    expect '"uuids":["00000000-0000-4000-8000-000000000002"]'
    respond "$id" '{"structuredContent":{"operation":"get_record_custom_metadata","succeeded":1,"failed":0,"results":[{"uuid":"00000000-0000-4000-8000-000000000002","metadata":{"projectname":"Sample","issuer":null,"department":"","completionyear":2030,"unrelated":"discard"}}]}}'
    next
    expect '"name":"get_record_properties"'
    respond "$id" "{\"structuredContent\":$record}"
    next
    expect '"name":"get_record_parents"'
    expect '"kind":"groups"'
    respond "$id" "{\"structuredContent\":{\"operation\":\"get_record_parents\",\"succeeded\":1,\"failed\":0,\"results\":[{\"uuid\":\"00000000-0000-4000-8000-000000000002\",\"kind\":\"groups\",\"primary_parent\":$group,\"parents\":[$group],\"count\":1}]}}"
    next
    expect '"name":"get_record_properties"'
    expect '"uuid":"00000000-0000-4000-8000-000000000003"'
    respond "$id" "{\"structuredContent\":$group}"
    next
    expect '"name":"get_record_children"'
    respond "$id" "{\"structuredContent\":{\"items\":[$record],\"offset\":0,\"total\":1}}"
    next
    expect '"name":"get_databases"'
    expect '"uuid":"00000000-0000-4000-8000-000000000001"'
    respond "$id" '{"isError":false,"content":[{"type":"text","text":"[{\"uuid\":\"00000000-0000-4000-8000-000000000001\",\"rootUUID\":\"00000000-0000-4000-8000-000000000003\",\"name\":\"Isolated fixture\"}]"}]}'
    next
    expect '"name":"list_custom_metadata_fields"'
    expect '"include_disabled":true'
    respond "$id" '{"isError":false,"content":[{"type":"text","text":"[{\"identifier\":\"projectname\",\"title\":\"Project\",\"type\":\"string\",\"disabled\":false},{\"identifier\":\"department\",\"type\":\"set\",\"disabled\":true,\"values\":[\"Sample\"]},{\"identifier\":\"unrelated\"}]"}]}'
    keep_open
    """#))
    _ = try await client.discover()
    let metadata = try await client.metadata(of: recordID, in: scope)
    #expect(metadata.count == 12)
    #expect(metadata[.projectname] == .string("Sample"))
    #expect(metadata[.issuer] == .null)
    #expect(metadata[.department] == .string(""))
    #expect(metadata[.completionyear] == .integer(2030))
    #expect(metadata[.biddeadline] == .missing)
    let parents = try await client.parents(of: recordID, in: scope)
    #expect(parents.primaryParentID == groupID)
    #expect(parents.parents.map(\.id) == [groupID])
    let children = try await client.children(of: groupID, in: scope)
    #expect(children.records.map(\.id) == [recordID])
    let isolated = DEVONthinkReadScope(databaseID: databaseID, permitsGlobalFieldDefinitions: true)
    let fields = try await client.metadataFieldDefinitions(in: isolated)
    #expect(fields.map(\.field) == [.projectname, .department])
    #expect(fields.first?.title == "Project")
    #expect(fields.last?.isDisabled == true)
    #expect(fields.last?.allowedValues == ["Sample"])
    await client.close()
}

/// The live server answers `get_record_parents` and `get_record_custom_metadata` in their
/// batch form, where the record UUID is echoed per entry rather than at the top level.
/// A payload that binds to another record, or that reports a partial batch, is refused.
@Test func mcpRefusesBatchPayloadsThatDoNotBindToTheRequestedRecord() async throws {
    let client = DEVONthinkReadOnlyClient(configuration: fake(#"""
    initialize
    respond "$id" '{"tools":[{"name":"get_record_properties","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"uuid":{"type":"string"},"database_uuid":{"type":"string"}}}},{"name":"get_record_custom_metadata","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"uuids":{"type":"array","items":{"type":"string"},"maxItems":500},"database_uuid":{"type":"string"}}}},{"name":"get_record_parents","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"uuids":{"type":"array","items":{"type":"string"},"maxItems":500},"database_uuid":{"type":"string"},"kind":{"type":"string","enum":["groups","tags","both"]}}}}]}'
    record='{"uuid":"00000000-0000-4000-8000-000000000002","databaseUUID":"00000000-0000-4000-8000-000000000001","name":"Fixture document","type":"pdf"}'
    next
    expect '"name":"get_record_properties"'
    respond "$id" "{\"structuredContent\":$record}"
    next
    expect '"name":"get_record_custom_metadata"'
    respond "$id" '{"structuredContent":{"operation":"get_record_custom_metadata","succeeded":1,"failed":0,"results":[{"uuid":"00000000-0000-4000-8000-000000000009","metadata":{"projectname":"Other"}}]}}'
    next
    expect '"name":"get_record_properties"'
    respond "$id" "{\"structuredContent\":$record}"
    next
    expect '"name":"get_record_parents"'
    respond "$id" '{"structuredContent":{"operation":"get_record_parents","succeeded":0,"failed":1,"failed_uuids":["00000000-0000-4000-8000-000000000002"],"results":[]}}'
    keep_open
    """#))
    _ = try await client.discover()
    await #expect(throws: FormaError.invalidResponse) { try await client.metadata(of: recordID, in: scope) }
    await #expect(throws: FormaError.invalidResponse) { try await client.parents(of: recordID, in: scope) }
    await client.close()
}

@Test func mcpRejectsCrossDatabaseResultsAndWrongRecordIdentity() async throws {
    let client = DEVONthinkReadOnlyClient(configuration: fake(#"""
    initialize
    respond "$id" '{"tools":[{"name":"get_record_properties","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"uuid":{"type":"string"},"database_uuid":{"type":"string"}}}},{"name":"search_records","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"query":{"type":"string"},"database_uuid":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"}}}}]}'
    next
    expect '"name":"search_records"'
    respond "$id" '{"structuredContent":{"results":[{"uuid":"00000000-0000-4000-8000-000000000002","databaseUUID":"00000000-0000-4000-8000-000000000001","name":"Good","type":"pdf"},{"uuid":"00000000-0000-4000-8000-000000000003","databaseUUID":"00000000-0000-4000-8000-000000000004","name":"Out of scope","type":"pdf"}],"offset":0,"total":2}}'
    next
    expect '"name":"get_record_properties"'
    respond "$id" '{"structuredContent":{"uuid":"00000000-0000-4000-8000-000000000003","databaseUUID":"00000000-0000-4000-8000-000000000001","name":"Wrong record","type":"pdf"}}'
    keep_open
    """#))
    _ = try await client.discover()
    await #expect(throws: FormaError.unauthorized) { try await client.search("fixture", in: scope) }
    await #expect(throws: FormaError.unauthorized) { try await client.metadata(of: recordID, in: scope) }
    await client.close()
}

@Test func mcpCorrelatesOutOfOrderResponsesAndSeparatesStderr() async throws {
    let transport = MCPStdio(configuration: fake(#"""
    next
    firstID=$id
    firstLine=$line
    next
    printf 'debug message\n' >&2
    case "$line" in *'"method":"alpha"'*) respond "$id" '"alpha"';; *) respond "$id" '"beta"';; esac
    case "$firstLine" in *'"method":"alpha"'*) respond "$firstID" '"alpha"';; *) respond "$firstID" '"beta"';; esac
    keep_open
    """#))
    async let alpha = transport.request("alpha")
    async let beta = transport.request("beta")
    let results = try await (alpha, beta)
    #expect(results.0 == .string("alpha"))
    #expect(results.1 == .string("beta"))
    await transport.close()
}

@Test func mcpTimeoutDiscardsLateReplyAndCloseRejectsFurtherRequests() async throws {
    let transport = MCPStdio(configuration: fake(#"""
    next
    expect '"method":"timeout"'
    expired=$id
    next
    expect '"method":"valid"'
    respond "$expired" '"late"'
    respond "$id" '"fresh"'
    keep_open
    """#, timeout: .seconds(2)))
    await #expect(throws: FormaError.timeout) { try await transport.request("timeout") }
    let fresh = try await transport.request("valid")
    #expect(fresh == .string("fresh"))
    await transport.close()
    await #expect(throws: FormaError.disconnected) { try await transport.request("after-close") }
}

@Test func mcpReportsOversizedFramesDisconnectAndRemoteError() async {
    let oversized = MCPStdio(configuration: fake(#"""
    next
    printf '%0128d' 0
    keep_open
    """#, frameLimit: 64))
    await #expect(throws: FormaError.invalidResponse) { try await oversized.request("overflow") }
    let disconnect = MCPStdio(configuration: fake("next\nexit 0"))
    await #expect(throws: FormaError.disconnected) { try await disconnect.request("disconnect") }
    let remote = MCPStdio(configuration: fake(#"""
    next
    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"private diagnostics"}}\n' "$id"
    keep_open
    """#))
    await #expect(throws: FormaError.remoteStatus(-32602)) { try await remote.request("error") }
    await remote.close()
}

@Test func mcpCancellationAndCloseResumeOutstandingCalls() async throws {
    let transport = MCPStdio(configuration: fake(#"""
    pair() {
        for _ in 1 2; do
            next
            case "$line" in
                *'"method":"hold"'*) held=$id;;
                *'"method":"barrier"'*) barrier=$id;;
                *) exit 4;;
            esac
        done
        respond "$barrier" '"ready"'
    }
    pair
    pair
    keep_open
    """#))
    let cancelled = Task { try await transport.request("hold") }
    _ = try await transport.request("barrier")
    cancelled.cancel()
    await #expect(throws: FormaError.cancelled) { try await cancelled.value }

    let pending = Task { try await transport.request("hold") }
    _ = try await transport.request("barrier")
    await transport.close()
    await #expect(throws: FormaError.disconnected) { try await pending.value }
}

@Test func mcpDisablesChangedSchemaOnReconnect() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    var fixture = fake(#"""
    initialize
    if [ -e "$1" ]; then
        description=changed
    else
        : > "$1"
        description=original
    fi
    respond "$id" "{\"tools\":[{\"name\":\"get_databases\",\"annotations\":{\"readOnlyHint\":true},\"inputSchema\":{\"type\":\"object\",\"description\":\"$description\",\"properties\":{\"uuid\":{\"type\":\"string\"}}}}]}"
    keep_open
    """#)
    fixture = MCPConfiguration(executable: fixture.executable, arguments: fixture.arguments + ["forma-mcp-fixture", marker.path],
                               timeout: fixture.timeout, maximumFrameBytes: fixture.maximumFrameBytes)
    let client = DEVONthinkReadOnlyClient(configuration: fixture)
    let first = try await client.discover()
    #expect(first.availableReadOnlyTools == ["get_databases"])
    await client.close()
    let second = try await client.discover()
    #expect(second.tools.first?.inputSchemaSHA256 != first.tools.first?.inputSchemaSHA256)
    #expect(second.availableReadOnlyTools.isEmpty)
    await #expect(throws: FormaError.incompatible) { try await client.database(in: scope) }
    await client.close()
}
