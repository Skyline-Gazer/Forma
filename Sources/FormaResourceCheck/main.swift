import Foundation
import FormaCore

// Usage: FormaResourceCheck <path/to/Forma.app>
//
// Exit codes: 0 complete, 1 incomplete (missing or unreadable resources),
// 2 bad usage.

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: FormaResourceCheck <Forma.app>\n".utf8))
    exit(2)
}

let result = ShippedResourceProbe.probe(appURL: URL(fileURLWithPath: arguments[1]))
print("bundle: \(result.bundlePath ?? "missing")")
print("missing: \(result.missing.isEmpty ? "none" : result.missing.joined(separator: ", "))")
print("unreadable: \(result.unreadable.isEmpty ? "none" : result.unreadable.joined(separator: ", "))")
print(result.isComplete ? "result: COMPLETE" : "result: INCOMPLETE")
exit(result.isComplete ? 0 : 1)
