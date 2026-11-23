import Foundation

/// Body evidence for plain-text documents (`txt`).
///
/// A text file is its own format: no container to open, no page model, no part
/// and no cell. The only honest address in it is a range of characters, so a
/// text locator is a zero-based UTF-16 range measured from the start of the
/// decoded document - the same unit the PDF and DOCX locators already use, which
/// is what lets one reviewer rule ("open the file at that range, read the
/// quote") cover every locator kind.
///
/// Two invariants make that rule hold:
///
/// - The emitted text is exactly what its range selects. Offsets are derived by
///   summing the UTF-16 widths of the characters passed over, including the
///   whitespace skipped at the start of a block and trimmed at its end, so the
///   range addresses its own quote by construction rather than by a caller
///   remembering to align them.
/// - A block never exceeds `maximumBlockUTF16Characters`, which equals the
///   excerpt bound the registry stores. A PDF page or DOCX paragraph can be
///   longer than the excerpt stored for it - that locator then over-describes
///   the quote - while a text block never does, and `ManifestValidator` checks
///   the agreement for text citations.
///
/// Nothing here classifies anything. Deciding what a document *is* belongs to the
/// model (#148: business intent understanding, not a regex enumeration of
/// keywords); the extractor's job ends at reporting bytes that were really
/// observed, or reporting honestly that it could not read them.
enum PlainTextEvidence {
    /// UTF-16 units one read may emit in total - the same document budget a PDF
    /// or DOCX read uses, so adding a format adds no new exposure policy.
    static let maximumDocumentUTF16Characters = 12_000

    /// UTF-16 units one block may span. A literal rather than
    /// `EvidenceRegistry.maximumExcerptCharacters`, because extraction must not
    /// come to depend on the Mapping layer; a test pins the two together.
    static let maximumBlockUTF16Characters = 2_000

    /// Blocks one read may emit. The document budget usually binds first - 200
    /// blocks of 2,000 units is far more than 12,000 units - so what this bounds
    /// is the opposite shape: a file of thousands of two-word lines, which would
    /// otherwise register thousands of rows for one source. It is the text
    /// sibling of the PDF page limit, and when it bites the read says so with
    /// `truncated` instead of presenting a short list as the whole body.
    static let maximumBlocks = 200

    static func extract(from data: Data) throws -> EvidenceExtraction {
        guard let decoded = decode(data) else { return .empty(.unavailable) }
        return try blocks(of: decoded)
    }

    /// Detects UTF-8 and UTF-16 by byte-order mark and otherwise requires valid
    /// UTF-8. Anything that does not decode strictly is reported as unreadable
    /// rather than guessed at: a mojibake excerpt quoted into a prompt is
    /// fabricated evidence, and a codepage detector (GBK, Big5, Shift-JIS) is a
    /// separate decision with its own error budget, not a fallback to reach for
    /// when a byte sequence fails. Decoded text carrying NUL is treated the same
    /// way - that is a binary file wearing a `.txt` name, not a document.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return plain(String(data: data.dropFirst(3), encoding: .utf8)) }
        if data.starts(with: [0xFF, 0xFE]) { return utf16(data.dropFirst(2), littleEndian: true) }
        if data.starts(with: [0xFE, 0xFF]) { return utf16(data.dropFirst(2), littleEndian: false) }
        return plain(String(data: data, encoding: .utf8))
    }

    static func blocks(of text: String) throws -> EvidenceExtraction {
        var scanner = Scanner(text: text)
        try scanner.run()
        return .collected(scanner.items, truncated: scanner.truncated)
    }

    private static func plain(_ text: String?) -> String? {
        guard let text, !text.contains("\u{0}") else { return nil }
        return text
    }

    /// UTF-16 accepted only by inventing a replacement character. Foundation's
    /// UTF-16 decoding substitutes rather than failing, so an odd byte count and
    /// unpaired surrogates are checked here: a text locator promises a reviewer
    /// can find the quote again, and a silently repaired character breaks that
    /// promise invisibly.
    private static func utf16(_ data: Data, littleEndian: Bool) -> String? {
        guard data.count % 2 == 0 else { return nil }
        let bytes = [UInt8](data)
        let units: [UTF16.CodeUnit] = stride(from: 0, to: bytes.count, by: 2).map { index in
            let first = UInt16(bytes[index])
            let second = UInt16(bytes[index + 1])
            return littleEndian ? first | (second << 8) : (first << 8) | second
        }
        var cursor = 0
        while cursor < units.count {
            switch units[cursor] {
            case 0xD800...0xDBFF:
                guard cursor + 1 < units.count, case 0xDC00...0xDFFF = units[cursor + 1] else { return nil }
                cursor += 2
            case 0xDC00...0xDFFF:
                return nil
            default:
                cursor += 1
            }
        }
        return plain(String(decoding: units, as: UTF16.self))
    }

    /// Cuts the decoded text into citable blocks.
    ///
    /// A blank line always ends a block, because that is the paragraph boundary
    /// plain text actually declares, and a block is cut at the bound above when
    /// it would grow past it - so long paragraphs and single long lines are both
    /// addressed, and no range ever claims more text than was quoted. Leading
    /// whitespace is never part of a block, which is what keeps indentation out
    /// of a citation without moving the offsets.
    private struct Scanner {
        let text: String
        private var budget = EvidenceTextBudget(PlainTextEvidence.maximumDocumentUTF16Characters)
        private(set) var items: [EvidenceItem] = []
        /// True once content remains that this read did not quote, because the
        /// document budget or the block limit was reached.
        private(set) var truncated = false

        /// UTF-16 units of the decoded document already scanned.
        private var offset = 0
        private var scanned = 0

        private var block: [Character] = []
        private var blockUTF16 = 0
        private var blockStart = 0
        /// Whether anything other than whitespace has been seen since the last
        /// line break: two line breaks in a row are a paragraph break.
        private var lineHasContent = false

        mutating func run() throws {
            for character in text {
                if truncated { return }
                let width = character.utf16.count
                if character.isNewline {
                    if !lineHasContent {
                        // A blank line. Whatever was pending is a paragraph; the
                        // break itself is a separator and is not quoted.
                        try flush()
                        if truncated { return }
                    }
                    lineHasContent = false
                } else if !character.isWhitespace {
                    lineHasContent = true
                }
                // Whitespace before the first content character of a block is
                // indentation or a separator: skipped, and still counted, so the
                // next block's range starts where its text really starts.
                if character.isWhitespace, block.isEmpty {
                    offset += width
                    try tick()
                    continue
                }
                if blockUTF16 + width > PlainTextEvidence.maximumBlockUTF16Characters {
                    // Cut at the block bound, on a cluster boundary: a single
                    // grapheme wider than the room left moves to the next block
                    // instead of being split or dropped.
                    try flush()
                    if truncated { return }
                }
                if block.isEmpty { blockStart = offset }
                block.append(character)
                blockUTF16 += width
                offset += width
                try tick()
            }
            try flush()
        }

        /// Cancellation is checked at a coarse interval rather than per
        /// character: a file of nothing but blank lines emits no block, so
        /// without this a cancelled scan would keep walking bytes. The scan
        /// otherwise stops as soon as the document budget is spent.
        private mutating func tick() throws {
            scanned += 1
            if scanned % 4_096 == 0 { try Task.checkCancellation() }
        }

        private mutating func flush() throws {
            defer { block = []; blockUTF16 = 0 }
            guard !block.isEmpty else { return }
            try Task.checkCancellation()
            var leading = 0
            while leading < block.count, block[leading].isWhitespace { leading += 1 }
            var trailing = block.count
            while trailing > leading, block[trailing - 1].isWhitespace { trailing -= 1 }
            guard trailing > leading else { return }
            let start = blockStart + Self.width(of: block[0..<leading])
            let fragment = budget.takePrefix(Self.joined(block[leading..<trailing]))
            let taken = fragment.utf16.count
            // An empty fragment means the document budget was already spent: the
            // rest of the file is real but unquoted, so this read is truncated.
            guard taken > 0, items.count < PlainTextEvidence.maximumBlocks else {
                truncated = true
                return
            }
            // `start` was measured in the same UTF-16 units `fragment` counts,
            // and the budget cuts only at a character boundary, so this range
            // selects exactly the text stored beside it.
            items.append(EvidenceItem(
                locator: .text(characterRange: start..<(start + taken)), text: fragment
            ))
            if budget.truncated { truncated = true }
        }

        private static func width(of slice: ArraySlice<Character>) -> Int {
            slice.reduce(0) { $0 + $1.utf16.count }
        }

        private static func joined(_ characters: ArraySlice<Character>) -> String {
            var result = ""
            for character in characters { result.append(character) }
            return result
        }
    }
}
