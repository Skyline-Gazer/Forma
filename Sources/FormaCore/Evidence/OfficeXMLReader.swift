import Foundation

/// XMLParser never receives a URL and never sees a DTD. Accept the UTF-8 and
/// UTF-16 encodings used by OOXML, including UTF-16 without a byte-order mark.
class OfficeXMLReader: NSObject, XMLParserDelegate {
    struct Element {
        let name: String
        let namespace: String
    }

    private(set) var path: [Element] = []
    private var namespaces: [String: [String]] = [:]
    private var failure: (any Error)?

    func parse(_ data: Data) throws {
        try Self.checkProlog(data)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = self
        let success = parser.parse()
        if let failure { throw failure }
        guard success, parser.parserError == nil, path.isEmpty else { throw EvidenceFailure.corrupt }
    }

    func start(_ attributes: [String: String]) throws {}
    func end() throws {}
    func text(_ text: String) throws {}

    func relationshipID(_ attributes: [String: String]) throws -> String {
        var result: String?
        for (key, value) in attributes {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[1] == "id",
                  let namespace = namespaces[String(parts[0])]?.last,
                  OfficeNamespaces.relationships.contains(namespace) else { continue }
            guard result == nil, !value.isEmpty else { throw EvidenceFailure.corrupt }
            result = value
        }
        guard let result else { throw EvidenceFailure.corrupt }
        return result
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        namespaces[prefix, default: []].append(namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        _ = namespaces[prefix]?.popLast()
        if namespaces[prefix]?.isEmpty == true { namespaces.removeValue(forKey: prefix) }
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes attributeDict: [String: String]
    ) {
        do {
            try Task.checkCancellation()
            guard path.count < 128 else { throw EvidenceFailure.budget }
            path.append(Element(name: elementName, namespace: namespaceURI ?? ""))
            try start(attributeDict)
        } catch {
            abort(parser, error)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard failure == nil else { return }
        do {
            try end()
            path.removeLast()
        } catch {
            abort(parser, error)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard failure == nil else { return }
        do { try text(string) } catch { abort(parser, error) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else {
            abort(parser, EvidenceFailure.corrupt)
            return
        }
        self.parser(parser, foundCharacters: string)
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        abort(parser, EvidenceFailure.corrupt)
        return nil
    }

    private func abort(_ parser: XMLParser, _ error: any Error) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    private static func checkProlog(_ data: Data) throws {
        let prolog: Data
        let encodingNames: [String]
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0x3C, 0x00]) {
            guard let text = String(data: data, encoding: .utf16LittleEndian) else { throw EvidenceFailure.corrupt }
            prolog = Data(text.utf8)
            encodingNames = ["utf-16", "utf-16le"]
        } else if data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0x00, 0x3C]) {
            guard let text = String(data: data, encoding: .utf16BigEndian) else { throw EvidenceFailure.corrupt }
            prolog = Data(text.utf8)
            encodingNames = ["utf-16", "utf-16be"]
        } else {
            prolog = data
            encodingNames = ["utf-8"]
        }

        var cursor = prolog.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        while cursor < prolog.count {
            switch prolog[cursor] {
            case 9, 10, 13, 32:
                cursor += 1
            case 60: // '<'
                let tail = prolog[cursor...]
                if tail.starts(with: "<!--".utf8) {
                    guard let end = prolog.range(of: Data("-->".utf8), in: (cursor + 4)..<prolog.count) else {
                        throw EvidenceFailure.corrupt
                    }
                    cursor = end.upperBound
                } else if tail.starts(with: "<?".utf8) {
                    guard let end = prolog.range(of: Data("?>".utf8), in: (cursor + 2)..<prolog.count) else {
                        throw EvidenceFailure.corrupt
                    }
                    if tail.starts(with: "<?xml".utf8), cursor + 5 < end.lowerBound,
                       [UInt8(9), 10, 13, 32].contains(prolog[cursor + 5]) {
                        // Bound the declaration before parsing its optional encoding name.
                        guard end.lowerBound - cursor <= 512,
                              let declaration = String(data: prolog[cursor..<end.lowerBound], encoding: .utf8) else {
                            throw EvidenceFailure.corrupt
                        }
                        if let field = declaration.range(of: #"\bencoding\s*=\s*(['"])[A-Za-z][A-Za-z0-9._-]*\1"#,
                                                         options: .regularExpression) {
                            let value = declaration[field].split(whereSeparator: { $0 == "'" || $0 == "\"" }).last
                            guard let value, encodingNames.contains(value.lowercased()) else { throw EvidenceFailure.corrupt }
                        }
                    }
                    cursor = end.upperBound
                } else {
                    guard !tail.starts(with: "<!".utf8), cursor + 1 < prolog.count,
                          prolog[cursor + 1] != 0 else { throw EvidenceFailure.corrupt }
                    return
                }
            default:
                throw EvidenceFailure.corrupt
            }
        }
        throw EvidenceFailure.corrupt
    }
}

enum OfficeNamespaces {
    static let word = [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        "http://purl.oclc.org/ooxml/wordprocessingml/main"
    ]
    static let spreadsheet = [
        "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
        "http://purl.oclc.org/ooxml/spreadsheetml/main"
    ]
    static let relationships = [
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
        "http://purl.oclc.org/ooxml/officeDocument/relationships"
    ]
    static let packageRelationships = [
        "http://schemas.openxmlformats.org/package/2006/relationships",
        "http://purl.oclc.org/ooxml/package/relationships"
    ]
}
