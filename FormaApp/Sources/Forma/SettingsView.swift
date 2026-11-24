import FormaCore
import SwiftUI

/// The settings area: which provider may be asked, what would actually leave the
/// machine, how paths and text are redacted first, what the DEVONthink
/// connection advertises, and which CasePack a run would use.
///
/// The preview is the whole point of this screen: what `previewEgress` shows is
/// the system text, payload and digest of the *first* batch the engine's own
/// planner would build from the registered evidence - not a receipt for the
/// bytes a run sends, because a run re-reads file bodies before dispatch. It is
/// shown before any consent is given and before anything is sent. Nothing here
/// simulates a result: an absent key, a missing context or a blocked MCP query
/// is reported with FormaCore's own reason.
struct SettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var key = ""
    @State private var keySaved = false

    /// The preview pane shows this many bytes of the payload and says so; the
    /// byte count and digest always describe the whole request.
    private static let previewCharacters = 4_000

    var body: some View {
        Form {
            providerSection
            egressSection
            previewSection
            redactionSection
            mcpSection
            casePackSection
            profileSection
            storageSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Provider

    private var providerSection: some View {
        Section("服务商") {
            Picker("服务商", selection: Binding(get: { model.provider }, set: { model.selectProvider($0) })) {
                ForEach(ProbeProvider.networkCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .disabled(model.phase.isBusy)
            .accessibilityIdentifier("mapping-provider")
            TextField("模型 ID", text: $model.modelID)
                .accessibilityIdentifier("mapping-model")
            if model.provider.requiresConfiguredEndpoint {
                TextField("Base URL（例如 http://127.0.0.1:11434/v1）", text: $model.customBaseURL)
                    .accessibilityIdentifier("mapping-base-url")
                Text("发送目标始终是这个地址：Forma 只向此处填写的完整 URL 发送请求，重定向一律拒绝。https 用于公网，http 仅允许 127.x、localhost 或 [::1] 回环。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("每批请求文件数", value: $model.entryLimit, format: .number)
                .accessibilityIdentifier("mapping-entry-limit")
            SecureField("\(model.provider.displayName) 的 API 密钥", text: $key)
            Button("保存 API 密钥到钥匙串") {
                // The Keychain write left the main actor (#151 audit item 4),
                // so the answer arrives on a later turn: the field's "saved"
                // mark means the write returned successfully, not that the
                // click happened.
                Task { keySaved = await model.saveKey(key) }
            }
                .disabled(key.isEmpty)
                .accessibilityIdentifier("save-api-key")
            if keySaved { Text("API 密钥已保存到钥匙串。").foregroundStyle(.secondary) }
            Text("Forma 将密钥保存在 macOS 钥匙串中，仅在发送请求时读取。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Egress consent

    /// Consent is stated in the user's language and in the same short words the
    /// shell's 外发许可 control uses; no full English sentence about leaving the
    /// machine is shown anywhere in a titlebar or a form row (owner failure #7).
    private var egressSection: some View {
        Section("云端外发") {
            Toggle("允许一次映射请求离开本机", isOn: $model.allowCloud)
                .accessibilityIdentifier("egress-consent")
            Text("默认关闭，重启后绝不恢复。没有它，FormaCore 的客户端会拒绝任何外发请求；一次运行即消耗本许可。")
                .font(.caption).foregroundStyle(.secondary)
            // One link per the provider actually selected. A compatible server
            // is whoever's machine it runs on: there is no Forma-known policy
            // page to point at, so the row states the obligation instead.
            switch model.provider {
            case .openAI:
                Link("API 数据处理政策", destination: URL(string: "https://platform.openai.com/docs/guides/your-data")!)
            case .anthropic:
                Link("API 数据处理政策", destination: URL(string: "https://privacy.anthropic.com/")!)
            case .openAICompatible:
                Text("数据将离开本机前往上面填写的 Base URL。该服务器的数据处理政策由其运营方决定，发送前先向运营方确认。")
                    .font(.caption).foregroundStyle(.secondary)
            case .offline:
                EmptyView()
            }
        }
    }

    // MARK: - Payload preview

    private var previewSection: some View {
        Section("请求预览") {
            HStack {
                Button("生成预览") { model.previewEgress() }
                    .disabled(model.phase != .idle)
                    .accessibilityIdentifier("build-preview")
                if model.phase == .previewing {
                    Button("取消") { model.cancelAux() }
                }
            }
            // Not "the exact bytes a run sends": a run re-captures each file's
            // rows before dispatch, so this is the request the current stored
            // evidence produces. The distinction decides whether a reviewer
            // treats what they read as a receipt or as an estimate.
            Text("展示整表运行会基于当前清单和上下文构建的第一批内容——系统文本、负载、摘要。它由运行所用的同一套代码规划，并基于已登记的证据组装；但运行会在发送前重新读取文件正文，因此这里的正文摘录可能与运行实际附上的内容不同。重新处理选定的例外时只发送这些文件，其第一批可能是另一组文档。全部在本地构建，不访问网络。")
                .font(.caption).foregroundStyle(.secondary)
            if let preview = model.preview {
                LabeledContent("负载字节数", value: preview.value.byteCount.formatted())
                LabeledContent("请求摘要", value: preview.value.digest)
                    .font(.caption.monospaced())
                LabeledContent("已应用的脱敏版本", value: preview.value.redactionVersion)
                LabeledContent("预览批次的文件数", value: preview.fileCount.formatted())
                LabeledContent("此清单的批次数", value: preview.batchCount.formatted())
                    .help("引擎按认领文件的候选对文件分组：一批就是某个候选在清单中的切片，"
                        + "上限是任一批可携带的最多文件数，"
                        + "而不是从顶部取出的固定切片")
                LabeledContent("本次预览使用的上限", value: preview.entryLimit.formatted())
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("系统文本").font(.caption).foregroundStyle(.secondary)
                        Text(preview.value.system).font(.caption).textSelection(.enabled)
                        Text("负载").font(.caption).foregroundStyle(.secondary)
                        Text(Self.payloadExcerpt(preview.value))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180, maxHeight: 260)
                if !model.leakedTerms.isEmpty {
                    Text("FormaCore 的方案未在这些字节中替换的词条：\(model.leakedTerms.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(model.notice ?? "尚未生成预览。生成预览需要一个已扫描的来源、一个档案和一个已保存的项目上下文。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("已脱敏角色", value: model.roleInventory.isEmpty ? "未定义词条" : "见下方清单")
        }
    }

    private static func payloadExcerpt(_ preview: ProviderMappingClient.Preview) -> String {
        let text = String(decoding: preview.payload, as: UTF8.self)
        guard text.count > previewCharacters else { return text }
        return String(text.prefix(previewCharacters)) + "\n… 共 \(text.count.formatted()) 个字符；上方的计数和摘要涵盖全部字符。"
    }

    // MARK: - Redaction

    private var redactionSection: some View {
        Section("脱敏词条") {
            // Bound to each term's own identity, so the delete button below
            // removes one row without re-parenting the fields of the survivors.
            ForEach($model.redactionTerms) { $term in
                HStack(spacing: 8) {
                    TextField("词条", text: $term.term)
                    Picker("角色", selection: $term.role) {
                        ForEach(RedactionPlan.Role.allCases, id: \.self) { role in
                            Text(role.rawValue).tag(role)
                        }
                    }
                    .frame(width: 130)
                    // Deletion belongs to the row it deletes. A blank row is
                    // inert - FormaCore's plan skips terms with no text - so a
                    // separate "clean up" sweep over the whole list was solving
                    // a problem the plan never had, while leaving no way to
                    // remove a term that was typed by mistake.
                    Button {
                        model.redactionTerms.removeAll { $0.id == term.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("删除该词条")
                    .accessibilityIdentifier("remove-redaction-term")
                }
            }
            if model.redactionTerms.isEmpty {
                Text("没有词条：FormaCore 的身份方案不替换任何内容。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("添加词条") { model.redactionTerms.append(WorkspaceModel.RedactionTerm(term: "", role: .identifier)) }
                .accessibilityIdentifier("add-redaction-term")
            TextField("占位符盐值", text: $model.redactionSalt)
                .accessibilityIdentifier("redaction-salt")
            Text("占位符是盐值与词条的确定性哈希；盐值不会离开本机。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(RedactionPlan.Role.allCases, id: \.self) { role in
                LabeledContent(role.rawValue, value: (model.roleInventory[role] ?? 0).formatted())
            }
            if let profile = model.selectedProfile {
                LabeledContent("示例占位符",
                               value: model.redactionTerms.first.flatMap { model.redaction.placeholder(for: $0.term) }
                                    ?? "添加一个非空词条即可查看示例")
                    .font(.caption.monospaced())
                Text("档案中模型必须看到的反例数：\(profile.counterExamples.count.formatted())")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - DEVONthink

    private var mcpSection: some View {
        Section("DEVONthink MCP") {
            HStack {
                Button("发现官方 MCP") { model.discoverMCP() }
                    .disabled(model.phase != .idle)
                    .accessibilityIdentifier("discover-mcp")
                if model.phase == .discoveringMCP {
                    Button("取消") { model.cancelAux() }
                }
            }
            Text("发现过程会向已安装的 DEVONthink MCP 服务器发送 initialize 和 tools/list。Forma 仅使用只读客户端：本应用没有写入、导入或移动记录的路径。")
                .font(.caption).foregroundStyle(.secondary)
            if let capabilities = model.capabilities {
                LabeledContent("服务器", value: "\(capabilities.serverName) \(capabilities.serverVersion)")
                LabeledContent("协议", value: capabilities.protocolVersion)
                LabeledContent("工具描述符", value: capabilities.tools.count.formatted())
                LabeledContent("探测时间", value: capabilities.probedAt.formatted())
                LabeledContent("get_record_parents", value: capabilities.hasRecordParents ? "已声明" : "不可用")
                LabeledContent("契约受支持的只读工具",
                               value: capabilities.availableReadOnlyTools.joined(separator: ", ").isEmpty
                                ? "未声明任何工具" : capabilities.availableReadOnlyTools.joined(separator: ", "))
            }
            Text("在 Forma 设置窗口中提供某个隔离 DEVONthink 数据库自身的 UUID 之前，对该数据库的查询一律被阻止；Forma 不会读取未被指向的数据库。")
                .font(.caption).foregroundStyle(.secondary)
            Text("授权的历史只能以用户指明记录构建的 `ContextHistoryMatch` 形式进入上下文。本区域不提供此类记录，因此上下文仅由结构构建。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - CasePack

    private var casePackSection: some View {
        Section("CasePack") {
            if let pack = model.casePack {
                LabeledContent("标识符", value: pack.id)
                LabeledContent("版本", value: pack.version)
                LabeledContent("结构", value: pack.schemaVersion)
                LabeledContent("包内案例数", value: pack.cases.count.formatted())
                LabeledContent("可受理案例数", value: pack.cases.filter(\.isAdmissible).count.formatted())
                if let profile = model.selectedProfile {
                    LabeledContent("为 \(profile.profileID) 选定",
                                   value: "\(model.selectedCaseCount(for: profile).formatted()) / \(pack.cases.count.formatted()) 个案例")
                }
            } else {
                Text(model.notice ?? "无法从应用包中读取随附的 CasePack。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("案例是 FormaCore 自带的示例与反例。引擎按档案和版本选择它们；此处不会编辑它们。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section("档案") {
            Picker("档案", selection: Binding(
                get: {
                    guard model.profiles.contains(where: { $0.profileID == model.selectedProfileID }) else { return nil }
                    return model.selectedProfileID
                },
                set: { model.selectedProfileID = $0 }
            )) {
                if !model.profiles.contains(where: { $0.profileID == model.selectedProfileID }) {
                    Text(ShellProfilePicker.placeholder).tag(String?.none)
                }
                ForEach(model.profiles, id: \.profileID) { profile in
                    Text(profile.displayName).tag(Optional(profile.profileID))
                }
            }
            .disabled(!ShellProfilePicker.isEnabled(optionCount: model.profiles.count) || model.phase.isBusy)
            .accessibilityIdentifier("settings-profile")
            if let profile = model.selectedProfile {
                LabeledContent("标识符", value: profile.versionKey)
                LabeledContent("结构", value: profile.schemaVersion)
                LabeledContent("目标类型", value: profile.target.kind.rawValue)
                LabeledContent("目标数据库", value: profile.target.databaseName ?? "未命名")
                LabeledContent("目标 UUID", value: profile.target.databaseUUID ?? "无 · 绑定为符号形式")
                LabeledContent("分组模板", value: profile.target.groupTemplate.joined(separator: " / "))
                LabeledContent("分类", value: profile.categories.map(\.identifier).joined(separator: ", "))
                LabeledContent("文档类型数", value: profile.documentTypes.count.formatted())
                LabeledContent("允许无关联文档", value: profile.permitsUnaffiliatedDocuments ? "是" : "否")
                LabeledContent("授予执行权限", value: profile.grantsExecution ? "是" : "否 · 不会写入任何内容")
                Text("字段策略：\(profile.fields.count.formatted()) / \(MetadataFieldID.allCases.count.formatted()) 个槽位")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(MetadataFieldID.allCases, id: \.self) { field in
                    if let policy = profile.fields[field] {
                        LabeledContent(field.rawValue,
                                       value: "\(policy.level.rawValue) · \(policy.valueType.rawValue) · \(policy.requiredForValidated ? "必填" : "可选") · 原生 \(policy.nativeTypeStatus.rawValue)")
                            .font(.caption)
                    }
                }
            } else {
                Text(model.notice ?? "没有可用的档案。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Local state

    private var storageSection: some View {
        Section("版本与本地状态") {
            LabeledContent("提取器", value: EvidenceRegistry.extractorVersion)
            LabeledContent("提示词", value: MappingPrompt.version)
            LabeledContent("脱敏", value: RedactionPlan.version)
            LabeledContent("外发范围", value: "\(EgressContract.version) / \(EgressContract.scopeVersion)")
            LabeledContent("摘录上限", value: "\(EvidenceRegistry.maximumExcerptCharacters.formatted()) 个字符")
            LabeledContent("提示词摘录上限", value: "\(EvidenceRegistry.maximumPromptExcerptCharacters.formatted()) 个字符")
            LabeledContent("范围", value: model.selectedScope?.displayName ?? "未选择")
            LabeledContent("上下文", value: model.context.map { "修订 \($0.revision) · \($0.candidates.count) 个候选" } ?? "未构建")
            LabeledContent("清单", value: model.manifest.map { "修订 \($0.envelope.revision) · \($0.entries.count) 条目" } ?? "无")
            LabeledContent("打包", value: model.bundleURL?.path ?? "未选择")
            Text("选择项、档案、服务商、模型、批次上限和脱敏词条在重启后恢复。云端外发许可不会恢复。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
