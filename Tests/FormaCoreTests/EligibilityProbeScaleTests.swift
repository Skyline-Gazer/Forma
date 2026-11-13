import Foundation
import Testing

@testable import FormaCore

/// Opt-in probe scale measurement.
///
/// The default suites prove the probe's *semantics* on a handful of files. This
/// one answers a different question — what the bounded probe actually costs when
/// a real listing arrives, and whether its own counters agree with the work it
/// claims to do. It is disabled unless `FORMA_PROBE_SCALE=1`, so ordinary CI does
/// not pay for 10k filesystem objects; the manual `Probe scale` workflow enables
/// it and keeps the printed JSON as evidence.
///
/// Synthetic files on a hosted runner are **not** a real macOS scan benchmark:
/// no OneDrive hydration, no APFS copying, no provider latency. It measures this
/// module, nothing else.
@Suite("Eligibility probe scale",
       .enabled(if: ProcessInfo.processInfo.environment["FORMA_PROBE_SCALE"] == "1"))
struct EligibilityProbeScaleTests {
    private struct Fixture {
        let base: URL
        let root: URL
        let entries: [SourceEntry]

        init(fileCount: Int, directoryCount: Int) throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            root = base.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var built: [SourceEntry] = []
            built.reserveCapacity(fileCount)
            let payload = Data("payload".utf8)
            for index in 0..<fileCount {
                let directory = "d\(index % directoryCount)"
                let path = "\(directory)/f\(index).bin"
                let url = root.appendingPathComponent(path)
                if index < directoryCount {
                    try FileManager.default.createDirectory(
                        at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
                }
                try payload.write(to: url)
                let metadata = try SourceFileMetadata.read(url)
                built.append(SourceEntry(
                    id: UUID(), rootID: UUID(), relativePath: path,
                    normalizedRelativePath: path.lowercased(), state: .present,
                    hydrationPending: false, sourceVersion: 1, snapshotRevision: 1,
                    provider: .local, snapshotFingerprint: String(repeating: "d", count: 64),
                    sizeBytes: metadata.sizeBytes,
                    modificationTimeNanoseconds: metadata.modifiedNanoseconds, sha256: nil))
            }
            entries = built
        }

        func cleanUp() { try? FileManager.default.removeItem(at: base) }

        func probe(_ request: EligibilityProbeRequest) throws -> EligibilityProbeReport {
            EligibilityFactCollector.collect(access: try SourceRootAccess(root), entries: entries,
                                             request: request)
        }
    }

    @Test("ten thousand entries produce one result each and amortize directory metadata")
    func tenThousandEntries() throws {
        let fileCount = 10_000
        let directoryCount = 100
        let fixture = try Fixture(fileCount: fileCount, directoryCount: directoryCount)
        defer { fixture.cleanUp() }

        let request = EligibilityProbeRequest(includeGit: false)
        let clock = ContinuousClock()
        var report: EligibilityProbeReport?
        let elapsed = clock.measure {
            report = try? fixture.probe(request)
        }
        let measured = try #require(report)

        #expect(measured.results.count == fileCount)
        #expect(measured.skipped == 0)
        #expect(!measured.timedOut)
        #expect(!measured.cancelled)
        #expect(measured.gitInvocations == 0)
        // One descriptor per entry for its own stat, plus each ancestor directory
        // opened once for the marker and nested-repository walks. Anything close to
        // `fileCount * depth` would mean the per-directory memo is not working.
        let perDirectoryCost = 2 * (directoryCount + 1) + 4
        #expect(measured.descriptorOpens <= fileCount + perDirectoryCost,
                "descriptor opens: \(measured.descriptorOpens)")
        #expect(measured.results.allSatisfy { $0.facts.cacheMarker == .absent })
        #expect(measured.results.allSatisfy { $0.facts.nestedRepository == .no })

        let milliseconds = elapsed.seconds * 1_000
        let line = """
        {"entries":\(fileCount),"directories":\(directoryCount),\
        "descriptor_opens":\(measured.descriptorOpens),\
        "milliseconds":\(String(format: "%.1f", milliseconds)),"kind":"synthetic"}
        """
        print("PROBE_SCALE \(line)")
    }

    @Test("the request bound and the deadline both stop the batch and say so")
    func boundsHoldAtScale() throws {
        let fixture = try Fixture(fileCount: 2_000, directoryCount: 20)
        defer { fixture.cleanUp() }

        let bounded = try fixture.probe(EligibilityProbeRequest(maxEntries: 250, includeGit: false))
        #expect(bounded.results.count == 250)
        #expect(bounded.skipped == 1_750)
        #expect(bounded.descriptorOpens > 0)

        let expired = try fixture.probe(
            EligibilityProbeRequest(deadline: .milliseconds(1), includeGit: false))
        #expect(expired.timedOut)
        #expect(expired.results.count < 2_000)
    }
}

private extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
