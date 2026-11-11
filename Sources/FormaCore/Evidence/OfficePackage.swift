import Foundation
import ZIPFoundation

/// The ZIP library silently stops iteration on encrypted or malformed entries.
/// Check the directory and local headers before relying on its entry sequence.
final class OfficePackage {
    private static let entryLimit = 2_048
    private static let expandedLimit: UInt64 = 64 * 1_024 * 1_024
    private static let partLimit: UInt64 = 8 * 1_024 * 1_024

    private let archive: Archive
    private var entries: [String: Entry] = [:]

    init(_ data: Data) throws {
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]),
           Self.containsOfficeEncryptionStreams(data) {
            throw EvidenceFailure.encrypted
        }
        let directory = try Self.inspectDirectory(data)
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw EvidenceFailure.corrupt
        }
        var expanded: UInt64 = 0
        var count = 0
        for entry in archive {
            try Task.checkCancellation()
            let name = entry.path
            guard count < directory.count, entry.type != .symlink, Self.isSafePath(name),
                  entries[name] == nil else { throw EvidenceFailure.corrupt }
            let expected = directory[count]
            guard expected.size == entry.uncompressedSize, expected.compressedSize == entry.compressedSize,
                  entry.type == .directory || entry.checksum == expected.checksum else {
                throw EvidenceFailure.corrupt
            }
            guard entry.uncompressedSize <= Self.expandedLimit - expanded else { throw EvidenceFailure.budget }
            expanded += entry.uncompressedSize
            entries[name] = entry
            count += 1
        }
        guard count == directory.count else { throw EvidenceFailure.corrupt }
    }

    func contains(_ path: String) -> Bool { entries[path] != nil }

    func part(_ path: String) throws -> Data {
        try Task.checkCancellation()
        guard let entry = entries[path], entry.type == .file else { throw EvidenceFailure.corrupt }
        guard entry.uncompressedSize <= Self.partLimit else { throw EvidenceFailure.budget }
        let expectedSize = Int(entry.uncompressedSize)
        var data = Data()
        data.reserveCapacity(expectedSize)
        do {
            let checksum = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard chunk.count <= expectedSize - data.count else { throw EvidenceFailure.corrupt }
                data.append(chunk)
            }
            guard data.count == expectedSize, checksum == entry.checksum else { throw EvidenceFailure.corrupt }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EvidenceFailure.corrupt
        }
        return data
    }

    private static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else {
            return false
        }
        let name = path.hasSuffix("/") ? path.dropLast() : path[...]
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private struct DirectoryEntry {
        let size: UInt64
        let compressedSize: UInt64
        let checksum: UInt32
    }

    private static func inspectDirectory(_ data: Data) throws -> [DirectoryEntry] {
        guard data.count >= 22 else { throw EvidenceFailure.corrupt }
        var end = data.count - 22
        let lowerBound = max(0, end - Int(UInt16.max))
        while data.word32(end) != 0x0605_4B50 {
            guard end > lowerBound else { throw EvidenceFailure.corrupt }
            end -= 1
        }
        guard end + 22 + Int(data.word16(end + 20)) == data.count else { throw EvidenceFailure.corrupt }
        guard data.word16(end + 4) == 0, data.word16(end + 6) == 0 else { throw EvidenceFailure.unsupported }
        let count = UInt64(data.word16(end + 10))
        let size = UInt64(data.word32(end + 12))
        let offset = UInt64(data.word32(end + 16))
        let directoryEnd = end
        // ZIPFoundation 0.9.20 traps with an un-catchable Range precondition on ZIP64 input,
        // both for an archive-level end-of-central-directory record and while extracting an
        // entry whose sizes use the 0xFFFFFFFF placeholder (reproduced by ContainerBoundaryTests).
        // Forma's input budget is 64 MiB, so no in-scope DOCX or XLSX needs ZIP64: reject every
        // ZIP64 marker before the library is constructed. This keeps the failure an honest
        // `unsupported` status instead of a crash inside a scan.
        let zip64Locator = end >= 20 && data.word32(end - 20) == 0x0706_4B50
        let zip64Record = end >= 76 && data.word32(end - 76) == 0x0606_4B50
        guard data.word16(end + 8) == count, !zip64Locator, !zip64Record,
              count != UInt64(UInt16.max), size != UInt64(UInt32.max), offset != UInt64(UInt32.max) else {
            if zip64Locator || zip64Record || count == UInt64(UInt16.max)
                    || size == UInt64(UInt32.max) || offset == UInt64(UInt32.max) {
                throw EvidenceFailure.unsupported
            }
            throw EvidenceFailure.corrupt
        }
        guard offset <= UInt64(directoryEnd), size == UInt64(directoryEnd) - offset else {
            throw EvidenceFailure.corrupt
        }
        guard count <= Self.entryLimit else { throw EvidenceFailure.budget }
        var cursor = Int(offset)
        var entries: [DirectoryEntry] = []
        var regions: [(local: UInt64, end: UInt64)] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            guard directoryEnd - cursor >= 46, data.word32(cursor) == 0x0201_4B50 else {
                throw EvidenceFailure.corrupt
            }
            let flags = data.word16(cursor + 8)
            if flags & 0x2041 != 0 { throw EvidenceFailure.encrypted }
            let nameSize = Int(data.word16(cursor + 28))
            let extraSize = Int(data.word16(cursor + 30))
            let commentSize = Int(data.word16(cursor + 32))
            let nameStart = cursor + 46
            let next = nameStart + nameSize + extraSize + commentSize
            guard nameSize > 0, next <= directoryEnd, data.word16(cursor + 34) == 0 else {
                throw EvidenceFailure.corrupt
            }
            let uncompressed = UInt64(data.word32(cursor + 24))
            let compressed = UInt64(data.word32(cursor + 20))
            let local = UInt64(data.word32(cursor + 42))
            if [uncompressed, compressed, local].contains(UInt64(UInt32.max))
                || data.word16(cursor + 6) >= 45 {
                throw EvidenceFailure.unsupported
            }
            guard local <= offset, offset - local >= 30, data.word32(Int(local)) == 0x0403_4B50 else {
                throw EvidenceFailure.corrupt
            }
            let header = Int(local)
            let localFlags = data.word16(header + 6)
            if localFlags & 0x2041 != 0 { throw EvidenceFailure.encrypted }
            let localNameSize = Int(data.word16(header + 26))
            let localName = header + 30
            let contents = localName + localNameSize + Int(data.word16(header + 28))
            let method = data.word16(cursor + 10)
            let dataEnd = UInt64(contents) + compressed
            guard localFlags == flags, data.word16(header + 8) == method,
                  contents <= Int(offset), localNameSize == nameSize,
                  data[localName..<(localName + nameSize)].elementsEqual(data[nameStart..<(nameStart + nameSize)]),
                  compressed <= offset - UInt64(contents), dataEnd <= offset,
                  method != 0 || compressed == uncompressed else {
                throw EvidenceFailure.corrupt
            }
            entries.append(DirectoryEntry(size: uncompressed, compressedSize: compressed, checksum: data.word32(cursor + 16)))
            regions.append((local: local, end: dataEnd))
            cursor = next
        }
        // A central directory may claim a compressed span that runs into the next entry's
        // local header. Stored data would then be read across that boundary with a CRC the
        // writer chose, so each data region must end before the following local header.
        let ordered = regions.sorted { $0.local < $1.local }
        for pair in zip(ordered, ordered.dropFirst()) where pair.0.end > pair.1.local {
            throw EvidenceFailure.corrupt
        }
        guard cursor == directoryEnd else { throw EvidenceFailure.corrupt }
        return entries
    }


    // Field offsets below are the [MS-CFB] 2.2 Header and 2.3 Directory Entry layouts:
    // sector shift at 30, total FAT sectors at 44, first directory sector at 48, DIFAT chain
    // start at 68 and the first 109 DIFAT entries at 76. A directory entry name is UTF-16
    // starting at its offset, with the byte count (including the terminating zero) at +64 and
    // the object type at +66, where 2 is a stream.
    private static func containsOfficeEncryptionStreams(_ data: Data) -> Bool {
        // Encrypted OOXML replaces the ZIP package with a Compound File Binary container.
        guard data.count >= 512, data.word16(28) == 0xFFFE else { return false }
        let version = data.word16(26)
        let sectorShift = data.word16(30)
        guard (version == 3 && sectorShift == 9) || (version == 4 && sectorShift == 12) else { return false }
        let sectorSize = 1 << Int(sectorShift)
        let sectorCount = data.count / sectorSize - 1
        guard sectorCount > 0 else { return false }
        func sectorOffset(_ sector: UInt32) -> Int? {
            guard sector < sectorCount else { return nil }
            return (Int(sector) + 1) * sectorSize
        }

        let fatCount = Int(data.word32(44))
        guard fatCount > 0, fatCount <= sectorCount else { return false }
        var fatSectors: [UInt32] = []
        for index in 0..<min(fatCount, 109) { fatSectors.append(data.word32(76 + index * 4)) }
        var difatSector = data.word32(68)
        var visited: Set<UInt32> = []
        while fatSectors.count < fatCount {
            guard visited.insert(difatSector).inserted, let start = sectorOffset(difatSector) else { return false }
            for index in 0..<min(sectorSize / 4 - 1, fatCount - fatSectors.count) {
                fatSectors.append(data.word32(start + index * 4))
            }
            difatSector = data.word32(start + sectorSize - 4)
        }

        let info = Array("EncryptionInfo".utf16)
        let package = Array("EncryptedPackage".utf16)
        var foundInfo = false
        var foundPackage = false
        var directorySector = data.word32(48)
        visited.removeAll(keepingCapacity: true)
        while let start = sectorOffset(directorySector), visited.insert(directorySector).inserted {
            for slot in stride(from: start, to: start + sectorSize, by: 128) where data[slot + 66] == 2 {
                let nameSize = Int(data.word16(slot + 64))
                let name: [UInt16]
                if nameSize == (info.count + 1) * 2 { name = info }
                else if nameSize == (package.count + 1) * 2 { name = package }
                else { continue }
                if data.word16(slot + name.count * 2) == 0,
                   name.enumerated().allSatisfy({ data.word16(slot + $0.offset * 2) == $0.element }) {
                    if name == info { foundInfo = true }
                    else { foundPackage = true }
                    if foundInfo && foundPackage { return true }
                }
            }
            let index = Int(directorySector) / (sectorSize / 4)
            guard index < fatSectors.count, let fat = sectorOffset(fatSectors[index]) else { return false }
            directorySector = data.word32(fat + Int(directorySector) % (sectorSize / 4) * 4)
        }
        return false
    }
}

private extension Data {
    func word16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func word32(_ offset: Int) -> UInt32 {
        UInt32(word16(offset)) | UInt32(word16(offset + 2)) << 16
    }

    func word64(_ offset: Int) -> UInt64 {
        UInt64(word32(offset)) | UInt64(word32(offset + 4)) << 32
    }
}
