import FormaCore
import SwiftUI

/// The exceptions area inside the shell: the filter/diagnostic pane and the
/// blocked-entry table. Row details moved to `ExceptionsInspector`, the
/// reprocess commands and the per-run egress permission to the shell's toolbar
/// grammar. Rows still come from the same two sources the exporter uses: the
/// manifest's hold/unknown/invalidated entries and `ValidationReport.allViolations`
/// grouped by `instancePath`. Reprocessing hands FormaCore only the selected
/// source identifiers; the engine decides what to ask and the validator decides
/// the resulting state.
struct ExceptionsView: View {
    @ObservedObject var model: WorkspaceModel
    /// The width bounds the shell declared for this area's leading pane.
    let leading: AreaWidth

    /// The column budget the shell declared for the blocked-entry table.
    private var rowWidths: [ShellColumnWidth] { ShellLayout.columns(for: .exceptionRows) }

    /// The filter's code options and the filtered table.
    ///
    /// Both were computed here, which meant a flatMap over every violation of
    /// every blocked row plus a `Set` plus a sort, and a second full pass over
    /// the rows for the table, on *every body evaluation* - and the body reads
    /// `rows` three times (the table, the "Shown N of M" line and the
    /// reprocess count), so one render did the work three times. They are
    /// stored on the model now, rebuilt where the rows or the filters change,
    /// by the same rule `WorkspaceProjection.filteredExceptions` implements and
    /// `WorkspaceProjectionTests` pins.
    private var codes: [String] { model.exceptionCodes }
    private var rows: [ExceptionRow] { model.visibleExceptions }

    var body: some View {
        HSplitView {
            filterPanel
                .areaWidth(leading)
            if model.exceptions.isEmpty {
                ContentUnavailableView("No exceptions", systemImage: "checkmark.seal",
                                       description: Text(emptyReason))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                rowTable
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onChange(of: model.exceptionStateFilter) { _, _ in model.exceptionSelection.removeAll() }
        .onChange(of: model.exceptionCodeFilter) { _, _ in model.exceptionSelection.removeAll() }
    }

    private var emptyReason: String {
        guard let manifest = model.manifest else {
            return "还没有清单。运行映射引擎，或在「映射」区域打开一个已导出的包。"
        }
        // Both numbers come off one binding, so they describe the same manifest.
        if manifest.report.counts.validated == manifest.entries.count {
            return "FormaCore 已验证本版本的每一条记录。"
        }
        return "本版本没有待定、未知或已作废的记录。"
    }

    // MARK: - Filter pane

    private var filterPanel: some View {
        List {
            Section("Filter") {
                Picker("State", selection: $model.exceptionStateFilter) {
                    ForEach(ExceptionFilterState.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .accessibilityIdentifier("exception-state-filter")
                Picker("Violation code", selection: $model.exceptionCodeFilter) {
                    Text("全部原因").tag(String?.none)
                    ForEach(codes, id: \.self) { code in
                        // Business copy in the list, raw code in the help and in
                        // the row's 诊断 detail - never the other way round
                        // (owner failure #8).
                        Text(businessCopy(for: code).headline)
                            .help("\(businessCopy(for: code).sentence)\n\(code)")
                            .tag(String?.some(code))
                    }
                }
                .accessibilityIdentifier("exception-code-filter")
                .disabled(codes.isEmpty)
                LabeledContent("Shown", value: "\(rows.count.formatted()) of \(model.exceptions.count.formatted())")
                LabeledContent("Selected", value: model.exceptionSelection.count.formatted())
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
                        LabeledContent(businessCopy(for: group.group.rawValue).headline,
                                       value: "\(businessCopy(for: group.status.rawValue).headline) · \(group.violations.count.formatted())")
                            .help(businessCopy(for: group.group.rawValue).sentence)
                            .accessibilityIdentifier("diagnostic-raw-\(group.group.rawValue)")
                    }
                }
            }
            Section("Reprocessing") {
                // This describes what the toolbar control will do, so it reads
                // the same per-run flag the confirmation sets - not the
                // Settings-level one, which a different action may have set and
                // which this run ignores.
                Text(model.reprocessEgress
                     ? "本次运行已获外发许可；点击工具栏「外发许可」可立即关闭。"
                     : "外发许可关闭：FormaCore 会拒绝每个 Provider 请求，并逐文件记录原因。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.exceptionSelection.isEmpty {
                    LabeledContent("Files in scope", value: model.files(in: model.exceptionSelection).count.formatted())
                }
                Text("A reprocessed run covers only the selected files, so this revision's manifest lists those entries.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Table

    private var rowTable: some View {
        Table(rows, selection: $model.exceptionSelection) {
            TableColumn("Relative path") { row in
                Text(row.relativePath).lineLimit(1).help(row.relativePath)
            }
            .width(min: rowWidths[0].cgMin, ideal: rowWidths[0].cgIdeal, max: rowWidths[0].cgMax)
            TableColumn("State") { row in
                let copy = businessCopy(for: row.state.rawValue)
                Text(copy.headline)
                    .help(copy.sentence)
                    .accessibilityIdentifier("diagnostic-raw-\(row.state.rawValue)")
            }
            .width(min: rowWidths[1].cgMin, ideal: rowWidths[1].cgIdeal, max: rowWidths[1].cgMax)
            TableColumn("Reason") { row in
                Text(businessCopy(for: row.reason).headline)
                    .lineLimit(1)
                    .help(businessCopy(for: row.reason).sentence + "\n" + row.reason)
                    .accessibilityIdentifier("diagnostic-raw-\(row.reason)")
            }
            .width(min: rowWidths[2].cgMin, ideal: rowWidths[2].cgIdeal, max: rowWidths[2].cgMax)
            TableColumn("Codes") { row in
                Text(row.codes.map { businessCopy(for: $0).headline }.joined(separator: " · "))
                    .lineLimit(1)
                    .help(row.codes.map { "\(businessCopy(for: $0).headline)（\($0)）" }.joined(separator: " · "))
                    .accessibilityIdentifier("diagnostic-codes-\(row.sourceID.uuidString)")
            }
            .width(min: rowWidths[3].cgMin, ideal: rowWidths[3].cgIdeal, max: rowWidths[3].cgMax)
            TableColumn("Violations") { row in
                Text(row.violations.count.formatted()).monospacedDigit()
            }
            .width(min: rowWidths[4].cgMin, ideal: rowWidths[4].cgIdeal, max: rowWidths[4].cgMax)
        }
    }
}

/// The exceptions inspector: one blocked entry's recorded reasons and
/// violations, or the selected set. The raw codes FormaCore recorded stay in
/// the expandable 诊断 detail of each violation; everything above it speaks in
/// business sentences (owner failures #7 and #8).
@MainActor
struct ExceptionsInspector: View {
    @ObservedObject var model: WorkspaceModel

    private var selected: [ExceptionRow] {
        model.exceptions.filter { model.exceptionSelection.contains($0.sourceID) }
    }

    var body: some View {
        if selected.count == 1, let row = selected.first {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(row.relativePath).font(.headline).textSelection(.enabled)
                    let stateCopy = businessCopy(for: row.state.rawValue)
                    LabeledContent("Decision state", value: stateCopy.headline)
                        .help(stateCopy.sentence)
                    let reasonCopy = businessCopy(for: row.reason)
                    LabeledContent("Recorded reason", value: reasonCopy.headline)
                        .help(reasonCopy.sentence + "\n" + row.reason)
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
                            let copy = businessCopy(for: violation.code)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(copy.headline)
                                    .font(.caption)
                                Text(copy.sentence)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(violation.detail).font(.caption2).foregroundStyle(.secondary)
                                DisclosureGroup("诊断详情") {
                                    Text("\(copy.rawCode) · \(violation.instancePath)")
                                        .font(.caption2.monospaced())
                                        .textSelection(.enabled)
                                }
                                .font(.caption2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("diagnostic-raw-\(violation.code)-\(index)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
            }
        } else if selected.isEmpty {
            ContentUnavailableView("Select an exception", systemImage: "exclamationmark.triangle",
                                   description: Text("在「诊断」表格中选择一行。"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(selected.count.formatted()) files selected").font(.headline)
                    ForEach(selected) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.relativePath).font(.caption)
                            Text("\(businessCopy(for: row.state.rawValue).headline) · \(businessCopy(for: row.reason).headline)")
                                .font(.caption2).foregroundStyle(.secondary)
                                .help("\(row.state.rawValue) · \(row.reason)")
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
