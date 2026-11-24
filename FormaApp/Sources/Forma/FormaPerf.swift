import FormaCore
import Foundation
import os

/// The `os_signpost` half of the D2 instrumentation (#151).
///
/// Subsystem `com.forma.perf`, oslog category `Navigation`, exactly as the
/// issue specifies. Two channels, with a reason for each:
///
/// * Signpost **intervals and events** carry only static names, so Instruments
///   gets a timeline lane for an area switch, a panel appearance, a registry
///   read, a row rebuild, an export, a revalidation and each stage of a
///   reload. `analyze_trace.py --list-signposts --signpost-subsystem
///   com.forma.perf` finds them by name.
/// * **os_log** messages carry the numbers - how many entries a pass touched
///   and whether it short-circuited - because a count is the only fact about a
///   transition that distinguishes the six-file case from the thousand-file
///   one. `--list-logs --log-subsystem com.forma.perf` finds those.
///
/// Neither channel can carry a path, a filename, a UUID or a token. The
/// messages are built from `PerfFact`, whose fields are a closed set of stage
/// names plus two integers, and `PerfTraceTests` fails the moment that type
/// gains a way to speak a string that came from a file. `PerfTrace.sink` is
/// how `FormaCore` reaches this type: the emission path a CI test drives is
/// the same one Instruments reads, so the instrumentation is verified rather
/// than hoped for.
enum FormaPerf {
    private static let logger = Logger(subsystem: "com.forma.perf", category: "Navigation")
    private static let signposter = OSSignposter(subsystem: "com.forma.perf", category: "Navigation")

    /// Installs the Core sink. Called once, from the app delegate, before any
    /// model exists, so no instrumented stage can run unhooked.
    static func install() {
        PerfTrace.sink = record
    }

    static func record(_ fact: PerfFact) {
        switch fact.stage {
        case .areaSwitch: signposter.emitEvent("area-switch")
        case .panelAppearance: signposter.emitEvent("panel-appearance")
        case .evidenceCacheHit: signposter.emitEvent("evidence-cache-hit")
        case .evidenceLoadCoalesced: signposter.emitEvent("evidence-load-coalesced")
        case .evidenceLoadStale: signposter.emitEvent("evidence-load-stale")
        case .evidenceLoad, .refreshRows, .export, .revalidate, .reloadListing, .reloadContext,
             .reloadManifest, .progressCoalesced:
            break
        }
        logger.log("\(fact.stage.signpostName, privacy: .public) count=\(fact.count, privacy: .public) short=\(fact.shortCircuited, privacy: .public)")
    }

    // MARK: - Intervals

    /// The static name of one measured span. A `StaticString` cannot be built
    /// from a runtime string, which is the mechanism that keeps this
    /// instrumentation from ever learning a path: adding a span means adding
    /// a literal here.
    private static func name(_ stage: PerfFact.Stage) -> StaticString {
        switch stage {
        case .evidenceLoad: "evidence-load"
        case .refreshRows: "refresh-rows"
        case .export: "export-bundle"
        case .revalidate: "revalidate-bundle"
        case .reloadListing: "reload-listing"
        case .reloadContext: "reload-context"
        case .reloadManifest: "reload-manifest"
        case .areaSwitch: "area-switch"
        case .panelAppearance: "panel-appearance"
        case .evidenceCacheHit: "evidence-cache-hit"
        case .evidenceLoadCoalesced: "evidence-load-coalesced"
        case .evidenceLoadStale: "evidence-load-stale"
        case .progressCoalesced: "progress-coalesced"
        }
    }

    static func begin(_ stage: PerfFact.Stage) -> OSSignpostIntervalState {
        signposter.beginInterval(name(stage), id: signposter.makeSignpostID())
    }

    static func end(_ stage: PerfFact.Stage, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name(stage), state)
    }
}
