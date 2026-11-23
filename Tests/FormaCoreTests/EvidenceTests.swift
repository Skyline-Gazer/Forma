import CoreGraphics
import CoreText
import Foundation
import Testing
import ZIPFoundation
import FormaCore

@Suite("Evidence extraction")
struct EvidenceTests {
    @Test func pdfLocationsAndPageBudget() throws {
        let pdf = try makePDF([nil, "Synthetic invoice", "Third page", "Past the page budget"])
        let extraction = try extract(pdf, extension: "pdf")
        #expect(extraction.status == .truncated)
        #expect(extraction.items.count == 2)
        let item = try #require(extraction.items.first)
        let text = try #require(item.text)
        #expect(text.contains("Synthetic invoice"))
        #expect(item.locator == .pdf(page: 2, characterRange: 0..<text.utf16.count))
        #expect(extraction.items.allSatisfy { $0.text?.contains("Past the page budget") != true })
    }

    @Test func distinguishesTextlessEncryptedAndCorruptPDFs() throws {
        let textless = try extract(makePDF([nil]), extension: "pdf")
        let encrypted = try extract(makePDF(["Protected evidence"], password: "synthetic"), extension: "pdf")
        let corrupt = try extract(Data("not a PDF".utf8), extension: "pdf")
        #expect(textless == EvidenceExtraction(status: .unavailable, items: []))
        #expect(encrypted == EvidenceExtraction(status: .encrypted, items: []))
        #expect(corrupt == EvidenceExtraction(status: .corrupt, items: []))
    }

    @Test func docxIncludesTableParagraphsAndUTF16Offsets() throws {
        let document = wordDocument("""
            <w:p><w:r><w:t>Title 😀</w:t><w:tab/><w:t>Number</w:t></w:r></w:p>
            <w:p/>
            <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell A</w:t></w:r></w:p></w:tc>
            <w:tc><w:p><w:r><w:t>Cell B</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
            """)
        let result = try extract(docx(document), extension: "DOCX")
        #expect(result.status == .ok)
        #expect(result.items.map(\.text) == ["Title 😀\tNumber", "Cell A", "Cell B"])
        #expect(result.items.map(\.locator) == [
            .docx(part: "word/document.xml", paragraph: 1, characterRange: 0..<15),
            .docx(part: "word/document.xml", paragraph: 3, characterRange: 0..<6),
            .docx(part: "word/document.xml", paragraph: 4, characterRange: 0..<6),
        ])
    }

    @Test func docxTruncatesAtAUnicodeScalarBoundary() throws {
        let prefix = String(repeating: "a", count: 11_999)
        let data = try docx(wordDocument("<w:p><w:r><w:t>\(prefix)😀after</w:t></w:r></w:p>"))
        let result = try extract(data, extension: "docx")
        #expect(result.status == .truncated)
        #expect(result.items == [EvidenceItem(
            locator: .docx(part: "word/document.xml", paragraph: 1, characterRange: 0..<11_999), text: prefix
        )])
    }

    @Test func xlsxFollowsRelationshipsAndRetainsCellSemantics() throws {
        let data = try xlsx(
            sheets: [("Summary", "visible", "a"), ("Costs", "hidden", "b"), ("Internal", "veryHidden", "c")],
            relationships: [
                relationship("b", "worksheet", "../custom/costs.xml"),
                relationship("c", "worksheet", "/private/sheet.xml"),
                relationship("a", "worksheet", "tables/report.xml"),
                relationship("strings", "sharedStrings", "../custom/strings.xml"),
            ],
            parts: [
                ("xl/tables/report.xml", sheet("""
                <row r="1"><c r="A1" t="s"><v>0</v></c>
                <c r="C1" t="inlineStr"><is><r><t>Inline</t></r><r><t xml:space="preserve"> value</t></r></is></c>
                <c><v>42</v></c></row>
                """)),
                ("custom/costs.xml", sheet("""
                <row r="3"><c r="B3"><f>SUM(2,3)</f><v>5</v></c>
                <c r="C3"><f>SUM(3,4)</f><v/></c><c r="D3" t="b"><v>1</v></c></row>
                """)),
                ("private/sheet.xml", sheet("<row><c t=\"str\"><f t=\"shared\" si=\"0\"/><v>Cache</v></c></row>")),
                ("custom/strings.xml", """
                <sst xmlns="\(spreadsheetNamespace)"><si><r><t>Shared</t></r><r><t xml:space="preserve"> string</t></r>
                <rPh sb="0" eb="1"><t>phonetic</t></rPh></si></sst>
                """),
            ]
        )
        let result = try extract(data, extension: "xlsx")
        #expect(result.status == .ok)
        #expect(result.items == [
            EvidenceItem(locator: .xlsx(sheet: "Summary", cell: "A1"), text: "Shared string", sheetVisibility: .visible, cellType: "s"),
            EvidenceItem(locator: .xlsx(sheet: "Summary", cell: "C1"), text: "Inline value", sheetVisibility: .visible, cellType: "inlineStr"),
            EvidenceItem(locator: .xlsx(sheet: "Summary", cell: "D1"), text: "42", sheetVisibility: .visible, cellType: "n"),
            EvidenceItem(locator: .xlsx(sheet: "Costs", cell: "B3"), text: "5", sheetVisibility: .hidden, cellType: "n", formula: "SUM(2,3)", cachedValue: "5"),
            EvidenceItem(locator: .xlsx(sheet: "Costs", cell: "C3"), text: nil, sheetVisibility: .hidden, cellType: "n", formula: "SUM(3,4)"),
            EvidenceItem(locator: .xlsx(sheet: "Costs", cell: "D3"), text: "1", sheetVisibility: .hidden, cellType: "b"),
            EvidenceItem(locator: .xlsx(sheet: "Internal", cell: "A1"), text: "Cache", sheetVisibility: .veryHidden, cellType: "str", formula: "", cachedValue: "Cache"),
        ])
    }

    @Test func xlsxEnforcesPerSheetCellBudget() throws {
        let rows = (1...201).map { "<row r=\"\($0)\"><c r=\"A\($0)\"><v>\($0)</v></c></row>" }.joined()
        let data = try xlsx(
            sheets: [("Summary", "visible", "sheet")], relationships: [relationship("sheet", "worksheet", "sheet.xml")],
            parts: [("xl/sheet.xml", sheet(rows))]
        )
        let result = try extract(data, extension: "xlsx")
        #expect(result.status == .truncated)
        #expect(result.items.count == 200)
        #expect(result.items.last?.locator == .xlsx(sheet: "Summary", cell: "A200"))
    }

    @Test func rejectsExternalAndEscapingWorksheetRelationships() throws {
        let external = relationship("sheet", "worksheet", "https://example.invalid/sheet.xml", external: true)
        let escaped = relationship("sheet", "worksheet", "../../sheet.xml")
        let encoded = relationship("sheet", "worksheet", "%2e%2e/sheet.xml")
        for link in [external, escaped, encoded] {
            let data = try xlsx(sheets: [("Summary", "visible", "sheet")], relationships: [link], parts: [])
            #expect(try extract(data, extension: "xlsx") == EvidenceExtraction(status: .corrupt, items: []))
        }
    }

    @Test func worksheetRelationshipTargetsResolveInsideThePackageOrFailClosed() throws {
        let sheet = "<worksheet xmlns=\"\(spreadsheetNamespace)\"><sheetData>"
            + "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>located value</t></is></c></row></sheetData></worksheet>"
        let located = EvidenceExtraction(status: .ok, items: [
            EvidenceItem(locator: .xlsx(sheet: "Summary", cell: "A1"), text: "located value",
                         sheetVisibility: .visible, cellType: "inlineStr"),
        ])
        // OPC permits package-root-relative targets and percent-encoded names; both resolve.
        for (target, part) in [("worksheets/sheet1.xml", "xl/worksheets/sheet1.xml"),
                               ("/xl/worksheets/sheet1.xml", "xl/worksheets/sheet1.xml"),
                               ("works%20sheets/sheet1.xml", "xl/works%20sheets/sheet1.xml")] {
            let data = try xlsx(sheets: [("Summary", "visible", "sheet")],
                                relationships: [relationship("sheet", "worksheet", target)],
                                parts: [(part, sheet)])
            #expect(try extract(data, extension: "xlsx") == located, "target \(target)")
        }
        // A declared part that the package does not contain is corruption, never an empty success.
        let missing = try xlsx(sheets: [("Summary", "visible", "sheet")],
                               relationships: [relationship("sheet", "worksheet", "worksheets/gone.xml")],
                               parts: [("xl/worksheets/sheet1.xml", sheet)])
        #expect(try extract(missing, extension: "xlsx") == EvidenceExtraction(status: .corrupt, items: []))
        // Resolving above the package root is rejected instead of silently truncated.
        let above = try xlsx(sheets: [("Summary", "visible", "sheet")],
                             relationships: [relationship("sheet", "worksheet", "../../../sheet.xml")],
                             parts: [("xl/worksheets/sheet1.xml", sheet)])
        #expect(try extract(above, extension: "xlsx") == EvidenceExtraction(status: .corrupt, items: []))
    }

    @Test func rejectsDTDsInUTF8AndUTF16() throws {
        let body = wordDocument("<w:p><w:r><w:t>&secret;</w:t></w:r></w:p>")
        let dtd = """
            <!DOCTYPE w:document [<!ENTITY secret SYSTEM "file:///etc/passwd">]>
            """
        let utf8 = Data((dtd + body).utf8)
        let utf16 = try #require(("<?xml version=\"1.0\" encoding=\"UTF-16\"?>" + dtd + body).data(using: .utf16))
        for document in [utf8, utf16] {
            let data = try archive([("word/document.xml", document)], compressed: true)
            #expect(try extract(data, extension: "docx") == EvidenceExtraction(status: .corrupt, items: []))
        }
    }

    @Test func acceptsUTF16ButDiscardsEvidenceFromMalformedXML() throws {
        let body = wordDocument("<w:p><w:r><w:t>Synthetic 😀</w:t></w:r></w:p>")
        let declaration = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>"
        let utf16 = try #require((declaration + body).data(using: .utf16))
        let valid = try extract(archive([("word/document.xml", utf16)]), extension: "docx")
        #expect(valid.status == .ok)
        #expect(valid.items.first?.text == "Synthetic 😀")

        let corrupt = try extract(docx(body + "<secondRoot/>"), extension: "docx")
        #expect(corrupt == EvidenceExtraction(status: .corrupt, items: []))
    }

    @Test func rejectsUnsafeZipPathsAndDamagedCRC() throws {
        let document = Data(wordDocument("<w:p><w:r><w:t>Evidence</w:t></w:r></w:p>").utf8)
        let unsafe = try archive([("word/document.xml", document), ("../outside.xml", Data("unsafe".utf8))])
        #expect(try extract(unsafe, extension: "docx") == EvidenceExtraction(status: .corrupt, items: []))

        var damaged = try archive([("word/document.xml", document)], compressed: false)
        let marker = try #require(damaged.range(of: Data("Evidence".utf8)))
        damaged[marker.lowerBound] = 0x58
        #expect(try extract(damaged, extension: "docx") == EvidenceExtraction(status: .corrupt, items: []))
    }

    @Test func distinguishesZipEncryptionFlagFromCorruption() throws {
        var protected = try docx(wordDocument("<w:p><w:r><w:t>Evidence</w:t></w:r></w:p>"))
        let firstDirectoryRecord = try #require(protected.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        protected[firstDirectoryRecord.lowerBound + 8] |= 1
        #expect(try extract(protected, extension: "docx") == EvidenceExtraction(status: .encrypted, items: []))
    }

    @Test func enforcesExpandedPartBudgetBeforeXMLParsing() throws {
        let oversized = String(repeating: "a", count: 8 * 1_024 * 1_024 + 1)
        let data = try docx(wordDocument("<w:p><w:r><w:t>\(oversized)</w:t></w:r></w:p>"))
        #expect(try extract(data, extension: "docx") == EvidenceExtraction(status: .truncated, items: []))
    }

    @Test func enforcesInputByteBudget() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(EvidenceExtractor.maximumInputBytes) + 1)
        try handle.close()
        #expect(try EvidenceExtractor.extract(file: file, fileExtension: "pdf") == EvidenceExtraction(status: .truncated, items: []))
    }

    @Test func unsupportedFormatIsUnavailable() throws {
        // `txt` became a supported body format in `evidence.v2` (#152); these are
        // the formats that stay hash-and-name only. A name is a clue about a file,
        // not a claim that Forma read anything in it, so the read must answer
        // `unavailable` with no items rather than guess from the extension.
        #expect(try extract(Data("Synthetic".utf8), extension: "rtf") == EvidenceExtraction(status: .unavailable,
                                                                                            items: []))
        #expect(try extract(Data("# Synthetic".utf8), extension: "md") == EvidenceExtraction(status: .unavailable,
                                                                                             items: []))
        #expect(EvidenceExtractor.supportedFileExtensions == ["pdf", "docx", "xlsx", "txt"])
    }

    // MARK: - Plain text (#152)

    @Test("a text body is cut into blocks whose locator addresses exactly its own quote")
    func textBlocksAddressTheirOwnQuote() throws {
        let body = """
        示例项目_2026 智能化改造项目
        招标公告

        项目编号: ZB2026001
        投标截止: 2026-03-18 09:00

          本项目的投标主体为示例投标单位甲。
        """
        let result = try extract(Data(body.utf8), extension: "txt")
        #expect(result.status == .ok)
        let ranges = textRanges(result)
        #expect(ranges.count == result.items.count, "every text item carries a text locator")
        #expect(!ranges.isEmpty)
        for (item, range) in zip(result.items, ranges) {
            // The whole promise of a locator: reopen the document at these
            // offsets and the stored excerpt is what you read.
            #expect(slice(body, range) == item.text, "\(range) does not address \(item.text ?? "nil")")
        }
        // Blank lines are block boundaries, not content, and indentation is not
        // quoted: each block starts at its first non-whitespace character.
        #expect(result.items.first?.text == "示例项目_2026 智能化改造项目\n招标公告")
        #expect(result.items.last?.text?.hasPrefix("本项目的投标主体为示例投标单位甲。") == true)
        #expect(result.items.allSatisfy { ($0.text ?? "").isEmpty == false })
        // Offsets never overlap and never run backwards.
        for (left, right) in zip(ranges, ranges.dropFirst()) {
            #expect(right.lowerBound > left.upperBound, "blocks must not overlap")
        }
    }

    @Test("text encoding is detected by byte-order mark and undecodable bytes are refused")
    func textEncodings() throws {
        let body = "项目名称 示例项目_2026\n投标截止 2026-03-18"
        var variants: [Data] = [
            Data(body.utf8),
            Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8),
            Data([0xFF, 0xFE]) + body.utf16LEBytes,
            Data([0xFE, 0xFF]) + body.utf16BEBytes,
        ]
        for variant in variants {
            let result = try extract(variant, extension: "txt")
            #expect(result.status == .ok, "byte order mark and both widths must decode")
            #expect(result.items.first?.text?.contains("示例项目_2026") == true)
            #expect(result.items.allSatisfy { !($0.text ?? "").contains("\u{FFFD}") })
        }
        // What is not text is reported as unreadable instead of quoted as if it
        // were: mojibake in a prompt is fabricated evidence.
        variants = [
            Data([0x80, 0x81, 0x82, 0x83]),                       // invalid UTF-8
            Data([0x70, 0x00, 0x00, 0x00]),                       // NUL inside: a binary file
            Data([0xFF, 0xFE, 0x41]),                             // UTF-16 with an odd tail
            Data([0xFF, 0xFE]) + Data([0x00, 0xD8, 0x41, 0x00]),  // unpaired high surrogate
            Data([0xFF, 0xFE]) + Data([0x00, 0xDC, 0x41, 0x00]),  // lone low surrogate
        ]
        for variant in variants {
            #expect(try extract(variant, extension: "txt") == EvidenceExtraction(status: .unavailable, items: []),
                    "\(variant) must not produce evidence")
        }
    }

    @Test("an empty or blank text file yields no content evidence")
    func emptyTextIsUnavailableNotBlankEvidence() throws {
        for body in ["", "\n", "   \n\t\n"] {
            #expect(try extract(Data(body.utf8), extension: "txt") == EvidenceExtraction(status: .unavailable,
                                                                                         items: []))
        }
        // A file whose only content is a number reads fine and says nothing: the
        // extractor reports the bytes, it does not decide they are meaningful.
        let result = try extract(Data("123456".utf8), extension: "txt")
        #expect(result.status == .ok)
        #expect(result.items.count == 1)
        #expect(result.items.first?.text == "123456")
    }

    @Test("a long text line is sliced, and a long document stops at the shared budget")
    func textBudgetsAndSlicing() throws {
        let single = String(repeating: "字", count: 5_000)  // one line, 5,000 UTF-16 units
        let sliced = try extract(Data(single.utf8), extension: "txt")
        #expect(sliced.status == .ok, "one long line is still readable text")
        let pieces = textRanges(sliced)
        // The block bound is 2,000 units, so 5,000 units is 2,000 + 2,000 + 1,000.
        #expect(pieces.count == 3)
        #expect(pieces.allSatisfy { $0.count <= 2_000 })
        #expect(pieces.first?.lowerBound == 0)
        #expect(pieces.reduce(0) { $0 + $1.count } == 5_000, "slicing must not drop or overlap text")
        for (left, right) in zip(pieces, pieces.dropFirst()) { #expect(right.lowerBound == left.upperBound) }
        for (item, range) in zip(sliced.items, pieces) { #expect(slice(single, range) == item.text) }

        // 700 lines is ~15,400 units, past the 12,000-unit document budget the
        // PDF and DOCX reads share, so the read must say it stopped.
        let manyLines = (1...700).map { "第 \($0) 行 项目编号 ZB2026001" }.joined(separator: "\n")
        let truncated = try extract(Data(manyLines.utf8), extension: "txt")
        #expect(truncated.status == .truncated)
        let ranges = textRanges(truncated)
        #expect(ranges.count == truncated.items.count)
        #expect(ranges.reduce(0) { $0 + $1.count } == 12_000, "the read quotes the budget, then says it stopped")
        #expect(ranges.allSatisfy { $0.upperBound <= manyLines.utf16.count })
        for (item, range) in zip(truncated.items, ranges) { #expect(slice(manyLines, range) == item.text) }
    }

    @Test("a text read is reproducible for the same bytes")
    func textReadIsReproducible() throws {
        let body = "示例项目_2026 招标公告\n\n投标主体 示例投标单位甲\n"
        let first = try extract(Data(body.utf8), extension: "txt")
        let again = try extract(Data(body.utf8), extension: "txt")
        #expect(first == again, "a citation minted from one read must resolve against the next")
    }
}

/// The UTF-16 ranges a read addressed, in order.
func textRanges(_ extraction: EvidenceExtraction) -> [Range<Int>] {
    extraction.items.compactMap { item in
        if case .text(let range) = item.locator { return range }
        return nil
    }
}

fileprivate extension String {
    /// The UTF-16 code units of the string in the given byte order, so a fixture
    /// can write a UTF-16 file without going through Foundation's encodings.
    var utf16LEBytes: Data {
        var data = Data()
        for unit in utf16 { data.append(UInt8(unit & 0xFF)); data.append(UInt8(unit >> 8)) }
        return data
    }

    var utf16BEBytes: Data {
        var data = Data()
        for unit in utf16 { data.append(UInt8(unit >> 8)); data.append(UInt8(unit & 0xFF)) }
        return data
    }
}

/// Reads the text a UTF-16 range addresses in the decoded document: the promise
/// every locator makes, checked directly instead of by trusting the offsets.
func slice(_ text: String, _ range: Range<Int>) -> String {
    guard range.lowerBound >= 0, range.upperBound <= text.utf16.count, range.lowerBound <= range.upperBound else {
        return "\u{0}OUT_OF_RANGE\u{0}"
    }
    return String(text.utf16[range.lowerBound..<range.upperBound])
}

private let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
private let spreadsheetNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
private let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
private let packageRelationshipNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"

private func wordDocument(_ body: String) -> String {
    "<w:document xmlns:w=\"\(wordNamespace)\"><w:body>\(body)</w:body></w:document>"
}

private func sheet(_ rows: String) -> String {
    "<worksheet xmlns=\"\(spreadsheetNamespace)\"><sheetData>\(rows)</sheetData></worksheet>"
}

private func relationship(_ id: String, _ type: String, _ target: String, external: Bool = false) -> String {
    """
    <Relationship Id="\(id)" Type="\(relationshipNamespace)/\(type)" Target="\(target)"\(external ? " TargetMode=\"External\"" : "")/>
    """
}

private func relationshipPart(_ entries: [String]) -> String {
    "<Relationships xmlns=\"\(packageRelationshipNamespace)\">\(entries.joined())</Relationships>"
}

private func docx(_ document: String) throws -> Data {
    try archive([
        ("[Content_Types].xml", Data("""
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """.utf8)),
        ("_rels/.rels", Data(relationshipPart([relationship("document", "officeDocument", "word/document.xml")]).utf8)),
        ("word/document.xml", Data(document.utf8)),
    ])
}

private func xlsx(
    sheets: [(name: String, state: String, id: String)], relationships: [String], parts: [(String, String)]
) throws -> Data {
    let names = sheets.enumerated().map { index, value in
        "<sheet name=\"\(value.name)\" state=\"\(value.state)\" sheetId=\"\(index + 1)\" rel:id=\"\(value.id)\"/>"
    }.joined()
    let workbook = """
        <workbook xmlns="\(spreadsheetNamespace)" xmlns:rel="\(relationshipNamespace)"><sheets>\(names)</sheets></workbook>
        """
    let partTypes = parts.map { name, xml in
        let type = xml.hasPrefix("<sst") ? "sharedStrings" : "worksheet"
        return "<Override PartName=\"/\(name)\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.\(type)+xml\"/>"
    }.joined()
    let types = """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        \(partTypes)</Types>
        """
    let files = [
        ("[Content_Types].xml", types),
        ("_rels/.rels", relationshipPart([relationship("workbook", "officeDocument", "xl/workbook.xml")])),
        ("xl/workbook.xml", workbook),
        ("xl/_rels/workbook.xml.rels", relationshipPart(relationships)),
    ] + parts
    return try archive(files.map { ($0.0, Data($0.1.utf8)) })
}

private func archive(_ parts: [(String, Data)], compressed: Bool = true) throws -> Data {
    let archive = try Archive(accessMode: .create)
    for (name, data) in parts {
        try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count),
                             compressionMethod: compressed ? .deflate : .none) { offset, length in
            let start = Int(offset)
            return data.subdata(in: start..<(start + length))
        }
    }
    return try #require(archive.data)
}

private func extract(_ data: Data, extension fileExtension: String) throws -> EvidenceExtraction {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(fileExtension)
    defer { try? FileManager.default.removeItem(at: file) }
    try data.write(to: file)
    return try EvidenceExtractor.extract(file: file, fileExtension: fileExtension)
}

/// A one- or multi-page PDF with real text, shared across the suites that need
/// a body the extractor can actually read.
func makePDF(_ pages: [String?], password: String? = nil) throws -> Data {
    let storage = try #require(CFDataCreateMutable(nil, 0))
    let consumer = try #require(CGDataConsumer(data: storage))
    var bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
    var options: [String: Any] = [:]
    if let password {
        options[kCGPDFContextUserPassword as String] = password
        options[kCGPDFContextOwnerPassword as String] = "owner-\(password)"
    }
    let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, options as CFDictionary))
    let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    for page in pages {
        context.beginPDFPage(nil)
        if let page {
            let text = NSAttributedString(
                string: page, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            context.textPosition = CGPoint(x: 32, y: 300)
            CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
        }
        context.endPDFPage()
    }
    context.closePDF()
    let bytes = try #require(CFDataGetBytePtr(storage))
    return Data(bytes: bytes, count: CFDataGetLength(storage))
}
