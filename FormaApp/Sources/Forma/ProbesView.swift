import FormaCore
import SwiftUI

struct ProbesView: View {
    /// The settings scene reads the application's one settings-and-run model,
    /// so provider, model id and Base URL here are the exact values a mapping
    /// run will use. The pre-P0 pane kept its own `@AppStorage` probe model
    /// ids - a second spelling of "the model" that could and did drift from
    /// what Settings showed. With no workspace open there is no configuration
    /// to probe, and the pane says so instead of inventing one.
    @ObservedObject var workspaceModel: WorkspaceModel
    @State private var key = ""
    @State private var consent = false
    @State private var providerResult: ProviderProbeResult?
    @State private var providerError: FormaError?
    @State private var keySaved = false
    @State private var capabilities: DEVONthinkCapabilities?
    @State private var mcpError: FormaError?
    @State private var isolatedDatabase = ""
    @State private var isolatedRecord = ""
    @State private var isolatedConsent = false
    @State private var fieldsConsent = false
    @State private var isolatedResult: String?
    @State private var parentResult: String?
    @State private var definitions: [DEVONthinkMetadataFieldDefinition]?
    @State private var providerTask: Task<Void, Never>?
    @State private var mcpTask: Task<Void, Never>?
    private let probe = ProviderProbe()


    private var provider: ProbeProvider { workspaceModel.provider }

    private struct Configuration: Equatable {
        let provider: ProbeProvider
        let model: String
        let baseURL: String
    }

    private var configuration: Configuration {
        Configuration(provider: provider, model: workspaceModel.modelID, baseURL: workspaceModel.customBaseURL)
    }

    /// Writes go through `selectProvider`, not a raw assignment: switching
    /// there resets consent and swaps a untouched default model id, which is
    /// exactly the discipline a probe must inherit from Settings.
    private var providerBinding: Binding<ProbeProvider> {
        Binding(get: { provider }, set: { workspaceModel.selectProvider($0) })
    }

    private var modelBinding: Binding<String> {
        $workspaceModel.modelID
    }

    private var customBaseURLBinding: Binding<String> {
        $workspaceModel.customBaseURL
    }

    var body: some View {
        Form {
            Section("DEVONthink MCP") {
                if let capabilities {
                    LabeledContent("服务器", value: "\(capabilities.serverName) \(capabilities.serverVersion)")
                    LabeledContent("协议版本", value: capabilities.protocolVersion)
                    LabeledContent("工具描述数量", value: capabilities.tools.count.formatted())
                    LabeledContent("get_record_parents", value: capabilities.hasRecordParents ? "已发布" : "不可用")
                }
                if let mcpError { Text(mcpError.localizedDescription).foregroundStyle(.secondary) }
                Button("发现官方 MCP", action: discover)
                    .disabled(mcpTask != nil)
                Text("发现操作会向已安装的 DEVONthink MCP 服务器发送 initialize 和 tools/list。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("隔离的 DEVONthink 测试") {
                TextField("隔离数据库 UUID", text: $isolatedDatabase)
                TextField("测试记录 UUID", text: $isolatedRecord)
                Toggle("这些 ID 属于已授权的测试数据库", isOn: $isolatedConsent)
                Toggle("此 DEVONthink 会话仅包含测试数据库", isOn: $fieldsConsent)
                Text("字段定义适用于整个 DEVONthink 会话。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("运行隔离读取检查", action: runIsolatedCheck)
                    .disabled(!isolatedConsent || mcpTask != nil || UUID(uuidString: isolatedDatabase) == nil
                              || UUID(uuidString: isolatedRecord) == nil)
                if let isolatedResult { LabeledContent("数据库与记录", value: isolatedResult) }
                if let parentResult { LabeledContent("父分组", value: parentResult) }
                if let definitions {
                    LabeledContent("元数据定义", value: "\(definitions.count) / \(DEVONthinkMetadataField.allCases.count)")
                    ForEach(DEVONthinkMetadataField.allCases, id: \.self) { field in
                        let definition = definitions.first { $0.field == field }
                        LabeledContent(field.rawValue, value: definition.map {
                            "\($0.title ?? "无标签") · \($0.nativeType)\($0.isDisabled ? " · 已禁用" : "")"
                        } ?? "缺失")
                    }
                }
            }
            Section("AI 服务商探测") {
                Picker("服务商", selection: providerBinding) {
                    ForEach(ProbeProvider.networkCases, id: \.self) { provider in Text(provider.displayName).tag(provider) }
                }
                .disabled(providerTask != nil)
                TextField("模型 ID", text: modelBinding)
                    .disabled(providerTask != nil)
                if provider == .openAICompatible {
                    TextField("Base URL（例如 http://127.0.0.1:11434/v1）", text: customBaseURLBinding)
                        .disabled(providerTask != nil)
                        .accessibilityIdentifier("probe-base-url")
                }
                SecureField("API 密钥", text: $key)
                Button("将 API 密钥保存到钥匙串", action: saveKey).disabled(key.isEmpty)
                if keySaved { Text("API 密钥已保存到钥匙串。").foregroundStyle(.secondary) }
                Text(ProviderProbe.syntheticPrompt)
                    .font(.caption).textSelection(.enabled)
                Toggle("向 \(provider.displayName) 发送合成探测请求", isOn: $consent)
                if provider == .openAICompatible {
                    Text("探测目标就是设置页填写的 Base URL 解析出的完整地址；两者不一致时不会发出请求。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("所选服务商将收到上面显示的合成文本和一份 JSON schema。启用前请先查看其 API 数据处理政策。")
                    .font(.caption).foregroundStyle(.secondary)
                switch provider {
                case .openAI:
                    Link("API 数据政策", destination: URL(string: "https://platform.openai.com/docs/guides/your-data")!)
                case .anthropic:
                    Link("API 数据政策", destination: URL(string: "https://privacy.anthropic.com/")!)
                case .openAICompatible:
                    Text("兼容服务器的数据政策由其运营方决定；发送前向运营方确认。")
                        .font(.caption).foregroundStyle(.secondary)
                case .offline:
                    EmptyView()
                }
                Button("运行服务商探测", action: runProvider)
                    .disabled(!consent || providerTask != nil)
                if let providerError { Text(providerError.localizedDescription).foregroundStyle(.secondary) }
                if let providerResult {
                    LabeledContent("结果", value: providerResult.error?.localizedDescription ?? "结构校验通过")
                    if let id = providerResult.modelID { LabeledContent("返回的模型", value: id) }
                    if let count = providerResult.inputTokens { LabeledContent("输入 token 数", value: count.formatted()) }
                    if let count = providerResult.outputTokens { LabeledContent("输出 token 数", value: count.formatted()) }
                    if let count = providerResult.cacheReadInputTokens { LabeledContent("缓存读取 token 数", value: count.formatted()) }
                    if let count = providerResult.cacheCreationInputTokens { LabeledContent("缓存写入 token 数", value: count.formatted()) }
                    LabeledContent("延迟", value: "\(providerResult.latencyMilliseconds) ms")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 470, idealWidth: 550, minHeight: 460, idealHeight: 610)
        .onChange(of: configuration) { _, _ in
            consent = false
            key = ""
            keySaved = false
            providerResult = nil
            providerError = nil
        }
        .onDisappear {
            key = ""
            providerTask?.cancel()
            mcpTask?.cancel()
        }
    }

    private func discover() {
        capabilities = nil
        mcpError = nil
        mcpTask = Task {
            let client = DEVONthinkReadOnlyClient()
            do { capabilities = try await client.discover() }
            catch {
                let safe = error as? FormaError ?? .unavailable
                FormaDiagnostics.failure(.discoverMCP, safe)
                mcpError = safe
            }
            await client.close()
            mcpTask = nil
        }
    }

    private func runIsolatedCheck() {
        guard isolatedConsent, let databaseID = UUID(uuidString: isolatedDatabase),
              let recordID = UUID(uuidString: isolatedRecord) else { return }
        let scope = DEVONthinkReadScope(databaseID: databaseID, recordIDs: [recordID],
                                        permitsGlobalFieldDefinitions: fieldsConsent)
        isolatedConsent = false
        fieldsConsent = false
        isolatedResult = nil
        parentResult = nil
        definitions = nil
        mcpError = nil
        mcpTask = Task {
            let client = DEVONthinkReadOnlyClient()
            do {
                capabilities = try await client.discover()
                _ = try await client.database(in: scope)
                let metadata = try await client.metadata(of: recordID, in: scope)
                let missing = metadata.values.filter { $0 == .missing }.count
                let null = metadata.values.filter { $0 == .null }.count
                isolatedResult = "范围已验证 · \(missing) 缺失 · \(null) 空值"
                do {
                    let parents = try await client.parents(of: recordID, in: scope)
                    parentResult = "\(parents.parents.count) 已验证"
                } catch {
                    parentResult = (error as? FormaError ?? .unavailable).localizedDescription
                }
                if scope.permitsGlobalFieldDefinitions {
                    definitions = try await client.metadataFieldDefinitions(in: scope)
                }
            } catch {
                let safe = error as? FormaError ?? .unavailable
                FormaDiagnostics.failure(.discoverMCP, safe)
                mcpError = safe
            }
            await client.close()
            mcpTask = nil
        }
    }

    private func saveKey() {
        providerError = nil
        keySaved = false
        defer { key = "" }
        do {
            try probe.saveKey(key, for: provider, customBaseURL: workspaceModel.customBaseURL)
            keySaved = true
        } catch {
            let safe = error as? FormaError ?? .storage
            FormaDiagnostics.failure(.saveCredential, safe)
            providerError = safe
        }
    }

    private func runProvider() {
        let provider = provider
        let model = modelBinding.wrappedValue
        let customBaseURL = workspaceModel.customBaseURL
        let configuration = configuration
        let allowed = consent
        providerResult = nil
        providerError = nil
        consent = false
        providerTask = Task {
            let result = await probe.run(provider: provider, model: model, allowCloud: allowed,
                                         customBaseURL: customBaseURL)
            if let error = result.error { FormaDiagnostics.failure(.providerProbe, error) }
            if !Task.isCancelled, configuration == self.configuration { providerResult = result }
            providerTask = nil
        }
    }
}
