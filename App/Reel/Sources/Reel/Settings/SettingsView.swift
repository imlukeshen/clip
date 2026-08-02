import AIKit
import DesignSystem
import Foundation
import ReelAppCore
import SwiftUI

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: AppModel

    var body: some View {
        SettingsContent(model: model, settings: model.aiSettings)
            .environment(\.theme, colorScheme == .dark ? Theme.dark : Theme.light)
            .frame(width: 560, height: 520)
    }
}

private struct SettingsContent: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @Bindable var settings: AISettingsModel
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var googleKey = ""
    @State private var showsAcknowledgements = false

    var body: some View {
        Form {
            LabeledContent("Library") {
                Text(model.libraryRoot.path(percentEncoded: false))
                    .font(theme.type.numeric.font)
                    .textSelection(.enabled)
            }
            if model.canRevertMigration {
                Button("Revert library migration…", role: .destructive) {
                    model.revertLibraryMigration()
                }
            }
            Section("Assistant") {
                Picker("Provider", selection: providerBinding) {
                    Text("Local / compatible").tag(ProviderID.openAICompatible)
                    Text("OpenAI").tag(ProviderID.openAI)
                    Text("Anthropic").tag(ProviderID.anthropic)
                    Text("Google").tag(ProviderID.google)
                }
                TextField("Model", text: $settings.model)
                if settings.selectedProvider == .openAICompatible {
                    TextField("Base URL", text: $settings.compatibleBaseURL)
                    Text("Ollama and LM Studio work without an API key.")
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textTertiary)
                } else {
                    HStack {
                        SecureField("API key", text: credentialBinding)
                        Button("Save") {
                            let value = credentialBinding.wrappedValue
                            let provider = settings.selectedProvider
                            Task {
                                await settings.saveCredential(value, provider: provider)
                                credentialBinding.wrappedValue = ""
                            }
                        }
                    }
                }
                Picker("Confirm edits", selection: $settings.confirmationPolicy) {
                    Text("Destructive edits").tag(ConfirmationPolicy.confirmDestructive)
                    Text("Every edit").tag(ConfirmationPolicy.confirmAll)
                    Text("Apply undoably").tag(ConfirmationPolicy.autoApply)
                }
            }

            Section("Egress ledger") {
                if settings.egressEntries.isEmpty {
                    Text("No outbound requests recorded.")
                        .foregroundStyle(theme.palette.textTertiary)
                } else {
                    ForEach(settings.egressEntries.prefix(8)) { entry in
                        LabeledContent(entry.provider.rawValue) {
                            Text(
                                "\(entry.purpose.rawValue) · \(entry.date.formatted(date: .abbreviated, time: .shortened))\(entry.mediaAttached ? " · media" : "")"
                            )
                            .font(theme.type.caption.font)
                        }
                    }
                }
                Button("Refresh ledger") { Task { await settings.refresh() } }
            }

            Section("About") {
                Button("Third-party acknowledgements") { showsAcknowledgements = true }
            }
        }
        .formStyle(.grouped)
        .font(theme.type.body.font)
        .foregroundStyle(theme.palette.textPrimary)
        .background(theme.palette.surfaceBase)
        .task { await settings.refresh() }
        .sheet(isPresented: $showsAcknowledgements) {
            AcknowledgementsView()
                .environment(\.theme, theme)
        }
    }

    private var providerBinding: Binding<ProviderID> {
        Binding(get: { settings.selectedProvider }, set: { settings.selectedProvider = $0 })
    }

    private var credentialBinding: Binding<String> {
        switch settings.selectedProvider {
        case .openAI: $openAIKey
        case .anthropic: $anthropicKey
        case .google: $googleKey
        default: $openAIKey
        }
    }
}

private struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Third-party acknowledgements").font(theme.type.title.font)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            ScrollView {
                Text(contents)
                    .font(theme.type.caption.font)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
        }
        .frame(width: 620, height: 520)
        .background(theme.palette.surfaceBase)
    }

    private var contents: String {
        guard
            let url = Bundle.main.url(
                forResource: "ACKNOWLEDGEMENTS", withExtension: "md"),
            let value = try? String(contentsOf: url, encoding: .utf8)
        else { return "Acknowledgements are unavailable in this build." }
        return value
    }
}
