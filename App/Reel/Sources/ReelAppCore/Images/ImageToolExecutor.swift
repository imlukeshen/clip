import AIKit
import CoreGraphics
import CoreModel
import Foundation

public struct ImageToolExecutionContext: Sendable {
    public var document: ImageDocument
    public var sourceURL: URL
    public var suggestions: [RedactionSuggestion]

    public init(
        document: ImageDocument,
        sourceURL: URL,
        suggestions: [RedactionSuggestion] = []
    ) {
        self.document = document
        self.sourceURL = sourceURL
        self.suggestions = suggestions
    }
}

public struct ImageToolResult: Sendable, Equatable {
    public var message: String
    public var patches: [ImagePatch]
    public var suggestions: [RedactionSuggestion]
    public var value: String?

    public init(
        message: String,
        patches: [ImagePatch] = [],
        suggestions: [RedactionSuggestion] = [],
        value: String? = nil
    ) {
        self.message = message
        self.patches = patches
        self.suggestions = suggestions
        self.value = value
    }
}

public struct ImageToolExecutor: Sendable {
    private let suggester: OnDeviceRedactionSuggester
    private let altTextGenerator: OnDeviceAltTextGenerator

    public init(
        suggester: OnDeviceRedactionSuggester = OnDeviceRedactionSuggester(),
        altTextGenerator: OnDeviceAltTextGenerator = OnDeviceAltTextGenerator()
    ) {
        self.suggester = suggester
        self.altTextGenerator = altTextGenerator
    }

    public func execute(
        _ invocation: ToolInvocation,
        context: ImageToolExecutionContext
    ) async throws -> ImageToolResult {
        guard let command = CommandRegistry.command(named: invocation.name),
            command.category == .image
        else { throw ImageToolExecutorError.unknownTool(invocation.name) }

        switch invocation.name {
        case "cropTo":
            let arguments = try invocation.arguments.decode(CropArguments.self)
            var geometry = context.document.geometry
            if let rect = arguments.rect?.cgRect {
                geometry.crop = rect
            } else if let aspect = arguments.aspect {
                geometry.crop = try centeredCrop(for: aspect, canvas: context.document.canvas)
            } else {
                throw ImageToolExecutorError.invalidArguments("Provide aspect or rect.")
            }
            return ImageToolResult(
                message: "Prepared the image crop.", patches: [.setGeometry(geometry)])

        case "addAnnotation":
            let arguments = try invocation.arguments.decode(AnnotationArguments.self)
            let layer = try annotation(arguments)
            return ImageToolResult(
                message: "Prepared a \(arguments.type) annotation.",
                patches: [.addLayer(layer, atIndex: context.document.layers.count)]
            )

        case "suggestRedactions":
            let suggestions = try await suggester.suggestions(in: context.sourceURL)
            return ImageToolResult(
                message:
                    "Found \(suggestions.count) possible sensitive region\(suggestions.count == 1 ? "" : "s") on device.",
                suggestions: suggestions
            )

        case "applyRedactions":
            let arguments = try invocation.arguments.decode(ApplyRedactionsArguments.self)
            let selected = context.suggestions.filter { arguments.suggestionIDs.contains($0.id) }
            guard selected.count == arguments.suggestionIDs.count else {
                throw ImageToolExecutorError.unknownSuggestion
            }
            let layer = Layer.redaction(
                RedactionLayer(regions: selected.map(\.region), style: .pixelate(size: 12))
            )
            return ImageToolResult(
                message:
                    "Prepared \(selected.count) reviewed redaction\(selected.count == 1 ? "" : "s").",
                patches: [.addLayer(layer, atIndex: context.document.layers.count)]
            )

        case "addPadding":
            let arguments = try invocation.arguments.decode(PaddingArguments.self)
            let layer = Layer.padding(
                PaddingLayer(
                    amount: arguments.amount ?? 0.08,
                    color: arguments.color?.rgba ?? RGBA(r: 0.08, g: 0.09, b: 0.12, a: 1)
                )
            )
            return ImageToolResult(
                message: "Prepared image padding.",
                patches: [.addLayer(layer, atIndex: context.document.layers.count)]
            )

        case "generateAltText":
            let value = try await altTextGenerator.generate(for: context.sourceURL)
            return ImageToolResult(message: "Generated alt text on device.", value: value)

        case "numberSteps":
            let steps = context.document.layers.compactMap { layer -> StepLayer? in
                if case .step(let value) = layer { return value }
                return nil
            }.sorted {
                $0.position.y == $1.position.y
                    ? $0.position.x < $1.position.x : $0.position.y < $1.position.y
            }
            let patches = steps.enumerated().map { index, step -> ImagePatch in
                var updated = step
                updated.number = index + 1
                return .updateLayer(.step(updated))
            }
            return ImageToolResult(
                message: "Numbered \(steps.count) step badge\(steps.count == 1 ? "" : "s").",
                patches: patches
            )

        default:
            throw ImageToolExecutorError.unknownTool(invocation.name)
        }
    }

    private func centeredCrop(for aspect: String, canvas: ImageCanvas) throws -> CGRect {
        let ratio: Double
        if aspect.localizedCaseInsensitiveCompare("square") == .orderedSame {
            ratio = 1
        } else {
            let parts = aspect.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
                throw ImageToolExecutorError.invalidArguments(
                    "Aspect must look like 16:9 or square.")
            }
            ratio = parts[0] / parts[1]
        }
        let sourceRatio = Double(canvas.width) / Double(canvas.height)
        if ratio > sourceRatio {
            let height = sourceRatio / ratio
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        let width = ratio / sourceRatio
        return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }

    private func annotation(_ arguments: AnnotationArguments) throws -> Layer {
        let rect = arguments.rect.cgRect
        switch arguments.type.lowercased() {
        case "arrow":
            return .annotation(
                AnnotationLayer(
                    kind: .arrow,
                    points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)],
                    bounds: rect
                )
            )
        case "box": return .annotation(AnnotationLayer(kind: .box, bounds: rect))
        case "ellipse": return .annotation(AnnotationLayer(kind: .ellipse, bounds: rect))
        case "text": return .text(TextLayer(text: arguments.text ?? "Text", frame: rect))
        case "highlight": return .highlight(HighlightLayer(regions: [rect]))
        case "step":
            return .step(StepLayer(number: 1, position: CGPoint(x: rect.midX, y: rect.midY)))
        default:
            throw ImageToolExecutorError.invalidArguments("Unknown annotation type.")
        }
    }
}

public enum ImageToolExecutorError: Error, Sendable, Equatable {
    case unknownTool(String)
    case invalidArguments(String)
    case unknownSuggestion
}

private struct RectArguments: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private struct CropArguments: Codable {
    var aspect: String?
    var rect: RectArguments?
}

private struct AnnotationArguments: Codable {
    var type: String
    var rect: RectArguments
    var text: String?
}

private struct ApplyRedactionsArguments: Codable { var suggestionIDs: [String] }

private struct ColorArguments: Codable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double?
    var rgba: RGBA { RGBA(r: r, g: g, b: b, a: a ?? 1) }
}

private struct PaddingArguments: Codable {
    var amount: Double?
    var color: ColorArguments?
}
