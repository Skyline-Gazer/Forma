import Foundation
import Testing

@testable import FormaCore

/// The navigation half of #151: what a switch between areas is allowed to do.
///
/// These tests run the transition function the shell runs (`apply(_:to:)`),
/// not a model of it. The app raises the same events from the same places -
/// the sidebar binding, the scene's `onDisappear`, the selections' `didSet` -
/// and `WorkspaceModel.perform(_:)` is the only interpreter of the list, so a
/// failure here is a change in what the window will do, not in a comment about
/// it.
///
/// What CI proves and what it does not: this is the decision rule and its
/// counters. It is not a window. Frame stability during 20 rapid drags, real
/// switch latency and any Instruments number stay deferred to #153 and the
/// recipe in `docs/NAV-PERF-MAC-TRACE.md`.
struct ShellNavigationTests {
    private var areas: [AppArea] { AppArea.allCases }

    // MARK: - The switch itself

    @Test func areaSwitchProducesNoEffectsForAnyPair() {
        for from in areas {
            for to in areas {
                var state = ShellNavigationState(area: from, scopeID: UUID(), profileID: "p",
                                                 manifestPresent: true)
                let scope = state.scopeID
                let profile = state.profileID
                let effects = apply(.areaChanged(to: to), to: &state)
                // The empty list is the issue's acceptance line, stated as a
                // value: no scan, no context build, no mapping, no reload, no
                // cancel, and no discarded selection.
                #expect(effects.isEmpty, "\(from.rawValue) -> \(to.rawValue) produced \(effects)")
                #expect(state.scopeID == scope)
                #expect(state.profileID == profile)
                #expect(state.manifestPresent == true)
                #expect(state.area == to)
            }
        }
    }

    @Test func retappingTheCurrentAreaIsNotASwitch() {
        var state = ShellNavigationState(area: .workspace)
        let switchEffects = apply(.areaChanged(to: .workspace), to: &state)
        #expect(switchEffects.isEmpty)
        #expect(state.counters.areaSwitches == 0)
        #expect(state.area == .workspace)
    }

    @Test func aHundredSwitchesCountSwitchesAndStartNoWork() {
        var state = ShellNavigationState(area: .workspace, scopeID: UUID(), profileID: "p",
                                        manifestPresent: true)
        var ledger = ShellWorkCounters()
        // The cycle the issue describes: Workspace to Mapping and back, the
        // pair whose re-entry used to re-read the registry and cancel tasks.
        let cycle: [AppArea] = [.workspace, .mapping, .workspace, .exceptions, .settings, .importArchive]
        for step in 0 ..< 100 {
            let event = ShellNavigationEvent.areaChanged(to: cycle[step % cycle.count])
            let effects = apply(event, to: &state)
            ledger.record(effects: effects)
        }
        // Equal-value retaps inside the cycle are not switches, so the count
        // is checked against the state machine's own view rather than the loop
        // count: the invariant is that every recorded switch started nothing.
        #expect(state.counters.areaSwitches > 0)
        #expect(state.counters.areaSwitches <= 100)
        #expect(ledger.started == [:])
        #expect(ledger.isIdle)
        #expect(state.scopeID != nil)
        #expect(state.profileID == "p")
        #expect(state.manifestPresent == true)
    }

    @Test func switchingFromABusyShellStillStartsNothing() {
        // #151's other half: the stall appeared while a mapping run held the
        // shell, so the rule must not gain an effect when work is in flight.
        // There is no in-flight parameter in the rule at all - that is the
        // point - and this test is what keeps it that way.
        var state = ShellNavigationState(area: .mapping, scopeID: UUID(), profileID: "p",
                                        manifestPresent: true)
        for to in areas {
            state.counters.record(.mapping)
            let effects = apply(.areaChanged(to: to), to: &state)
            #expect(effects.isEmpty)
            #expect(state.counters.count(of: .mapping) == 1, "the switch itself must not touch tallies")
            #expect(state.counters.count(of: .cancel) == 0)
        }
    }

    // MARK: - The events that legitimately do start work

    @Test func closingTheWindowCancelsAndNothingElseDoes() {
        var open = ShellNavigationState(area: .workspace)
        let closeEffects = apply(.shellClosed, to: &open)
        #expect(closeEffects == [.cancelInFlightWork])

        var scope = ShellNavigationState(area: .workspace)
        _ = apply(.scopeChanged(to: UUID()), to: &scope)
        #expect(!scope.counters.isIdle, "a source switch does start a reload")
        #expect(scope.counters.count(of: .cancel) == 0, "...and it is not a cancel")
        #expect(scope.counters.count(of: .reload) == 1)
    }

    @Test func scopeSwitchDropsTheManifestButProfileSwitchKeepsIt() {
        let id = UUID()
        var state = ShellNavigationState(area: .workspace, scopeID: UUID(), profileID: "p",
                                        manifestPresent: true)
        let effects = apply(.scopeChanged(to: id), to: &state)
        #expect(state.scopeID == id)
        #expect(state.manifestPresent == false, "a manifest belongs to the source that made it")
        #expect(effects.contains(.resetAreaSelections))
        #expect(effects.contains(.reload))
        // The file selections are reset because they named files in a listing
        // that is gone; the profile is not, because it never referred to files.
        #expect(state.profileID == "p")

        let profileEffects = apply(.profileChanged(to: "q"), to: &state)
        #expect(profileEffects == [.reload])
        #expect(state.profileID == "q")
        #expect(state.scopeID == id, "a profile switch must not lose the chosen source")
    }

    @Test func effectToWorkMappingIsTheOneBothTheAppAndTheTestsUse() {
        // The trace recipe reads these tallies on a Mac. If an effect began
        // mapping work without being counted, the counters would report an
        // idle shell while the window stalled, which is how #151 was found in
        // the first place.
        #expect(ShellEffect.reload.startedWork == .reload)
        #expect(ShellEffect.cancelInFlightWork.startedWork == .cancel)
        #expect(ShellEffect.resetAreaSelections.startedWork == nil)
        #expect(ShellEffect.clearFileEvidence.startedWork == nil)
        var ledger = ShellWorkCounters()
        ledger.record(effects: [.resetAreaSelections, .clearFileEvidence, .reload])
        #expect(ledger.count(of: .reload) == 1)
        #expect(ledger.count(of: .cancel) == 0)
        #expect(ledger.started.count == 1)
    }

    // MARK: - Publication and reload coalescing

    @Test func smallRunsPublishEveryFileAsTheyAlwaysDid() {
        // #151's own failure case is a six-file directory. Coalescing must not
        // change what that person sees, so the budget is a floor, not a cap,
        // at small sizes.
        let coalescing = CaptureProgressCoalescing()
        let publishes = (0 ..< 6).filter { coalescing.shouldPublish(index: $0, total: 6) }
        #expect(publishes == [0, 1, 2, 3, 4, 5])
        #expect((0 ..< 20).filter { coalescing.shouldPublish(index: $0, total: 20) }.count == 20)
    }

    @Test func largeRunsBoundTheirPublishesAndKeepTheEnds() {
        let coalescing = CaptureProgressCoalescing()
        let publishes = (0 ..< 1000).filter { coalescing.shouldPublish(index: $0, total: 1000) }
        #expect(publishes.first == 0)
        #expect(publishes.last == 999, "a progress line must not stop short of the last file")
        #expect(publishes.count <= 21, "\(publishes.count) whole-shell invalidations for one run")
        #expect(publishes == publishes.sorted(), "the line never goes backwards")
        // Nothing is *dropped*: every file is still visited by the loop, only
        // fewer of them announce themselves.
        let gaps = zip(publishes, publishes.dropFirst()).map(-)
        #expect(gaps.max()! <= 50, "the strip must not sit on one number for a hundred files")
        #expect(coalescing.shouldPublish(index: 1000, total: 1000) == false)
        #expect(coalescing.shouldPublish(index: -1, total: 1000) == false)
        #expect(coalescing.shouldPublish(index: 0, total: 0) == false)
    }

    @Test func overlappingReloadsRunOnePassAndThenTheOwedOne() {
        var coalescing = ReloadCoalescing()
        // Scope and profile changed in the same second: three requests, and
        // the third arrives while the first is still running.
        #expect(coalescing.request() == true, "the first request runs")
        #expect(coalescing.request() == false)
        #expect(coalescing.request() == false)
        #expect(coalescing.started == 1)
        #expect(coalescing.coalesced == 2, "two duplicate passes were avoided, not two dropped reloads")
        #expect(coalescing.complete() == true, "a pass is owed because the selection moved")
        #expect(coalescing.started == 2)
        #expect(coalescing.complete() == false)
        #expect(coalescing.isRunning == false)
        #expect(coalescing.request() == true, "and the coalescer is idle again for the next change")

        // A cancel is a request to stop, not a request to run later.
        var cancelled = ReloadCoalescing()
        #expect(cancelled.request())
        #expect(!cancelled.request())
        cancelled.cancel()
        #expect(cancelled.pending == false)
        #expect(cancelled.isRunning == false)
        #expect(cancelled.request(), "the next genuine change still starts a pass")
    }

    // MARK: - The trace vocabulary

    @Test func everyStageNameIsStaticAndPathShapedLikeASignpost() {
        // `analyze_trace.py --list-signposts` filters on these strings, and an
        // os_signpost name has to be a compile-time literal. A stage whose
        // name needed formatting at runtime would be a leak waiting to happen.
        for stage in PerfFact.Stage.allCases {
            #expect(!stage.rawValue.contains(" "), "\(stage.rawValue) is not a single signpost token")
            #expect(!stage.rawValue.contains("/"), "\(stage.rawValue) would carry a path separator")
            #expect(stage.rawValue == stage.signpostName)
            #expect(stage.rawValue.allSatisfy { $0.isLowercase || $0 == "-" || $0.isNumber })
        }
        // Names are stable identifiers in a trace, so renaming one is a change
        // to the recipe in docs/NAV-PERF-MAC-TRACE.md and nothing else.
        #expect(Set(PerfFact.Stage.allCases.map(\.rawValue)).count == PerfFact.Stage.allCases.count)
    }

    @Test func aFactCannotSpeakAFileName() {
        // The privacy claim, tested: a fact emitted while the app is holding
        // paths and tokens publishes only its stage and its two integers, so
        // none of that content can appear in the emitted line. Written this
        // way rather than through `PerfTrace.sink` on purpose - the sink is
        // process-global state and these suites run `--parallel`, so a test
        // that installed one would race an unrelated one. The sink itself is
        // covered by the app build; what CI pins is that a fact *has* no
        // field that could carry a name.
        let fact = PerfFact(stage: .evidenceLoad, count: 1_000, shortCircuited: false)
        #expect(fact.line == "evidence-load count=1000 shortCircuited=false")
        #expect(!fact.line.contains("/"))
        #expect(!fact.line.contains(".txt"))
        #expect(!fact.line.contains(UUID().uuidString))
        // Every stage renders the same way for the same two integers, so the
        // same fixture on two machines produces comparable lines.
        for stage in PerfFact.Stage.allCases {
            #expect(PerfFact(stage: stage, count: 6).line == "\(stage.rawValue) count=6 shortCircuited=false")
            #expect(PerfFact(stage: stage, count: 0, shortCircuited: true).line
                    == "\(stage.rawValue) count=0 shortCircuited=true")
        }
        // `PerfFact` has exactly the three fields this test can name. A fourth
        // one would have to be added here as well, which is the reviewable
        // diff a privacy regression should be.
        let measured = PerfFact(stage: .refreshRows, count: 42, shortCircuited: true)
        #expect(measured.stage == .refreshRows)
        #expect(measured.count == 42)
        #expect(measured.shortCircuited == true)
    }

    @Test func anUnhookedTraceWritesNothingAndStillCounts() {
        var state = ShellNavigationState(area: .workspace)
        let effects = apply(.areaChanged(to: .mapping), to: &state)
        // With no sink installed the emission path is a nil check; the rule
        // and its counters are unaffected, so shipping the instrumentation
        // cannot change what it measures.
        PerfTrace.emit(.areaSwitch)
        #expect(effects.isEmpty)
        #expect(state.counters.areaSwitches == 1)
    }
}
