import FormaCore
import SwiftUI

/// The settings area: which provider may be asked, what would actually leave the
/// machine, how paths and text are redacted first, what the DEVONthink
/// connection advertises, and which CasePack a run would use.
///
/// The preview is the whole point of this screen: `ProviderMappingClient.preview`
/// returns the exact bytes one request would send, and it is shown before any
/// consent is given and before anything is sent. Nothing here simulates a
/// result: an absent key, a missing context or a blocked MCP query is reported
/// with FormaCore's own reason.
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
        .navigationTitle("Settings")
        .onDisappear {
            key = ""
            keySaved = false
            model.cancelAux()
        }
    }

    // MARK: - Provider

    private var providerSection: some View {
        Section("Provider") {
            Picker("Provider", selection: Binding(get: { model.provider }, set: { model.selectProvider($0) })) {
                ForEach(ProbeProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .disabled(model.phase.isBusy)
            .accessibilityIdentifier("mapping-provider")
            TextField("Model ID", text: $model.modelID)
                .accessibilityIdentifier("mapping-model")
            TextField("Files per batch request", value: $model.entryLimit, format: .number)
                .accessibilityIdentifier("mapping-entry-limit")
            SecureField("API key for \(model.provider.displayName)", text: $key)
            Button("Save API Key to Keychain") { keySaved = model.saveKey(key) }
                .disabled(key.isEmpty)
                .accessibilityIdentifier("save-api-key")
            if keySaved { Text("API key saved in Keychain.").foregroundStyle(.secondary) }
            Text("Forma stores the key in the macOS Keychain and reads it only when a request is sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Egress consent

    private var egressSection: some View {
        Section("Cloud egress") {
            Toggle("Allow one mapping request to leave this machine", isOn: $model.allowCloud)
                .accessibilityIdentifier("egress-consent")
            Text("Off by default and never restored after a restart. FormaCore's client refuses a request without it, and a run consumes the consent.")
                .font(.caption).foregroundStyle(.secondary)
            Link("API data handling policy",
                 destination: model.provider == .openAI
                    ? URL(string: "https://platform.openai.com/docs/guides/your-data")!
                    : URL(string: "https://privacy.anthropic.com/")!)
        }
    }

    // MARK: - Payload preview

    private var previewSection: some View {
        Section("Request preview") {
            HStack {
                Button("Build Preview") { model.previewEgress() }
                    .disabled(model.phase != .idle)
                    .accessibilityIdentifier("build-preview")
                if model.phase == .previewing {
                    Button("Cancel") { model.cancelAux() }
                }
            }
            Text("Shows the first batch a run would build from this listing and context — system text, payload, digest — planned by the same code the run uses, built locally, with no network access. A run re-reads a file whose rows are not stored yet, so a body excerpt can differ from an earlier capture.")
                .font(.caption).foregroundStyle(.secondary)
            if let preview = model.preview {
                LabeledContent("Payload bytes", value: preview.byteCount.formatted())
                LabeledContent("Request digest", value: preview.digest)
                    .font(.caption.monospaced())
                LabeledContent("Redaction version", value: model.redaction.isIdentity ? "Identity (no terms)" : RedactionPlan.version)
                LabeledContent("Files in previewed batch", value: "\(model.previewedFileCount.formatted()) of \(model.previewedBatchCount.formatted()) batches")
                    .help("The engine groups files by the candidate that claims them, so one batch is one candidate's slice and never simply the first \(model.entryLimit.formatted()) files of the listing")
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System text").font(.caption).foregroundStyle(.secondary)
                        Text(preview.system).font(.caption).textSelection(.enabled)
                        Text("Payload").font(.caption).foregroundStyle(.secondary)
                        Text(Self.payloadExcerpt(preview))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180, maxHeight: 260)
                if !model.leakedTerms.isEmpty {
                    Text("Terms FormaCore's plan did not substitute in these bytes: \(model.leakedTerms.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(model.notice ?? "No preview built yet. A preview needs a scanned source, a profile and a stored project context.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Redacted roles", value: model.roleInventory.isEmpty ? "No terms defined" : "See inventory below")
        }
    }

    private static func payloadExcerpt(_ preview: ProviderMappingClient.Preview) -> String {
        let text = String(decoding: preview.payload, as: UTF8.self)
        guard text.count > previewCharacters else { return text }
        return String(text.prefix(previewCharacters)) + "\n… \(text.count.formatted()) characters in total; the count and digest above cover all of them."
    }

    // MARK: - Redaction

    private var redactionSection: some View {
        Section("Redaction terms") {
            // Bound by the row's own identity. `RedactionTerm` is Identifiable
            // precisely so that deleting one row cannot renumber the bindings of
            // the others: with array indices as identities, a removal leaves the
            // enclosing ForEach holding a subscript that no longer exists, and
            // the text fields of the surviving rows get re-parented to the wrong
            // term.
            ForEach($model.redactionTerms) { $term in
                HStack(spacing: 8) {
                    TextField("Term", text: $term.term)
                    Picker("Role", selection: $term.role) {
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
                    .accessibilityLabel("Remove this term")
                    .accessibilityIdentifier("remove-redaction-term")
                }
            }
            if model.redactionTerms.isEmpty {
                Text("No terms: FormaCore's identity plan substitutes nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Add Term") { model.redactionTerms.append(WorkspaceModel.RedactionTerm(term: "", role: .identifier)) }
                .accessibilityIdentifier("add-redaction-term")
            TextField("Placeholder salt", text: $model.redactionSalt)
                .accessibilityIdentifier("redaction-salt")
            Text("Placeholders are deterministic hashes of salt plus term; the salt never leaves the machine.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(RedactionPlan.Role.allCases, id: \.self) { role in
                LabeledContent(role.rawValue, value: (model.roleInventory[role] ?? 0).formatted())
            }
            if let profile = model.selectedProfile {
                LabeledContent("Sample placeholder",
                               value: model.redactionTerms.first.flatMap { model.redaction.placeholder(for: $0.term) }
                                    ?? "Add a non-empty term to see one")
                    .font(.caption.monospaced())
                Text("Profile counter-examples the model must see: \(profile.counterExamples.count.formatted())")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - DEVONthink

    private var mcpSection: some View {
        Section("DEVONthink MCP") {
            HStack {
                Button("Discover Official MCP") { model.discoverMCP() }
                    .disabled(model.phase != .idle)
                    .accessibilityIdentifier("discover-mcp")
                if model.phase == .discoveringMCP {
                    Button("Cancel") { model.cancelAux() }
                }
            }
            Text("Discovery sends initialize and tools/list to the installed DEVONthink MCP server. Forma uses the read-only client only: this app has no path that writes, imports or moves a record.")
                .font(.caption).foregroundStyle(.secondary)
            if let capabilities = model.capabilities {
                LabeledContent("Server", value: "\(capabilities.serverName) \(capabilities.serverVersion)")
                LabeledContent("Protocol", value: capabilities.protocolVersion)
                LabeledContent("Tool descriptors", value: capabilities.tools.count.formatted())
                LabeledContent("Probed", value: capabilities.probedAt.formatted())
                LabeledContent("get_record_parents", value: capabilities.hasRecordParents ? "Advertised" : "Unavailable")
                LabeledContent("Read-only tools with a supported contract",
                               value: capabilities.availableReadOnlyTools.joined(separator: ", ").isEmpty
                                ? "None advertised" : capabilities.availableReadOnlyTools.joined(separator: ", "))
            }
            Text("Queries against an isolated DEVONthink database are BLOCKED until you supply that database's own UUID in the Forma settings window; nothing is read from a database Forma has not been pointed at.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Authorized history can only enter a context as a `ContextHistoryMatch` built from records the user named. This area supplies none, so a context is built from structure alone.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - CasePack

    private var casePackSection: some View {
        Section("CasePack") {
            if let pack = model.casePack {
                LabeledContent("Identifier", value: pack.id)
                LabeledContent("Version", value: pack.version)
                LabeledContent("Schema", value: pack.schemaVersion)
                LabeledContent("Cases in pack", value: pack.cases.count.formatted())
                LabeledContent("Admissible cases", value: pack.cases.filter(\.isAdmissible).count.formatted())
                if let profile = model.selectedProfile {
                    LabeledContent("Selected for \(profile.profileID)",
                                   value: "\(model.selectedCaseCount(for: profile).formatted()) of \(pack.cases.count.formatted()) cases")
                }
            } else {
                Text(model.notice ?? "The shipped CasePack could not be read from the app bundle.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Cases are FormaCore's own examples and counter-examples. The engine selects them per profile and version; nothing here edits them.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section("Profile") {
            Picker("Profile", selection: Binding(get: { model.selectedProfileID }, set: { model.selectedProfileID = $0 })) {
                ForEach(model.profiles, id: \.profileID) { profile in
                    Text(profile.displayName).tag(Optional(profile.profileID))
                }
            }
            .disabled(model.phase.isBusy)
            .accessibilityIdentifier("settings-profile")
            if let profile = model.selectedProfile {
                LabeledContent("Identifier", value: profile.versionKey)
                LabeledContent("Schema", value: profile.schemaVersion)
                LabeledContent("Target kind", value: profile.target.kind.rawValue)
                LabeledContent("Target database", value: profile.target.databaseName ?? "Not named")
                LabeledContent("Target UUID", value: profile.target.databaseUUID ?? "None · binding is symbolic")
                LabeledContent("Group template", value: profile.target.groupTemplate.joined(separator: " / "))
                LabeledContent("Categories", value: profile.categories.map(\.identifier).joined(separator: ", "))
                LabeledContent("Document types", value: profile.documentTypes.count.formatted())
                LabeledContent("Permits unaffiliated documents", value: profile.permitsUnaffiliatedDocuments ? "Yes" : "No")
                LabeledContent("Grants execution", value: profile.grantsExecution ? "Yes" : "No · nothing is written")
                Text("Field policy: \(profile.fields.count.formatted()) of \(MetadataFieldID.allCases.count.formatted()) slots")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(MetadataFieldID.allCases, id: \.self) { field in
                    if let policy = profile.fields[field] {
                        LabeledContent(field.rawValue,
                                       value: "\(policy.level.rawValue) · \(policy.valueType.rawValue) · \(policy.requiredForValidated ? "required" : "optional") · native \(policy.nativeTypeStatus.rawValue)")
                            .font(.caption)
                    }
                }
            } else {
                Text(model.notice ?? "No profile is available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Local state

    private var storageSection: some View {
        Section("Versions and local state") {
            LabeledContent("Extractor", value: EvidenceRegistry.extractorVersion)
            LabeledContent("Prompt", value: MappingPrompt.version)
            LabeledContent("Redaction", value: RedactionPlan.version)
            LabeledContent("Excerpt limit", value: "\(EvidenceRegistry.maximumExcerptCharacters.formatted()) characters")
            LabeledContent("Prompt excerpt limit", value: "\(EvidenceRegistry.maximumPromptExcerptCharacters.formatted()) characters")
            LabeledContent("Scope", value: model.selectedScope?.displayName ?? "None selected")
            LabeledContent("Context", value: model.context.map { "revision \($0.revision) · \($0.candidates.count) candidates" } ?? "Not built")
            LabeledContent("Manifest", value: model.manifest.map { "revision \($0.envelope.revision) · \($0.entries.count) entries" } ?? "None")
            LabeledContent("Bundle", value: model.bundleURL?.path ?? "Not selected")
            Text("Selections, the profile, provider, model, batch limit and redaction terms are restored after a restart. Cloud egress consent never is.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
