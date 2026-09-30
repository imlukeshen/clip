import AIKit
import AppKit
import CaptureKit
import DesignSystem
import Foundation
import ReelAppCore
import SwiftUI

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: AppModel

    var body: some View {
        SettingsContent(model: model, settings: model.aiSettings)
            .environment(\.theme, model.appearance.theme(matching: colorScheme))
            .tint(model.appearance.theme(matching: colorScheme).palette.accent)
            .preferredColorScheme(model.appearance.colorScheme)
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
    @State private var confirmsTeXCacheClear = false
    @State private var confirmsPDFFontCacheClear = false

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
            Picker("Appearance", selection: $model.appearance) {
                ForEach(AppearancePreference.allCases, id: \.self) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            Section("Capture") {
                Toggle(
                    "Save system clipboard history",
                    isOn: clipboardCaptureBinding
                )
                .accessibilityIdentifier("settings-clipboard-capture")
                Text(
                    "Off by default. When enabled, clipx stores eligible copied text, images, "
                        + "and file locations locally for up to seven days. Sensitive, transient, "
                        + "and oversized pasteboard items are ignored. Disable this at any time to stop watching."
                )
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
                Toggle(
                    "Global clipx Clipboard shortcut (Command-Shift-C)",
                    isOn: clipboardShortcutBinding
                )
                .accessibilityIdentifier("settings-global-clipboard-shortcut")
                Text(
                    "Turn this off if Maccy or another clipboard manager uses Command-Shift-C. "
                        + "clipx Clipboard remains available from the sidebar and Capture menu."
                )
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
                Picker("New recordings", selection: captureDestinationBinding) {
                    ForEach(CaptureDestination.allCases) { destination in
                        Text(destination.title).tag(destination)
                    }
                }
                Text(model.captureDestination.detail)
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
                Text(
                    "While clipx is open, screenshots enter clipx Clipboard. Recordings can "
                        + "open in the video editor, enter the clipboard, or stay untouched. "
                        + "clipx stops watching when you quit, and the original macOS file stays put."
                )
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
            }
            Section("LaTeX") {
                LabeledContent("Package cache") {
                    Text(model.texPackageCacheURL.path(percentEncoded: false))
                        .font(theme.type.numeric.font)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            model.texPackageCacheURL
                        ])
                    }
                    Button(
                        model.isTeXPackageCacheResetting ? "Clearing cache…" : "Clear cache…",
                        role: .destructive
                    ) {
                        confirmsTeXCacheClear = true
                    }
                    .disabled(model.isTeXPackageCacheResetting)
                }
                Text(
                    "Package downloads happen only after your explicit choice and are recorded "
                        + "in the egress ledger. Clearing the cache resets that choice, so the next build asks again."
                )
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
            }
            Section("PDF text editing") {
                Toggle(
                    "Automatically resolve missing fonts",
                    isOn: pdfFontDownloadBinding
                )
                LabeledContent("Verified font cache") {
                    Text(model.pdfFontCacheURL.path(percentEncoded: false))
                        .font(theme.type.numeric.font)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            model.pdfFontCacheURL
                        ])
                    }
                    Button("Clear cache…", role: .destructive) {
                        confirmsPDFFontCacheClear = true
                    }
                }
                Text(
                    "clipx first uses the PDF's embedded or installed font. If new text needs "
                        + "missing glyphs, it can download a pinned, SHA-256 verified open font "
                        + "from the Google Fonts repository. PDF-provided URLs are never opened."
                )
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
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
                    HStack {
                        Button("Test connection") {
                            Task { await settings.testCompatibleProvider() }
                        }
                        .disabled(settings.isCheckingCompatibleProvider)
                        if settings.isCheckingCompatibleProvider {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text(
                        "Ollama defaults to localhost:11434. LM Studio also works through its "
                            + "OpenAI-compatible server, but manages its own models."
                    )
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
                    if settings.canInstallLocalModels {
                        localModels
                    }
                } else {
                    HStack {
                        SecureField("API key", text: credentialBinding)
                        Button("Save") {
                            let value = credentialBinding.wrappedValue
                            let provider = settings.selectedProvider
                            Task {
                                if await settings.saveCredential(value, provider: provider) {
                                    credentialBinding.wrappedValue = ""
                                }
                            }
                        }
                    }
                }
                if let notice = settings.notice {
                    Text(notice)
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textSecondary)
                        .textSelection(.enabled)
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
        // Re-read on every appearance and whenever the endpoint changes: Ollama
        // is a separate process, so models can arrive or be removed without clipx
        // hearing about it.
        .task(id: settings.compatibleBaseURL) { await settings.refreshInstalledLocalModels() }
        .task(id: settings.selectedProvider) { await settings.refreshInstalledLocalModels() }
        .sheet(isPresented: $showsAcknowledgements) {
            AcknowledgementsView()
                .environment(\.theme, theme)
        }
        .confirmationDialog(
            "Clear cached TeX packages?",
            isPresented: $confirmsTeXCacheClear,
            titleVisibility: .visible
        ) {
            Button("Clear cache", role: .destructive) { model.clearTeXPackageCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your documents and generated PDFs will not be removed.")
        }
        .confirmationDialog(
            "Clear cached PDF fonts?",
            isPresented: $confirmsPDFFontCacheClear,
            titleVisibility: .visible
        ) {
            Button("Clear cache", role: .destructive) { model.clearPDFFontCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PDFs and edits stay intact. Missing open fonts may be downloaded again.")
        }
    }

    /// Installing and choosing models on a local Ollama.
    ///
    /// Only the models that advertise tool calling are suggested. The assistant
    /// drives clipx by emitting tool calls, so one without it will answer
    /// questions and change nothing.
    @ViewBuilder private var localModels: some View {
        if !settings.installedLocalModels.isEmpty {
            Picker("Installed", selection: $settings.model) {
                ForEach(settings.installedLocalModels, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
        }

        if let download = settings.localModelDownload {
            switch download {
            case .running(let name, let progress):
                VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
                    HStack {
                        if let fraction = progress.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Button("Cancel") { settings.cancelLocalModelDownload() }
                    }
                    Text(
                        [name, progress.status, progress.byteSummary]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                    )
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
                }
            case .failed(let name, let message):
                HStack(alignment: .firstTextBaseline) {
                    Text("\(name): \(message)")
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.danger)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { settings.dismissLocalModelDownloadFailure() }
                }
            }
        } else if !settings.availableLocalModelSuggestions.isEmpty {
            Menu("Download a model…") {
                ForEach(settings.availableLocalModelSuggestions) { suggestion in
                    Button(Self.label(for: suggestion)) {
                        settings.downloadLocalModel(suggestion.name)
                    }
                }
            }
            .menuStyle(ReelMenuStyle())
        }

        Text(
            "Ollama downloads the model; clipx only talks to your machine. Sizes are "
                + "approximate, and any other Ollama model can be installed by typing its "
                + "name above. Only models that support tool calling can edit for you."
        )
        .font(theme.type.caption.font)
        .foregroundStyle(theme.palette.textTertiary)
    }

    private static func label(for suggestion: LocalModelSuggestion) -> String {
        let size = String(format: "%.1f", suggestion.approximateGigabytes)
        return "\(suggestion.name) — about \(size) GB · \(suggestion.summary)"
    }

    private var captureDestinationBinding: Binding<CaptureDestination> {
        // Written as a closure rather than a method reference: the reabstraction
        // thunk the latter produces crashes IRGen in this toolchain.
        Binding(
            get: { model.captureDestination },
            set: { model.setCaptureDestination($0) }
        )
    }

    private var clipboardShortcutBinding: Binding<Bool> {
        Binding(
            get: { model.isGlobalClipboardShortcutEnabled },
            set: { isEnabled in
                model.setGlobalClipboardShortcutEnabled(isEnabled)
                ClipAppDelegate.refreshClipboardShortcutRegistration()
            }
        )
    }

    private var clipboardCaptureBinding: Binding<Bool> {
        Binding(
            get: { model.isClipboardCaptureEnabled },
            set: { model.setClipboardCaptureEnabled($0) }
        )
    }

    private var pdfFontDownloadBinding: Binding<Bool> {
        Binding(
            get: { model.isPDFFontAutoDownloadEnabled },
            set: { model.setPDFFontAutoDownloadEnabled($0) }
        )
    }

    private var providerBinding: Binding<ProviderID> {
        Binding(get: { settings.selectedProvider }, set: { settings.selectProvider($0) })
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
