import AIKit
import CoreGraphics
import CoreModel
import Foundation
import MediaEngine
import Observation

public enum ImageEditorTool: String, CaseIterable, Sendable, Identifiable {
    case select
    case pan
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
        case .pan: "Pan"
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
        case .pan: "hand.draw"
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

public enum ImageRedactionMode: String, CaseIterable, Sendable, Identifiable {
    case pixelate
    case blur
    case solid

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }
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
    public var pendingCrop: CGRect?
    public var selectedLayerID: LayerID?
    public var activeTool: ImageEditorTool = .select
    public var activeColor = RGBA(r: 0.96, g: 0.29, b: 0.25, a: 1)
    public var strokeWidth = 4.0
    public var textFontSize = 28.0
    public var blurRadius = 18.0
    public var redactionMode: ImageRedactionMode = .pixelate
    /// Current library location for the source image.
    public private(set) var sourceURL: URL
    /// Canonical library filename after collision and extension handling.
    public private(set) var sourceDisplayName: String
    public let undoManager = UndoManager()

    private let renderer: ImageDocumentRenderer
    private let sourceCanvas: ImageCanvas
    private let persistence: @Sendable (ImageDocument) async throws -> Void
    private var renderTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?

    public init(
        document: ImageDocument,
        sourceURL: URL,
        sourceCanvas: ImageCanvas? = nil,
        renderer: ImageDocumentRenderer = ImageDocumentRenderer(),
        persisting: @escaping @Sendable (ImageDocument) async throws -> Void
    ) {
        self.document = document
        self.sourceURL = sourceURL
        self.sourceDisplayName = sourceURL.lastPathComponent
        self.sourceCanvas = sourceCanvas ?? document.canvas
        self.renderer = renderer
        self.persistence = persisting
        undoManager.groupsByEvent = false
    }

    public func start() { rebuild() }

    public func stop() {
        renderTask?.cancel()
        persistenceTask?.cancel()
    }

    /// Rebinds the editor after the library moves its source asset.
    ///
    /// Library assets keep a stable identifier when renamed, but image renders
    /// read from the source URL on every rebuild. Updating the URL and starting
    /// a fresh render together prevents the next edit from reading the old,
    /// now-missing path.
    public func relocateSource(to url: URL, displayName: String) {
        let relocatedURL = url.standardizedFileURL
        let didMove = relocatedURL != sourceURL.standardizedFileURL
        sourceURL = relocatedURL
        sourceDisplayName = displayName
        if didMove { rebuild() }
    }

    public func activate(_ tool: ImageEditorTool) {
        if activeTool == .crop, tool != .crop { pendingCrop = nil }
        activeTool = tool
    }

    public var selectedLayer: Layer? {
        guard let selectedLayerID else { return nil }
        return document.layers.first { $0.id == selectedLayerID }
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

    /// Adds OCR-derived regions through the same undoable layer path as a manual redaction.
    /// Regions use Clip's top-left normalized canvas coordinates.
    public func addRedaction(regions: [NormalizedRect]) {
        let rects = regions.compactMap { region -> CGRect? in
            let rect = CGRect(
                x: region.x,
                y: region.y,
                width: region.width,
                height: region.height
            ).standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return isUsable(rect) ? rect : nil
        }
        guard !rects.isEmpty else { return }
        let layer = Layer.redaction(RedactionLayer(regions: rects, style: redactionStyle))
        do {
            try perform(
                .addLayer(layer, atIndex: document.layers.count),
                actionName: "Redact Live Text"
            )
            selectedLayerID = layer.id
            notice = rects.count == 1 ? "Redaction added." : "Redactions added."
        } catch {
            notice = "The redaction could not be added."
        }
    }

    public func commitGesture(from start: CGPoint, to end: CGPoint) {
        commitGesture(points: [start, end])
    }

    public func commitGesture(points rawPoints: [CGPoint]) {
        guard let rawStart = rawPoints.first else { return }
        let points = rawPoints.map(clampedPoint)
        let start = clampedPoint(rawStart)
        let end = points.last ?? start
        let rect = normalizedRect(from: start, to: end)
        let layer: Layer
        switch activeTool {
        case .arrow:
            guard distance(from: start, to: end) > 0.01 else { return }
            layer = .annotation(
                AnnotationLayer(
                    kind: .arrow,
                    points: [start, end],
                    bounds: expandedBounds(rect),
                    strokeColor: activeColor,
                    strokeWidth: strokeWidth
                )
            )
        case .box:
            guard isUsable(rect) else { return }
            layer = .annotation(
                AnnotationLayer(
                    kind: .box,
                    bounds: rect,
                    strokeColor: activeColor,
                    strokeWidth: strokeWidth
                )
            )
        case .ellipse:
            guard isUsable(rect) else { return }
            layer = .annotation(
                AnnotationLayer(
                    kind: .ellipse,
                    bounds: rect,
                    strokeColor: activeColor,
                    strokeWidth: strokeWidth
                )
            )
        case .freehand:
            guard points.count > 1, pathLength(points) > 0.005 else { return }
            let bounds = expandedBounds(bounds(for: points))
            layer = .annotation(
                AnnotationLayer(
                    kind: .freehand,
                    points: points,
                    bounds: bounds,
                    strokeColor: activeColor,
                    strokeWidth: strokeWidth
                )
            )
        case .text:
            let frame =
                isUsable(rect)
                ? rect
                : CGRect(
                    x: min(start.x, 0.7),
                    y: min(start.y, 0.9),
                    width: min(0.28, 1 - min(start.x, 0.7)),
                    height: min(0.1, 1 - min(start.y, 0.9))
                )
            layer = .text(
                TextLayer(text: "Text", frame: frame, color: activeColor, fontSize: textFontSize)
            )
        case .highlight:
            guard isUsable(rect) else { return }
            layer = .highlight(
                HighlightLayer(
                    regions: [rect],
                    color: RGBA(
                        r: activeColor.r,
                        g: activeColor.g,
                        b: activeColor.b,
                        a: 0.32
                    )
                )
            )
        case .step:
            let count = document.layers.count {
                if case .step = $0 { return true }
                return false
            }
            layer = .step(
                StepLayer(number: count + 1, position: end, fillColor: activeColor)
            )
        case .redact:
            guard isUsable(rect) else { return }
            layer = .redaction(RedactionLayer(regions: [rect], style: redactionStyle))
        case .blur:
            guard isUsable(rect) else { return }
            layer = .blur(BlurLayer(regions: [rect], radius: blurRadius))
        case .select, .pan, .crop, .padding, .eyedropper:
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

    public func stageCrop(_ rect: CGRect) {
        let normalized = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        pendingCrop = isUsable(normalized) ? normalized : nil
    }

    public func stageCrop(aspectRatio: Double?) {
        guard let aspectRatio, aspectRatio > 0 else {
            pendingCrop = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
            return
        }
        let targetAspect = CGFloat(aspectRatio)
        let canvasAspect = CGFloat(document.canvas.width) / CGFloat(document.canvas.height)
        if targetAspect >= canvasAspect {
            let height = canvasAspect / targetAspect
            pendingCrop = CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        } else {
            let width = targetAspect / canvasAspect
            pendingCrop = CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
    }

    public func applyPendingCrop() {
        guard let pendingCrop else { return }
        let current = document.geometry.crop
        var geometry = document.geometry
        geometry.crop = CGRect(
            x: current.minX + pendingCrop.minX * current.width,
            y: current.minY + pendingCrop.minY * current.height,
            width: pendingCrop.width * current.width,
            height: pendingCrop.height * current.height
        )
        var canvas = document.canvas
        canvas.width = max(Int((CGFloat(canvas.width) * pendingCrop.width).rounded()), 1)
        canvas.height = max(Int((CGFloat(canvas.height) * pendingCrop.height).rounded()), 1)
        self.pendingCrop = nil
        do {
            try perform([.setGeometry(geometry), .setCanvas(canvas)], actionName: "Crop Image")
        } catch {
            notice = "The crop could not be applied."
        }
    }

    public func cancelPendingCrop() { pendingCrop = nil }

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
        var resetCanvas = sourceCanvas
        let quarterTurns = Int((geometry.rotationDegrees / 90).rounded())
        if abs(quarterTurns).isMultiple(of: 2) == false {
            swap(&resetCanvas.width, &resetCanvas.height)
        }
        pendingCrop = nil
        do {
            try perform(
                [.setGeometry(geometry), .setCanvas(resetCanvas)],
                actionName: "Reset Crop"
            )
        } catch {
            notice = "The crop could not be reset."
        }
    }

    public func rotate(by degrees: Double) {
        var geometry = document.geometry
        geometry.rotationDegrees = (geometry.rotationDegrees + degrees).truncatingRemainder(
            dividingBy: 360
        )
        var patches: [ImagePatch] = [.setGeometry(geometry)]
        let quarterTurns = Int((degrees / 90).rounded())
        if abs(quarterTurns).isMultiple(of: 2) == false {
            var canvas = document.canvas
            swap(&canvas.width, &canvas.height)
            patches.append(.setCanvas(canvas))
        }
        try? perform(patches, actionName: "Rotate Image")
    }

    public func flipHorizontally() {
        var geometry = document.geometry
        geometry.isFlippedHorizontally.toggle()
        try? perform(.setGeometry(geometry), actionName: "Flip Image Horizontally")
    }

    public func flipVertically() {
        var geometry = document.geometry
        geometry.isFlippedVertically.toggle()
        try? perform(.setGeometry(geometry), actionName: "Flip Image Vertically")
    }

    public func addPadding(amount: Double = 0.08, cornerRadius: Double = 18) {
        let layer = Layer.padding(
            PaddingLayer(
                amount: min(max(amount, 0.01), 0.35),
                cornerRadius: min(max(cornerRadius, 0), 80)
            )
        )
        do {
            try perform(.addLayer(layer, atIndex: document.layers.count), actionName: "Add Padding")
            selectedLayerID = layer.id
        } catch {
            notice = "Padding could not be added."
        }
    }

    public func selectLayer(_ id: LayerID?) { selectedLayerID = id }

    public func selectLayer(at point: CGPoint) {
        selectedLayerID =
            document.layers.reversed().first { layer in
                guard layer.isVisible else { return false }
                if case .padding = layer { return false }
                return hitBounds(for: layer).contains(point)
            }?.id
    }

    public func updateSelectedText(_ value: String) {
        guard case .text(var layer) = selectedLayer else { return }
        layer.text = value.isEmpty ? " " : value
        try? perform(.updateLayer(.text(layer)), actionName: "Edit Text")
    }

    public func updateSelectedColor(_ color: RGBA) {
        guard let layer = selectedLayer else { return }
        let updated: Layer
        switch layer {
        case .annotation(var value):
            value.strokeColor = color
            updated = .annotation(value)
        case .text(var value):
            value.color = color
            updated = .text(value)
        case .highlight(var value):
            value.color = RGBA(r: color.r, g: color.g, b: color.b, a: value.color.a)
            updated = .highlight(value)
        case .step(var value):
            value.fillColor = color
            updated = .step(value)
        case .redaction, .blur, .padding:
            return
        }
        activeColor = color
        try? perform(.updateLayer(updated), actionName: "Change Layer Color")
    }

    public func updateSelectedStrokeWidth(_ width: Double) {
        guard case .annotation(var layer) = selectedLayer else { return }
        layer.strokeWidth = min(max(width, 1), 24)
        strokeWidth = layer.strokeWidth
        try? perform(.updateLayer(.annotation(layer)), actionName: "Change Stroke Width")
    }

    public func updateSelectedTextFontSize(_ size: Double) {
        guard case .text(var layer) = selectedLayer else { return }
        layer.fontSize = min(max(size, 8), 120)
        textFontSize = layer.fontSize
        try? perform(.updateLayer(.text(layer)), actionName: "Change Text Size")
    }

    public func updateSelectedBlurRadius(_ radius: Double) {
        guard case .blur(var layer) = selectedLayer else { return }
        layer.radius = min(max(radius, 2), 60)
        blurRadius = layer.radius
        try? perform(.updateLayer(.blur(layer)), actionName: "Change Blur")
    }

    public func updateSelectedRedactionMode(_ mode: ImageRedactionMode) {
        guard case .redaction(var layer) = selectedLayer else { return }
        redactionMode = mode
        layer.style = redactionStyle
        try? perform(.updateLayer(.redaction(layer)), actionName: "Change Redaction Style")
    }

    public func updateSelectedPadding(amount: Double? = nil, cornerRadius: Double? = nil) {
        guard case .padding(var layer) = selectedLayer else { return }
        if let amount { layer.amount = min(max(amount, 0.01), 0.35) }
        if let cornerRadius { layer.cornerRadius = min(max(cornerRadius, 0), 80) }
        try? perform(.updateLayer(.padding(layer)), actionName: "Change Padding")
    }

    public func moveSelectedLayer(by delta: CGPoint) {
        guard let layer = selectedLayer, !layer.isLocked else {
            if selectedLayer?.isLocked == true { notice = "Unlock the layer before moving it." }
            return
        }
        let bounds = layerBounds(for: layer)
        let translation = CGPoint(
            x: min(max(delta.x, -bounds.minX), 1 - bounds.maxX),
            y: min(max(delta.y, -bounds.minY), 1 - bounds.maxY)
        )
        guard abs(translation.x) > 0.0001 || abs(translation.y) > 0.0001 else { return }
        let updated = translating(layer, by: translation)
        try? perform(.updateLayer(updated), actionName: "Move Layer")
    }

    public func duplicateSelectedLayer() {
        guard let selectedLayer else { return }
        let duplicate = duplicating(selectedLayer, offset: CGPoint(x: 0.025, y: 0.025))
        do {
            try perform(
                .addLayer(duplicate, atIndex: document.layers.count),
                actionName: "Duplicate Layer"
            )
            selectedLayerID = duplicate.id
        } catch {
            notice = "The layer could not be duplicated."
        }
    }

    public func removeSelectedLayer() {
        guard let selectedLayerID else { return }
        removeLayer(selectedLayerID)
    }

    public func sampleColor(at point: CGPoint) {
        guard let renderedImage, let color = sampledColor(in: renderedImage, at: point) else {
            notice = "A color could not be sampled here."
            return
        }
        activeColor = color
        notice = "Color sampled."
        activeTool = .select
    }

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

    private var redactionStyle: RedactionStyle {
        switch redactionMode {
        case .pixelate: .pixelate(size: 12)
        case .blur: .blur(radius: blurRadius)
        case .solid: .solid(.black)
        }
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    private func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { result, pair in
            result + distance(from: pair.0, to: pair.1)
        }
    }

    private func isUsable(_ rect: CGRect) -> Bool {
        rect.width > 0.008 && rect.height > 0.008
    }

    private func bounds(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { result, point in
            result.union(CGRect(origin: point, size: .zero))
        }
    }

    private func expandedBounds(_ rect: CGRect) -> CGRect {
        let minimum: CGFloat = 0.001
        let width = max(rect.width, minimum)
        let height = max(rect.height, minimum)
        return CGRect(
            x: min(max(rect.midX - width / 2, 0), 1 - width),
            y: min(max(rect.midY - height / 2, 0), 1 - height),
            width: width,
            height: height
        )
    }

    private func hitBounds(for layer: Layer) -> CGRect {
        layerBounds(for: layer).insetBy(dx: -0.012, dy: -0.012)
    }

    private func layerBounds(for layer: Layer) -> CGRect {
        let bounds: CGRect
        switch layer {
        case .annotation(let value): bounds = value.bounds
        case .text(let value): bounds = value.frame
        case .highlight(let value): bounds = union(value.regions)
        case .redaction(let value): bounds = union(value.regions)
        case .blur(let value): bounds = union(value.regions)
        case .padding: bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        case .step(let value):
            let diameter =
                CGFloat(value.diameter)
                / CGFloat(min(document.canvas.width, document.canvas.height))
            bounds = CGRect(
                x: value.position.x - diameter / 2,
                y: value.position.y - diameter / 2,
                width: diameter,
                height: diameter
            )
        }
        return bounds
    }

    private func union(_ rects: [CGRect]) -> CGRect {
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private func translating(_ layer: Layer, by delta: CGPoint) -> Layer {
        switch layer {
        case .annotation(var value):
            value.bounds = value.bounds.offsetBy(dx: delta.x, dy: delta.y)
            value.points = value.points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
            return .annotation(value)
        case .text(var value):
            value.frame = value.frame.offsetBy(dx: delta.x, dy: delta.y)
            return .text(value)
        case .highlight(var value):
            value.regions = value.regions.map { $0.offsetBy(dx: delta.x, dy: delta.y) }
            return .highlight(value)
        case .redaction(var value):
            value.regions = value.regions.map { $0.offsetBy(dx: delta.x, dy: delta.y) }
            return .redaction(value)
        case .blur(var value):
            value.regions = value.regions.map { $0.offsetBy(dx: delta.x, dy: delta.y) }
            return .blur(value)
        case .padding:
            return layer
        case .step(var value):
            value.position = CGPoint(
                x: value.position.x + delta.x,
                y: value.position.y + delta.y
            )
            return .step(value)
        }
    }

    private func duplicating(_ layer: Layer, offset: CGPoint) -> Layer {
        switch translating(layer, by: offset) {
        case .annotation(var value):
            value.id = .generate()
            return .annotation(value)
        case .text(var value):
            value.id = .generate()
            return .text(value)
        case .highlight(var value):
            value.id = .generate()
            return .highlight(value)
        case .redaction(var value):
            value.id = .generate()
            return .redaction(value)
        case .blur(var value):
            value.id = .generate()
            return .blur(value)
        case .padding(var value):
            value.id = .generate()
            return .padding(value)
        case .step(var value):
            value.id = .generate()
            value.number =
                document.layers.count {
                    if case .step = $0 { return true }
                    return false
                } + 1
            return .step(value)
        }
    }

    private func sampledColor(in image: CGImage, at point: CGPoint) -> RGBA? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard
            let context = CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        let x = floor(clampedPoint(point).x * CGFloat(max(image.width - 1, 1)))
        let topY = floor(clampedPoint(point).y * CGFloat(max(image.height - 1, 1)))
        let y = CGFloat(image.height - 1) - topY
        context.translateBy(x: -x, y: -y)
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        )
        let alpha = Double(pixel[3]) / 255
        guard alpha > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        return RGBA(
            r: min(Double(pixel[0]) / 255 / alpha, 1),
            g: min(Double(pixel[1]) / 255 / alpha, 1),
            b: min(Double(pixel[2]) / 255 / alpha, 1),
            a: alpha
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
