import AppKit
import CoreModel
import DesignSystem
import LibraryStore
import ReelAppCore
import SwiftUI

struct UnifiedInspector: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let editor = model.pdfEditor {
                PDFLayerInspector(editor: editor)
            } else if let editor = model.imageEditor {
                ImageLayerInspector(editor: editor)
            } else if let editor = model.editor {
                EditorInspector(model: model, editor: editor)
            } else {
                libraryInspector
            }
        }
        .frame(width: 280)
        .background(theme.palette.surfacePanel)
    }

    @ViewBuilder private var libraryInspector: some View {
        let selected = model.assets.filter { model.selection.selected.contains($0.id) }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Inspector").font(theme.type.label.font)
                Spacer()
                Text("\(selected.count) selected")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            Divider().overlay(theme.palette.line)
            if selected.count == 1, let asset = selected.first {
                AssetThumbnailSummary(asset: asset, root: model.libraryRoot)
                Text(asset.displayName)
                    .font(theme.type.body.font)
                    .lineLimit(3)
                LabeledContent("Kind", value: asset.kind.rawValue.capitalized)
                LabeledContent(
                    "Size",
                    value: ByteCountFormatter.string(
                        fromByteCount: asset.byteSize, countStyle: .file)
                )
                if let duration = asset.duration {
                    LabeledContent("Duration", value: String(format: "%.2fs", duration.seconds))
                }
                if let width = asset.width, let height = asset.height {
                    LabeledContent("Dimensions", value: "\(width) × \(height)")
                }
                LabeledContent("Modified", value: asset.createdAt.formatted())
                Text(asset.relativePath)
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textTertiary)
                    .textSelection(.enabled)
                Button("Reveal in Finder") { model.revealSelectionInFinder() }
                    .buttonStyle(ReelBorderedButtonStyle())
            } else if selected.count > 1 {
                Text("\(selected.count) files")
                    .font(theme.type.title.font)
                LabeledContent(
                    "Combined size",
                    value: ByteCountFormatter.string(
                        fromByteCount: selected.reduce(0) { $0 + $1.byteSize },
                        countStyle: .file
                    )
                )
                Button("Reveal in Finder") { model.revealSelectionInFinder() }
                    .buttonStyle(ReelBorderedButtonStyle())
            } else {
                EmptyState(
                    headline: "Nothing selected",
                    body: "Select a file to inspect its metadata."
                )
            }
            Spacer()
        }
        .padding(14)
    }
}

private struct PDFLayerInspector: View {
    @Environment(\.theme) private var theme
    @Bindable var editor: PDFEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PDF Edits").font(theme.type.label.font)
                Spacer()
                Text("\(editor.selectedPage?.layers.count ?? 0)")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            if let layers = editor.selectedPage?.layers, !layers.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(layers.reversed())) { layer in
                            Button {
                                editor.selectLayer(layer.id)
                            } label: {
                                HStack {
                                    Image(systemName: symbol(for: layer))
                                    Text(layer.name)
                                    Spacer()
                                }
                                .padding(6)
                                .background(
                                    editor.selectedLayerID == layer.id
                                        ? theme.palette.accentDim : Color.clear
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                EmptyState(
                    headline: "No page edits",
                    body: "Choose Text, Highlight, or Redact and drag on the page."
                )
            }
            if case .text(let text) = editor.selectedLayer {
                Divider().overlay(theme.palette.line)
                Text("Text").font(theme.type.label.font)
                TextField(
                    "Text",
                    text: Binding(
                        get: { text.text },
                        set: { editor.updateSelectedText($0) }
                    ),
                    axis: .vertical
                )
                LabeledContent("Font", value: text.font.postScriptName)
                    .font(theme.type.caption.font)
                if text.font.isEmbedded {
                    Text(text.font.isSubset ? "Embedded subset" : "Embedded font")
                        .font(theme.type.caption.font)
                        .foregroundStyle(
                            text.font.isSubset ? theme.palette.click : theme.palette.success
                        )
                }
            }
            if editor.selectedLayer != nil {
                Button("Delete edit", role: .destructive) { editor.removeSelectedLayer() }
                    .buttonStyle(.borderless)
            }
            Divider().overlay(theme.palette.line)
            Text("Fonts on source page").font(theme.type.label.font)
            if let fonts = editor.pageAnalysis?.fonts, !fonts.isEmpty {
                ForEach(fonts, id: \.postScriptName) { font in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(font.postScriptName).font(theme.type.caption.font)
                        Text(fontStatus(font))
                            .font(theme.type.micro.font)
                            .foregroundStyle(
                                font.isSubset ? theme.palette.click : theme.palette.textTertiary
                            )
                    }
                }
            } else {
                Text("No embedded text fonts detected.")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            ForEach(editor.fontWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.click)
            }
            Divider().overlay(theme.palette.line)
            Text("On-device text recognition").font(theme.type.label.font)
            if let text = editor.selectedPage?.ocrText {
                Text(text.isEmpty ? "No text recognized" : "\(text.count) characters saved")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
            } else {
                Text("OCR has not been run for this page.")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            Button(editor.selectedPage?.ocrText == nil ? "Recognize page" : "Recognize again") {
                editor.recognizeSelectedPage()
            }
            .buttonStyle(ReelBorderedButtonStyle())
            .disabled(editor.isRecognizingText)
            Spacer()
        }
        .padding(14)
    }

    private func symbol(for layer: PDFLayer) -> String {
        switch layer {
        case .text: "textformat"
        case .highlight: "highlighter"
        case .redaction: "eye.slash"
        }
    }

    private func fontStatus(_ font: PDFFontDescriptor) -> String {
        if font.isSubset { return "Embedded subset - new glyphs may be unavailable" }
        return font.isEmbedded ? "Embedded" : "Referenced"
    }
}

private struct ImageLayerInspector: View {
    @Environment(\.theme) private var theme
    @Bindable var editor: ImageEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Layers").font(theme.type.label.font)
                Spacer()
                Text("\(editor.document.layers.count)")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            if editor.document.layers.isEmpty {
                EmptyState(
                    headline: "No layers yet",
                    body: "Choose a tool, then drag on the image."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(editor.document.layers.reversed())) { layer in
                            layerRow(layer)
                        }
                    }
                }
            }
            Divider().overlay(theme.palette.line)
            if let id = editor.selectedLayerID,
                let layer = editor.document.layers.first(where: { $0.id == id })
            {
                Text(layer.kindName).font(theme.type.label.font)
                HStack {
                    Button("Down") { editor.moveLayer(id, by: -1) }
                    Button("Up") { editor.moveLayer(id, by: 1) }
                    Spacer()
                    Button("Delete", role: .destructive) { editor.removeLayer(id) }
                }
                .buttonStyle(.borderless)
                Text("All image edits are non-destructive. The source asset remains unchanged.")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            Divider().overlay(theme.palette.line)
            Text("On-device AI").font(theme.type.label.font)
            Button("Suggest redactions") {
                editor.runImageCommand("suggestRedactions")
            }
            .buttonStyle(ReelBorderedButtonStyle())
            if !editor.redactionSuggestions.isEmpty {
                ForEach(editor.redactionSuggestions) { suggestion in
                    HStack {
                        Text(suggestion.kind.rawValue.capitalized)
                        Spacer()
                        Text(suggestion.preview)
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                    .font(theme.type.caption.font)
                }
                Button("Apply reviewed suggestions") {
                    editor.runImageCommand("applyRedactions")
                }
                .buttonStyle(ReelBorderedButtonStyle())
            }
            Button("Generate alt text") {
                editor.runImageCommand("generateAltText")
            }
            .buttonStyle(.plain)
            if let altText = editor.altText {
                Text(altText)
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textSecondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(14)
    }

    private func layerRow(_ layer: Layer) -> some View {
        HStack(spacing: 6) {
            Button {
                editor.toggleVisibility(layer.id)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            Button {
                editor.selectLayer(layer.id)
            } label: {
                Text(layer.kindName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                editor.toggleLock(layer.id)
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
        }
        .font(theme.type.caption.font)
        .padding(.horizontal, 7)
        .frame(height: 34)
        .background(
            editor.selectedLayerID == layer.id ? theme.palette.accentDim : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct AssetThumbnailSummary: View {
    let asset: AssetRecord
    let root: URL

    var body: some View {
        Group {
            if let path = asset.thumbnailPath,
                let image = NSImage(contentsOf: root.appendingPathComponent(path))
            {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "doc.richtext").font(.system(size: 32))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .clipped()
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
