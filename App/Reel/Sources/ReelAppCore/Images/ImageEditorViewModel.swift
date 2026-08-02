import AIKit
import CoreGraphics
import CoreModel
import Foundation
import MediaEngine
import Observation

public enum ImageEditorTool: String, CaseIterable, Sendable, Identifiable {
    case select
    case crop
    case arrow
    case box
    case ellipse
    case freehand
    case text
    case highlight
    case step
    case redact
    case blur
    case padding
    case eyedropper

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .freehand: "Draw"
        case .step: "Step"
        case .redact: "Redact"
        case .eyedropper: "Color"
        default: rawValue.capitalized
        }
    }

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .ellipse: "circle"
        case .freehand: "pencil.tip"
        case .text: "textformat"
        case .highlight: "highlighter"
        case .step: "1.circle"
        case .redact: "eye.slash"
        case .blur: "drop.halffull"
        case .padding: "rectangle.inset.filled"
        case .eyedropper: "eyedropper"
        }
    }
}

@MainActor
@Observable
public final class ImageEditorViewModel {
    public private(set) var document: ImageDocument
    public private(set) var renderedImage: CGImage?
    public private(set) var isRendering = false
    public private(set) var notice: String?
    public private(set) var redactionSuggestions: [RedactionSuggestion] = []
    public private(set) var altText: String?
    public var selectedLayerID: LayerID?
    public var activeTool: ImageEditorTool = .select
    public let sourceURL: URL
    public let undoManager = UndoManager()

    private let renderer: ImageDocumentRenderer
    private let persistence: @Sendable (ImageDocument) async throws -> Void
    private var renderTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?

    public init(
        document: ImageDocument,
        sourceURL: URL,
        renderer: ImageDocumentRenderer = ImageDocumentRenderer(),
        persisting: @escaping @Sendable (ImageDocument) async throws -> Void
    ) {
        self.document = document
        self.sourceURL = sourceURL
        self.renderer = renderer
        self.persistence = persisting
        undoManager.groupsByEvent = false
    }

    public func start() { rebuild() }

    public func stop() {
        renderTask?.cancel()
        persistenceTask?.cancel()
    }

    public func activate(_ tool: ImageEditorTool) {
        activeTool = tool
        switch tool {
        case .crop: cropToInset()
        case .padding: addPadding()
        default: break
        }
    }

    public func perform(_ patch: ImagePatch, actionName: String) throws {
        try perform([patch], actionName: actionName)
    }

    public func perform(_ patches: [ImagePatch], actionName: String) throws {
        guard !patches.isEmpty else { return }
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        var candidate = document
        var inverses: [ImagePatch] = []
        for patch in patches { inverses.append(try candidate.apply(patch)) }
        document = candidate
        if let selectedLayerID,
            !document.layers.contains(where: { $0.id == selectedLayerID })
        {
            self.selectedLayerID = nil
        }
        registerUndo(Array(inverses.reversed()), actionName: actionName)
        undoManager.setActionName(actionName)
        persist()
        rebuild()
    }

    public func undo() { undoManager.undo() }
    public func redo() { undoManager.redo() }

    public func commitGesture(from start: CGPoint, to end: CGPoint) {
        let rect = normalizedRect(from: start, to: end)
        guard rect.width > 0.01, rect.height > 0.01 else { return }
        let layer: Layer
        switch activeTool {
        case .arrow:
            layer = .annotation(
                AnnotationLayer(kind: .arrow, points: [start, end], bounds: rect)
            )
        case .box:
            layer = .annotation(AnnotationLayer(kind: .box, bounds: rect))
        case .ellipse:
            layer = .annotation(AnnotationLayer(kind: .ellipse, bounds: rect))
        case .freehand:
            layer = .annotation(
                AnnotationLayer(kind: .freehand, points: [start, end], bounds: rect)
            )
        case .text:
            layer = .text(TextLayer(text: "Text", frame: rect))
        case .highlight:
            layer = .highlight(HighlightLayer(regions: [rect]))
        case .step:
            let count = document.layers.count {
                if case .step = $0 { return true }
                return false
            }
            layer = .step(StepLayer(number: count + 1, position: end))
        case .redact:
            layer = .redaction(RedactionLayer(regions: [rect], style: .pixelate(size: 12)))
        case .blur:
            layer = .blur(BlurLayer(regions: [rect]))
        case .select, .crop, .padding, .eyedropper:
            return
        }
        do {
            try perform(
                .addLayer(layer, atIndex: document.layers.count),
                actionName: "Add \(layer.kindName)")
            selectedLayerID = layer.id
        } catch {
            notice = "The layer could not be added."
        }
    }

    public func cropToInset() {
        var geometry = document.geometry
        geometry.crop = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        do {
            try perform(.setGeometry(geometry), actionName: "Crop Image")
        } catch {
            notice = "The crop could not be applied."
        }
    }

    public func resetCrop() {
        var geometry = document.geometry
        geometry.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        do {
            try perform(.setGeometry(geometry), actionName: "Reset Crop")
        } catch {
            notice = "The crop could not be reset."
        }
    }

    public func addPadding() {
        let layer = Layer.padding(PaddingLayer())
        do {
            try perform(.addLayer(layer, atIndex: document.layers.count), actionName: "Add Padding")
            selectedLayerID = layer.id
        } catch {
            notice = "Padding could not be added."
        }
    }

    public func selectLayer(_ id: LayerID?) { selectedLayerID = id }

    public func toggleVisibility(_ id: LayerID) {
        guard let layer = document.layers.first(where: { $0.id == id }) else { return }
        try? perform(
            .updateLayer(layer.settingVisibility(!layer.isVisible)),
            actionName: layer.isVisible ? "Hide Layer" : "Show Layer"
        )
    }

    public func toggleLock(_ id: LayerID) {
        guard let layer = document.layers.first(where: { $0.id == id }) else { return }
        try? perform(
            .updateLayer(layer.settingLocked(!layer.isLocked)),
            actionName: layer.isLocked ? "Unlock Layer" : "Lock Layer"
        )
    }

    public func moveLayer(_ id: LayerID, by offset: Int) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(index + offset, 0), document.layers.count - 1)
        guard destination != index else { return }
        try? perform(.reorderLayer(id, to: destination), actionName: "Reorder Layer")
    }

    public func removeLayer(_ id: LayerID) {
        do {
            try perform(.removeLayer(id), actionName: "Remove Layer")
        } catch {
            notice = "The layer could not be removed."
        }
    }

    public func runImageCommand(_ id: String) {
        let arguments: JSONValue
        switch id {
        case "cropTo":
            arguments = .object(["aspect": .string("16:9")])
        case "addAnnotation":
            arguments = .object([
                "type": .string("arrow"),
                "rect": .object([
                    "x": .number(0.2), "y": .number(0.2),
                    "width": .number(0.35), "height": .number(0.25),
                ]),
            ])
        case "applyRedactions":
            arguments = .object([
                "suggestionIDs": .array(redactionSuggestions.map { .string($0.id) })
            ])
        default:
            arguments = .object([:])
        }
        let context = ImageToolExecutionContext(
            document: document,
            sourceURL: sourceURL,
            suggestions: redactionSuggestions
        )
        Task {
            do {
                let result = try await ImageToolExecutor().execute(
                    ToolInvocation(callID: UUID().uuidString, name: id, arguments: arguments),
                    context: context
                )
                if !result.suggestions.isEmpty { redactionSuggestions = result.suggestions }
                if let value = result.value { altText = value }
                if !result.patches.isEmpty {
                    try perform(
                        result.patches, actionName: CommandRegistry.command(named: id)?.title ?? id)
                }
                notice = result.message
            } catch {
                notice = "The image command could not be completed."
            }
        }
    }

    public func export(to url: URL, format: ImageExportFormat) {
        let document = document
        let sourceURL = sourceURL
        let renderer = renderer
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try renderer.export(document, sourceURL: sourceURL, to: url, format: format)
                }.value
                notice = "Exported \(url.lastPathComponent)."
            } catch {
                notice = "The image could not be exported."
            }
        }
    }

    public func clearNotice() { notice = nil }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func registerUndo(_ patches: [ImagePatch], actionName: String) {
        undoManager.registerUndo(withTarget: self) { target in
            do {
                var candidate = target.document
                var redos: [ImagePatch] = []
                for patch in patches { redos.append(try candidate.apply(patch)) }
                target.document = candidate
                target.registerUndo(Array(redos.reversed()), actionName: actionName)
                target.undoManager.setActionName(actionName)
                target.persist()
                target.rebuild()
            } catch {
                target.notice = "Undo could not restore the previous image edit."
            }
        }
    }

    private func persist() {
        let snapshot = document
        let persistence = persistence
        let precedingTask = persistenceTask
        persistenceTask = Task { [weak self] in
            _ = await precedingTask?.result
            do {
                try await persistence(snapshot)
            } catch {
                self?.notice = "The image edits could not be saved."
            }
        }
    }

    private func rebuild() {
        renderTask?.cancel()
        let document = document
        let sourceURL = sourceURL
        let renderer = renderer
        isRendering = true
        renderTask = Task { [weak self] in
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try renderer.renderPreview(document, sourceURL: sourceURL)
                }.value
                try Task.checkCancellation()
                self?.renderedImage = image
                self?.isRendering = false
            } catch is CancellationError {
                // A newer edit superseded this render.
            } catch {
                self?.isRendering = false
                self?.notice = "The image preview could not be rendered."
            }
        }
    }
}
