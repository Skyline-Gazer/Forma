import Foundation

/// Which kind of work the shell can start.
///
/// The names are the ones #151's acceptance list uses, so the counter and the
/// issue read the same way: switching an area must leave every one of them at
/// the value it had before the switch.
public enum ShellWork: String, CaseIterable, Codable, Sendable, Hashable {
    case scan
    case buildContext
    case mapping
    case export
    case revalidate
    case reconcile
    case reload
    case evidenceLoad
    case cancel
}

/// Instrumented counters for the shell's work entry points.
///
/// This is the test-only-visible half of the D2 instrumentation: the app calls
/// `record(_:)` from the methods that actually start work, so a trace (or a
/// CI assertion over the same type) can show that N area switches produced zero
/// new work. A counter over a dictionary of ints costs one increment, so the
/// instrumentation cannot itself become the thing under measurement.
///
/// The transition rule below never writes here except through `record(_:)`
/// for the switch it is reporting. Counting real work is the app's job, at the
/// entry point where work starts; if the rule that decides "no work" also
/// incremented the tally on its own, a test could not tell "nothing was
/// scheduled" apart from "the rule did not notice what it scheduled".
public struct ShellWorkCounters: Equatable, Sendable, Codable {
    public private(set) var started: [ShellWork: Int] = [:]
    public private(set) var areaSwitches: Int = 0

    public init() {}

    public mutating func record(_ work: ShellWork) {
        started[work, default: 0] += 1
    }

    public mutating func recordAreaSwitch() {
        areaSwitches += 1
    }

    /// Records the work a list of effects starts.
    ///
    /// The app's effect interpreter and the tests' spy both come through here,
    /// which is what makes a CI run and an Instruments run report the same
    /// number for the same navigation: one mapping from effect to work,
    /// declared once.
    public mutating func record(effects: [ShellEffect]) {
        for effect in effects {
            if let work = effect.startedWork { record(work) }
        }
    }

    public func count(of work: ShellWork) -> Int { started[work] ?? 0 }

    /// True when nothing has been started except the switches themselves -
    /// the state the shell must be in after any number of navigation clicks.
    public var isIdle: Bool { started.isEmpty }

    /// The work started between two snapshots of the same ledger.
    ///
    /// A trace reads the absolute counters; the tests read this, because a
    /// scripted sequence run on top of a model that had already done work is
    /// only meaningful as a difference.
    public func started(since other: ShellWorkCounters) -> [ShellWork: Int] {
        var delta: [ShellWork: Int] = [:]
        for work in ShellWork.allCases {
            let change = count(of: work) - other.count(of: work)
            if change != 0 { delta[work] = change }
        }
        return delta
    }
}

/// The navigation state the shell owns: where the person is, and the three
/// selections a stall must never discard.
///
/// `scopeID`, `profileID` and `manifestPresent` are the state #151 names as
/// "loses scope or manifest". They are here as values, not as bindings, so the
/// transition rules below are the same code the shell runs; `WorkspaceModel`
/// keeps the authority over each one and mirrors it into this struct at the
/// moment it changes.
public struct ShellNavigationState: Equatable, Sendable {
    public var area: AppArea
    public var scopeID: UUID?
    public var profileID: String?
    public var manifestPresent: Bool
    public var counters: ShellWorkCounters

    public init(area: AppArea = .workspace, scopeID: UUID? = nil, profileID: String? = nil,
                manifestPresent: Bool = false, counters: ShellWorkCounters = ShellWorkCounters()) {
        self.area = area
        self.scopeID = scopeID
        self.profileID = profileID
        self.manifestPresent = manifestPresent
        self.counters = counters
    }
}

/// What a navigation event is allowed to do.
public enum ShellEffect: Equatable, Sendable, CaseIterable {
    /// Stop the in-flight long task. Only the window closing may ask for this.
    case cancelInFlightWork
    /// Forget the file and cluster selections, because they belonged to another
    /// listing. Never fired by an area switch.
    case resetAreaSelections
    /// Close the file-detail read and drop its evidence with it.
    case clearFileEvidence
    /// Re-read listing, context and manifest for the current selection.
    case reload

    /// The work this effect starts, or nil when it only discards state.
    ///
    /// `resetAreaSelections` and `clearFileEvidence` throw values away rather
    /// than beginning anything, so they are not counted as work; a trace that
    /// counted them would make a legitimate scope switch look like the stall
    /// #151 describes.
    public var startedWork: ShellWork? {
        switch self {
        case .cancelInFlightWork: .cancel
        case .reload: .reload
        case .resetAreaSelections, .clearFileEvidence: nil
        }
    }
}

/// A navigation event the shell can raise.
///
/// Launch restoration is deliberately absent: `restore()` belongs to the
/// scene's own `.task`, which SwiftUI starts and cancels with the scene, and
/// routing it through a synchronous effect list would either await inside a
/// non-async interpreter or move the work into an unstructured child task that
/// a closing window could no longer cancel. The one event that would have been
/// "the app started" is therefore not a navigation event at all, and the doc
/// recipe measures launch separately from switching.
public enum ShellNavigationEvent: Equatable, Sendable {
    /// The person chose another area in the sidebar.
    case areaChanged(to: AppArea)
    /// The chosen source changed. The value is the new one, so the mirror
    /// moves with the event rather than being re-read afterwards.
    case scopeChanged(to: UUID?)
    /// The chosen profile changed.
    case profileChanged(to: String?)
    /// The scene's content was removed - the window closed.
    case shellClosed
}

/// The single transition function of the D2 shell.
///
/// `areaChanged` returns no effects and changes no selection: that is issue
/// #151's failure ("switching tabs starts scan/restore/mapping, cancels
/// persistent tasks, loses scope or manifest") expressed as a rule the app
/// obeys rather than a comment it hopes is followed. The old per-tab
/// `.onDisappear { cancelAll() }` fired on every switch; D1 moved that closure
/// to the scene-owned shell, and this function is where the difference is
/// pinned: only `shellClosed` produces `.cancelInFlightWork`, and it produces
/// it whether or not something was running, because `cancelAll()` with nothing
/// to stop is a no-op while a rule that guessed "nothing is running" from a
/// mirror of the task handles would be a window that closed on a live task.
///
/// Effects are returned, not performed, so a test can compare the list itself
/// rather than a side effect of having run the app. `WorkspaceModel.perform(_:)`
/// is the only production interpreter, and it calls the same methods the
/// selections' `didSet` bodies called before it existed - so there is one
/// implementation of each behaviour, and no second path that could drift.
@discardableResult
public func apply(_ event: ShellNavigationEvent, to state: inout ShellNavigationState) -> [ShellEffect] {
    switch event {
    case let .areaChanged(to):
        // A re-tap of the current row is not a switch at all: a binding can
        // write the value it already had when a persisted selection is
        // normalised, and counting that as a switch would make the "no work
        // per switch" claim unfalsifiable.
        guard to != state.area else { return [] }
        state.area = to
        // The switch itself is the only thing this rule records.
        state.counters.recordAreaSwitch()
        return []
    case let .scopeChanged(to):
        state.scopeID = to
        // The manifest and everything derived from it belong to the source
        // that produced them, so a scope switch drops them by design. This is
        // the one path that legitimately reloads, and it is not an area switch.
        state.manifestPresent = false
        return [.resetAreaSelections, .clearFileEvidence, .reload]
    case let .profileChanged(to):
        state.profileID = to
        // The context and the manifest are both keyed by profile, so a profile
        // switch reads them again; the selections survive, because the files
        // are still the same files.
        return [.reload]
    case .shellClosed:
        return [.cancelInFlightWork]
    }
}
