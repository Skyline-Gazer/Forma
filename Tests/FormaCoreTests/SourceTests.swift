import CryptoKit
import Darwin
import Foundation
import GRDB
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


    @Test func hashOnlyStreamsLargeFilesAndEvidenceRejectsUnsupportedFormats() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appendingPathComponent("large.BIN")
        let descriptor = file.withUnsafeFileSystemRepresentation { path in path.map { open($0, O_CREAT | O_EXCL | O_RDWR, 0o600) } ?? -1 }
        #expect(descriptor >= 0)
        #expect(ftruncate(descriptor, EvidenceExtractor.maximumInputBytes + 1) == 0)
        #expect(close(descriptor) == 0)
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let entry = try #require(try await workspace.scan(scope).entries.first)
        let unsupported = try await workspace.evidence(for: entry)
        #expect(unsupported.status == .unavailable)
        #expect(unsupported.sha256 == nil)
        let hashed = try await workspace.hash(for: entry)
        var zeros = SHA256()
        let block = [UInt8](repeating: 0, count: 1024 * 1024)
        var remaining = EvidenceExtractor.maximumInputBytes + 1
        while remaining > 0 {
            let count = Int(min(remaining, Int64(block.count)))
            block.withUnsafeBytes { bytes in zeros.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes.prefix(count))) }
            remaining -= Int64(count)
        }
        #expect(hashed.status == .ok)
        #expect(hashed.items.isEmpty)
        #expect(hashed.sha256 == sourceHex(zeros.finalize()))
        #expect(hashed.entry.sha256 == hashed.sha256)
        #expect(hashed.entry.sourceVersion == entry.sourceVersion)
        #expect(hashed.entry.snapshotRevision == entry.snapshotRevision + 1)
        #expect(try fixture.scalar("SELECT hash_strength FROM source_snapshots WHERE revision = 2") == "sha256")
    }
    @Test func pathNormalizationUsesVolumeCaseSemanticsAndRejectsEscapes() throws {
        #expect(try SourcePath.normalize("./Folder//x/../Cafe\u{301}.PDF", caseSensitive: true) == "Folder/Café.PDF")
        #expect(try SourcePath.normalize("./Folder/Cafe\u{301}.PDF", caseSensitive: false) == "folder/café.pdf")
        #expect(throws: FormaError.invalidSource) { try SourcePath.normalize("/escape", caseSensitive: true) }
        #expect(throws: FormaError.invalidSource) { try SourcePath.normalize("valid/../../escape", caseSensitive: true) }
        #expect(throws: FormaError.invalidSource) { try SourcePath.normalize("nul\0name", caseSensitive: true) }
    }

    @Test func replacedFileUnderAnotherSpellingKeepsIdentityAndVersionsContent() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.write("first content", at: "Notes/Report.pdf")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let stored = try #require(try await workspace.scan(scope).entries.first { $0.relativePath == "Notes/Report.pdf" })

        // On a volume that folds spellings, a different-cased name is still the same
        // registered relative path: reuse the ID, version the content, keep the file listed.
        try FileManager.default.removeItem(at: original)
        _ = try fixture.write("second content", at: "Notes/report.pdf")
        let after = try await workspace.scan(scope)
        let entry = try #require(after.entries.first { $0.id == stored.id })

        #expect(entry.relativePath == "Notes/report.pdf")
        #expect(entry.state == .present)
        #expect(entry.sourceVersion == stored.sourceVersion + 1)
        #expect(entry.snapshotRevision == stored.snapshotRevision + 1)
        #expect(entry.snapshotFingerprint != stored.snapshotFingerprint)
        #expect(after.entries.filter { $0.normalizedRelativePath == entry.normalizedRelativePath }.count == 1)
        #expect(after.issues.isEmpty)
        #expect(after.state == .complete)
        #expect(try fixture.scalar("SELECT previous_path FROM path_history WHERE relative_path = 'Notes/report.pdf'")
                == "Notes/Report.pdf")
    }

    // Two names that fold to one relative path must share one identity rule, not be
    // silently merged: a normalizing volume stores one entry, while a volume that keeps
    // both spellings hands the scanner two names for one folded key.
    @Test func foldedSpellingsNormalizeToOneKeyAndNeverFabricateASecondIdentity() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.write("composed form", at: "Notes/Café.pdf")
        _ = try fixture.write("decomposed form", at: "Notes/Cafe\u{301}.pdf")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let listing = try await workspace.scan(scope)
        let stored = try #require(listing.entries.first)

        #expect(try SourcePath.normalize("Notes/Café.pdf", caseSensitive: false)
                == SourcePath.normalize("Notes/Cafe\u{301}.pdf", caseSensitive: false))
        // Exactly one on-disk spelling may claim the folded path; no second ID appears.
        #expect(listing.entries.filter { $0.normalizedRelativePath == stored.normalizedRelativePath }.count == 1)
        let spellings = try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "Notes").path)
        #expect(Set(spellings) == ["Café.pdf"] || spellings.count == 2)
        if Set(spellings) == ["Café.pdf"] {
            #expect(listing.state == .complete)
            #expect(listing.issues.isEmpty)
        } else {
            #expect(listing.state == .incomplete)
            #expect(listing.issues.filter { $0.reason == .pathCollision }.count == 2)
            #expect(listing.entries.filter { $0.normalizedRelativePath == stored.normalizedRelativePath }.isEmpty)
        }
    }

    // A folding volume can also report two spellings for one path Forma already knows.
    // That ambiguity must hold the known entry instead of losing it or folding identities.
    @Test func knownPathCollisionHoldsEntryAndMarksScanIncomplete() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.write("report body", at: "Notes/report.md")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let known = try #require(try await workspace.scan(scope).entries.first)

        let replacement = try SourceFileMetadata.read(
            try fixture.write("different object", at: "Notes/Report.md"))
        let result = SourceScanResult(
            records: [SourceScanRecord(relativePath: "Notes/Report.md",
                                       normalizedPath: known.normalizedRelativePath,
                                       metadata: replacement, provider: .local, stableIdentity: nil)],
            directories: ["Notes"],
            issues: [.init(relativePath: "Notes/report.md", reason: .pathCollision),
                     .init(relativePath: "Notes/Report.md", reason: .pathCollision)],
            collisionPaths: [known.normalizedRelativePath]
        )
        let database = try DatabaseQueue(path: fixture.database.path)
        let scanID = UUID()
        let published = try await database.write { tx in
            try tx.execute(sql: "INSERT INTO scans(id, scope_id, started_at, state) VALUES (?, ?, ?, 'scanning')",
                           arguments: [scanID.sourceKey, scope.id.sourceKey, Date().timeIntervalSince1970])
            return try SourceWorkspace.publish(result, scope: scope,
                                               root: SourceStore.root(tx, id: scope.rootID), scanID: scanID, in: tx)
        }
        let entry = try #require(published.entries.first { $0.id == known.id })

        #expect(entry.state == .held)
        #expect(entry.snapshotRevision == known.snapshotRevision + 1)
        #expect(published.state == .incomplete)
        #expect(published.entries.count == 1)
    }

    @Test func workspaceStorageIsOwnerReadableOnly() throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        _ = try SourceWorkspace(databaseURL: fixture.database)
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.database.path)[.posixPermissions] as? NSNumber
        #expect(mode.map { $0.uint16Value & 0o777 == 0o600 } == true)
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
