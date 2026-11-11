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
        #expect(try extract(Data("Synthetic".utf8), extension: "txt") == EvidenceExtraction(status: .unavailable, items: []))
    }
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
