import AppKit
import FormaCore
import SwiftUI

/// The default, task-oriented Alpha surface. The existing engineering areas
/// remain available for diagnostics; this view never invents model values or
/// bypasses the Core's evidence, revision, and import authorization contracts.
struct ReviewDeskView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var selectedFile: UUID?

    private var selectedRow: WorkspaceModel.MappingRow? {
        model.rows.first { $0.sourceID == selectedFile }
    }

    private var nextStep: String {
        if model.selectedScope == nil { return "先选择一个需要整理的资料目录" }
        if model.listing == nil { return "扫描资料，建立文件清单" }
        if model.context == nil || model.contextIsStale { return "建立项目上下文，识别文件归属" }
        if model.manifest == nil { return "生成本地审核草稿（不使用 AI、不发送文件）" }
        return "逐份确认字段及证据，最后预览归档位置"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                fileList
                    .frame(minWidth: 270, idealWidth: 360)
                ScrollView {
                    reviewDetail
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 410, idealWidth: 620)
            }
            if let plan = model.importPlan {
                Divider()
                planSummary(plan)
            }
        }
        .sheet(item: $model.draft) { draft in
            correctionSheet(draft)
        }
        .task(id: selectedFile) {
            if let selectedFile { await model.loadEvidence(for: selectedFile) }
        }
        .onChange(of: model.selectedScopeID) { _, _ in
            selectedFile = nil
        }
        .onChange(of: model.rows.count) { _, count in
            if count > 0 && (selectedFile == nil || !model.rows.contains(where: { $0.sourceID == selectedFile })) {
                selectedFile = model.rows.first?.sourceID
            }
        }
        .accessibilityIdentifier("area-review-desk")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("资料整理").font(.title2.bold())
                    Text(nextStep).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if let manifest = model.manifest {
                    Text("已验证 \(manifest.report.counts.validated) / \(manifest.entries.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Label("仅本地 · 不写入 DEVONthink", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                Picker("资料目录", selection: $model.selectedScopeID) {
                    Text("请选择").tag(Optional<UUID>.none)
                    ForEach(model.scopes) { scope in
                        Text(scope.displayName).tag(Optional(scope.id))
                    }
                }
                .frame(maxWidth: 230)
                .accessibilityIdentifier("review-source-picker")

                Button("添加目录…", systemImage: "folder.badge.plus", action: chooseSource)
                    .disabled(model.phase.isBusy)
                    .accessibilityIdentifier("review-add-source")

                Picker("资料库类型", selection: $model.selectedProfileID) {
                    Text("请选择").tag(Optional<String>.none)
                    ForEach(model.profiles, id: \.profileID) { profile in
                        Text(profile.displayName).tag(Optional(profile.profileID))
                    }
                }
                .frame(maxWidth: 205)
                .accessibilityIdentifier("review-profile-picker")

                Spacer(minLength: 6)
                Button("1 扫描") { model.scan() }
                    .disabled(model.phase.isBusy || model.selectedScope == nil)
                    .accessibilityIdentifier("review-scan")
                Button("2 识别项目") { model.buildContext() }
                    .disabled(model.phase.isBusy || model.listing == nil || model.selectedProfile == nil)
                    .accessibilityIdentifier("review-build-context")
                Button("3 开始审核") {
                    model.plannerMode = .offline
                    _ = model.runMapping(egress: false)
                }
                .disabled(!model.canMap)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("review-offline-map")
                Button("4 归档预览") { model.buildImportPlan() }
                    .disabled(model.manifest == nil || model.phase.isBusy)
                    .accessibilityIdentifier("review-build-plan")
            }
            if let notice = model.notice, !notice.isEmpty {
                Label(ReviewDeskLabels.feedback(notice),
                      systemImage: notice.contains("refused") ? "exclamationmark.triangle" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(notice.contains("refused") ? .orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("review-feedback")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("文件待办").font(.headline)
                Spacer()
                Text("\(model.rows.count) 份").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            if model.rows.isEmpty {
                ContentUnavailableView(
                    "尚无审核草稿",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("选择资料目录，依次扫描、识别项目并开始审核。离线模式不会猜测业务字段。")
                )
            } else {
                List(selection: $selectedFile) {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            Text((row.entry.relativePath as NSString).lastPathComponent)
                                .lineLimit(2)
                                .font(.body)
                            HStack(spacing: 8) {
                                Label(ReviewDeskLabels.state(row.entry.state.rawValue),
                                      systemImage: row.entry.state.rawValue == "validated"
                                        ? "checkmark.circle" : "circle.dotted")
                                    .font(.caption)
                                Spacer()
                                if let category = row.entry.metadata[.documentcategory] {
                                    Text(category).font(.caption2).lineLimit(1)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(row.sourceID)
                    }
                }
                .accessibilityIdentifier("review-file-list")
            }
        }
    }

    @ViewBuilder
    private var reviewDetail: some View {
        if let row = selectedRow {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text((row.entry.relativePath as NSString).lastPathComponent)
                        .font(.title3.bold())
                        .textSelection(.enabled)
                    Text(row.entry.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(ReviewDeskLabels.state(row.entry.state.rawValue))
                        .font(.subheadline)
                }

                GroupBox("业务字段 · 优先确认") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(primaryFields, id: \.self) { field in
                            fieldRow(row, field: field)
                            if field != primaryFields.last { Divider() }
                        }
                    }
                    .padding(7)
                }

                GroupBox("文档内容线索") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("以下是本地提取的证据摘录，不是完整文档预览。选取字段时请确认内容是否真实支持该判断。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let evidence = (model.evidenceBySource[row.sourceID] ?? [])
                            .filter { $0.isUsable && $0.source == .content }
                        if evidence.isEmpty {
                            Text("暂无可引用的正文片段；请检查文件是否已读取、是否为受保护或未下载的文件。")
                                .font(.callout)
                        } else {
                            ForEach(Array(evidence.prefix(5)), id: \.id) { record in
                                Text(record.excerpt ?? "")
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                        }
                    }
                    .padding(7)
                }

                DisclosureGroup("其他业务字段与技术详情") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(MetadataFieldID.allCases.filter { !primaryFields.contains($0) }, id: \.self) { field in
                            fieldRow(row, field: field)
                            Divider()
                        }
                        Text("诊断页面仍保留完整 Manifest、证据 ID、修订历史与验证组。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
        } else {
            ContentUnavailableView(
                model.rows.isEmpty ? "先生成审核草稿" : "选择一份文件",
                systemImage: "doc.text",
                description: Text("选择左侧文件，查看字段、正文线索和审核操作。")
            )
        }
    }

    private var primaryFields: [MetadataFieldID] {
        model.selectedProfile?.profileID == "project-archive"
            ? [.projectname, .completionyear, .documentcategory]
            : [.documentcategory, .documenttype, .issuer]
    }

    private func fieldRow(_ row: WorkspaceModel.MappingRow, field: MetadataFieldID) -> some View {
        let outcome = row.entry.outcome(for: field)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(ReviewDeskLabels.field(field)).font(.subheadline.weight(.medium))
                if model.selectedProfile?.fields[field]?.requiredForValidated == true {
                    Text("必填").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Button("修改") { model.beginCorrection(sourceID: row.sourceID, field: field) }
                    .buttonStyle(.link)
                    .disabled(model.phase.isBusy)
                    .accessibilityIdentifier("review-edit-\(field.rawValue)")
            }
            Text(outcome?.value ?? "尚未确认")
                .foregroundStyle(outcome?.value == nil ? .secondary : .primary)
                .textSelection(.enabled)
            if let outcome, !outcome.evidenceIDs.isEmpty {
                Text("已关联 \(outcome.evidenceIDs.count) 条证据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func correctionSheet(_ draft: WorkspaceModel.CorrectionDraft) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("确认\(ReviewDeskLabels.field(draft.field))")
                .font(.title3.bold())
            if let policy = model.selectedProfile?.fields[draft.field] {
                Text(policy.rule)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if draft.field == .documentcategory {
                Picker("文件分类", selection: Binding(
                    get: { model.draft?.value ?? "" },
                    set: { model.draft?.value = $0 }
                )) {
                    Text("请选择分类").tag("")
                    ForEach(model.selectedProfile?.categories ?? [], id: \.identifier) { category in
                        Text(category.identifier).tag(category.identifier)
                    }
                }
                .accessibilityIdentifier("review-category-select")
            } else {
                TextField("字段内容", text: Binding(
                    get: { model.draft?.value ?? "" },
                    set: { model.draft?.value = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("review-correction-value")
            }

            Text("选择支持上述判断的来源内容")
                .font(.subheadline.weight(.medium))
            Text("只选择实际包含相关事实的证据。来源目录、文件名、正文的证明力不同；系统仍会按 Profile 规则复核。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.evidenceBySource[draft.sourceID] ?? [], id: \.id) { record in
                        Toggle(isOn: Binding(
                            get: { model.draft?.citations.contains(record.id) ?? false },
                            set: { on in
                                if on { model.draft?.citations.insert(record.id) }
                                else { model.draft?.citations.remove(record.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ReviewDeskLabels.evidence(record.source.rawValue))
                                    .font(.caption.weight(.semibold))
                                Text(record.excerpt ?? "内容无法读取")
                                    .font(.callout)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!record.isUsable)
                    }
                }
            }
            if draft.value.isEmpty == false && draft.citations.isEmpty {
                Label("请至少选择一条有效证据，否则系统会拒绝保存。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let notice = model.notice, notice.contains("FormaCore refused this correction:") {
                Label(ReviewDeskLabels.feedback(notice),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("review-correction-error")
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { model.cancelCorrection() }
                if model.recordingDraftID == draft.id {
                    ProgressView("正在验证…")
                        .controlSize(.small)
                } else {
                    Button("验证并保存") { model.applyCorrection() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.phase.isBusy)
                        .accessibilityIdentifier("review-save-correction")
                }
            }
        }
        .padding(20)
        .frame(width: 570, height: 520)
    }

    private func planSummary(_ plan: ImportPlan) -> some View {
        DisclosureGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.rows, id: \.sourceID) { row in
                        HStack(alignment: .top, spacing: 12) {
                            Text((row.relativePath as NSString).lastPathComponent)
                                .frame(maxWidth: 250, alignment: .leading)
                            Text(row.groupPath.isEmpty
                                 ? "归档位置尚未确定"
                                 : row.groupPath.joined(separator: " / "))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.codes.map(\.rawValue).joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxHeight: 150)
        } label: {
            HStack(spacing: 8) {
                Label("归档预览 · 不会执行写入", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                Text("\(plan.rows.count) 份文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("展开查看每份文件的目标目录与阻断原因")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
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

private enum ReviewDeskLabels {
    static func field(_ field: MetadataFieldID) -> String {
        switch field.rawValue {
        case "projectname": "项目名称"
        case "completionyear": "归档完成年份"
        case "documentcategory": "文件分类"
        case "documenttype": "文件类型"
        case "bidderentity": "投标主体"
        case "endcustomer": "最终客户"
        case "issuer": "出具单位"
        case "department": "部门"
        case "salesowner": "业务负责人"
        case "biddeadline": "投标截止日期"
        case "tenderreference": "招标编号"
        case "bsdcode": "内部 BSD 编码"
        default: field.rawValue
        }
    }

    static func state(_ raw: String) -> String {
        switch raw {
        case "validated": "已验证"
        case "hold": "信息待补充"
        case "unknown", "mapped": "待审核"
        case "invalidated": "来源已变更"
        default: raw
        }
    }

    static func evidence(_ source: String) -> String {
        switch source {
        case "content": "正文摘录"
        case "path": "来源目录"
        case "filename": "文件名"
        case "fs_metadata": "文件属性"
        case "sibling": "同项目文件"
        case "mcp": "只读历史记录"
        default: source
        }
    }

    static func feedback(_ message: String) -> String {
        if message.contains("evidence_not_found") {
            return "修正未保存：引用的证据不存在、不可用或与当前文件版本不一致。这是 Alpha 已知问题，不应反复扫描来绕过。"
        }
        if message.contains("insufficient_evidence") {
            return "修正未保存：所选来源线索不足以独立证明这个字段，请选择实际支持该事实的正文证据。"
        }
        if message.contains("quote_mismatch") {
            return "修正未保存：选中的证据摘录无法对应填写内容，请核对原文。"
        }
        if message.contains("sourceChanged") {
            return "文件已变化，旧审核不能继续使用。请检查来源并重新建立当前草稿。"
        }
        return message
    }
}