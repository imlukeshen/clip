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
            if model.selectedWorkspace == .pdf, let editor = model.pdfEditor {
                PDFLayerInspector(editor: editor)
            } else if model.selectedWorkspace == .photo, let editor = model.imageEditor {
                ImageLayerInspector(editor: editor)
            } else if model.selectedWorkspace == .video, let editor = model.editor {
                EditorInspector(model: model, editor: editor)
            } else if model.selectedWorkspace == .text, let editor = model.textEditor {
                TextInspector(model: model, editor: editor)
            } else {
                // The library no longer has a persistent inspector — "Get Info"
                // on an item replaces it — and `MainWindow` only mounts this rail
                // when an editor is open, so this branch is unreachable in
                // practice and renders nothing rather than an empty pane.
                EmptyView()
            }
        }
        .frame(width: model.inspectorWidth)
        .background(theme.palette.surfacePanel)
    }
}

/// Shared inspector chat input, shaped like a compact standalone composer
/// instead of a full-width toolbar. Keeping this in one component prevents the
/// text and video inspectors from drifting by a pixel or a corner radius.
struct AssistantChatComposer: View {
    @Environment(\.theme) private var theme
    @Binding var draft: String
    let isWorking: Bool
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.sm) {
            TextField("Ask Clip anything…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(theme.type.body.font)
                .lineLimit(1...5)
                .onSubmit(send)

            HStack(spacing: theme.metrics.spacing.sm) {
                Text("Return to send")
                    .font(theme.type.micro.font)
                    .foregroundStyle(theme.palette.textTertiary)
                Spacer()
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.palette.accentOn)
                        .frame(width: 28, height: 28)
                        .background(theme.palette.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.4 : 1)
                .accessibilityIdentifier("assistant-chat-send")
            }
        }
        .padding(theme.metrics.spacing.md)
        .background(theme.palette.surfaceRaised)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.sheet, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.sheet, style: .continuous)
                .strokeBorder(theme.palette.lineStrong, lineWidth: theme.metrics.hairline)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .padding(theme.metrics.spacing.md)
        .accessibilityIdentifier("assistant-chat-composer")
    }

    private var isDisabled: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking
    }
}

struct AssistantChatBubble: View {
    @Environment(\.theme) private var theme
    let message: AssistantMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 28) }
            Text(message.text)
                .font(theme.type.caption.font)
                .foregroundStyle(
                    message.role == .status ? theme.palette.textTertiary : theme.palette.textPrimary
                )
                .textSelection(.enabled)
                .padding(.horizontal, theme.metrics.spacing.md)
                .padding(.vertical, 9)
                .background(background)
                .clipShape(
                    RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
                )
            if message.role != .user { Spacer(minLength: 28) }
        }
        .frame(maxWidth: .infinity)
    }

    private var background: Color {
        switch message.role {
        case .user: theme.palette.accentDim
        case .assistant: theme.palette.surfaceRaised
        case .status: theme.palette.surfaceRaised.opacity(0.55)
        }
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
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: theme.metrics.radius.control,
                                        style: .continuous
                                    )
                                )
                            }
                            .buttonStyle(ReelPlainButtonStyle())
                        }
                    }
                }
            } else {
                EmptyState(headline: "No edits on this page")
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
                    .buttonStyle(ReelPlainButtonStyle())
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
    @State private var isSmartActionsExpanded = false
    @State private var textDraft = ""
    @State private var strokeValue = 4.0
    @State private var textSizeValue = 28.0
    @State private var blurValue = 18.0
    @State private var paddingValue = 0.08
    @State private var radiusValue = 18.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Inspector")
                    .font(theme.type.title.font)
                Spacer()
                Text(editor.activeTool.title)
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 7)
                    .background(theme.palette.surfaceRaised)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            Divider().overlay(theme.palette.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    transformSection

                    if let layer = editor.selectedLayer {
                        selectedLayerSection(layer)
                    } else {
                        noSelectionSection
                    }

                    layerListSection
                    smartActionsSection
                }
                .padding(14)
            }
            .scrollIndicators(.visible)
        }
        .onAppear(perform: loadSelectedValues)
        .onChange(of: editor.selectedLayerID) { _, _ in loadSelectedValues() }
        .onChange(of: editor.document) { _, _ in loadSelectedValues() }
    }

    private var transformSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("Canvas", symbol: "aspectratio")
            HStack(spacing: 5) {
                inspectorIconButton("Rotate left", symbol: "rotate.left") {
                    editor.rotate(by: -90)
                }
                inspectorIconButton("Rotate right", symbol: "rotate.right") {
                    editor.rotate(by: 90)
                }
                inspectorIconButton(
                    "Flip horizontally",
                    symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right"
                ) {
                    editor.flipHorizontally()
                }
                inspectorIconButton(
                    "Flip vertically",
                    symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down"
                ) {
                    editor.flipVertically()
                }
                Spacer()
                Text("\(editor.document.canvas.width) × \(editor.document.canvas.height)")
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
    }

    private var noSelectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Properties", symbol: "slider.horizontal.3")
            EmptyState(headline: "No layer selected")
        }
    }

    private func selectedLayerSection(_ layer: Layer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(layer.kindName, symbol: layer.inspectorSymbol)
                Spacer()
                Menu {
                    Button("Duplicate") { editor.duplicateSelectedLayer() }
                    Button("Move forward") { editor.moveLayer(layer.id, by: 1) }
                    Button("Move backward") { editor.moveLayer(layer.id, by: -1) }
                    Divider()
                    Button("Delete", role: .destructive) { editor.removeSelectedLayer() }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            selectedProperties(layer)

            HStack(spacing: 6) {
                Button {
                    editor.toggleVisibility(layer.id)
                } label: {
                    Label(
                        layer.isVisible ? "Visible" : "Hidden",
                        systemImage: layer.isVisible ? "eye" : "eye.slash")
                }
                .buttonStyle(ReelBorderedButtonStyle())

                Button {
                    editor.toggleLock(layer.id)
                } label: {
                    Label(
                        layer.isLocked ? "Locked" : "Unlocked",
                        systemImage: layer.isLocked ? "lock.fill" : "lock.open")
                }
                .buttonStyle(ReelBorderedButtonStyle())
            }
        }
        .padding(11)
        .background(theme.palette.surfaceRaised.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.card, style: .continuous)
                .strokeBorder(theme.palette.line, lineWidth: theme.metrics.hairline)
        }
    }

    @ViewBuilder private func selectedProperties(_ layer: Layer) -> some View {
        switch layer {
        case .annotation:
            colorRow(for: layer)
            valueSlider(
                title: "Stroke",
                value: $strokeValue,
                range: 1...18,
                step: 1,
                suffix: "px"
            ) { editor.updateSelectedStrokeWidth(strokeValue) }

        case .text:
            TextField("Text", text: $textDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .onSubmit { editor.updateSelectedText(textDraft) }
            colorRow(for: layer)
            valueSlider(
                title: "Size",
                value: $textSizeValue,
                range: 8...72,
                step: 1,
                suffix: "pt"
            ) { editor.updateSelectedTextFontSize(textSizeValue) }

        case .highlight, .step:
            colorRow(for: layer)

        case .blur:
            valueSlider(
                title: "Strength",
                value: $blurValue,
                range: 4...48,
                step: 2,
                suffix: ""
            ) { editor.updateSelectedBlurRadius(blurValue) }

        case .redaction(let value):
            Picker("Style", selection: redactionModeBinding(for: value.style)) {
                ForEach(ImageRedactionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

        case .padding:
            valueSlider(
                title: "Padding",
                value: $paddingValue,
                range: 0.02...0.25,
                step: 0.01,
                suffix: "%",
                displayValue: Int((paddingValue * 100).rounded())
            ) { editor.updateSelectedPadding(amount: paddingValue) }
            valueSlider(
                title: "Corners",
                value: $radiusValue,
                range: 0...64,
                step: 1,
                suffix: "px"
            ) { editor.updateSelectedPadding(cornerRadius: radiusValue) }
        }
    }

    private var layerListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("Layers", symbol: "square.3.layers.3d")
                Spacer()
                Text("\(editor.document.layers.count)")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            if editor.document.layers.isEmpty {
                EmptyState(headline: "No layers")
            } else {
                LazyVStack(spacing: 3) {
                    ForEach(Array(editor.document.layers.reversed())) { layer in
                        layerRow(layer)
                    }
                }
            }
        }
    }

    private var smartActionsSection: some View {
        DisclosureGroup(isExpanded: $isSmartActionsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
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
                                .lineLimit(1)
                        }
                        .font(theme.type.caption.font)
                    }
                    Button("Apply reviewed suggestions") {
                        editor.runImageCommand("applyRedactions")
                    }
                    .buttonStyle(ReelProminentButtonStyle())
                }

                Button("Generate alt text") {
                    editor.runImageCommand("generateAltText")
                }
                .buttonStyle(ReelBorderedButtonStyle())

                if let altText = editor.altText {
                    Text(altText)
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textSecondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 8)
        } label: {
            sectionHeader("Smart Actions", symbol: "sparkles")
        }
    }

    private func layerRow(_ layer: Layer) -> some View {
        HStack(spacing: 6) {
            Button {
                editor.toggleVisibility(layer.id)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .frame(width: 18)
            }
            .buttonStyle(ReelPlainButtonStyle())
            Button {
                editor.selectLayer(layer.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: layer.inspectorSymbol)
                        .foregroundStyle(
                            editor.selectedLayerID == layer.id
                                ? theme.palette.accent : theme.palette.textTertiary
                        )
                        .frame(width: 16)
                    Text(layer.kindName)
                        .lineLimit(1)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ReelPlainButtonStyle())
            Button {
                editor.toggleLock(layer.id)
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .frame(width: 18)
            }
            .buttonStyle(ReelPlainButtonStyle())
        }
        .font(theme.type.caption.font)
        .padding(.horizontal, 7)
        .frame(height: 34)
        .background(
            editor.selectedLayerID == layer.id ? theme.palette.accentDim : Color.clear
        )
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.control, style: .continuous)
        )
    }

    private func sectionHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(theme.type.label.font)
            .foregroundStyle(theme.palette.textSecondary)
    }

    private func inspectorIconButton(
        _ help: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 27, height: 27)
        }
        .buttonStyle(ReelIconButtonStyle())
        .help(help)
    }

    private func colorRow(for layer: Layer) -> some View {
        HStack {
            Text("Color")
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
            Spacer()
            ColorPicker("Color", selection: colorBinding(for: layer), supportsOpacity: false)
                .labelsHidden()
        }
    }

    private func valueSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String,
        displayValue: Int? = nil,
        commit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textTertiary)
                .frame(width: 52, alignment: .leading)
            Slider(value: value, in: range, step: step) { editing in
                if !editing { commit() }
            }
            Text("\(displayValue ?? Int(value.wrappedValue.rounded()))\(suffix)")
                .font(theme.type.numeric.font)
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func colorBinding(for layer: Layer) -> Binding<Color> {
        Binding(
            get: { Color(inspectorRGBA: layer.inspectorColor ?? editor.activeColor) },
            set: {
                let color = $0.inspectorRGBA
                editor.activeColor = color
                editor.updateSelectedColor(color)
            }
        )
    }

    private func redactionModeBinding(for style: RedactionStyle) -> Binding<ImageRedactionMode> {
        Binding(
            get: {
                switch style {
                case .pixelate: .pixelate
                case .blur: .blur
                case .solid: .solid
                }
            },
            set: { editor.updateSelectedRedactionMode($0) }
        )
    }

    private func loadSelectedValues() {
        guard let layer = editor.selectedLayer else { return }
        switch layer {
        case .annotation(let value): strokeValue = value.strokeWidth
        case .text(let value):
            textDraft = value.text
            textSizeValue = value.fontSize
        case .blur(let value): blurValue = value.radius
        case .padding(let value):
            paddingValue = value.amount
            radiusValue = value.cornerRadius
        case .highlight, .redaction, .step: break
        }
    }
}

extension Layer {
    fileprivate var inspectorSymbol: String {
        switch self {
        case .annotation(let value):
            switch value.kind {
            case .arrow: "arrow.up.right"
            case .box: "rectangle"
            case .ellipse: "circle"
            case .line: "line.diagonal"
            case .freehand: "pencil.tip"
            }
        case .text: "textformat"
        case .highlight: "highlighter"
        case .redaction: "eye.slash"
        case .blur: "drop.halffull"
        case .padding: "rectangle.inset.filled"
        case .step: "number.circle"
        }
    }

    fileprivate var inspectorColor: RGBA? {
        switch self {
        case .annotation(let value): value.strokeColor
        case .text(let value): value.color
        case .highlight(let value): value.color
        case .step(let value): value.fillColor
        case .redaction, .blur, .padding: nil
        }
    }
}

extension Color {
    fileprivate init(inspectorRGBA color: RGBA) {
        self.init(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: color.a)
    }

    fileprivate var inspectorRGBA: RGBA {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else {
            return RGBA(r: 1, g: 0.29, b: 0.25, a: 1)
        }
        return RGBA(
            r: Double(color.redComponent),
            g: Double(color.greenComponent),
            b: Double(color.blueComponent),
            a: Double(color.alphaComponent)
        )
    }
}
