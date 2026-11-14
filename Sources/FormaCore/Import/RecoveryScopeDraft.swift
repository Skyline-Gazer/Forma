import Foundation

/// What the "Read Scope…" sheet holds while a person types.
///
/// The field run showed why this cannot stay inside the view: macOS Accessibility
/// `AXUIElementSetAttributeValue(kAXValue)` updates the text the field *shows*
/// without necessarily driving the SwiftUI binding, so a test that only inspects
/// or sets AX values can pass while the app never saw the input. The validation
/// therefore lives here, where it is testable without a window, and the sheet only
/// renders it.
public struct RecoveryScopeDraft: Sendable, Equatable {
    public var databaseID: String
    public var databaseName: String
    public var groupPath: String

    public init(databaseID: String = "", databaseName: String = "", groupPath: String = "") {
        self.databaseID = databaseID
        self.databaseName = databaseName
        self.groupPath = groupPath
    }

    public enum Validation: Sendable, Equatable {
        /// Something required is still empty. The sheet shows no error yet.
        case incomplete
        /// Every field is filled, but the database id is not a UUID.
        case invalidUUID
        /// Ready to confirm; carries the canonical scope.
        case ready(ImportRecoveryScopeConfirmation)
    }

    /// The group path as components: slashes split, empty components dropped.
    public var groupComponents: [String] {
        groupPath.split(separator: "/").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Trimmed inputs. Confirmation is refused on empty required fields, so a
    /// stray space is not a value.
    public var trimmedDatabaseID: String {
        databaseID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedDatabaseName: String {
        databaseName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var validation: Validation {
        guard !trimmedDatabaseID.isEmpty,
              !trimmedDatabaseName.isEmpty,
              !groupComponents.isEmpty else {
            return .incomplete
        }
        guard UUID(uuidString: trimmedDatabaseID) != nil else {
            return .invalidUUID
        }
        guard let confirmation = ImportRecoveryScopeConfirmation(
            databaseID: trimmedDatabaseID,
            databaseName: trimmedDatabaseName,
            groupPath: groupComponents,
            confirmedAt: Date(),
            confirmedBy: "operator") else {
            return .invalidUUID
        }
        return .ready(confirmation)
    }

    /// Clears the draft. Used by "Cancel" and after a successful confirmation, so
    /// a reopened sheet never presents a previously confirmed scope as if it were
    /// a new one.
    public mutating func reset() {
        databaseID = ""
        databaseName = ""
        groupPath = ""
    }
}
