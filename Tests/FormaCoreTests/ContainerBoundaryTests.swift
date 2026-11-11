import Foundation
import Testing
@testable import FormaCore

/// ZIP container validation is the read boundary for every DOCX and XLSX file, so the ZIP64,
/// encrypted-container and data-region branches need executable evidence rather than review
/// opinion. `ContainerBuilder` writes each record field by field (APPNOTE 4.3.7 central
/// directory, 4.3.14 ZIP64 end record and locator, [MS-CFB] 2.2 header and 2.3 directory
/// entries) because ordinary writers never emit the inconsistent combinations under test.
struct ContainerBoundaryTests {
    @Test func plainArchiveEnumeratesEntriesInDirectoryOrder() throws {
        let package = try OfficePackage(ContainerBuilder.pair())
        #expect(try package.contains("a.txt"))
        #expect(try package.contains("b.txt"))
        #expect(try package.part("a.txt") == Data("AAAA".utf8))
        #expect(try package.part("b.txt") == Data("BBBB".utf8))
    }

    @Test func dataRegionOverlappingTheNextLocalHeaderIsRejected() throws {
        // Entry a declares ten stored bytes although only four exist before entry b's local
        // header, and its CRC still matches those four bytes. Honouring the declared region
        // would let a writer place arbitrary bytes inside a document part.
        #expect(throws: EvidenceFailure.corrupt) {
            try OfficePackage(ContainerBuilder.pair(firstDeclaredSize: 10))
        }
    }

    @Test func zip64ContainersAreRejectedBeforeTheLibraryRuns() throws {
        // Measured library behaviour, not a design preference: ZIPFoundation 0.9.20 traps with
        // an un-catchable Range precondition both on a ZIP64 end-of-central-directory record and
        // while extracting an entry whose sizes use the 0xFFFFFFFF placeholder. Forma's input
        // budget is 64 MiB, so no in-scope DOCX or XLSX needs ZIP64; pretending to support it
        // would turn one document into a crashed scan.
        let shapes: [(label: String, data: Data)] = [
            ("entry level fields", ContainerBuilder.pair(zip64Entries: true)),
            ("archive level end record", ContainerBuilder.pair(zip64Entries: true, zip64End: true)),
            ("zero trailing disk", ContainerBuilder.one(zip64Entries: true, centralValues: 4,
                                                          offsetPlaceholder: true, trailingDisk: 0)),
            ("non-zero trailing disk", ContainerBuilder.one(zip64Entries: true, centralValues: 4,
                                                             offsetPlaceholder: true, trailingDisk: 1)),
            ("inconsistent field length", ContainerBuilder.one(zip64Entries: true, centralValues: 3,
                                                                offsetPlaceholder: true, declaredFieldBytes: 20)),
            ("placeholder offset without value", ContainerBuilder.one(zip64Entries: true, centralValues: 2,
                                                                       offsetPlaceholder: true)),
        ]
        for shape in shapes {
            #expect(throws: EvidenceFailure.unsupported, "\(shape.label)") { try OfficePackage(shape.data) }
        }
    }

    @Test func inconsistentEntryCountFailsClosed() throws {
        // The end record claims three entries while the directory holds one.
        #expect(throws: EvidenceFailure.corrupt) { try OfficePackage(ContainerBuilder.one(claimedEntries: 3)) }
    }

    @Test func encryptedOfficeContainerIsSeparatedFromCorruption() throws {
        // Encrypted OOXML keeps EncryptionInfo plus EncryptedPackage streams inside a Compound
        // File: blocked by permission, which is not the same as damaged.
        #expect(throws: EvidenceFailure.encrypted) { try OfficePackage(ContainerBuilder.cfbEncrypted()) }
        // A Compound File without those streams is not an OOXML package at all.
        #expect(throws: EvidenceFailure.corrupt) { try OfficePackage(ContainerBuilder.cfbOrdinary()) }
    }

    @Test func extractorReportsContainerStatesWithoutReadingContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "forma-container-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let encrypted = directory.appending(path: "book.docx")
        let ordinary = directory.appending(path: "notes.xlsx")
        try ContainerBuilder.cfbEncrypted().write(to: encrypted)
        try ContainerBuilder.cfbOrdinary().write(to: ordinary)
        #expect(try EvidenceExtractor.extract(file: encrypted, fileExtension: "docx").status == .encrypted)
        #expect(try EvidenceExtractor.extract(file: ordinary, fileExtension: "xlsx").status == .corrupt)
    }
}

/// Field-level container writer for the branches above.
private enum ContainerBuilder {
    private static let placeholder = UInt32.max

    private struct Entry {
        let name: String
        let payload: [UInt8]
        var crc: UInt32 { Self.checksum(payload) }

        static func checksum(_ payload: [UInt8]) -> UInt32 {
            var value: UInt32 = 0xFFFF_FFFF
            for byte in payload {
                value ^= UInt32(byte)
                for _ in 0..<8 { value = (value & 1) != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
            }
            return value ^ 0xFFFF_FFFF
        }
    }

    private struct Sink {
        private(set) var bytes: [UInt8] = []

        mutating func marker(_ signature: [UInt8]) { bytes += signature }
        mutating func text(_ value: String) { bytes += Array(value.utf8) }
        mutating func raw(_ value: [UInt8]) { bytes += value }
        mutating func u16(_ value: UInt16) { bytes += [UInt8(value & 0xFF), UInt8(value >> 8)] }
        mutating func u32(_ value: UInt32) { u16(UInt16(value & 0xFFFF)); u16(UInt16(value >> 16)) }
        mutating func u64(_ value: UInt64) { u32(UInt32(value & 0xFFFF_FFFF)); u32(UInt32(value >> 32)) }
        var count: Int { bytes.count }
    }

    /// APPNOTE 4.3.7 puts one 64-bit value in the ZIP64 extended information field for each
    /// 32-bit placeholder, in the order uncompressed size, compressed size, local header offset,
    /// then optionally the starting disk number.
    private static func extendedField(values: [UInt64], declaredBytes: Int?) -> [UInt8] {
        var field = Sink()
        field.u16(0x0001)
        field.u16(UInt16(declaredBytes ?? values.count * 8))
        for value in values { field.u64(value) }
        return field.bytes
    }

    private static func archive(entries: [Entry], zip64Entries: Bool, zip64End: Bool,
                                centralValues: Int, offsetPlaceholder: Bool, trailingDisk: UInt64?,
                                declaredFieldBytes: Int?, firstDeclaredSize: Int?,
                                claimedEntries: Int?) -> Data {
        var body = Sink()
        var offsets: [Int] = []
        var declaredSizes: [Int] = []

        for (index, entry) in entries.enumerated() {
            offsets.append(body.count)
            let declared = index == 0 && firstDeclaredSize != nil ? firstDeclaredSize! : entry.payload.count
            declaredSizes.append(declared)
            var extra: [UInt8] = []
            if zip64Entries {
                extra = extendedField(values: [UInt64(declared), UInt64(declared)], declaredBytes: nil)
            }
            body.marker([0x50, 0x4B, 0x03, 0x04])
            body.u16(zip64Entries ? 45 : 20)
            body.u16(0)
            body.u16(0)
            body.u16(0)
            body.u16(0)
            body.u32(entry.crc)
            body.u32(zip64Entries ? placeholder : UInt32(declared))
            body.u32(zip64Entries ? placeholder : UInt32(declared))
            body.u16(UInt16(entry.name.utf8.count))
            body.u16(UInt16(extra.count))
            body.text(entry.name)
            body.raw(extra)
            body.raw(entry.payload)
        }

        var directory = Sink()
        for (index, entry) in entries.enumerated() {
            var extra: [UInt8] = []
            if zip64Entries {
                var values = [UInt64(entry.payload.count), UInt64(entry.payload.count)]
                if centralValues >= 3 { values.append(UInt64(offsets[index])) }
                if centralValues >= 4, let trailingDisk { values.append(trailingDisk) }
                extra = extendedField(values: values, declaredBytes: declaredFieldBytes)
            }
            directory.marker([0x50, 0x4B, 0x01, 0x02])
            directory.u16(20)
            directory.u16(zip64Entries ? 45 : 20)
            directory.u16(0)
            directory.u16(0)
            directory.u16(0)
            directory.u16(0)
            directory.u32(entry.crc)
            directory.u32(zip64Entries ? placeholder : UInt32(declaredSizes[index]))
            directory.u32(zip64Entries ? placeholder : UInt32(entry.payload.count))
            directory.u16(UInt16(entry.name.utf8.count))
            directory.u16(UInt16(extra.count))
            directory.u16(0)
            directory.u16(0)
            directory.u16(0)
            directory.u32(0)
            directory.u32(offsetPlaceholder ? placeholder : UInt32(offsets[index]))
            directory.text(entry.name)
            directory.raw(extra)
        }

        let start = body.count
        body.raw(directory.bytes)
        let claimed = claimedEntries ?? entries.count
        if zip64End {
            var record = Sink()
            record.u64(44)
            record.u16(45)
            record.u16(45)
            record.u32(0)
            record.u32(0)
            record.u64(UInt64(claimed))
            record.u64(UInt64(claimed))
            record.u64(UInt64(directory.count))
            record.u64(UInt64(start))
            var locator = Sink()
            locator.u32(0)
            locator.u64(UInt64(start + directory.count))
            locator.u32(1)
            body.marker([0x50, 0x4B, 0x06, 0x06])
            body.raw(record.bytes)
            body.marker([0x50, 0x4B, 0x06, 0x07])
            body.raw(locator.bytes)
        }
        var end = Sink()
        end.u16(0)
        end.u16(0)
        if zip64End {
            end.u16(0xFFFF)
            end.u16(0xFFFF)
            end.u32(placeholder)
            end.u32(placeholder)
        } else {
            end.u16(UInt16(claimed))
            end.u16(UInt16(claimed))
            end.u32(UInt32(directory.count))
            end.u32(UInt32(start))
        }
        end.u16(0)
        body.marker([0x50, 0x4B, 0x05, 0x06])
        body.raw(end.bytes)
        return Data(body.bytes)
    }

    private static var pairEntries: [Entry] {
        [Entry(name: "a.txt", payload: Array("AAAA".utf8)),
         Entry(name: "b.txt", payload: Array("BBBB".utf8))]
    }

    private static var oneEntry: [Entry] { [Entry(name: "a.txt", payload: Array("payload".utf8))] }

    static func pair(firstDeclaredSize: Int? = nil, zip64Entries: Bool = false,
                     zip64End: Bool = false) -> Data {
        archive(entries: pairEntries, zip64Entries: zip64Entries, zip64End: zip64End,
                centralValues: zip64End ? 3 : 2, offsetPlaceholder: zip64End, trailingDisk: nil,
                declaredFieldBytes: nil, firstDeclaredSize: firstDeclaredSize, claimedEntries: nil)
    }

    static func one(zip64Entries: Bool = false, centralValues: Int = 2, offsetPlaceholder: Bool = false,
                    trailingDisk: UInt64? = nil, declaredFieldBytes: Int? = nil,
                    claimedEntries: Int? = nil) -> Data {
        archive(entries: oneEntry, zip64Entries: zip64Entries, zip64End: false,
                centralValues: centralValues, offsetPlaceholder: offsetPlaceholder,
                trailingDisk: trailingDisk, declaredFieldBytes: declaredFieldBytes,
                firstDeclaredSize: nil, claimedEntries: claimedEntries)
    }

    /// [MS-CFB] 2.2 header, one FAT sector and one directory sector holding four entries.
    private static func compoundFile(info: String, package: String) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        for (index, byte) in magic.enumerated() { header[index] = byte }
        func put16(_ value: UInt16, at offset: Int) {
            header[offset] = UInt8(value & 0xFF)
            header[offset + 1] = UInt8(value >> 8)
        }
        func put32(_ value: UInt32, at offset: Int) {
            put16(UInt16(value & 0xFFFF), at: offset)
            put16(UInt16(value >> 16), at: offset + 2)
        }
        put16(0x003E, at: 24)
        put16(3, at: 26)
        put16(0xFFFE, at: 28)
        put16(9, at: 30)
        put32(1, at: 44)
        put32(1, at: 48)
        put32(0xFFFF_FFFE, at: 68)
        put32(0, at: 76)
        for index in 1..<109 { put32(0xFFFF_FFFE, at: 72 + 4 * index) }

        var fat = Sink()
        fat.u32(0xFFFF_FFFD)
        for _ in 1..<128 { fat.u32(0xFFFF_FFFE) }

        func directoryEntry(name: String, kind: UInt8, child: UInt32) -> [UInt8] {
            var slot = [UInt8](repeating: 0, count: 128)
            let encoded = Array(name.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            for (index, byte) in encoded.enumerated() { slot[index] = byte }
            let size = UInt16(encoded.count + 2)
            slot[64] = UInt8(size & 0xFF)
            slot[65] = UInt8(size >> 8)
            slot[66] = kind
            for shift in 0..<4 { slot[76 + shift] = UInt8((child >> (8 * shift)) & 0xFF) }
            for shift in 0..<4 { slot[116 + shift] = UInt8((0xFFFF_FFFE >> (8 * shift)) & 0xFF) }
            return slot
        }
        var directory = Sink()
        directory.raw(directoryEntry(name: "Root Entry", kind: 0x05, child: 1))
        directory.raw(directoryEntry(name: info, kind: 0x02, child: 0xFFFF_FFFE))
        directory.raw(directoryEntry(name: package, kind: 0x02, child: 0xFFFF_FFFE))
        directory.raw(directoryEntry(name: "", kind: 0x00, child: 0xFFFF_FFFE))
        return Data(header + fat.bytes + directory.bytes)
    }

    static func cfbEncrypted() -> Data { compoundFile(info: "EncryptionInfo", package: "EncryptedPackage") }
    static func cfbOrdinary() -> Data { compoundFile(info: "ObjectPool", package: "_GoBack") }
}
