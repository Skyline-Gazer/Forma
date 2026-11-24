import Foundation
import Testing

@testable import FormaCore

/// The shell grammar is Core-side data, so every claim the D1 shell makes about
/// stable toolbars, non-blank pickers and business copy for internal codes is
/// checked here without SwiftUI.
@Suite("App shell presentation")
struct AppShellPresentationTests {

    // MARK: - Command stability

    private static var everyDimension: [(AppArea, BusyState, PlannerMode)] {
        AppArea.allCases.flatMap { area in
            [BusyState.idle, .busy].flatMap { phase in
                PlannerMode.allCases.map { mode in (area, phase, mode) }
            }
        }
    }

    @Test("no command title or help is ever blank, in any area/phase/planner")
    func commandsAreLabeled() {
        for (area, phase, planner) in Self.everyDimension {
            for command in ShellCommands.commands(for: area, phase: phase, planner: planner) {
                #expect(!command.title.isEmpty, "\(area.rawValue)/\(phase.rawValue): \(command.id) has no title")
                #expect(!command.help.isEmpty, "\(area.rawValue)/\(phase.rawValue): \(command.id) has no help")
                #expect(command.placement == .primary || command.placement == .egress)
            }
        }
    }

    @Test("the command set is stable across busy/idle except the allowed cancel swap")
    func commandSetStableAcrossPhases() {
        for area in AppArea.allCases {
            for planner in PlannerMode.allCases {
                let idle = ShellCommands.commands(for: area, phase: .idle, planner: planner)
                let busy = ShellCommands.commands(for: area, phase: .busy, planner: planner)
                let swapped = idle.filter { !ShellCommands.swapsForCancel($0) }.map(\.id)
                let keptBusy = busy.filter { $0.id != ShellCommands.cancelCommand(for: area)?.id }.map(\.id)
                // Idle non-swapping commands must all survive into busy (disabled,
                // but visible): the set changes by swap, never by silent removal.
                #expect(Set(swapped) == Set(keptBusy), "\(area.rawValue): \(swapped) vs \(keptBusy)")
                // Surviving commands keep id, title, image and placement across the
                // phase change; only enablement may differ.
                for busyCommand in keptBusy {
                    guard let idleCommand = idle.first(where: { $0.id == busyCommand }) else { continue }
                    let busyAgain = busy.first(where: { $0.id == busyCommand })!
                    #expect(idleCommand.title == busyAgain.title)
                    #expect(idleCommand.systemImage == busyAgain.systemImage)
                    #expect(idleCommand.placement == busyAgain.placement)
                    #expect(!busyAgain.isEnabled || area == .exceptions,
                            "a surviving command must be disabled while busy (exceptions' clear-selection is not work)")
                }
                // Busy shows cancel only for areas that run cancellable work,
                // and it is enabled there.
                if let cancel = ShellCommands.cancelCommand(for: area) {
                    let shown = busy.first { $0.id == cancel.id }
                    #expect(shown != nil)
                    #expect(shown?.isEnabled == true)
                    #expect(idle.first { $0.id == cancel.id } == nil)
                }
                // The planner dimension changes only the mapping area.
                if area != .mapping {
                    let offline = ShellCommands.commands(for: area, phase: .idle, planner: .offline).map(\.id)
                    let ai = ShellCommands.commands(for: area, phase: .idle, planner: .ai).map(\.id)
                    #expect(offline == ai, "\(area.rawValue) must not depend on the planner mode")
                }
            }
        }
    }

    @Test("a local run is offered exactly where it means something")
    func assessLocalOnlyForProviderRuns() {
        let offline = ShellCommands.commands(for: .mapping, phase: .idle, planner: .offline)
        let ai = ShellCommands.commands(for: .mapping, phase: .idle, planner: .ai)
        #expect(offline.first { $0.id == "assess-local" } == nil)
        #expect(ai.first { $0.id == "assess-local" } != nil)
        // The offline run itself never claims to "assess without egress": it is
        // the ordinary map command with the offline help.
        let run = offline.first { $0.id == "run-mapping" }
        #expect(run?.help.contains("不发送") == true)
    }

    // MARK: - Profile picker contract

    @Test("the profile picker resolves to a label or the placeholder, never blank")
    func profilePickerNeverBlank() {
        let options: [(id: String, name: String)] = [
            (id: "p1", name: "档案一"),
            (id: "p2", name: "档案二"),
        ]
        #expect(ShellProfilePicker.label(selected: "p1", options: options) == "档案一")
        #expect(ShellProfilePicker.label(selected: "gone", options: options) == ShellProfilePicker.placeholder)
        #expect(ShellProfilePicker.label(selected: nil, options: options) == ShellProfilePicker.placeholder)
        #expect(ShellProfilePicker.label(selected: nil, options: []) == ShellProfilePicker.placeholder)
        #expect(!ShellProfilePicker.placeholder.isEmpty)
        #expect(ShellProfilePicker.isEnabled(optionCount: 0) == false)
        #expect(ShellProfilePicker.isEnabled(optionCount: 2) == true)
    }

    // MARK: - Business copy

    @Test("business copy is total over every currently-surfaced code")
    func businessCopyTotalOverSurfacedCodes() {
        let surfaced = [
            "snapshot_changed", "membership_changed", "source_missing",
            "evidence_not_found", "evidence_incomplete", "association_unknown",
            "hold", "unknown", "validated", "mapped", "invalidated", "digest",
        ]
        for code in surfaced {
            let copy = businessCopy(for: code)
            #expect(copy.rawCode == code)
            #expect(!copy.headline.isEmpty, "\(code): no business headline")
            #expect(!copy.sentence.isEmpty, "\(code): no business sentence")
            // The curated copy speaks the user's language: it carries CJK text and
            // does not leak the snake_case code into the headline.
            #expect(copy.headline.contains(where: { $0.isCJKPresentation }))
            #expect(!copy.headline.contains("_"))
        }
    }

    @Test("an uncurated code keeps its raw text for the diagnostics detail")
    func businessCopyFallbackPreservesRaw() {
        let copy = businessCopy(for: "provider_network_timeout")
        #expect(copy.rawCode == "provider_network_timeout")
        #expect(!copy.headline.isEmpty)
        #expect(!copy.sentence.isEmpty)
    }

    // MARK: - Area persistence

    @Test("every area round-trips through its persisted raw value")
    func appAreaPersistenceRoundTrip() {
        for area in AppArea.allCases {
            let data = try! JSONEncoder().encode(area)
            let decoded = try! JSONDecoder().decode(AppArea.self, from: data)
            #expect(decoded == area)
            #expect(AppArea(rawValue: area.rawValue) == area)
            #expect(!area.title.isEmpty)
            #expect(!area.systemImage.isEmpty)
        }
        #expect(AppArea.allCases.count == 6)
        // Append-only contract: every raw value persisted before the desk was
        // added still decodes to the same area, and "review" is the only new
        // identity. A rename of an old case would break this and is a
        // migration, not a refactor.
        for legacy in ["workspace", "mapping", "import", "exceptions", "settings"] {
            #expect(AppArea(rawValue: legacy) != nil, "\(legacy) no longer decodes")
        }
        #expect(AppArea(rawValue: "review") == .reviewDesk)
    }

    @Test("a stored selection unknown to this build restores to the desk, and known values survive")
    func appAreaRestoreFallback() {
        // #144 default landing: nothing stored, or a value from a future
        // build, restores to the business Review Desk - never a blank window,
        // never an engineering area.
        #expect(AppArea.restored(from: nil) == .reviewDesk)
        #expect(AppArea.restored(from: "") == .reviewDesk)
        #expect(AppArea.restored(from: "some-future-area") == .reviewDesk)
        #expect(AppArea.defaultLanding == .reviewDesk)
        #expect(AppArea.restored(from: "settings") == .settings)
        #expect(AppArea.restored(from: "workspace") == .workspace)
        #expect(AppArea.restored(from: "review") == .reviewDesk)
        // The sidebar grammar: the desk leads, and every area appears exactly
        // once.
        #expect(Set(AppArea.navigationOrder) == Set(AppArea.allCases))
        #expect(AppArea.navigationOrder.count == AppArea.allCases.count)
        #expect(AppArea.navigationOrder.first == .reviewDesk)
    }

    // MARK: - Egress consent presentation

    @Test("egress consent is a short label plus a confirmation, not a titlebar sentence")
    func egressConsentSurface() {
        #expect(EgressConsent.shortLabel.count <= 6)
        #expect(!EgressConsent.shortLabel.contains(" "))
        #expect(EgressConsent.whatLeavesLines.count >= 3)
        for line in EgressConsent.whatLeavesLines where !line.isEmpty {
            #expect(line.contains(where: { $0.isCJKPresentation }))
        }
        #expect(EgressConsent.confirmAction != EgressConsent.cancelAction)
        // Every data category the contract can name has business copy.
        for category in EgressDataCategory.allCases {
            #expect(!EgressConsent.copy(for: category).isEmpty)
        }
    }

    @Test("planner naming is one tested string per mode")
    func plannerLabels() {
        #expect(plannerModeLabel(.offline).contains("非 AI"))
        #expect(!plannerModeLabel(.ai).isEmpty)
        #expect(plannerModeLabel(.offline) != plannerModeLabel(.ai))
        #expect(offlinePlannerShortNotice.count < 60)
    }
}

private extension Character {
    var isCJKPresentation: Bool {
        unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
