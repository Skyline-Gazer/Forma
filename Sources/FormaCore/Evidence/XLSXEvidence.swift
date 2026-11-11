import Foundation

enum XLSXEvidence {
    private static let sheetLimit = 32
    private static let cellsPerSheet = 200
    private static let workbookCellLimit = 2_000

    static func extract(from package: OfficePackage) throws -> EvidenceExtraction {
        let workbookPart: String
        if package.contains("_rels/.rels") {
            let root = try RelationshipReader.read(package.part("_rels/.rels"))
            let documents = root.values.filter { $0.type == "officeDocument" }
            guard documents.count == 1, let document = documents.first else { throw EvidenceFailure.corrupt }
            workbookPart = try document.part(relativeTo: "", in: package)
        } else {
            workbookPart = "xl/workbook.xml"
        }
        let workbook = WorkbookReader()
        try workbook.parse(package.part(workbookPart))
        guard workbook.foundSheets else { throw EvidenceFailure.corrupt }
        let components = workbookPart.split(separator: "/")
        guard let workbookName = components.last else { throw EvidenceFailure.corrupt }
        let relationshipPart = (components.dropLast().map(String.init) + ["_rels", "\(workbookName).rels"])
            .joined(separator: "/")
        let relationships = try RelationshipReader.read(package.part(relationshipPart))
        let sharedParts = relationships.values.filter { $0.type == "sharedStrings" }
        guard sharedParts.count <= 1 else { throw EvidenceFailure.corrupt }
        var shared: [String]?
        if let relationship = sharedParts.first {
            let reader = SharedStringReader()
            try reader.parse(package.part(relationship.part(relativeTo: workbookPart, in: package)))
            shared = reader.strings
        }

        var worksheets: [(WorkbookReader.Sheet, String)] = []
        var worksheetParts: Set<String> = []
        var truncated = false
        for sheet in workbook.sheets {
            guard let relationship = relationships[sheet.relationshipID] else { throw EvidenceFailure.corrupt }
            if relationship.type != "worksheet" {
                guard ["chartsheet", "dialogsheet", "macrosheet", "intlMacrosheet"].contains(relationship.type) else {
                    throw EvidenceFailure.corrupt
                }
                truncated = true
                continue
            }
            let part = try relationship.part(relativeTo: workbookPart, in: package)
            guard package.contains(part), worksheetParts.insert(part).inserted else { throw EvidenceFailure.corrupt }
            if worksheets.count < sheetLimit { worksheets.append((sheet, part)) }
            else { truncated = true }
        }

        var items: [EvidenceItem] = []
        var remainingText = 32_000
        for (sheet, part) in worksheets {
            do {
                let reader = WorksheetReader(
                    sheet: sheet, shared: shared, cellLimit: min(cellsPerSheet, workbookCellLimit - items.count),
                    remainingText: remainingText
                )
                try reader.parse(package.part(part))
                guard reader.foundSheetData else { throw EvidenceFailure.corrupt }
                items.append(contentsOf: reader.items)
                remainingText = reader.remainingText
                truncated = truncated || reader.truncated
            } catch EvidenceFailure.budget {
                truncated = true
            }
        }
        return .collected(items, truncated: truncated)
    }
}

private struct OfficeRelationship {
    let type: String
    let target: String
    let external: Bool

    func part(relativeTo source: String, in package: OfficePackage) throws -> String {
        guard !external, !target.isEmpty, !target.contains("\\"), !target.contains(":"),
              !target.contains("?"), !target.contains("#"), !target.contains("\0") else {
            throw EvidenceFailure.corrupt
        }
        let absolute = target.hasPrefix("/")
        let path = absolute ? target.dropFirst() : target[...]
        var original = absolute ? [] : source.split(separator: "/").dropLast().map(String.init)
        var decoded = original
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, let name = component.removingPercentEncoding,
                  !name.contains("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0") else {
                throw EvidenceFailure.corrupt
            }
            switch name {
            case ".":
                guard component == "." else { throw EvidenceFailure.corrupt }
            case "..":
                guard component == "..", !original.isEmpty else { throw EvidenceFailure.corrupt }
                original.removeLast()
                decoded.removeLast()
            default:
                original.append(String(component))
                decoded.append(name)
            }
        }
        guard !original.isEmpty else { throw EvidenceFailure.corrupt }
        let uri = original.joined(separator: "/")
        return package.contains(uri) ? uri : decoded.joined(separator: "/")
    }
}

private final class RelationshipReader: OfficeXMLReader {
    private var relationships: [String: OfficeRelationship] = [:]

    static func read(_ data: Data) throws -> [String: OfficeRelationship] {
        let reader = RelationshipReader()
        try reader.parse(data)
        return reader.relationships
    }

    override func start(_ attributes: [String: String]) throws {
        guard let element = path.last else { return }
        if path.count == 1 {
            guard element.name == "Relationships", OfficeNamespaces.packageRelationships.contains(element.namespace) else {
                throw EvidenceFailure.corrupt
            }
        } else if path.count == 2, element.name == "Relationship", element.namespace == path[0].namespace {
            guard let id = attributes["Id"], !id.isEmpty, relationships[id] == nil,
                  let uri = attributes["Type"], let target = attributes["Target"], !target.isEmpty else {
                throw EvidenceFailure.corrupt
            }
            let type = OfficeNamespaces.relationships.lazy.compactMap { namespace -> String? in
                let prefix = namespace + "/"
                return uri.hasPrefix(prefix) ? String(uri.dropFirst(prefix.count)) : nil
            }.first ?? uri
            let mode = attributes["TargetMode"] ?? "Internal"
            guard mode == "Internal" || mode == "External" else { throw EvidenceFailure.corrupt }
            relationships[id] = OfficeRelationship(type: type, target: target, external: mode == "External")
        }
    }
}

private final class WorkbookReader: OfficeXMLReader {
    struct Sheet {
        let name: String
        let visibility: EvidenceSheetVisibility
        let relationshipID: String
    }

    private(set) var foundSheets = false
    private(set) var sheets: [Sheet] = []
    private var names: Set<String> = []

    override func start(_ attributes: [String: String]) throws {
        guard let element = path.last else { return }
        if path.count == 1 {
            guard element.name == "workbook", OfficeNamespaces.spreadsheet.contains(element.namespace) else {
                throw EvidenceFailure.corrupt
            }
        } else if element.namespace == path[0].namespace {
            if path.count == 2, element.name == "sheets" {
                guard !foundSheets else { throw EvidenceFailure.corrupt }
                foundSheets = true
            } else if path.count == 3, path[1].name == "sheets", path[1].namespace == element.namespace,
                      element.name == "sheet" {
                guard sheets.count < 2_048 else { throw EvidenceFailure.budget }
                guard let name = attributes["name"], !name.isEmpty, names.insert(name).inserted,
                      let visibility = EvidenceSheetVisibility(rawValue: attributes["state"] ?? "visible") else {
                    throw EvidenceFailure.corrupt
                }
                guard name.utf16.count <= 256 else { throw EvidenceFailure.budget }
                sheets.append(Sheet(name: name, visibility: visibility, relationshipID: try relationshipID(attributes)))
            }
        }
    }
}

private final class SharedStringReader: OfficeXMLReader {
    private(set) var strings: [String] = []
    private var value = ""
    private var textDepth: Int?

    override func start(_ attributes: [String: String]) throws {
        guard let element = path.last else { return }
        if path.count == 1 {
            guard element.name == "sst", OfficeNamespaces.spreadsheet.contains(element.namespace) else {
                throw EvidenceFailure.corrupt
            }
        } else if isRichText(at: 1, in: "si") {
            textDepth = path.count
        }
    }

    override func end() throws {
        if textDepth == path.count { textDepth = nil }
        if path.count == 2, path[1].name == "si", path[1].namespace == path[0].namespace {
            // Empty strings still occupy an index.
            guard strings.count < 250_000 else { throw EvidenceFailure.budget }
            strings.append(value)
            value = ""
        }
    }

    override func text(_ text: String) throws {
        if textDepth == path.count { value += text }
    }
}

private final class WorksheetReader: OfficeXMLReader {
    private struct Cell {
        let coordinate: String
        let type: String
        var value: String?
        var formula: String?
        var inline: String?
        var oversized = false
    }

    private enum Field { case value, formula, inline }

    private let sheet: WorkbookReader.Sheet
    private let shared: [String]?
    private let cellLimit: Int
    private(set) var remainingText: Int
    private(set) var foundSheetData = false
    private(set) var items: [EvidenceItem] = []
    private(set) var truncated = false
    private var row = 0
    private var column = 0
    private var cell: Cell?
    private var field: Field?
    private var fieldDepth: Int?
    private var fieldText = ""
    private var fieldBudget = EvidenceTextBudget(32_000)

    init(sheet: WorkbookReader.Sheet, shared: [String]?, cellLimit: Int, remainingText: Int) {
        self.sheet = sheet
        self.shared = shared
        self.cellLimit = cellLimit
        self.remainingText = remainingText
    }

    override func start(_ attributes: [String: String]) throws {
        guard let element = path.last else { return }
        if path.count == 1 {
            guard element.name == "worksheet", OfficeNamespaces.spreadsheet.contains(element.namespace) else {
                throw EvidenceFailure.corrupt
            }
            return
        }
        let namespace = path[0].namespace
        guard element.namespace == namespace, path[1].name == "sheetData", path[1].namespace == namespace else { return }
        if path.count == 2 {
            guard !foundSheetData else { throw EvidenceFailure.corrupt }
            foundSheetData = true
            return
        }
        guard path[2].name == "row", path[2].namespace == namespace else { return }
        if path.count == 3 {
            let number: Int
            if let reference = attributes["r"] {
                guard let parsed = Self.rowNumber(reference[...]) else { throw EvidenceFailure.corrupt }
                number = parsed
            } else {
                number = row + 1
            }
            guard number > row, number <= 1_048_576 else { throw EvidenceFailure.corrupt }
            row = number
            column = 0
            return
        }
        guard path[3].name == "c", path[3].namespace == namespace else { return }
        if path.count == 4 {
            let coordinate: String
            if let reference = attributes["r"] {
                guard let parsedColumn = Self.columnNumber(reference, row: row), parsedColumn > column else {
                    throw EvidenceFailure.corrupt
                }
                column = parsedColumn
                coordinate = reference
            } else {
                column += 1
                guard column <= 16_384 else { throw EvidenceFailure.corrupt }
                coordinate = Self.coordinate(column: column, row: row)
            }
            let type = attributes["t"] ?? "n"
            guard ["b", "d", "e", "inlineStr", "n", "s", "str"].contains(type) else { throw EvidenceFailure.corrupt }
            cell = Cell(coordinate: coordinate, type: type)
            return
        }
        if path.count == 5 {
            switch element.name {
            case "v":
                guard cell?.value == nil else { throw EvidenceFailure.corrupt }
                startField(.value)
            case "f":
                guard cell?.formula == nil else { throw EvidenceFailure.corrupt }
                startField(.formula)
            case "is":
                guard cell?.inline == nil else { throw EvidenceFailure.corrupt }
                startField(.inline)
                fieldDepth = nil
            default: break
            }
        } else if field == .inline, isRichText(at: 4, in: "is") {
            fieldDepth = path.count
        }
    }

    override func end() throws {
        if fieldDepth == path.count { fieldDepth = nil }
        if path.count == 5, let field {
            switch field {
            case .value: cell?.value = fieldText
            case .formula: cell?.formula = fieldText
            case .inline: cell?.inline = fieldText
            }
            if fieldBudget.truncated { cell?.oversized = true }
            self.field = nil
            fieldText = ""
        } else if path.count == 4, let cell {
            try append(cell)
            self.cell = nil
        }
    }

    override func text(_ text: String) throws {
        if fieldDepth == path.count, !fieldBudget.truncated { fieldText += fieldBudget.takePrefix(text) }
    }

    private func startField(_ field: Field) {
        self.field = field
        fieldDepth = path.count
        fieldBudget = EvidenceTextBudget(32_000)
    }

    private func append(_ cell: Cell) throws {
        if cell.oversized {
            truncated = true
            return
        }
        let raw = cell.value.flatMap { $0.isEmpty ? nil : $0 }
        let text: String?
        switch cell.type {
        case "s":
            if let raw {
                guard let shared, let index = Int(raw), shared.indices.contains(index) else {
                    throw EvidenceFailure.corrupt
                }
                text = shared[index]
            } else {
                text = nil
            }
        case "inlineStr": text = cell.inline
        default: text = raw
        }
        guard text != nil || cell.formula != nil else { return }
        let cached = cell.formula == nil ? nil : raw
        let size = (text?.utf16.count ?? 0) + (cell.formula?.utf16.count ?? 0)
            + (cached == text ? 0 : cached?.utf16.count ?? 0)
        guard items.count < cellLimit, size <= remainingText else {
            truncated = true
            return
        }
        remainingText -= size
        items.append(EvidenceItem(
            locator: .xlsx(sheet: sheet.name, cell: cell.coordinate), text: text,
            sheetVisibility: sheet.visibility, cellType: cell.type, formula: cell.formula, cachedValue: cached
        ))
    }

    private static func rowNumber(_ value: Substring) -> Int? {
        guard value.utf8.first.map({ (49...57).contains($0) }) == true,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let row = Int(value), row <= 1_048_576 else { return nil }
        return row
    }

    private static func columnNumber(_ coordinate: String, row: Int) -> Int? {
        var column = 0
        var end = coordinate.startIndex
        let bytes = coordinate.utf8
        while end != bytes.endIndex, (65...90).contains(bytes[end]) {
            column = column * 26 + Int(bytes[end]) - 64
            guard column <= 16_384 else { return nil }
            bytes.formIndex(after: &end)
        }
        guard column > 0, rowNumber(coordinate[end...]) == row else { return nil }
        return column
    }

    private static func coordinate(column: Int, row: Int) -> String {
        var column = column
        var letters: [UInt8] = []
        while column > 0 {
            column -= 1
            letters.append(UInt8(column % 26 + 65))
            column /= 26
        }
        return String(decoding: letters.reversed(), as: UTF8.self) + String(row)
    }
}

private extension OfficeXMLReader {
    /// Plain and rich text runs share the same structure in `si` and `is`.
    func isRichText(at container: Int, in name: String) -> Bool {
        guard path.count == container + 2 || path.count == container + 3 else { return false }
        let namespace = path[0].namespace
        guard path[container].name == name, path[container].namespace == namespace,
              let end = path.last, end.name == "t", end.namespace == namespace else { return false }
        return path.count == container + 2 || (path[container + 1].name == "r" && path[container + 1].namespace == namespace)
    }
}
