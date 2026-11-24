import Foundation

/// The navigation-performance trace vocabulary, as data.
///
/// Issue #151 requires `os_signpost` instrumentation around the transitions
/// that make Workspace ↔ Mapping stall, and it requires that instrumentation
/// to be privacy-safe. Both halves are decided here, in FormaCore, because the
/// only thing CI can run is Core: the app installs a sink that forwards these
/// facts to `OSSignposter`, and the tests assert what such a fact may contain.
///
/// The rule the type exists to enforce is that a fact carries a stage name and
/// integers. There is no case that can hold a path, a filename, a UUID or a
/// token, so leaking private data through the trace would require changing
/// this file - which is the reviewable diff a privacy regression should be.
public struct PerfFact: Equatable, Sendable {
    public enum Stage: String, CaseIterable, Sendable {
        /// The shell moved from one area to another.
        case areaSwitch = "area-switch"
        /// An area's content appeared - the point at which a view-owned `.task`
        /// used to re-run and re-read the evidence registry.
        case panelAppearance = "panel-appearance"
        /// A registry read for one source started.
        case evidenceLoad = "evidence-load"
        /// A registry read was skipped because the rows are already held.
        case evidenceCacheHit = "evidence-cache-hit"
        /// A registry read was skipped because an identical read is in flight.
        case evidenceLoadCoalesced = "evidence-load-coalesced"
        /// A registry read returned too late to publish: its key moved first.
        case evidenceLoadStale = "evidence-load-stale"
        /// The mapping and exception rows were rebuilt.
        case refreshRows = "refresh-rows"
        /// An export bundle was written.
        case export = "export"
        /// An export bundle was re-checked offline.
        case revalidate = "revalidate"
        /// One stage of `reload()` completed.
        case reloadListing = "reload-listing"
        case reloadContext = "reload-context"
        case reloadManifest = "reload-manifest"
        /// A model-wide publication was suppressed by progress coalescing.
        case progressCoalesced = "progress-coalesced"

        /// The signpost name. Static, so `analyze_trace.py --list-signposts`
        /// can filter on it and nothing user-supplied reaches the oslog.
        public var signpostName: String { rawValue }
    }

    public let stage: Stage
    /// How many records the stage touched. A count, never an identifier: the
    /// empty / 6-file / 1k cases #151 asks for are distinguishable by count.
    public let count: Int
    /// Whether the stage short-circuited (a cache hit, a coalesced update).
    public let shortCircuited: Bool

    public init(stage: Stage, count: Int = 0, shortCircuited: Bool = false) {
        self.stage = stage
        self.count = count
        self.shortCircuited = shortCircuited
    }

    /// The one string that ever leaves the process.
    ///
    /// Built from a static stage name and two integers only, which is what the
    /// privacy regression test pins: a fact emitted while the app is looking at
    /// files whose names are secret still cannot contain them.
    public var line: String {
        "\(stage.signpostName) count=\(count) shortCircuited=\(shortCircuited)"
    }
}

/// Where the facts go.
///
/// Unset by default, so a host that is not being traced pays one closure test
/// per instrumented stage and writes nothing. FormaApp installs the
/// `OSSignposter` sink; the tests install a recorder. Keeping the sink here is
/// what makes "the instrumentation is test-visible" true rather than
/// aspirational: the same emission path runs under `swift test` that runs under
/// Instruments.
public enum PerfTrace {
    nonisolated(unsafe) public static var sink: (@Sendable (PerfFact) -> Void)?

    public static func emit(_ stage: PerfFact.Stage, count: Int = 0, shortCircuited: Bool = false) {
        sink?(PerfFact(stage: stage, count: count, shortCircuited: shortCircuited))
    }

    /// Restores the no-op configuration. A test that installs a sink calls this
    /// when it finishes, so an unrelated suite never sees another's recorder.
    public static func clearSink() { sink = nil }
}
