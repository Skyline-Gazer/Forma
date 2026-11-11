import FormaCore
import SwiftUI

struct ProbesView: View {
    @AppStorage("openAIProbeModel") private var openAIModel = ProbeProvider.openAI.defaultModel
    @AppStorage("anthropicProbeModel") private var anthropicModel = ProbeProvider.anthropic.defaultModel
    @State private var provider: ProbeProvider = .openAI
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

    private var model: Binding<String> { provider == .openAI ? $openAIModel : $anthropicModel }

    var body: some View {
        Form {
            Section("DEVONthink MCP") {
                if let capabilities {
                    LabeledContent("Server", value: "\(capabilities.serverName) \(capabilities.serverVersion)")
                    LabeledContent("Protocol", value: capabilities.protocolVersion)
                    LabeledContent("Tool descriptors", value: capabilities.tools.count.formatted())
                    LabeledContent("get_record_parents", value: capabilities.hasRecordParents ? "Advertised" : "Unavailable")
                }
                if let mcpError { Text(mcpError.localizedDescription).foregroundStyle(.secondary) }
                Button("Discover Official MCP", action: discover)
                    .disabled(mcpTask != nil)
                Text("Discovery sends initialize and tools/list to the installed DEVONthink MCP server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Isolated DEVONthink Test") {
                TextField("Isolated database UUID", text: $isolatedDatabase)
                TextField("Test record UUID", text: $isolatedRecord)
                Toggle("These IDs belong to an authorized test database", isOn: $isolatedConsent)
                Toggle("This DEVONthink session contains only test databases", isOn: $fieldsConsent)
                Text("Field definitions apply to the entire DEVONthink session.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Run Isolated Read Check", action: runIsolatedCheck)
                    .disabled(!isolatedConsent || mcpTask != nil || UUID(uuidString: isolatedDatabase) == nil
                              || UUID(uuidString: isolatedRecord) == nil)
                if let isolatedResult { LabeledContent("Database and record", value: isolatedResult) }
                if let parentResult { LabeledContent("Parent groups", value: parentResult) }
                if let definitions {
                    LabeledContent("Metadata definitions", value: "\(definitions.count) of \(DEVONthinkMetadataField.allCases.count)")
                    ForEach(DEVONthinkMetadataField.allCases, id: \.self) { field in
                        let definition = definitions.first { $0.field == field }
                        LabeledContent(field.rawValue, value: definition.map {
                            "\($0.title ?? "No label") · \($0.nativeType)\($0.isDisabled ? " · disabled" : "")"
                        } ?? "Missing")
                    }
                }
            }
            Section("AI Provider Probe") {
                Picker("Provider", selection: $provider) {
                    ForEach(ProbeProvider.allCases, id: \.self) { provider in Text(provider.displayName).tag(provider) }
                }
                .disabled(providerTask != nil)
                TextField("Model ID", text: model)
                    .disabled(providerTask != nil)
                SecureField("API key", text: $key)
                Button("Save API Key to Keychain", action: saveKey).disabled(key.isEmpty)
                if keySaved { Text("API key saved in Keychain.").foregroundStyle(.secondary) }
                Text(ProviderProbe.syntheticPrompt)
                    .font(.caption).textSelection(.enabled)
                Toggle("Send the synthetic probe to \(provider.displayName)", isOn: $consent)
                Text("The selected provider receives the displayed synthetic text and a JSON schema. See its API data-handling policy before enabling.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("API data policy", destination: provider == .openAI
                     ? URL(string: "https://platform.openai.com/docs/guides/your-data")!
                     : URL(string: "https://privacy.anthropic.com/")!)
                Button("Run Provider Probe", action: runProvider)
                    .disabled(!consent || providerTask != nil)
                if let providerError { Text(providerError.localizedDescription).foregroundStyle(.secondary) }
                if let providerResult {
                    LabeledContent("Result", value: providerResult.error?.localizedDescription ?? "Schema validated")
                    if let id = providerResult.modelID { LabeledContent("Returned model", value: id) }
                    if let count = providerResult.inputTokens { LabeledContent("Input tokens", value: count.formatted()) }
                    if let count = providerResult.outputTokens { LabeledContent("Output tokens", value: count.formatted()) }
                    if let count = providerResult.cacheReadInputTokens { LabeledContent("Cache read tokens", value: count.formatted()) }
                    if let count = providerResult.cacheCreationInputTokens { LabeledContent("Cache creation tokens", value: count.formatted()) }
                    LabeledContent("Latency", value: "\(providerResult.latencyMilliseconds) ms")
                }
            }
        }
        .onAppear { providerResult = probe.lastResult(for: provider) }
        .formStyle(.grouped)
        .frame(minWidth: 470, idealWidth: 550, minHeight: 460, idealHeight: 610)
        .onChange(of: provider) { _, _ in
            consent = false
            key = ""
            keySaved = false
            providerResult = probe.lastResult(for: provider)
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
                isolatedResult = "Scope verified · \(missing) missing · \(null) null"
                do {
                    let parents = try await client.parents(of: recordID, in: scope)
                    parentResult = "\(parents.parents.count) verified"
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
            try probe.saveKey(key, for: provider)
            keySaved = true
        } catch {
            let safe = error as? FormaError ?? .storage
            FormaDiagnostics.failure(.saveCredential, safe)
            providerError = safe
        }
    }

    private func runProvider() {
        let provider = provider
        let model = model.wrappedValue
        let allowed = consent
        providerResult = nil
        providerError = nil
        consent = false
        providerTask = Task {
            let result = await probe.run(provider: provider, model: model, allowCloud: allowed)
            if let error = result.error { FormaDiagnostics.failure(.providerProbe, error) }
            if !Task.isCancelled { providerResult = result }
            providerTask = nil
        }
    }
}
