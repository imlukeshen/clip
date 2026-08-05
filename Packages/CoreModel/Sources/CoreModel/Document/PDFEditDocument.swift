import CoreGraphics
import Foundation

public enum PDFPageTag: Sendable {}
public typealias PDFPageID = TypedID<PDFPageTag>

public enum PDFLayerTag: Sendable {}
public typealias PDFLayerID = TypedID<PDFLayerTag>

public struct PDFPageSize: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public enum PDFPageRotation: Int, Codable, Sendable, Equatable, CaseIterable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270

    public func rotatedClockwise() -> Self {
        switch self {
        case .degrees0: .degrees90
        case .degrees90: .degrees180
        case .degrees180: .degrees270
        case .degrees270: .degrees0
        }
    }
}

public struct PDFFontDescriptor: Codable, Sendable, Equatable {
    public var postScriptName: String
    public var familyName: String?
    public var flags: UInt32
    public var isEmbedded: Bool
    public var isSubset: Bool

    public init(
        postScriptName: String,
        familyName: String? = nil,
        flags: UInt32 = 0,
        isEmbedded: Bool = false,
        isSubset: Bool? = nil
    ) {
        self.postScriptName = postScriptName
        self.familyName = familyName
        self.flags = flags
        self.isEmbedded = isEmbedded
        self.isSubset = isSubset ?? Self.hasSubsetPrefix(postScriptName)
    }

    public static func hasSubsetPrefix(_ name: String) -> Bool {
        guard name.count > 7 else { return false }
        let prefix = name.prefix(6)
        return name.dropFirst(6).first == "+"
            && prefix.allSatisfy { $0.isASCII && $0.isUppercase }
    }

    public func warning(for replacement: String, observedCharacters: Set<Character>) -> String? {
        guard isSubset else { return nil }
        let missing = Set(replacement).subtracting(observedCharacters)
        guard !missing.isEmpty else { return nil }
        return "\(postScriptName) is a subset font and may not contain: \(String(missing.sorted()))"
    }
}

public struct PDFTextLayer: Codable, Sendable, Equatable {
    public var id: PDFLayerID
    public var text: String
    /// Normalized page coordinates with an upper-left origin.
    public var frame: CGRect
    public var font: PDFFontDescriptor
    public var fontSize: Double
    public var color: RGBA
    /// Links this edit to a real text object in the immutable source PDF.
    ///
    /// When present, PDFEngine replaces that page object instead of painting a
    /// second text box over the page. Keeping the original value makes the edit
    /// deterministic across save, undo, and export without mutating the source.
    public var sourceReference: PDFSourceTextReference?

    public init(
        id: PDFLayerID = .generate(),
        text: String,
        frame: CGRect,
        font: PDFFontDescriptor = PDFFontDescriptor(postScriptName: "Helvetica"),
        fontSize: Double = 12,
        color: RGBA = .black,
        sourceReference: PDFSourceTextReference? = nil
    ) {
        self.id = id
        self.text = text
        self.frame = frame
        self.font = font
        self.fontSize = fontSize
        self.color = color
        self.sourceReference = sourceReference
    }
}

public struct PDFSourceTextReference: Codable, Sendable, Equatable {
    /// Stable while the source PDF remains immutable, which is a document-model invariant.
    public var pageObjectIndex: Int
    public var originalText: String
    public var originalFontPostScriptName: String

    public init(
        pageObjectIndex: Int,
        originalText: String,
        originalFontPostScriptName: String
    ) {
        self.pageObjectIndex = pageObjectIndex
        self.originalText = originalText
        self.originalFontPostScriptName = originalFontPostScriptName
    }
}

public struct PDFHighlightLayer: Codable, Sendable, Equatable {
    public var id: PDFLayerID
    public var regions: [CGRect]
    public var color: RGBA

    public init(
        id: PDFLayerID = .generate(),
        regions: [CGRect],
        color: RGBA = RGBA(r: 1, g: 0.84, b: 0.12, a: 0.35)
    ) {
        self.id = id
        self.regions = regions
        self.color = color
    }
}

public struct PDFRedactionLayer: Codable, Sendable, Equatable {
    public var id: PDFLayerID
    public var regions: [CGRect]
    public var color: RGBA

    public init(
        id: PDFLayerID = .generate(),
        regions: [CGRect],
        color: RGBA = .black
    ) {
        self.id = id
        self.regions = regions
        self.color = color
    }
}

public enum PDFLayer: Codable, Sendable, Equatable, Identifiable {
    case text(PDFTextLayer)
    case highlight(PDFHighlightLayer)
    case redaction(PDFRedactionLayer)

    public var id: PDFLayerID {
        switch self {
        case .text(let layer): layer.id
        case .highlight(let layer): layer.id
        case .redaction(let layer): layer.id
        }
    }

    public var name: String {
        switch self {
        case .text: "Text"
        case .highlight: "Highlight"
        case .redaction: "Redaction"
        }
    }
}

public struct PDFPage: Codable, Sendable, Equatable, Identifiable {
    public var id: PDFPageID
    /// Zero-based page index in the immutable source PDF. Nil represents a blank page.
    public var sourcePageIndex: Int?
    public var size: PDFPageSize
    public var rotation: PDFPageRotation
    public var layers: [PDFLayer]
    public var ocrText: String?

    public init(
        id: PDFPageID = .generate(),
        sourcePageIndex: Int?,
        size: PDFPageSize,
        rotation: PDFPageRotation = .degrees0,
        layers: [PDFLayer] = [],
        ocrText: String? = nil
    ) {
        self.id = id
        self.sourcePageIndex = sourcePageIndex
        self.size = size
        self.rotation = rotation
        self.layers = layers
        self.ocrText = ocrText
    }
}

public enum PDFPatch: DocumentPatch {
    case insertPage(PDFPage, atIndex: Int)
    case removePage(PDFPageID)
    case updatePage(PDFPage)
    case reorderPage(PDFPageID, to: Int)
    case addLayer(PDFLayer, to: PDFPageID, atIndex: Int)
    case removeLayer(PDFLayerID, from: PDFPageID)
    case updateLayer(PDFLayer, on: PDFPageID)
    case setOCRText(String?, on: PDFPageID)
}

public struct PDFEditDocument: EditableDocument {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: DocumentID
    public var sourceAssetID: AssetID
    public var title: String
    public var pages: [PDFPage]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: DocumentID = .generate(),
        sourceAssetID: AssetID,
        title: String,
        pages: [PDFPage]
    ) throws {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sourceAssetID = sourceAssetID
        self.title = title
        self.pages = pages
        try validate()
    }

    @discardableResult
    public mutating func apply(_ patch: PDFPatch) throws -> PDFPatch {
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
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PDFDocumentError.emptyTitle
        }
        guard !pages.isEmpty else { throw PDFDocumentError.emptyDocument }
        guard Set(pages.map(\.id)).count == pages.count else {
            throw PDFDocumentError.duplicatePage
        }
        var layerIDs = Set<PDFLayerID>()
        for page in pages {
            if let sourcePageIndex = page.sourcePageIndex, sourcePageIndex < 0 {
                throw PDFDocumentError.invalidSourcePage(sourcePageIndex)
            }
            guard page.size.width.isFinite, page.size.height.isFinite,
                page.size.width > 0, page.size.height > 0
            else { throw PDFDocumentError.invalidPageSize(page.id) }
            for layer in page.layers {
                guard layerIDs.insert(layer.id).inserted else {
                    throw PDFDocumentError.duplicateLayer(layer.id)
                }
                try validate(layer)
            }
        }
    }

    public func page(_ id: PDFPageID) -> PDFPage? {
        pages.first { $0.id == id }
    }

    private mutating func applyUnchecked(_ patch: PDFPatch) throws -> PDFPatch {
        switch patch {
        case .insertPage(let page, let index):
            guard (0...pages.count).contains(index) else {
                throw PDFDocumentError.invalidPageIndex(index)
            }
            pages.insert(page, at: index)
            return .removePage(page.id)
        case .removePage(let id):
            guard pages.count > 1 else { throw PDFDocumentError.emptyDocument }
            guard let index = pages.firstIndex(where: { $0.id == id }) else {
                throw PDFDocumentError.pageNotFound(id)
            }
            return .insertPage(pages.remove(at: index), atIndex: index)
        case .updatePage(let page):
            guard let index = pages.firstIndex(where: { $0.id == page.id }) else {
                throw PDFDocumentError.pageNotFound(page.id)
            }
            let old = pages[index]
            pages[index] = page
            return .updatePage(old)
        case .reorderPage(let id, let destination):
            guard let source = pages.firstIndex(where: { $0.id == id }) else {
                throw PDFDocumentError.pageNotFound(id)
            }
            guard pages.indices.contains(destination) else {
                throw PDFDocumentError.invalidPageIndex(destination)
            }
            let page = pages.remove(at: source)
            pages.insert(page, at: destination)
            return .reorderPage(id, to: source)
        case .addLayer(let layer, let pageID, let index):
            guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
                throw PDFDocumentError.pageNotFound(pageID)
            }
            guard (0...pages[pageIndex].layers.count).contains(index) else {
                throw PDFDocumentError.invalidLayerIndex(index)
            }
            pages[pageIndex].layers.insert(layer, at: index)
            return .removeLayer(layer.id, from: pageID)
        case .removeLayer(let layerID, let pageID):
            guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
                throw PDFDocumentError.pageNotFound(pageID)
            }
            guard let layerIndex = pages[pageIndex].layers.firstIndex(where: { $0.id == layerID })
            else { throw PDFDocumentError.layerNotFound(layerID) }
            let layer = pages[pageIndex].layers.remove(at: layerIndex)
            return .addLayer(layer, to: pageID, atIndex: layerIndex)
        case .updateLayer(let layer, let pageID):
            guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
                throw PDFDocumentError.pageNotFound(pageID)
            }
            guard let layerIndex = pages[pageIndex].layers.firstIndex(where: { $0.id == layer.id })
            else { throw PDFDocumentError.layerNotFound(layer.id) }
            let old = pages[pageIndex].layers[layerIndex]
            pages[pageIndex].layers[layerIndex] = layer
            return .updateLayer(old, on: pageID)
        case .setOCRText(let text, let pageID):
            guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
                throw PDFDocumentError.pageNotFound(pageID)
            }
            let old = pages[index].ocrText
            pages[index].ocrText = text
            return .setOCRText(old, on: pageID)
        }
    }

    private func validate(_ layer: PDFLayer) throws {
        let regions: [CGRect]
        switch layer {
        case .text(let text):
            guard !text.text.isEmpty || text.sourceReference != nil,
                text.fontSize.isFinite, text.fontSize > 0
            else {
                throw PDFDocumentError.invalidTextLayer(text.id)
            }
            if let reference = text.sourceReference, reference.pageObjectIndex < 0 {
                throw PDFDocumentError.invalidSourceTextReference(text.id)
            }
            try validateColor(text.color)
            regions = [text.frame]
        case .highlight(let highlight):
            try validateColor(highlight.color)
            regions = highlight.regions
        case .redaction(let redaction):
            try validateColor(redaction.color)
            regions = redaction.regions
        }
        guard !regions.isEmpty, regions.allSatisfy(isNormalized) else {
            throw PDFDocumentError.invalidLayerGeometry(layer.id)
        }
    }

    private func isNormalized(_ rect: CGRect) -> Bool {
        let values = [rect.origin.x, rect.origin.y, rect.width, rect.height]
        return values.allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
            && rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
    }

    private func validateColor(_ color: RGBA) throws {
        let components = [color.r, color.g, color.b, color.a]
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw PDFDocumentError.invalidColor
        }
    }
}

public enum PDFDocumentError: Error, Sendable, Equatable {
    case emptyTitle
    case emptyDocument
    case duplicatePage
    case duplicateLayer(PDFLayerID)
    case invalidPageIndex(Int)
    case invalidLayerIndex(Int)
    case pageNotFound(PDFPageID)
    case layerNotFound(PDFLayerID)
    case invalidSourcePage(Int)
    case invalidPageSize(PDFPageID)
    case invalidTextLayer(PDFLayerID)
    case invalidSourceTextReference(PDFLayerID)
    case invalidLayerGeometry(PDFLayerID)
    case invalidColor
}
