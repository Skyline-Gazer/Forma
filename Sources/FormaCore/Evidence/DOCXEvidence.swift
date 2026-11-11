import Foundation

final class DOCXEvidence: OfficeXMLReader {
    private static let part = "word/document.xml"
    private var wordNamespace = ""
    private var paragraph = 0
    private var paragraphDepth: Int?
    private var runTextDepth: Int?
    private var content = ""
    private var budget = EvidenceTextBudget(12_000)
    private var items: [EvidenceItem] = []
    private var foundBody = false

    static func extract(from package: OfficePackage) throws -> EvidenceExtraction {
        let reader = DOCXEvidence()
        try reader.parse(package.part(part))
        guard reader.foundBody else { throw EvidenceFailure.corrupt }
        return .collected(reader.items, truncated: reader.budget.truncated)
    }

    override func start(_ attributes: [String: String]) throws {
        guard let element = path.last else { return }
        if path.count == 1 {
            guard element.name == "document", OfficeNamespaces.word.contains(element.namespace) else {
                throw EvidenceFailure.corrupt
            }
            wordNamespace = element.namespace
        } else if path.count == 2, element.name == "body", element.namespace == wordNamespace {
            guard !foundBody else { throw EvidenceFailure.corrupt }
            foundBody = true
        }
        guard path.count >= 3, path[1].name == "body", path[1].namespace == wordNamespace,
              element.namespace == wordNamespace else { return }
        if element.name == "p", paragraphDepth == nil, !hasExcludedAncestor(after: 2) {
            paragraph += 1
            paragraphDepth = path.count
        }
        guard let paragraphDepth, path.count > paragraphDepth,
              path[path.count - 2].name == "r", path[path.count - 2].namespace == wordNamespace,
              !hasExcludedAncestor(after: paragraphDepth) else { return }
        switch element.name {
        case "t": runTextDepth = path.count
        case "tab", "ptab": append("\t")
        case "br", "cr": append("\n")
        case "noBreakHyphen": append("\u{2011}")
        case "softHyphen": append("\u{00AD}")
        default: break
        }
    }

    override func end() throws {
        if runTextDepth == path.count { runTextDepth = nil }
        if paragraphDepth == path.count {
            if content.contains(where: { !$0.isWhitespace }) {
                items.append(EvidenceItem(
                    locator: .docx(part: Self.part, paragraph: paragraph, characterRange: 0..<content.utf16.count),
                    text: content
                ))
            }
            content = ""
            paragraphDepth = nil
        }
    }

    override func text(_ text: String) throws {
        if runTextDepth == path.count { append(text) }
    }

    private func append(_ text: String) {
        if !budget.truncated { content += budget.takePrefix(text) }
    }

    private func hasExcludedAncestor(after depth: Int) -> Bool {
        path[depth..<(path.count - 1)].contains {
            $0.namespace == wordNamespace && ["del", "moveFrom", "txbxContent", "p"].contains($0.name)
        }
    }
}
