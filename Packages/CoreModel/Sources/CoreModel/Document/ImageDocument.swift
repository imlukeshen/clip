import CoreGraphics
import Foundation

public enum DocumentTag: Sendable {}
public typealias DocumentID = TypedID<DocumentTag>

public enum LayerTag: Sendable {}
public typealias LayerID = TypedID<LayerTag>

public enum ImageOrientation: String, Codable, Sendable, Equatable, CaseIterable {
    case up
    case right
    case down
    case left
}

public struct ImageCanvas: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var background: RGBA
    public var orientation: ImageOrientation

    public init(
        width: Int,
        height: Int,
        background: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0),
        orientation: ImageOrientation = .up
    ) {
        self.width = width
        self.height = height
        self.background = background
        self.orientation = orientation
    }
}

/// Source-relative geometry. Crop coordinates are normalized to the source image.
public struct Geometry: Codable, Sendable, Equatable {
    public var crop: CGRect
    public var rotationDegrees: Double
    public var isFlippedHorizontally: Bool
    public var isFlippedVertically: Bool
    public var scale: Double

    public init(
        crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        rotationDegrees: Double = 0,
        isFlippedHorizontally: Bool = false,
        isFlippedVertically: Bool = false,
        scale: Double = 1
    ) {
        self.crop = crop
        self.rotationDegrees = rotationDegrees
        self.isFlippedHorizontally = isFlippedHorizontally
        self.isFlippedVertically = isFlippedVertically
        self.scale = scale
    }
}

public enum AnnotationKind: String, Codable, Sendable, Equatable, CaseIterable {
    case arrow
    case box
    case ellipse
    case line
    case freehand
}

public struct AnnotationLayer: Codable, Sendable, Equatable {
    public var id: LayerID
    public var kind: AnnotationKind
    public var points: [CGPoint]
    public var bounds: CGRect
    public var strokeColor: RGBA
    public var fillColor: RGBA?
    public var strokeWidth: Double
    public var isVisible: Bool
    public var isLocked: Bool

    public init(
        id: LayerID = .generate(),
        kind: AnnotationKind,
        points: [CGPoint] = [],
        bounds: CGRect,
        strokeColor: RGBA = RGBA(r: 1, g: 0.25, b: 0.2, a: 1),
        fillColor: RGBA? = nil,
        strokeWidth: Double = 4,
        isVisible: Bool = true,
        isLocked: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.bounds = bounds
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.strokeWidth = strokeWidth
        self.isVisible = isVisible
        self.isLocked = isLocked
    }
}

public enum TextAlignment: String, Codable, Sendable, Equatable, CaseIterable {
    case leading
    case center
    case trailing
}

public struct TextLayer: Codable, Sendable, Equatable {
    public var id: LayerID
    public var text: String
    public var frame: CGRect
    public var color: RGBA
    public var fontName: String
    public var fontSize: Double
    public var alignment: TextAlignment
    public var isVisible: Bool
    public var isLocked: Bool

    public init(
        id: LayerID = .generate(),
        text: String,
        frame: CGRect,
        color: RGBA = RGBA(r: 1, g: 1, b: 1, a: 1),
        fontName: String = "SF Pro",
        fontSize: Double = 28,
        alignment: TextAlignment = .leading,
        isVisible: Bool = true,
        isLocked: Bool = false
    ) {
        self.id = id
        self.text = text
        self.frame = frame
        self.color = color
        self.fontName = fontName
        self.fontSize = fontSize
        self.alignment = alignment
        self.isVisible = isVisible
        self.isLocked = isLocked
    }
}

public struct HighlightLayer: Codable, Sendable, Equatable {
    public var id: LayerID
    public var regions: [CGRect]
    public var color: RGBA
    public var isVisible: Bool
    public var isLocked: Bool

    public init(
        id: LayerID = .generate(),
        regions: [CGRect],
        color: RGBA = RGBA(r: 1, g: 0.82, b: 0.1, a: 0.35),
        isVisible: Bool = true,
        isLocked: Bool = false
    ) {
        self.id = id
        self.regions = regions
        self.color = color
        self.isVisible = isVisible
        self.isLocked = isLocked
    }
}

public enum RedactionStyle: Codable, Sendable, Equatable {
    case solid(RGBA)
    case pixelate(size: Int)
    case blur(radius: Double)
}

public struct RedactionLayer: Codable, Sendable, Equatable {
    public var id: LayerID
    public var regions: [CGRect]
    public var style: RedactionStyle
    public var isVisible: Bool
    public var isLocked: Bool

    public init(
        id: LayerID = .generate(),
        regions: [CGRect],
        style: RedactionStyle = .solid(.black),
        isVisible: Bool = true,
        isLocked: Bool = false
    ) {
        self.id = id
        self.regions = regions
        self.style = style
        self.isVisible = isVisible
        self.isLocked = isLocked
    }
}

public struct BlurLayer: Codable, Sendable, Equatable {
    public var id: LayerID
    public var regions: [CGRect]
    public var radius: Double
    public var isVisible: Bool
    public var isLocked: Bool

    public init(
        id: LayerID = .generate(),
        regions: [CGRect],
        radius: Double = 18,
        isVisible: Bool = true,
        isLocked: Bool = false
    ) {
        self.id = id
        self.regions = regions
        self.radius = radius
        self.isVisible = isVisible
        self.isLocked = isLocked
    }
}

public struct ImageShadow: Codable, Sendable, Equatable {
    public var color: RGBA
    public var radius: Double
    public var offset: CGPoint

    public init(
        color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.35),
        radius: Double = 18,
        offset: CGPoint = CGPoint(x: 0, y: 8)
    ) {
        self.color = color
        self.radius = radius
        self.offset = offset
    }
}

public struct PaddingLayer: Codable, Sendable, Equatable {
    public var id: LayerID
    /// Insets expressed as fractions of the shorter canvas edge.
    public var amount: Double
    public var color: RGBA
    public var cornerRadius: Double
    public var shadow: ImageShadow?
    public var isVisible: Bool
    public var isLocked: Bool

    public init(
        id: LayerID = .generate(),
        amount: Double = 0.08,
        color: RGBA = RGBA(r: 0.08, g: 0.09, b: 0.12, a: 1),
        cornerRadius: Double = 18,
        shadow: ImageShadow? = ImageShadow(),
        isVisible: Bool = true,
        isLocked: Bool = false
    ) {
        self.id = id
        self.amount = amount
        self.color = color
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.isVisible = isVisible
        self.isLocked = isLocked
    }
}

public struct StepLayer: Codable, Sendable, Equatable {
    public var id: LayerID
    public var number: Int
    public var position: CGPoint
    public var fillColor: RGBA
    public var textColor: RGBA
    public var diameter: Double
    public var isVisible: Bool
    public var isLocked: Bool

    public init(
        id: LayerID = .generate(),
        number: Int,
        position: CGPoint,
        fillColor: RGBA = RGBA(r: 0.24, g: 0.47, b: 1, a: 1),
        textColor: RGBA = RGBA(r: 1, g: 1, b: 1, a: 1),
        diameter: Double = 32,
        isVisible: Bool = true,
        isLocked: Bool = false
    ) {
        self.id = id
        self.number = number
        self.position = position
        self.fillColor = fillColor
        self.textColor = textColor
        self.diameter = diameter
        self.isVisible = isVisible
        self.isLocked = isLocked
    }
}

/// Ordered bottom-to-top image operations.
public enum Layer: Codable, Sendable, Equatable, Identifiable {
    case annotation(AnnotationLayer)
    case text(TextLayer)
    case highlight(HighlightLayer)
    case redaction(RedactionLayer)
    case blur(BlurLayer)
    case padding(PaddingLayer)
    case step(StepLayer)

    public var id: LayerID {
        switch self {
        case .annotation(let layer): layer.id
        case .text(let layer): layer.id
        case .highlight(let layer): layer.id
        case .redaction(let layer): layer.id
        case .blur(let layer): layer.id
        case .padding(let layer): layer.id
        case .step(let layer): layer.id
        }
    }

    public var isVisible: Bool {
        switch self {
        case .annotation(let layer): layer.isVisible
        case .text(let layer): layer.isVisible
        case .highlight(let layer): layer.isVisible
        case .redaction(let layer): layer.isVisible
        case .blur(let layer): layer.isVisible
        case .padding(let layer): layer.isVisible
        case .step(let layer): layer.isVisible
        }
    }

    public var isLocked: Bool {
        switch self {
        case .annotation(let layer): layer.isLocked
        case .text(let layer): layer.isLocked
        case .highlight(let layer): layer.isLocked
        case .redaction(let layer): layer.isLocked
        case .blur(let layer): layer.isLocked
        case .padding(let layer): layer.isLocked
        case .step(let layer): layer.isLocked
        }
    }

    public var kindName: String {
        switch self {
        case .annotation(let layer): layer.kind.rawValue.capitalized
        case .text: "Text"
        case .highlight: "Highlight"
        case .redaction: "Redaction"
        case .blur: "Blur"
        case .padding: "Padding"
        case .step(let layer): "Step \(layer.number)"
        }
    }
}

public enum ImagePatch: DocumentPatch {
    case addLayer(Layer, atIndex: Int)
    case removeLayer(LayerID)
    case updateLayer(Layer)
    case reorderLayer(LayerID, to: Int)
    case setGeometry(Geometry)
    case setCanvas(ImageCanvas)
}

public struct ImageDocument: EditableDocument {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: DocumentID
    public var sourceAssetID: AssetID
    public var canvas: ImageCanvas
    public var geometry: Geometry
    public var layers: [Layer]

    public init(
        schemaVersion: Int = ImageDocument.currentSchemaVersion,
        id: DocumentID = .generate(),
        sourceAssetID: AssetID,
        canvas: ImageCanvas,
        geometry: Geometry = Geometry(),
        layers: [Layer] = []
    ) throws {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sourceAssetID = sourceAssetID
        self.canvas = canvas
        self.geometry = geometry
        self.layers = layers
        try validate()
    }

    @discardableResult
    public mutating func apply(_ patch: ImagePatch) throws -> ImagePatch {
        var candidate = self
        let inverse = try candidate.applyUnchecked(patch)
        try candidate.validate()
        self = candidate
        return inverse
    }

    public func validate() throws {
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw ModelError.schemaTooNew(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard canvas.width > 0, canvas.height > 0 else {
            throw ImageDocumentError.invalidCanvas(width: canvas.width, height: canvas.height)
        }
        try validateColor(canvas.background)
        guard geometry.scale.isFinite, geometry.scale > 0,
            geometry.rotationDegrees.isFinite,
            isNormalized(geometry.crop)
        else {
            throw ImageDocumentError.invalidGeometry
        }
        var ids = Set<LayerID>()
        for layer in layers {
            guard ids.insert(layer.id).inserted else {
                throw ImageDocumentError.duplicateLayer(layer.id)
            }
            try validate(layer)
        }
    }

    private mutating func applyUnchecked(_ patch: ImagePatch) throws -> ImagePatch {
        switch patch {
        case .addLayer(let layer, let index):
            guard !layers.contains(where: { $0.id == layer.id }) else {
                throw ImageDocumentError.duplicateLayer(layer.id)
            }
            guard (0...layers.count).contains(index) else {
                throw ImageDocumentError.indexOutOfRange(index, count: layers.count)
            }
            layers.insert(layer, at: index)
            return .removeLayer(layer.id)

        case .removeLayer(let id):
            guard let index = layers.firstIndex(where: { $0.id == id }) else {
                throw ImageDocumentError.layerNotFound(id)
            }
            let layer = layers.remove(at: index)
            return .addLayer(layer, atIndex: index)

        case .updateLayer(let layer):
            guard let index = layers.firstIndex(where: { $0.id == layer.id }) else {
                throw ImageDocumentError.layerNotFound(layer.id)
            }
            let previous = layers[index]
            layers[index] = layer
            return .updateLayer(previous)

        case .reorderLayer(let id, let destination):
            guard let index = layers.firstIndex(where: { $0.id == id }) else {
                throw ImageDocumentError.layerNotFound(id)
            }
            guard layers.indices.contains(destination) else {
                throw ImageDocumentError.indexOutOfRange(destination, count: layers.count)
            }
            let layer = layers.remove(at: index)
            layers.insert(layer, at: destination)
            return .reorderLayer(id, to: index)

        case .setGeometry(let geometry):
            let previous = self.geometry
            self.geometry = geometry
            return .setGeometry(previous)

        case .setCanvas(let canvas):
            let previous = self.canvas
            self.canvas = canvas
            return .setCanvas(previous)
        }
    }

    private func validate(_ layer: Layer) throws {
        switch layer {
        case .annotation(let value):
            guard isNormalized(value.bounds), value.points.allSatisfy(isNormalized),
                value.strokeWidth.isFinite, value.strokeWidth > 0
            else { throw ImageDocumentError.invalidLayer(value.id) }
            try validateColor(value.strokeColor)
            if let color = value.fillColor { try validateColor(color) }
        case .text(let value):
            guard isNormalized(value.frame), value.fontSize.isFinite, value.fontSize > 0 else {
                throw ImageDocumentError.invalidLayer(value.id)
            }
            try validateColor(value.color)
        case .highlight(let value):
            guard value.regions.allSatisfy(isNormalized) else {
                throw ImageDocumentError.invalidLayer(value.id)
            }
            try validateColor(value.color)
        case .redaction(let value):
            guard value.regions.allSatisfy(isNormalized) else {
                throw ImageDocumentError.invalidLayer(value.id)
            }
            switch value.style {
            case .solid(let color): try validateColor(color)
            case .pixelate(let size):
                guard size > 0 else { throw ImageDocumentError.invalidLayer(value.id) }
            case .blur(let radius):
                guard radius.isFinite, radius > 0 else {
                    throw ImageDocumentError.invalidLayer(value.id)
                }
            }
        case .blur(let value):
            guard value.regions.allSatisfy(isNormalized), value.radius.isFinite,
                value.radius > 0
            else { throw ImageDocumentError.invalidLayer(value.id) }
        case .padding(let value):
            guard value.amount.isFinite, value.amount >= 0, value.amount <= 1,
                value.cornerRadius.isFinite, value.cornerRadius >= 0
            else { throw ImageDocumentError.invalidLayer(value.id) }
            try validateColor(value.color)
            if let shadow = value.shadow {
                try validateColor(shadow.color)
                guard shadow.radius.isFinite, shadow.radius >= 0,
                    shadow.offset.x.isFinite, shadow.offset.y.isFinite
                else { throw ImageDocumentError.invalidLayer(value.id) }
            }
        case .step(let value):
            guard value.number > 0, isNormalized(value.position), value.diameter.isFinite,
                value.diameter > 0
            else { throw ImageDocumentError.invalidLayer(value.id) }
            try validateColor(value.fillColor)
            try validateColor(value.textColor)
        }
    }

    private func validateColor(_ color: RGBA) throws {
        guard [color.r, color.g, color.b, color.a].allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { throw ImageDocumentError.invalidColor }
    }

    private func isNormalized(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
            && (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    private func isNormalized(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
            && rect.minX >= 0 && rect.minY >= 0
            && rect.maxX <= 1 && rect.maxY <= 1
    }
}

public enum ImageDocumentError: Error, Sendable, Equatable {
    case invalidCanvas(width: Int, height: Int)
    case invalidGeometry
    case duplicateLayer(LayerID)
    case layerNotFound(LayerID)
    case indexOutOfRange(Int, count: Int)
    case invalidLayer(LayerID)
    case invalidColor
}
