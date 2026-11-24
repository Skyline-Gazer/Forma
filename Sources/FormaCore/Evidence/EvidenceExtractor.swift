import Darwin
import Foundation
import PDFKit

public enum EvidenceStatus: String, Codable, Sendable {
    case ok, truncated, unavailable, encrypted, corrupt
    case hydrationPending = "hydration_pending"
    case changedDuringRead = "changed_during_read"
}

public enum EvidenceLocator: Codable, Equatable, Sendable {
    /// Pages are one-based. Character ranges use zero-based UTF-16 offsets.
    case pdf(page: Int, characterRange: Range<Int>)
    /// Paragraphs are one-based in document order, including table paragraphs.
    /// Character ranges use zero-based UTF-16 offsets within the paragraph.
    case docx(part: String, paragraph: Int, characterRange: Range<Int>)
    case xlsx(sheet: String, cell: String)
    /// Plain text has no page, part or cell: a block is addressed by its
    /// zero-based UTF-16 range in the *decoded document*, so the range and the
    /// stored excerpt describe the same span (`PlainTextEvidence`).
    case text(characterRange: Range<Int>)
}

public enum EvidenceSheetVisibility: String, Codable, Sendable {
    case visible, hidden, veryHidden
}

public struct EvidenceItem: Codable, Equatable, Sendable {
    public let locator: EvidenceLocator
    public let text: String?
    public let sheetVisibility: EvidenceSheetVisibility?
    public let cellType: String?
    /// An empty string records a formula element with no expression of its own.
    public let formula: String?
    /// The stored `<v>` text for a formula, if present and nonempty.
    public let cachedValue: String?

    public init(
        locator: EvidenceLocator, text: String?, sheetVisibility: EvidenceSheetVisibility? = nil,
        cellType: String? = nil, formula: String? = nil, cachedValue: String? = nil
    ) {
        self.locator = locator
        self.text = text
        self.sheetVisibility = sheetVisibility
        self.cellType = cellType
        self.formula = formula
        self.cachedValue = cachedValue
    }
}

public struct EvidenceExtraction: Equatable, Sendable {
    /// `evidence.v2` adds plain-text bodies (#152): a `.txt` file now yields
    /// content rows where v1 reported `unavailable` and none at all. Existing
    /// PDF/DOCX/XLSX rows are unchanged, and an evidence *identifier* is not
    /// re-versioned here - see `EvidenceRegistry.identityVersion`, which stays
    /// `evidence.v1` so a citation in an older manifest keeps resolving. What
    /// this string records is which extractor was authoritative for a read.
    public static let extractorVersion = "evidence.v2"
    public var version: String { Self.extractorVersion }
    public let status: EvidenceStatus
    public let items: [EvidenceItem]

    public init(status: EvidenceStatus, items: [EvidenceItem]) {
        self.status = status
        self.items = items
    }
}

public enum EvidenceExtractor {
    public static let maximumInputBytes: Int64 = 64 * 1_024 * 1_024

    /// The formats whose *body* Forma is willing to quote. The list is one
    /// place on purpose: `SourceEvidenceReader` gates the same decision before
    /// it copies a file, and a second literal list would let one side learn
    /// about a format the other still refuses. Everything else is hashed and
    /// named, never read.
    public static let supportedFileExtensions: Set<String> = ["pdf", "docx", "xlsx", "txt"]

    public static func extract(file: URL, fileExtension: String) throws -> EvidenceExtraction {
        try Task.checkCancellation()
        let format = fileExtension.lowercased()
        guard file.isFileURL, supportedFileExtensions.contains(format) else { return .empty(.unavailable) }
        guard let before = try? SourceFileMetadata.read(file), before.isRegular else { return .empty(.unavailable) }
        if before.isHydrationPending { return .empty(.hydrationPending) }
        guard before.sizeBytes >= 0 else { return .empty(.unavailable) }
        guard before.sizeBytes <= maximumInputBytes else { return .empty(.truncated) }

        let descriptor = file.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else {
            return .empty((try? SourceFileMetadata.read(file)) == before ? .unavailable : .changedDuringRead)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let opened = try? SourceFileMetadata.read(descriptor: descriptor) else { return .empty(.unavailable) }
        if opened.isHydrationPending { return .empty(.hydrationPending) }
        guard opened == before else { return .empty(.changedDuringRead) }

        let result: EvidenceExtraction
        do {
            let data = try handle.read(upToCount: Int(before.sizeBytes) + 1) ?? Data()
            if data.count != before.sizeBytes {
                return .empty(.changedDuringRead)
            }
            try Task.checkCancellation()
            switch format {
            case "pdf": result = try pdf(data)
            case "txt": result = try PlainTextEvidence.extract(from: data)
            case "docx": result = try DOCXEvidence.extract(from: OfficePackage(data))
            default: result = try XLSXEvidence.extract(from: OfficePackage(data))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as EvidenceFailure {
            result = .empty(failure.status)
        } catch {
            result = .empty(.unavailable)
        }
        try Task.checkCancellation()
        guard let after = try? SourceFileMetadata.read(file),
              let readEnd = try? SourceFileMetadata.read(descriptor: descriptor) else { return .empty(.changedDuringRead) }
        if after.isHydrationPending || readEnd.isHydrationPending { return .empty(.hydrationPending) }
        guard after == opened, readEnd == opened else { return .empty(.changedDuringRead) }
        return result
    }

    private static func pdf(_ data: Data) throws -> EvidenceExtraction {
        guard let document = PDFDocument(data: data) else { return .empty(.corrupt) }
        if document.isEncrypted || document.isLocked { return .empty(.encrypted) }
        guard document.allowsCopying else { return .empty(.unavailable) }
        let pageLimit = 3
        var text = EvidenceTextBudget(12_000)
        var items: [EvidenceItem] = []
        for index in 0..<min(document.pageCount, pageLimit) {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { return .empty(.corrupt) }
            guard let content = page.string, content.contains(where: { !$0.isWhitespace }) else { continue }
            let fragment = text.takePrefix(content)
            if !fragment.isEmpty {
                items.append(EvidenceItem(
                    locator: .pdf(page: index + 1, characterRange: 0..<fragment.utf16.count), text: fragment
                ))
            }
            if text.truncated { break }
        }
        return .collected(items, truncated: document.pageCount > pageLimit || text.truncated)
    }
}

extension EvidenceExtraction {
    static func empty(_ status: EvidenceStatus) -> Self { Self(status: status, items: []) }

    static func collected(_ items: [EvidenceItem], truncated: Bool) -> Self {
        Self(status: truncated ? .truncated : items.isEmpty ? .unavailable : .ok, items: items)
    }
}

enum EvidenceFailure: Error {
    case corrupt, encrypted, budget, unsupported

    var status: EvidenceStatus {
        switch self {
        case .corrupt: .corrupt
        case .encrypted: .encrypted
        case .budget: .truncated
        case .unsupported: .unavailable
        }
    }
}

struct EvidenceTextBudget {
    private(set) var remaining: Int
    private(set) var truncated = false

    init(_ limit: Int) { remaining = limit }

    mutating func takePrefix(_ value: String) -> String {
        let length = value.utf16.count
        if length <= remaining {
            remaining -= length
            return value
        }
        truncated = true
        var used = 0
        let scalars = value.unicodeScalars
        var end = scalars.startIndex
        while end != scalars.endIndex {
            let width = scalars[end].value > 0xFFFF ? 2 : 1
            if width > remaining - used { break }
            used += width
            scalars.formIndex(after: &end)
        }
        // Later text cannot fill a gap left by a scalar that did not fit.
        remaining = 0
        return String(scalars[..<end])
    }
}
