import AppKit
import FormaCore
import SwiftUI

/// The business Review Desk (#144), living inside the unified shell from #157:
/// one routed area, one page plus the shell inspector, guided by
/// `ReviewDeskFlow` on the Core side. It is not a window of its own and adds
/// no second navigation: the source, scan, context, mapping, plan and export
/// actions it starts are the very calls the engineering areas make, and the
/// legacy areas stay reachable as 高级/诊断 routes.
///
/// The default answerer is the AI semantic path (#148). The deterministic
/// Offline Planner appears exactly once, as the labelled 手动草稿（非 AI 理解）
/// fallback; it is never framed as a result. No egress happens without the
/// confirmation dialog: the desk calls `runMapping(egress:)` with `true` only
/// inside the dialog's confirm action. Field values, citations and revisions
/// remain FormaCore's alone; this page only reads them and asks.
struct ReviewDeskView: View {
    @ObservedObject var model: WorkspaceModel
    /// Jumps to another shell area (the desk never restyles the sidebar).
    let selectArea: (AppArea) -> Void
    /// Opens the shell's export folder panel: the desk reuses it instead of
    /// carrying a second export path.
    let openExport: () -> Void

    /// The egress confirmation before an AI run (state matrix row 3).
    @State private var aiConsentPresented = false
    /// The last refusal FormaCore published for this desk session: the field
    /// it concerned and its codes, so the cause can sit beside the field
    /// rather than in a sidebar. Cleared when a revision is published or a
    /// different field is opened.
    @State private var refusal: Refusal?

    /// A published refusal, remembered for inline display.
    private struct Refusal: Equatable {
        let field: MetadataFieldID
        let codes: [String]
    }

    // MARK: - Flow facts

    private var inputs: ReviewDeskFlow.Inputs {
        ReviewDeskFlow.Inputs(
            hasScope: model.selectedScope != nil,
            hasProfile: model.selectedProfile != nil,
            hasListing: model.listing != nil,
            hasContext: model.context != nil && !model.contextIsStale,
            hasManifest: model.manifest != nil,
            hasPlan: model.importPlan != nil,
            isBusy: model.phase.isBusy,
            hasInvalidatedFiles: model.rows.contains { $0.entry.state == .invalidated })
    }

    private var flow: ReviewDeskFlow { ReviewDeskFlow.evaluate(inputs) }

    private var selectedRow: WorkspaceModel.MappingRow? {
        model.deskQueue.first { $0.sourceID == model.deskFileSelection }
            ?? model.rows.first { $0.sourceID == model.deskFileSelection }
    }

    var body: some View {
        VStack(spacing: 0) {
            stagePanel
            Divider()
            HSplitView {
                queue
                    .frame(minWidth: CGFloat(ShellLayout.deskQueue.min),
                           idealWidth: CGFloat(ShellLayout.deskQueue.ideal),
                           maxWidth: CGFloat(ShellLayout.deskQueue.max))
                ScrollView {
                    detail
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: CGFloat(ShellLayout.deskDetail.min),
                       idealWidth: CGFloat(ShellLayout.deskDetail.ideal),
                       maxWidth: CGFloat(ShellLayout.deskDetail.max))
            }
        }
        .confirmationDialog(EgressConsent.confirmationHeading,
                            isPresented: $aiConsentPresented, titleVisibility: .visible) {
            Button(EgressConsent.confirmAction) { startAIUnderstanding() }
            Button(EgressConsent.cancelAction, role: .cancel) {}
        } message: {
            VStack(alignment: .leading, spacing: 4) {
                Text("本次运行将发送（Provider：\(model.provider.displayName) · 模型：\(model.modelID)）：")
                    .font(.caption.weight(.medium))
                ForEach(Array(EgressConsent.whatLeavesLines.enumerated()), id: \.offset) { _, line in
                    Text("· \(line)").font(.caption)
                }
                Text(EgressConsent.whatStaysLine).font(.caption).foregroundStyle(.secondary)
                Text(EgressConsent.defaultOffNote).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: model.deskFileSelection) {
            if let selection = model.deskFileSelection {
                await model.loadEvidence(for: selection)
            }
        }
        .onChange(of: model.selectedScopeID) { _, _ in
            model.deskFileSelection = nil
            model.deskBaselineRevision = nil
            refusal = nil
        }
        .onChange(of: model.deskTriage) { _, _ in
            // A filter change keeps the cursor if the file stays visible,
            // otherwise parks on the first row of the new bucket.
            if let selection = model.deskFileSelection,
               !model.deskQueue.contains(where: { $0.sourceID == selection }) {
                model.deskFileSelection = model.deskQueue.first?.sourceID
            }
        }
        .onChange(of: model.rows.count) { _, _ in
            if model.deskFileSelection == nil {
                model.deskFileSelection = model.deskQueue.first?.sourceID
            }
        }
        .onChange(of: model.manifest?.envelope.revision) { _, revision in
            // Save & Next advances ONLY across a revision FormaCore published.
            guard ReviewDeskFlow.advances(baselineRevision: model.deskBaselineRevision,
                                          currentRevision: revision) else { return }
            model.deskBaselineRevision = nil
            refusal = nil
            advanceCursor()
        }
        .onChange(of: model.lastRefusalCodes) { _, codes in
            if !codes.isEmpty, let field = model.draft?.field {
                refusal = Refusal(field: field, codes: codes)
            } else if codes.isEmpty {
                // Any other outcome supersedes the remembered refusal: the
                // cause beside the field is a statement about the last click,
                // not a permanent banner.
                refusal = nil
            }
        }
        .accessibilityIdentifier("area-review-desk")
    }

    // MARK: - Stage panel

    private var stagePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                stageIndicator
                Spacer(minLength: 8)
                providerStatus
            }
            sourceRow
            actionRow
            if !flow.guidance.isEmpty {
                Text(flow.guidance)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("desk-guidance")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var stageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(DeskStage.allCases, id: \.self) { stage in
                let position = DeskStage.allCases.firstIndex(of: stage) ?? 0
                let current = DeskStage.allCases.firstIndex(of: flow.stage) ?? 0
                Label("\(stage.number) · \(stage.title)",
                      systemImage: position < current ? "checkmark.circle.fill"
                                  : position == current ? "smallcircle.filled.circle" : "circle")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(position == current ? .semibold : .regular))
                    .foregroundStyle(position <= current ? .primary : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(position == current ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: Capsule())
                    .accessibilityIdentifier("desk-stage-\(stage.rawValue)")
            }
        }
    }

    /// The provider/consent line the state matrix demands before an AI run:
    /// honest about what the desk knows, without pretending a result exists.
    private var providerStatus: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Label("\(model.provider.displayName) · \(model.modelID)", systemImage: "sparkles")
                .font(.caption.weight(.medium))
            Text("外发许可：逐次确认 · 默认关闭")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("desk-provider-status")
    }

    private var sourceRow: some View {
        HStack(spacing: 9) {
            Picker("资料目录", selection: $model.selectedScopeID) {
                Text(ShellProfilePicker.placeholder).tag(Optional<UUID>.none)
                ForEach(model.scopes) { scope in
                    Text(scope.displayName).tag(Optional(scope.id))
                }
            }
            .frame(maxWidth: 230)
            .fixedSize()
            .accessibilityIdentifier("desk-source-picker")

            Button("添加目录…", systemImage: "folder.badge.plus") { perform(.addSource) }
                .disabled(model.phase.isBusy)
                .accessibilityIdentifier("desk-add-source")

            Picker("资料库类型", selection: $model.selectedProfileID) {
                Text(ShellProfilePicker.placeholder).tag(Optional<String>.none)
                ForEach(model.profiles, id: \.profileID) { profile in
                    Text(profile.displayName).tag(Optional(profile.profileID))
                }
            }
            .frame(maxWidth: 210)
            .fixedSize()
            .disabled(!ShellProfilePicker.isEnabled(optionCount: model.profiles.count))
            .help(ShellProfilePicker.label(selected: model.profiles.contains(where: { $0.profileID == model.selectedProfileID })
                                           ? model.selectedProfileID : nil,
                                           options: model.profiles.map { ($0.profileID, $0.displayName) }))
            .accessibilityIdentifier("desk-profile-picker")

            Spacer(minLength: 6)

            Text(flow.next == .cancel ? flow.stage.title : "下一步")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 9) {
            Button {
                perform(flow.next)
            } label: {
                Label(flow.next.title, systemImage: flow.next.systemImage)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canRun(flow.next))
            .accessibilityIdentifier("desk-next-action")

            // The fallback stays adjacent to the AI default only at the stage
            // where the choice is real; the label says what it is not.
            if flow.stage == .aiUnderstanding {
                Button(DeskAction.manualDraft.title) { perform(.manualDraft) }
                    .disabled(!canRun(.manualDraft) || flow.next == .cancel)
                    .help(DeskGuidance.manualDraftNotice)
                    .accessibilityIdentifier("desk-manual-draft")
                Text(DeskGuidance.keyMissingHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if flow.stage == .archivePreview || model.importPlan != nil {
                Button(DeskAction.exportBundle.title, systemImage: DeskAction.exportBundle.systemImage) {
                    perform(.exportBundle)
                }
                .disabled(model.manifest == nil || model.phase.isBusy)
                .accessibilityIdentifier("desk-export")
            }
            Spacer()
            // The run's own notice lives in the shell status strip; the desk
            // shows only business framing here, so the last refusal beside
            // the field and the stage guidance never compete with English
            // diagnostics on a first-time page.
        }
    }

    // MARK: - Queue

    private var queue: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("文件待办").font(.headline)
                Spacer()
                Picker("", selection: $model.deskTriage) {
                    ForEach(DeskTriage.allCases, id: \.self) { bucket in
                        Text(bucket.title).tag(bucket)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("desk-triage-filter")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            if model.deskQueue.isEmpty {
                ContentUnavailableView(
                    model.rows.isEmpty ? "审核队列还没有文件" : "此筛选下没有文件",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(model.rows.isEmpty
                                       ? "按上方步骤依次进行：选择目录、扫描、识别项目，然后开始 AI 理解。"
                                       : "切换筛选可查看待处理、已验证或需关注的文件。"))
            } else {
                List(selection: Binding(
                    get: { model.deskFileSelection },
                    set: { model.deskFileSelection = $0; refusal = nil }
                )) {
                    ForEach(model.deskQueue) { row in
                        queueRow(row)
                            .tag(row.sourceID)
                    }
                }
                .accessibilityIdentifier("desk-file-list")
            }
        }
    }

    private func queueRow(_ row: WorkspaceModel.MappingRow) -> some View {
        let chip = deskChip(for: row.entry.state)
        return VStack(alignment: .leading, spacing: 5) {
            Text((row.entry.relativePath as NSString).lastPathComponent)
                .lineLimit(2)
                .font(.body)
            HStack(spacing: 8) {
                Label(chip.title, systemImage: chip.systemImage)
                    .font(.caption)
                    .foregroundStyle(chip == .validated ? .green : chip == .sourceChanged ? .orange : .secondary)
                Spacer()
                if let category = row.entry.metadata[.documentcategory] {
                    Text(category).font(.caption2).lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("desk-file-\(row.sourceID.uuidString)")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let row = selectedRow {
            VStack(alignment: .leading, spacing: 18) {
                header(row)
                fieldsCard(row)
                evidenceCard(row)
                if model.importPlan != nil {
                    planCard
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
        } else if model.rows.isEmpty {
            ContentUnavailableView(
                flow.stage.title,
                systemImage: "checklist",
                description: Text(flow.guidance))
        } else {
            ContentUnavailableView(
                "选择一份文件",
                systemImage: "doc.text",
                description: Text("从左侧队列选择文件，查看业务字段与证据摘录。"))
        }
    }

    private func header(_ row: WorkspaceModel.MappingRow) -> some View {
        let chip = deskChip(for: row.entry.state)
        return VStack(alignment: .leading, spacing: 5) {
            Text((row.entry.relativePath as NSString).lastPathComponent)
                .font(.title3.bold())
                .textSelection(.enabled)
            Text(row.entry.relativePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Label(chip.title, systemImage: chip.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(chip == .validated ? .green : chip == .sourceChanged ? .orange : .secondary)
                if row.entry.state == .invalidated, let reason = row.entry.invalidatedReason {
                    Text(businessCopy(for: reason).sentence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = row.failure {
                    Text("Provider 侧失败：\(error.localizedDescription) · \(DeskGuidance.providerError)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("desk-provider-failure")
                }
            }
        }
    }

    // MARK: Fields

    private var primaryFields: [MetadataFieldID] {
        model.selectedProfile?.profileID == ProjectArchiveContract.id
            ? [.projectname, .completionyear, .documentcategory]
            : [.documentcategory, .documenttype, .issuer]
    }

    private func fieldsCard(_ row: WorkspaceModel.MappingRow) -> some View {
        GroupBox("业务字段 · 优先确认") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(primaryFields, id: \.self) { field in
                    fieldRow(row, field: field)
                    if field != primaryFields.last { Divider() }
                }
                DisclosureGroup("其他业务字段") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(MetadataFieldID.allCases.filter { !primaryFields.contains($0) }, id: \.self) { field in
                            fieldRow(row, field: field)
                            Divider()
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(7)
        }
    }

    private func fieldRow(_ row: WorkspaceModel.MappingRow, field: MetadataFieldID) -> some View {
        let outcome = row.entry.outcome(for: field)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metadataFieldLabel(field)).font(.subheadline.weight(.medium))
                if model.selectedProfile?.fields[field]?.requiredForValidated == true {
                    Text("必填").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Button("修改") { beginCorrection(row, field: field) }
                    .buttonStyle(.link)
                    .disabled(model.phase.isBusy)
                    .accessibilityIdentifier("desk-edit-\(field.rawValue)")
            }
            Text(outcome?.value ?? "尚未确认")
                .foregroundStyle(outcome?.value == nil ? .secondary : .primary)
                .textSelection(.enabled)
            if let outcome, !outcome.evidenceIDs.isEmpty {
                Text("已关联 \(outcome.evidenceIDs.count) 条证据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The actionable cause sits beside the field it concerns; the raw
            // codes stay one disclosure down, per #144 P0.
            if let refusal, refusal.field == field {
                ForEach(refusal.codes, id: \.self) { code in
                    Label(deskRefusalSentence(forCode: code), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("desk-refusal-\(field.rawValue)-\(code)")
                }
                DisclosureGroup("诊断详情") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(refusal.codes, id: \.self) { code in
                            Text("FormaCore 代码：\(code)")
                                .font(.caption.monospaced())
                        }
                        Text("完整原因码与证据 ID 在右侧检查器可见；向支持人员报告时请附上它们。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 6)
                }
                .font(.caption)
            }
        }
    }

    // MARK: Evidence

    private func evidenceCard(_ row: WorkspaceModel.MappingRow) -> some View {
        let records = (model.evidenceBySource[row.sourceID] ?? []).filter { $0.isUsable }
        let expired = records.filter { model.currency(of: $0, for: row.sourceID) == .expired }
        return GroupBox("证据摘录 · 按来源分组") {
            VStack(alignment: .leading, spacing: 8) {
                Text("以下是本地提取的证据摘录，不是完整文档预览；选择字段时请确认内容确实支持该判断。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !expired.isEmpty {
                    expiredEvidenceNotice(row: row, count: expired.count)
                }
                if records.isEmpty {
                    Text("暂无可引用的证据行；请检查文件是否已扫描、是否可读或为未下载的云端占位。")
                        .font(.callout)
                } else {
                    ForEach(evidenceGroups(records), id: \.key) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.key).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(group.rows.prefix(4), id: \.id) { record in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(deskEvidenceLocatorLabel(record.locator))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 132, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.excerpt ?? "")
                                            .font(.callout)
                                            .lineLimit(3)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        // A row read from an older snapshot is
                                        // marked as such. The reviewer has to
                                        // see that it no longer describes the
                                        // file in front of them.
                                        if model.currency(of: record, for: row.sourceID) == .expired {
                                            Text(EvidenceCurrencyCopy.expiredBadge)
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(7)
        }
    }

    /// The recovery the reviewer gets when the rows on screen describe an
    /// older snapshot: read the file again, and cite what that read produced.
    private func expiredEvidenceNotice(row: WorkspaceModel.MappingRow, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(EvidenceCurrencyCopy.expiredSentence)（\(count.formatted()) 行）",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(EvidenceCurrencyCopy.rereadHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(EvidenceCurrencyCopy.rereadAction) { model.rereadEvidence(for: row.sourceID) }
                .controlSize(.small)
                .disabled(model.phase.isBusy)
                .accessibilityIdentifier("reread-evidence")
        }
        .accessibilityIdentifier("evidence-expired-notice")
    }

    /// Groups rows by the provenance label the reviewer reads (文件名/来源目录/
    /// 正文摘录/…). Opaque registry ids are deliberately absent here; they are
    /// recorded under the hood by the correction flow and surfaced in 诊断详情.
    private struct EvidenceGroup {
        let key: String
        let rows: [EvidenceRecord]
    }

    private func evidenceGroups(_ records: [EvidenceRecord]) -> [EvidenceGroup] {
        let order: [EvidenceSource] = [.filename, .path, .content, .sibling, .fsMetadata, .mcp]
        var seen: [String] = []
        var buckets: [String: [EvidenceRecord]] = [:]
        for record in records {
            let key = deskEvidenceSourceLabel(record.source)
            if buckets[key] == nil { seen.append(key) }
            buckets[key, default: []].append(record)
        }
        return seen.map { key in EvidenceGroup(key: key, rows: buckets[key] ?? []) }
            .sorted { lhs, rhs in
                let li = order.firstIndex(where: { deskEvidenceSourceLabel($0) == lhs.key }) ?? 99
                let ri = order.firstIndex(where: { deskEvidenceSourceLabel($0) == rhs.key }) ?? 99
                return li < ri
            }
    }

    // MARK: Archive preview

    private var planCard: some View {
        guard let plan = model.importPlan else {
            return AnyView(EmptyView())
        }
        return AnyView(GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(plan.rows.count) 份文件 · 通过 \(plan.passes) · 受阻 \(plan.blocked) · 暂缓 \(plan.deferred)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(plan.rows.prefix(12), id: \.sourceID) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Text((row.relativePath as NSString).lastPathComponent)
                            .frame(maxWidth: 210, alignment: .leading)
                        Text(deskPlanTargetLine(databaseName: row.databaseName, groupPath: row.groupPath))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.codes.map { businessCopy(for: $0.rawValue).headline }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 220, alignment: .trailing)
                    }
                    .font(.caption)
                }
                Text(DeskGuidance.dryRunOnly)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .padding(7)
        } label: {
            Label("归档预览 · 不会执行写入", systemImage: "doc.text.magnifyingglass")
                .font(.subheadline.weight(.semibold))
        }.accessibilityIdentifier("desk-plan-card"))
    }

    // MARK: - Actions

    private func canRun(_ action: DeskAction) -> Bool {
        if model.phase.isBusy { return action == .cancel }
        switch action {
        case .chooseSource, .addSource: return true
        case .configureProfile: return !model.profiles.isEmpty
        case .scan: return model.selectedScope != nil
        case .buildContext: return model.listing != nil && model.selectedProfile != nil
        case .aiUnderstanding: return model.canMap
        case .manualDraft: return model.canMap
        case .reviewFiles: return !model.deskQueue.isEmpty
        case .buildPlan: return model.manifest != nil
        case .exportBundle: return model.manifest != nil
        case .openSettings: return true
        case .cancel: return false
        }
    }

    private func perform(_ action: DeskAction) {
        switch action {
        case .chooseSource, .addSource: chooseSource()
        case .configureProfile:
            // The picker is in the header row; focus the window's own control
            // by doing nothing else - inventing a second picker would.
            break
        case .scan: model.scan()
        case .buildContext: model.buildContext()
        case .aiUnderstanding:
            // Explicit disclosure BEFORE any AI run; nothing is dispatched
            // until the dialog's confirm action calls startAIUnderstanding().
            aiConsentPresented = true
        case .manualDraft: performManualDraft()
        case .reviewFiles:
            model.deskFileSelection = model.deskQueue.first?.sourceID
        case .buildPlan: model.buildImportPlan()
        case .exportBundle: openExport()
        case .openSettings: selectArea(.settings)
        case .cancel: model.cancelWork()
        }
    }

    /// Confirm-action of the egress dialog: consent was given for THIS run,
    /// the AI answerer is chosen, and `egress: true` goes to FormaCore, whose
    /// own gate re-checks the authorization per request.
    private func startAIUnderstanding() {
        model.plannerMode = .ai
        _ = model.runMapping(sourceIDs: nil, egress: true)
    }

    /// The explicitly labelled fallback: the deterministic planner, framed as
    /// a draft, never as intelligence or success (#148).
    private func performManualDraft() {
        model.plannerMode = .offline
        _ = model.runMapping(sourceIDs: nil, egress: false)
    }

    /// Opens the shell's shared correction sheet, arming the Save & Next gate
    /// at the revision currently on screen.
    private func beginCorrection(_ row: WorkspaceModel.MappingRow, field: MetadataFieldID) {
        model.deskBaselineRevision = model.manifest?.envelope.revision
        refusal = nil
        model.beginCorrection(sourceID: row.sourceID, field: field)
    }

    private func advanceCursor() {
        let order = model.deskQueue.map(\.sourceID)
        guard let current = model.deskFileSelection else {
            model.deskFileSelection = order.first
            return
        }
        guard let next = ReviewDeskFlow.nextAfter(current.uuidString, in: order.map(\.uuidString)),
              let uuid = UUID(uuidString: next) else {
            // The bucket is exhausted. If another file remains, start from
            // it; if nothing is left, the just-published file stays selected
            // - a cleared cursor would read as "lost the review".
            if let first = order.first { model.deskFileSelection = first }
            return
        }
        model.deskFileSelection = uuid
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "选择要整理的资料文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await model.register(url) }
        }
    }
}

/// The desk's inspector slot in the shell: the expert diagnostics for the
/// file being reviewed - revisions, digests, raw evidence ids, run facts and
/// the reviewer's own correction history. Everything the desk page hides as
/// opaque identifiers stays here, addressable and verbatim, because support
/// reports need the exact codes.
@MainActor
struct ReviewDeskInspector: View {
    @ObservedObject var model: WorkspaceModel

    private var row: WorkspaceModel.MappingRow? {
        guard let selection = model.deskFileSelection else { return nil }
        return model.rows.first { $0.sourceID == selection }
    }

    var body: some View {
        Group {
            if let manifest = model.manifest {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("诊断详情").font(.headline)
                        Text("修订 \(manifest.envelope.revision) · 清单 \(manifest.envelope.manifestID.uuidString.prefix(8))…")
                            .font(.caption.monospaced())
                        if let row {
                            entryFacts(row)
                            fieldFacts(row)
                            evidenceFacts(row)
                            correctionFacts(row)
                        } else {
                            Text("在「资料整理」队列中选择文件后，这里显示其原始修订、证据 ID 与验证细节。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("尚无修订可检视", systemImage: "sidebar.right",
                                       description: Text("完成 AI 理解或手动草稿后，这里显示逐文件的诊断详情。"))
            }
        }
        .accessibilityIdentifier("desk-inspector")
    }

    private func entryFacts(_ row: WorkspaceModel.MappingRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("快照修订 \(row.entry.snapshotRevision) · 指纹 \(row.entry.snapshotFingerprint.prefix(12))…")
                .font(.caption.monospaced())
            Text("状态 \(row.entry.state.rawValue) · \(businessCopy(for: row.entry.state.rawValue).sentence)")
                .font(.caption)
            if let reason = row.entry.invalidatedReason {
                Text("作废原因 \(reason) · \(businessCopy(for: reason).headline)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let outcome = model.outcome {
                Text("本次运行：\(outcome.batches) 批 · \(outcome.requests) 请求 · 拒绝引用 \(outcome.refusedReferences)")
                    .font(.caption.monospaced())
            }
        }
    }

    private func fieldFacts(_ row: WorkspaceModel.MappingRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("字段与引用 ID").font(.caption.weight(.semibold))
            ForEach(row.entry.fields, id: \.field) { outcome in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(metadataFieldLabel(outcome.field))（\(outcome.field.rawValue)）· \(outcome.status.rawValue)")
                        .font(.caption2)
                    if !outcome.evidenceIDs.isEmpty {
                        Text(outcome.evidenceIDs.joined(separator: " "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if !outcome.conflicts.isEmpty {
                        Text("冲突：\(outcome.conflicts.map { businessCopy(for: $0).headline }.joined(separator: " · "))")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func evidenceFacts(_ row: WorkspaceModel.MappingRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("登记证据行").font(.caption.weight(.semibold))
            ForEach(model.evidenceBySource[row.sourceID] ?? [], id: \.id) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.id).font(.caption2.monospaced())
                    Text("\(deskEvidenceSourceLabel(record.source)) · \(deskEvidenceLocatorLabel(record.locator)) · \(record.extractionStatus.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func correctionFacts(_ row: WorkspaceModel.MappingRow) -> some View {
        let mine = model.correctionHistory.filter { $0.sourceID == row.sourceID }
        return VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("修正记录").font(.caption.weight(.semibold))
            Text(historyNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(mine, id: \.id) { record in
                HStack(spacing: 6) {
                    Text(record.reviewState.rawValue)
                        .font(.caption2.monospaced())
                        .foregroundStyle(record.reviewState == .rejected ? .orange : .secondary)
                    Text("\(metadataFieldLabel(record.field)) → \(record.correctedValue ?? "清空")")
                        .font(.caption2)
                    Text("发布修订 \(record.producedRevision.map { "\($0)" } ?? "无")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var historyNote: String {
        switch model.correctionHistoryState {
        case .notRead: "尚未读取本机修正历史。"
        case .fromStore: "以下为本机存储的全部修正尝试。"
        case .offlineBundle: "该清单来自导出包：尝试历史在导出方的机器上，本机无法读取。"
        case .readFailed: "修正历史读取失败，下面仅显示最近一次操作。"
        }
    }
}
