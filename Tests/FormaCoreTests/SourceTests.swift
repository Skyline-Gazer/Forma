import CryptoKit
import Darwin
import Foundation
import SQLite3
import Testing
import ZIPFoundation
@testable import FormaCore

@Suite("Source workspace")
struct SourceTests {
    @Test func scanAndRestartPreserveIDsAndImmutableSnapshots() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.write("first", at: "Project/Report.txt")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        #expect(try await workspace.register(fixture.root).id == scope.id)
        #expect(try await workspace.listing(scope).state == .notScanned)

        let first = try await workspace.scan(scope)
        let before = try #require(first.entries.first)
        #expect(first.isComplete)
        #expect(first.statistics?.directoryCount == 1)
        #expect(first.statistics?.extensions == ["txt": 1])
        #expect(first.statistics?.sizeBytes == 5)
        #expect(before.sha256 == nil)
        #expect(try await workspace.scan(scope).entries == first.entries)

        let reopened = try SourceWorkspace(databaseURL: fixture.database)
        #expect(try await reopened.scopes() == [scope])
        #expect(try await reopened.listing(scope).entries == first.entries)
        try Data("replacement document".utf8).write(to: file, options: .atomic)
        let after = try #require(try await reopened.scan(scope).entries.first)
        #expect(after.id == before.id)
        #expect(after.sourceVersion == before.sourceVersion + 1)
        #expect(after.snapshotRevision == before.snapshotRevision + 1)
        #expect(after.snapshotFingerprint != before.snapshotFingerprint)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM source_snapshots WHERE format = 'snapshot.v1'") == "2")
        #expect(try fixture.scalar("SELECT fingerprint FROM source_snapshots ORDER BY revision LIMIT 1") == before.snapshotFingerprint)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM pragma_foreign_key_check") == "0")
    }

    @Test func overlappingSelectionsReuseOneCanonicalRootInBothOrders() async throws {
        for childFirst in [false, true] {
            let fixture = try SourceFixture()
            defer { fixture.cleanUp() }
            let file = try fixture.write("sample", at: "Child/file.txt")
            _ = try fixture.write("outside the child", at: "sibling.txt")
            let child = file.deletingLastPathComponent()
            let workspace = try SourceWorkspace(databaseURL: fixture.database)
            let first = try await workspace.register(childFirst ? child : fixture.root)
            let firstScan = try await workspace.scan(first)
            let initialID = try #require(firstScan.entries.first { $0.relativePath.hasSuffix("file.txt") }).id
            let second = try await workspace.register(childFirst ? fixture.root : child)
            let parentScope = childFirst ? second : first
            let childScope = childFirst ? first : second
            #expect(first.rootID == second.rootID)
            #expect(first.id != second.id)
            let parentListing = try await workspace.scan(parentScope)
            let childListing = try await workspace.scan(childScope)
            #expect(parentListing.entries.map(\.relativePath) == ["Child/file.txt", "sibling.txt"])
            #expect(childListing.scope.relativePath == "Child")
            #expect(childListing.entries.map(\.id) == [initialID])
            #expect(try fixture.scalar("SELECT COUNT(*) FROM source_roots") == "1")
        }
    }

    @Test func directorySymlinksAreRecordedAndNeverFollowed() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let external = fixture.base.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try Data("outside".utf8).write(to: external.appendingPathComponent("external.txt"))
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("external"), withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("loop"), withDestinationURL: fixture.root)
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let listing = try await workspace.scan(scope)
        #expect(listing.isComplete)
        #expect(listing.entries.map(\.relativePath) == ["external", "loop"])
        #expect(listing.entries.allSatisfy { $0.state == .symlink })
        let entry = try #require(listing.entries.first)
        #expect(try await workspace.evidence(for: entry).status == .unavailable)
    }

    @Test func localRenamePreservesReliableIdentityAndHardLinksStayDistinct() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.write("original", at: "original.txt")
        let linked = try fixture.write("shared inode", at: "linked.txt")
        try FileManager.default.linkItem(at: linked, to: fixture.root.appendingPathComponent("other-link.txt"))
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let before = try await workspace.scan(scope)
        let original = try #require(before.entries.first { $0.relativePath == "original.txt" })
        let oldLink = try #require(before.entries.first { $0.relativePath == "linked.txt" })
        try FileManager.default.moveItem(at: file, to: fixture.root.appendingPathComponent("renamed.txt"))
        try FileManager.default.moveItem(at: linked, to: fixture.root.appendingPathComponent("new-link.txt"))
        let after = try await workspace.scan(scope)
        let renamed = try #require(after.entries.first { $0.relativePath == "renamed.txt" })
        let newLink = try #require(after.entries.first { $0.relativePath == "new-link.txt" })
        if try fixture.scalar("SELECT COUNT(*) FROM source_snapshots WHERE resource_identity_value IS NOT NULL") != "0" {
            #expect(renamed.id == original.id)
            #expect(renamed.sourceVersion == original.sourceVersion)
            #expect(try fixture.scalar("SELECT previous_path FROM path_history WHERE relative_path = 'renamed.txt'") == "original.txt")
        } else {
            #expect(renamed.id != original.id)
            #expect(after.entries.first { $0.id == original.id }?.state == .missing)
        }
        #expect(newLink.id != oldLink.id)
        #expect(after.entries.first { $0.id == oldLink.id }?.state == .missing)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM source_move_candidates WHERE reason = 'local-object-observation'") != "0")
    }

    @Test func incompleteCancelledAndInterruptedScansPreserveKnownEntries() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.write("sample", at: "file.txt")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let completed = try await workspace.scan(scope)
        try FileManager.default.removeItem(at: file)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await workspace.scan(scope)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await workspace.listing(scope).state == .cancelled)
        #expect(try await workspace.listing(scope).entries == completed.entries)

        try fixture.execute("INSERT INTO scans(id, scope_id, started_at, state) VALUES ('\(UUID().sourceKey)', '\(scope.id.sourceKey)', 0, 'scanning')")
        let reopened = try SourceWorkspace(databaseURL: fixture.database)
        #expect(try await reopened.listing(scope).state == .interrupted)
        #expect(try await reopened.listing(scope).entries == completed.entries)
        let missing = try await reopened.scan(scope)
        #expect(missing.entries.first?.state == .missing)

        _ = try fixture.write("restored", at: "file.txt")
        let restored = try await reopened.scan(scope)
        try FileManager.default.removeItem(at: fixture.root)
        let incomplete = try await reopened.scan(scope)
        #expect(incomplete.state == .incomplete)
        #expect(incomplete.issues.map(\.reason) == [.authorization])
        #expect(incomplete.entries == restored.entries)
    }

    @Test func evidenceHashesTheActualExtractedCopyAndInvalidatesChangedBytes() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let original = try sourceDOCX("Synthetic contract")
        let file = fixture.root.appendingPathComponent("Contract.DOCX")
        try original.write(to: file)
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let entry = try #require(try await workspace.scan(scope).entries.first)
        let evidence = try await workspace.evidence(for: entry)
        #expect(evidence.status == .ok)
        #expect(evidence.items.map(\.text) == ["Synthetic contract"])
        #expect(evidence.items.map(\.locator) == [.docx(part: "word/document.xml", paragraph: 1, characterRange: 0..<18)])
        #expect(evidence.sha256 == sourceHex(SHA256.hash(data: original)))
        #expect(evidence.entry.sha256 == evidence.sha256)
        #expect(evidence.entry.sourceVersion == entry.sourceVersion)
        #expect(evidence.entry.snapshotRevision == entry.snapshotRevision + 1)
        #expect(evidence.entry.snapshotFingerprint != entry.snapshotFingerprint)
        #expect(try await workspace.scan(scope).entries.first == evidence.entry)
        try sourceDOCX("Changed contract").write(to: file, options: .atomic)
        let changed = try await workspace.evidence(for: evidence.entry)
        #expect(changed.status == .changedDuringRead)
        #expect(changed.items.isEmpty)
        #expect(changed.sha256 == nil)
        #expect(changed.entry.sourceVersion == entry.sourceVersion + 1)
        #expect(changed.entry.sha256 == nil)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM source_snapshots WHERE hash_strength = 'sha256'") == "1")
    }

    @Test func datalessFlagAndOneDriveDomainAreIndependent() async throws {
        var statValue = stat()
        statValue.st_flags = UInt32(SF_DATALESS)
        #expect(SourceFileMetadata(statValue).isHydrationPending)
        #expect(!SourceFileMetadata(stat()).isHydrationPending)
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.write("local fixture", at: "CloudStorage/OneDrive-Example/file.txt")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(file.deletingLastPathComponent())
        let entry = try #require(try await workspace.scan(scope).entries.first)
        #expect(entry.provider == .oneDrive)
        #expect(!entry.hydrationPending)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM source_snapshots WHERE resource_identity_value IS NOT NULL") == "0")
    }

    @Test func pathNormalizationUsesVolumeCaseSemanticsAndRejectsEscapes() throws {
        #expect(try SourcePath.normalize("./Folder//x/../Cafe\u{301}.PDF", caseSensitive: true) == "Folder/Café.PDF")
        #expect(try SourcePath.normalize("./Folder/Cafe\u{301}.PDF", caseSensitive: false) == "folder/café.pdf")
        #expect(throws: FormaError.invalidSource) { try SourcePath.normalize("/escape", caseSensitive: true) }
        #expect(throws: FormaError.invalidSource) { try SourcePath.normalize("valid/../../escape", caseSensitive: true) }
        #expect(throws: FormaError.invalidSource) { try SourcePath.normalize("nul\0name", caseSensitive: true) }
    }
}

private struct SourceFixture {
    let base: URL
    let root: URL
    let database: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = base.appendingPathComponent("source", isDirectory: true)
        database = base.appendingPathComponent("workspace.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }

    func write(_ text: String, at path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func execute(_ sql: String) throws {
        try withDatabase { connection in
            try #require(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
        }
    }

    func scalar(_ sql: String) throws -> String? {
        try withDatabase { connection in
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var connection: OpaquePointer?
        let opened = sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(connection) }
        try #require(opened == SQLITE_OK)
        return try body(#require(connection))
    }
}

private func sourceDOCX(_ text: String) throws -> Data {
    let archive = try Archive(accessMode: .create)
    let parts = [
        ("[Content_Types].xml", """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            </Types>
            """),
        ("_rels/.rels", """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="document" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            </Relationships>
            """),
        ("word/document.xml", """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
            <w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:body></w:document>
            """),
    ]
    for (name, xml) in parts {
        let data = Data(xml.utf8)
        try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count)) { offset, length in
            data.subdata(in: Int(offset)..<(Int(offset) + length))
        }
    }
    return try #require(archive.data)
}
