import Foundation
import Testing
@testable import FormaCore

/// The "Read Scope…" form's validation, tested where it can be observed.
///
/// The field run could not drive the SwiftUI binding through Accessibility, so the
/// form's decisions were verified by hand and the validation itself was not
/// covered. Moving it into `RecoveryScopeDraft` means the same rules the sheet
/// renders are exercised here: empty, malformed, valid, repeated and reset.
@Suite("Recovery scope draft")
struct RecoveryScopeDraftTests {
    private let uuid = "11111111-1111-4111-8111-111111111111"

    private func draft(id: String = "11111111-1111-4111-8111-111111111111",
                       name: String = "Sandbox",
                       group: String = "Forma_I1B2/r1") -> RecoveryScopeDraft {
        RecoveryScopeDraft(databaseID: id, databaseName: name, groupPath: group)
    }

    @Test func anEmptyFormIsIncompleteRatherThanInvalid() {
        #expect(RecoveryScopeDraft().validation == .incomplete)
        // One missing field is still incomplete: the sheet should not accuse
        // anybody of an error before they have typed anything.
        #expect(draft(id: "").validation == .incomplete)
        #expect(draft(name: " ").validation == .incomplete)
        #expect(draft(group: " / ").validation == .incomplete)
    }

    @Test func aFilledFormWithANonUUIDIsInvalid() {
        #expect(draft(id: "not-a-uuid").validation == .invalidUUID)
    }

    @Test func aValidFormProducesTheCanonicalScope() throws {
        guard case .ready(let scope) = draft(id: uuid.lowercased(),
                                             name: "  Sandbox  ",
                                             group: "/Forma_I1B2//r1/").validation else {
            Issue.record("expected a ready scope")
            return
        }
        #expect(scope.databaseID == uuid)
        #expect(scope.databaseName == "Sandbox")
        #expect(scope.groupPath == ["Forma_I1B2", "r1"])
        #expect(scope.confirmedBy == "operator")
    }

    @Test func aGroupPathMayBeASingleComponent() throws {
        guard case .ready(let scope) = draft(group: "Forma_I1B2").validation else {
            Issue.record("expected a ready scope")
            return
        }
        #expect(scope.groupPath == ["Forma_I1B2"])
    }

    @Test func repeatedConfirmationProducesTheSameScopeTerms() throws {
        guard case .ready(let first) = draft().validation,
              case .ready(let second) = draft().validation else {
            Issue.record("expected ready scopes")
            return
        }
        // Only the confirmation time differs; the terms a recheck would use are
        // identical, so a second confirmation cannot silently widen anything.
        #expect(first.databaseID == second.databaseID)
        #expect(first.groupPath == second.groupPath)
        #expect(first.scope == second.scope)
    }

    @Test func resetClearsEverything() {
        var form = draft()
        form.reset()
        #expect(form == RecoveryScopeDraft())
        #expect(form.validation == .incomplete)
    }
}
