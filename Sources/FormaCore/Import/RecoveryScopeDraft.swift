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
    /// True once the person pressed Confirm in this sheet presentation. It only
    /// exists so an untouched empty form is not accused of an error; it is not
    /// application state and it is cleared by `reset()`.
    public var hasAttemptedConfirmation: Bool

    public init(databaseID: String = "", databaseName: String = "", groupPath: String = "",
                hasAttemptedConfirmation: Bool = false) {
        self.databaseID = databaseID
        self.databaseName = databaseName
        self.groupPath = groupPath
        self.hasAttemptedConfirmation = hasAttemptedConfirmation
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

    /// What the sheet should show right now.
    ///
    /// It is derived **only** from this draft. The application's recovery reason
    /// (for example `no_authorized_scope`) describes the banner, not the form; the
    /// field defect was exactly that mixture — a valid form kept showing an error
    /// because a stale application-level reason was OR-ed into the view.
    public enum Feedback: Sendable, Equatable {
        case none
        case missingFields
        case invalidUUID
        case ready
    }

    public var feedback: Feedback {
        switch validation {
        case .ready:
            return .ready
        case .invalidUUID:
            return .invalidUUID
        case .incomplete:
            return hasAttemptedConfirmation ? .missingFields : .none
        }
    }

    /// Marks that Confirm was pressed. Call it before reading `validation` when
    /// the person submits; it changes nothing about the values themselves.
    public mutating func attemptConfirmation() {
        hasAttemptedConfirmation = true
    }

    /// Clears the draft. Used by "Cancel" and after a successful confirmation, so
    /// a reopened sheet never presents a previously confirmed scope as if it were
    /// a new one.
    public mutating func reset() {
        databaseID = ""
        databaseName = ""
        groupPath = ""
        hasAttemptedConfirmation = false
    }
}
