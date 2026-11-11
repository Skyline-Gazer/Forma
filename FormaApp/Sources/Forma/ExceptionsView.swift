import FormaCore
import SwiftUI

/// The exception area: every entry FormaCore refused to validate, with the
/// reason the program recorded rather than the model's own explanation.
///
/// Rows come from the same two sources the exporter uses: the manifest's
/// hold/unknown/invalidated entries and `ValidationReport.allViolations`
/// grouped by `instancePath`. Reprocessing hands FormaCore only the selected
/// source identifiers; the engine decides what to ask and the validator decides
/// the resulting state.
struct ExceptionsView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var stateFilter: StateFilter = .all
    @State private var codeFilter: String?
    @State private var selection = Set<UUID>()

    enum StateFilter: String, CaseIterable, Identifiable {
        case all
        case hold
        case unknown
        case invalidated

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All blocked states"
            case .hold: DecisionState.hold.rawValue
            case .unknown: DecisionState.unknown.rawValue
            case .invalidated: DecisionState.invalidated.rawValue
            }
        }

        var state: DecisionState? {
            switch self {
            case .all: nil
            case .hold: .hold
            case .unknown: .unknown
            case .invalidated: .invalidated
            }
        }
    }

    private var codes: [String] {
        Array(Set(model.exceptions.flatMap(\.codes))).sorted()
    }

    private var rows: [WorkspaceModel.ExceptionRow] {
        model.exceptions.filter { row in
            (stateFilter.state == nil || row.state == stateFilter.state)
                && (codeFilter == nil || row.codes.contains(codeFilter ?? ""))
        }
    }

    private var selected: [WorkspaceModel.ExceptionRow] {
        rows.filter { selection.contains($0.sourceID) }
    }

    var body: some View {
        NavigationSplitView {
            filterPanel
                .navigationTitle("Exceptions")
                .navigationSplitViewColumnWidth(min: 230, ideal: 280)
        } detail: {
            if model.exceptions.isEmpty {
                ContentUnavailableView("No exceptions", systemImage: "checkmark.seal",
                                       description: Text(emptyReason))
            } else {
                HSplitView {
                    rowTable
                        .frame(minWidth: 420)
                    detailPane
                        .frame(minWidth: 280, idealWidth: 340)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.phase.isBusy {
                    Button("Cancel", systemImage: "stop.circle") { model.cancelWork() }
                        .accessibilityIdentifier("cancel-reprocess")
                } else {
                    Button("Reprocess Selected", systemImage: "arrow.3.trianglepath") {
                        model.runMapping(sourceIDs: selection, egress: model.allowCloud)
                    }
                    .disabled(selection.isEmpty || !model.canMap)
                    .help("Runs the mapping engine over the selected source identifiers only")
                    .accessibilityIdentifier("reprocess-selected")
                }
                Button("Clear Selection") { selection.removeAll() }
                    .disabled(selection.isEmpty)
            }
        }
        .onChange(of: stateFilter) { _, _ in selection.removeAll() }
        .onChange(of: codeFilter) { _, _ in selection.removeAll() }
        .onDisappear { model.cancelWork() }
    }

    private var emptyReason: String {
        if model.manifest == nil {
            return "There is no manifest yet. Run the mapping engine, or open an exported bundle in the Mapping area."
        }
        if model.manifest?.report.counts.validated == model.manifest?.entries.count {
            return "FormaCore validated every entry in this revision."
        }
        return "No entry in this revision is held, unknown or invalidated."
    }

    private var filterPanel: some View {
        List {
            Section("Filter") {
                Picker("State", selection: $stateFilter) {
                    ForEach(StateFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .accessibilityIdentifier("exception-state-filter")
                Picker("Violation code", selection: $codeFilter) {
                    Text("All codes").tag(String?.none)
                    ForEach(codes, id: \.self) { code in
                        Text(code).tag(String?.some(code))
                    }
                }
                .accessibilityIdentifier("exception-code-filter")
                .disabled(codes.isEmpty)
                LabeledContent("Shown", value: "\(rows.count.formatted()) of \(model.exceptions.count.formatted())")
                LabeledContent("Selected", value: selection.count.formatted())
            }
            if let report = model.manifest?.report {
                Section("Revision counts") {
                    LabeledContent("Entries", value: report.counts.entries.formatted())
                    LabeledContent("Validated", value: report.counts.validated.formatted())
                    LabeledContent("Hold", value: report.counts.hold.formatted())
                    LabeledContent("Unknown", value: report.counts.unknown.formatted())
                    LabeledContent("Invalidated", value: report.counts.invalidated.formatted())
                    LabeledContent("Eligible", value: report.counts.eligible.formatted())
                    ForEach(report.groups, id: \.group) { group in
                        LabeledContent(group.group.rawValue,
                                       value: "\(group.status.rawValue) · \(group.violations.count.formatted())")
                    }
                }
            }
            Section("Reprocessing") {
                Text(model.allowCloud
                     ? "The next run may use cloud egress because consent is on in Settings."
                     : "Cloud egress is off, so FormaCore refuses every provider request and reports that reason per file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !selection.isEmpty {
                    LabeledContent("Files in scope", value: model.files(in: selection).count.formatted())
                }
                Text("A reprocessed run covers only the selected files, so this revision's manifest lists those entries.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Correction attempts") {
                if model.correctionHistory.isEmpty {
                    Text("No reviewer decision has been recorded for this manifest.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Refusals belong here as much as acceptances: a click FormaCore
                // ruled out still happened, and hiding it would leave the
                // revision history describing only the decisions that were right.
                ForEach(model.correctionHistory, id: \.id) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(record.field.rawValue) → \(record.correctedValue ?? "cleared")")
                            .font(.caption)
                        Text(record.reviewState == .rejected
                             ? "Refused by FormaCore · replaced \(record.previousValue ?? "nothing")"
                             : "Recorded at revision \(record.manifestRevision.formatted()) · replaced \(record.previousValue ?? "nothing")")
                            .font(.caption2)
                            .foregroundStyle(record.reviewState == .rejected ? .orange : .secondary)
                    }
                    .accessibilityIdentifier("correction-\(record.id)")
                }
            }
        }
    }

    private var rowTable: some View {
        Table(rows, selection: $selection) {
            TableColumn("Relative path") { row in
                Text(row.relativePath).lineLimit(1).help(row.relativePath)
            }
            TableColumn("State") { row in
                Text(row.state.rawValue)
            }
            .width(min: 90, ideal: 105)
            TableColumn("Reason") { row in
                Text(row.reason).lineLimit(1).help(row.reason)
            }
            .width(min: 150, ideal: 220)
            TableColumn("Codes") { row in
                Text(row.codeList).lineLimit(1).help(row.codeList)
            }
            TableColumn("Violations") { row in
                Text(row.violations.count.formatted()).monospacedDigit()
            }
            .width(min: 70, ideal: 80)
        }
    }

    @ViewBuilder private var detailPane: some View {
        if selected.count == 1, let row = selected.first {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(row.relativePath).font(.headline).textSelection(.enabled)
                    LabeledContent("Decision state", value: row.state.rawValue)
                    LabeledContent("Recorded reason", value: row.reason)
                    LabeledContent("Source identifier", value: row.sourceID.uuidString.lowercased())
                    if let entry = model.manifest?.entry(for: row.sourceID) {
                        LabeledContent("Snapshot", value: "revision \(entry.snapshotRevision.formatted()) · \(entry.snapshotFingerprint)")
                            .font(.caption)
                        ForEach(MetadataFieldID.allCases, id: \.self) { field in
                            if let outcome = entry.outcome(for: field), outcome.status != .evidenced {
                                LabeledContent(field.rawValue,
                                               value: outcome.value.map { "\(outcome.status.rawValue) · \($0)" }
                                                    ?? outcome.status.rawValue)
                            }
                        }
                    }
                    Divider()
                    Text("Violations").font(.subheadline)
                    if row.violations.isEmpty {
                        Text("FormaCore recorded no violation for this path.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(row.violations.indices, id: \.self) { index in
                            let violation = row.violations[index]
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(violation.code) · \(violation.instancePath)")
                                    .font(.caption.monospaced())
                                Text(violation.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
            }
        } else if selected.isEmpty {
            ContentUnavailableView("Select an exception", systemImage: "exclamationmark.triangle")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(selected.count.formatted()) files selected").font(.headline)
                    ForEach(selected) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.relativePath).font(.caption)
                            Text("\(row.state.rawValue) · \(row.reason)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
            }
        }
    }
}
