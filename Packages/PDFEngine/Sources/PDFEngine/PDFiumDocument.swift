import CoreGraphics
import CoreModel
import Foundation
import PDFium

public struct PDFTextGlyph: Sendable, Equatable {
    public var text: String
    /// Normalized page coordinates with an upper-left origin.
    public var bounds: CGRect?
    public var font: PDFFontDescriptor?
    public var fontSize: Double

    public init(
        text: String,
        bounds: CGRect?,
        font: PDFFontDescriptor?,
        fontSize: Double
    ) {
        self.text = text
        self.bounds = bounds
        self.font = font
        self.fontSize = fontSize
    }
}

public struct PDFPageAnalysis: Sendable, Equatable {
    public var text: String
    public var glyphs: [PDFTextGlyph]
    public var fonts: [PDFFontDescriptor]

    public init(text: String, glyphs: [PDFTextGlyph], fonts: [PDFFontDescriptor]) {
        self.text = text
        self.glyphs = glyphs
        self.fonts = fonts
    }
}

public enum PDFEngineError: Error, Sendable, Equatable {
    case unreadableDocument(code: UInt)
    case invalidPage(Int)
    case renderFailed
}

/// A serialized PDFium document session. The immutable source bytes remain alive
/// for the full lifetime required by `FPDF_LoadMemDocument64`.
public final class PDFiumDocument: @unchecked Sendable {
    public let pageCount: Int

    private let source: NSData
    private let handle: FPDF_DOCUMENT
    private let lock = NSLock()

    public convenience init(url: URL, password: String? = nil) throws {
        try self.init(data: Data(contentsOf: url), password: password)
    }

    public init(data: Data, password: String? = nil) throws {
        PDFiumRuntime.initialize()
        let source = data as NSData
        let handle =
            password?.withCString { passwordPointer in
                FPDF_LoadMemDocument64(source.bytes, source.length, passwordPointer)
            } ?? FPDF_LoadMemDocument64(source.bytes, source.length, nil)
        guard let handle else {
            throw PDFEngineError.unreadableDocument(code: FPDF_GetLastError())
        }
        self.source = source
        self.handle = handle
        self.pageCount = Int(FPDF_GetPageCount(handle))
    }

    deinit {
        FPDF_CloseDocument(handle)
    }

    public func pageSize(at index: Int) throws -> PDFPageSize {
        try synchronized {
            let page = try loadPage(index)
            defer { FPDF_ClosePage(page) }
            return PDFPageSize(
                width: Double(FPDF_GetPageWidthF(page)),
                height: Double(FPDF_GetPageHeightF(page))
            )
        }
    }

    public func makeEditDocument(
        sourceAssetID: AssetID,
        title: String
    ) throws -> PDFEditDocument {
        try synchronized {
            let pages = try (0..<pageCount).map { index -> PDFPage in
                let page = try loadPage(index)
                defer { FPDF_ClosePage(page) }
                return PDFPage(
                    sourcePageIndex: index,
                    size: PDFPageSize(
                        width: Double(FPDF_GetPageWidthF(page)),
                        height: Double(FPDF_GetPageHeightF(page))
                    )
                )
            }
            return try PDFEditDocument(
                sourceAssetID: sourceAssetID,
                title: title,
                pages: pages
            )
        }
    }

    public func renderPage(
        at index: Int,
        maxPixelDimension: Int = 1_600,
        rotation: PDFPageRotation = .degrees0
    ) throws -> CGImage {
        try synchronized {
            let page = try loadPage(index)
            defer { FPDF_ClosePage(page) }
            let pageWidth = max(Double(FPDF_GetPageWidthF(page)), 1)
            let pageHeight = max(Double(FPDF_GetPageHeightF(page)), 1)
            let scale = min(Double(max(maxPixelDimension, 1)) / max(pageWidth, pageHeight), 4)
            let nativeWidth = max(Int((pageWidth * scale).rounded()), 1)
            let nativeHeight = max(Int((pageHeight * scale).rounded()), 1)
            let swapsAxes = rotation == .degrees90 || rotation == .degrees270
            let width = swapsAxes ? nativeHeight : nativeWidth
            let height = swapsAxes ? nativeWidth : nativeHeight
            guard let bitmap = FPDFBitmap_Create(Int32(width), Int32(height), 1) else {
                throw PDFEngineError.renderFailed
            }
            defer { FPDFBitmap_Destroy(bitmap) }
            _ = FPDFBitmap_FillRect(bitmap, 0, 0, Int32(width), Int32(height), 0xFFFF_FFFF)
            FPDF_RenderPageBitmap(
                bitmap,
                page,
                0,
                0,
                Int32(width),
                Int32(height),
                renderRotation(rotation),
                Int32(FPDF_ANNOT | FPDF_LCD_TEXT)
            )
            let stride = Int(FPDFBitmap_GetStride(bitmap))
            guard let buffer = FPDFBitmap_GetBuffer(bitmap), stride >= width * 4 else {
                throw PDFEngineError.renderFailed
            }
            let pixels = Data(bytes: buffer, count: stride * height)
            guard let provider = CGDataProvider(data: pixels as CFData) else {
                throw PDFEngineError.renderFailed
            }
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw PDFEngineError.renderFailed
            }
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            )
            guard
                let image = CGImage(
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: stride,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo,
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                )
            else { throw PDFEngineError.renderFailed }
            return image
        }
    }

    public func analyzePage(at index: Int) throws -> PDFPageAnalysis {
        try synchronized {
            let page = try loadPage(index)
            defer { FPDF_ClosePage(page) }
            guard let textPage = FPDFText_LoadPage(page) else {
                return PDFPageAnalysis(text: "", glyphs: [], fonts: [])
            }
            defer { FPDFText_ClosePage(textPage) }
            let count = max(Int(FPDFText_CountChars(textPage)), 0)
            var utf16 = [UInt16](repeating: 0, count: count + 1)
            let written = Int(FPDFText_GetText(textPage, 0, Int32(count), &utf16))
            let valueCount = max(min(written - 1, count), 0)
            let text = String(decoding: utf16.prefix(valueCount), as: UTF16.self)
            let pageWidth = max(Double(FPDF_GetPageWidthF(page)), 1)
            let pageHeight = max(Double(FPDF_GetPageHeightF(page)), 1)
            var glyphs: [PDFTextGlyph] = []
            var fonts: [PDFFontDescriptor] = []
            for characterIndex in 0..<count {
                let unicode = FPDFText_GetUnicode(textPage, Int32(characterIndex))
                let character = UnicodeScalar(unicode).map(String.init) ?? ""
                let font = fontDescriptor(textPage: textPage, characterIndex: characterIndex)
                if let font, !fonts.contains(font) { fonts.append(font) }
                glyphs.append(
                    PDFTextGlyph(
                        text: character,
                        bounds: normalizedBounds(
                            textPage: textPage,
                            characterIndex: characterIndex,
                            pageWidth: pageWidth,
                            pageHeight: pageHeight
                        ),
                        font: font,
                        fontSize: FPDFText_GetFontSize(textPage, Int32(characterIndex))
                    )
                )
            }
            return PDFPageAnalysis(text: text, glyphs: glyphs, fonts: fonts)
        }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func loadPage(_ index: Int) throws -> FPDF_PAGE {
        guard (0..<pageCount).contains(index), let page = FPDF_LoadPage(handle, Int32(index)) else {
            throw PDFEngineError.invalidPage(index)
        }
        return page
    }

    private func renderRotation(_ rotation: PDFPageRotation) -> Int32 {
        switch rotation {
        case .degrees0: 0
        case .degrees90: 1
        case .degrees180: 2
        case .degrees270: 3
        }
    }

    private func fontDescriptor(
        textPage: FPDF_TEXTPAGE,
        characterIndex: Int
    ) -> PDFFontDescriptor? {
        var flags: Int32 = 0
        let length = Int(
            FPDFText_GetFontInfo(textPage, Int32(characterIndex), nil, 0, &flags)
        )
        guard length > 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        _ = FPDFText_GetFontInfo(
            textPage,
            Int32(characterIndex),
            &buffer,
            UInt(length),
            &flags
        )
        let name = String(decoding: buffer.dropLast(), as: UTF8.self)
        let textObject = FPDFText_GetTextObject(textPage, Int32(characterIndex))
        let font = textObject.flatMap(FPDFTextObj_GetFont)
        let embedded = font.map { FPDFFont_GetIsEmbedded($0) == 1 } ?? false
        return PDFFontDescriptor(
            postScriptName: name,
            flags: UInt32(bitPattern: flags),
            isEmbedded: embedded
        )
    }

    private func normalizedBounds(
        textPage: FPDF_TEXTPAGE,
        characterIndex: Int,
        pageWidth: Double,
        pageHeight: Double
    ) -> CGRect? {
        var left = 0.0
        var right = 0.0
        var bottom = 0.0
        var top = 0.0
        guard
            FPDFText_GetCharBox(
                textPage,
                Int32(characterIndex),
                &left,
                &right,
                &bottom,
                &top
            ) != 0
        else { return nil }
        return CGRect(
            x: left / pageWidth,
            y: 1 - top / pageHeight,
            width: (right - left) / pageWidth,
            height: (top - bottom) / pageHeight
        )
    }
}

private enum PDFiumRuntime {
    private static let initialized: Void = FPDF_InitLibrary()

    static func initialize() {
        _ = initialized
    }
}
