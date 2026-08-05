import CoreGraphics
import CoreModel
import Foundation
import PDFium
import PDFiumSupport

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

public struct PDFTextBlock: Sendable, Equatable, Identifiable {
    public var id: Int { pageObjectIndex }
    public var pageObjectIndex: Int
    public var text: String
    /// Normalized page coordinates with an upper-left origin.
    public var bounds: CGRect
    public var font: PDFFontDescriptor
    public var fontSize: Double
    public var color: RGBA

    public init(
        pageObjectIndex: Int,
        text: String,
        bounds: CGRect,
        font: PDFFontDescriptor,
        fontSize: Double,
        color: RGBA
    ) {
        self.pageObjectIndex = pageObjectIndex
        self.text = text
        self.bounds = bounds
        self.font = font
        self.fontSize = fontSize
        self.color = color
    }
}

public struct PDFPageAnalysis: Sendable, Equatable {
    public var text: String
    public var glyphs: [PDFTextGlyph]
    public var fonts: [PDFFontDescriptor]
    public var textBlocks: [PDFTextBlock]

    public init(
        text: String,
        glyphs: [PDFTextGlyph],
        fonts: [PDFFontDescriptor],
        textBlocks: [PDFTextBlock] = []
    ) {
        self.text = text
        self.glyphs = glyphs
        self.fonts = fonts
        self.textBlocks = textBlocks
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

    public convenience init(url: URL, password: String? = nil) throws {
        try self.init(data: Data(contentsOf: url), password: password)
    }

    public init(data: Data, password: String? = nil) throws {
        PDFiumRuntime.initialize()
        let source = data as NSData
        let opened = try PDFiumRuntime.synchronized { () throws -> (FPDF_DOCUMENT, Int) in
            let handle =
                password?.withCString { passwordPointer in
                    FPDF_LoadMemDocument64(source.bytes, source.length, passwordPointer)
                } ?? FPDF_LoadMemDocument64(source.bytes, source.length, nil)
            guard let handle else {
                throw PDFEngineError.unreadableDocument(code: FPDF_GetLastError())
            }
            return (handle, Int(FPDF_GetPageCount(handle)))
        }
        self.source = source
        self.handle = opened.0
        self.pageCount = opened.1
    }

    deinit {
        PDFiumRuntime.synchronized {
            FPDF_CloseDocument(handle)
        }
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
        rotation: PDFPageRotation = .degrees0,
        sourceTextEdits: [PDFTextLayer] = [],
        fontData: (@Sendable (String) -> Data?)? = nil
    ) throws -> CGImage {
        try synchronized {
            let renderDocument: FPDF_DOCUMENT
            let ownsDocument: Bool
            if sourceTextEdits.isEmpty {
                renderDocument = handle
                ownsDocument = false
            } else {
                guard let copy = FPDF_LoadMemDocument64(source.bytes, source.length, nil) else {
                    throw PDFEngineError.unreadableDocument(code: FPDF_GetLastError())
                }
                renderDocument = copy
                ownsDocument = true
            }
            defer {
                if ownsDocument { FPDF_CloseDocument(renderDocument) }
            }
            let page = try loadPage(index, from: renderDocument)
            defer { FPDF_ClosePage(page) }
            if !sourceTextEdits.isEmpty {
                try applySourceTextEdits(
                    sourceTextEdits,
                    to: page,
                    in: renderDocument,
                    fontData: fontData
                )
            }
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
                return PDFPageAnalysis(text: "", glyphs: [], fonts: [], textBlocks: [])
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
            let textBlocks = pageTextBlocks(
                page: page,
                textPage: textPage,
                pageWidth: pageWidth,
                pageHeight: pageHeight
            )
            for block in textBlocks where !fonts.contains(block.font) {
                fonts.append(block.font)
            }
            return PDFPageAnalysis(
                text: text,
                glyphs: glyphs,
                fonts: fonts,
                textBlocks: textBlocks
            )
        }
    }

    /// Saves source text-object edits without rasterizing the page, preserving
    /// selectable text, vectors, links, forms, and original image quality.
    public func exportApplyingSourceEdits(
        _ document: PDFEditDocument,
        to destination: URL,
        fontData: @escaping @Sendable (String) -> Data? = { _ in nil }
    ) throws {
        try synchronized {
            guard let copy = FPDF_LoadMemDocument64(source.bytes, source.length, nil) else {
                throw PDFEngineError.unreadableDocument(code: FPDF_GetLastError())
            }
            defer { FPDF_CloseDocument(copy) }
            for page in document.pages {
                guard let sourceIndex = page.sourcePageIndex else { continue }
                let pageHandle = try loadPage(sourceIndex, from: copy)
                do {
                    let directEdits = page.layers.compactMap { layer -> PDFTextLayer? in
                        guard case .text(let text) = layer, text.sourceReference != nil else {
                            return nil
                        }
                        return text
                    }
                    if !directEdits.isEmpty {
                        try applySourceTextEdits(
                            directEdits,
                            to: pageHandle,
                            in: copy,
                            fontData: fontData
                        )
                    }
                    FPDFPage_SetRotation(pageHandle, renderRotation(page.rotation))
                } catch {
                    FPDF_ClosePage(pageHandle)
                    throw error
                }
                FPDF_ClosePage(pageHandle)
            }
            let result = destination.path.withCString { path in
                ClipPDFiumSaveDocumentToPath(
                    UnsafeMutableRawPointer(copy),
                    path,
                    UInt32(FPDF_NO_INCREMENTAL | FPDF_SUBSET_NEW_FONTS)
                )
            }
            guard result != 0 else { throw PDFEngineError.renderFailed }
        }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        try PDFiumRuntime.synchronized(body)
    }

    private func loadPage(_ index: Int) throws -> FPDF_PAGE {
        try loadPage(index, from: handle)
    }

    private func loadPage(_ index: Int, from document: FPDF_DOCUMENT) throws -> FPDF_PAGE {
        guard (0..<pageCount).contains(index), let page = FPDF_LoadPage(document, Int32(index))
        else {
            throw PDFEngineError.invalidPage(index)
        }
        return page
    }

    private func pageTextBlocks(
        page: FPDF_PAGE,
        textPage: FPDF_TEXTPAGE,
        pageWidth: Double,
        pageHeight: Double
    ) -> [PDFTextBlock] {
        let count = max(Int(FPDFPage_CountObjects(page)), 0)
        return (0..<count).compactMap { objectIndex in
            guard let object = FPDFPage_GetObject(page, Int32(objectIndex)),
                FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT,
                let text = textObjectString(object, textPage: textPage),
                !text.isEmpty,
                let bounds = normalizedBounds(
                    object: object,
                    pageWidth: pageWidth,
                    pageHeight: pageHeight
                ),
                let fontHandle = FPDFTextObj_GetFont(object)
            else { return nil }
            var size: Float = 12
            _ = FPDFTextObj_GetFontSize(object, &size)
            return PDFTextBlock(
                pageObjectIndex: objectIndex,
                text: text,
                bounds: bounds,
                font: fontDescriptor(font: fontHandle),
                fontSize: Double(size),
                color: fillColor(object)
            )
        }
    }

    private func textObjectString(
        _ object: FPDF_PAGEOBJECT,
        textPage: FPDF_TEXTPAGE
    ) -> String? {
        let byteCount = Int(FPDFTextObj_GetText(object, textPage, nil, 0))
        guard byteCount >= 2 else { return nil }
        var buffer = [UInt16](repeating: 0, count: (byteCount + 1) / 2)
        let written = Int(
            FPDFTextObj_GetText(object, textPage, &buffer, UInt(buffer.count * 2))
        )
        guard written >= 2 else { return nil }
        return String(decoding: buffer.prefix(max((written / 2) - 1, 0)), as: UTF16.self)
    }

    private func normalizedBounds(
        object: FPDF_PAGEOBJECT,
        pageWidth: Double,
        pageHeight: Double
    ) -> CGRect? {
        var left: Float = 0
        var bottom: Float = 0
        var right: Float = 0
        var top: Float = 0
        guard FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top) != 0 else {
            return nil
        }
        return CGRect(
            x: Double(left) / pageWidth,
            y: 1 - Double(top) / pageHeight,
            width: Double(right - left) / pageWidth,
            height: Double(top - bottom) / pageHeight
        ).standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func fontDescriptor(font: FPDF_FONT) -> PDFFontDescriptor {
        let postScriptName = fontName(font, getter: FPDFFont_GetBaseFontName) ?? "Helvetica"
        let familyName = fontName(font, getter: FPDFFont_GetFamilyName)
        let flags = FPDFFont_GetFlags(font)
        return PDFFontDescriptor(
            postScriptName: postScriptName,
            familyName: familyName,
            flags: flags < 0 ? 0 : UInt32(flags),
            isEmbedded: FPDFFont_GetIsEmbedded(font) == 1
        )
    }

    private func fontName(
        _ font: FPDF_FONT,
        getter: (FPDF_FONT?, UnsafeMutablePointer<CChar>?, Int) -> Int
    ) -> String? {
        let length = getter(font, nil, 0)
        guard length > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        _ = getter(font, &buffer, length)
        return String(
            decoding: buffer.dropLast().map(UInt8.init(bitPattern:)),
            as: UTF8.self
        )
    }

    private func fillColor(_ object: FPDF_PAGEOBJECT) -> RGBA {
        var red: UInt32 = 0
        var green: UInt32 = 0
        var blue: UInt32 = 0
        var alpha: UInt32 = 255
        guard FPDFPageObj_GetFillColor(object, &red, &green, &blue, &alpha) != 0 else {
            return .black
        }
        return RGBA(
            r: Double(red) / 255,
            g: Double(green) / 255,
            b: Double(blue) / 255,
            a: Double(alpha) / 255
        )
    }

    private func applySourceTextEdits(
        _ edits: [PDFTextLayer],
        to page: FPDF_PAGE,
        in document: FPDF_DOCUMENT,
        fontData: (@Sendable (String) -> Data?)?
    ) throws {
        for edit in edits {
            guard let reference = edit.sourceReference,
                let object = FPDFPage_GetObject(page, Int32(reference.pageObjectIndex)),
                FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT
            else { continue }
            if edit.text.isEmpty {
                _ = FPDFPageObj_SetIsActive(object, 0)
                continue
            }
            let usesOriginalFont =
                edit.font.postScriptName == reference.originalFontPostScriptName
            if usesOriginalFont {
                _ = withPDFiumWideString(edit.text) { FPDFText_SetText(object, $0) }
                _ = FPDFTextObj_SetFontSize(object, Float(edit.fontSize))
                setFillColor(edit.color, on: object)
                continue
            }
            guard let data = fontData?(edit.font.postScriptName),
                let replacement = makeTextObject(
                    text: edit.text,
                    fontSize: edit.fontSize,
                    fontData: data,
                    original: object,
                    document: document
                )
            else {
                _ = withPDFiumWideString(edit.text) { FPDFText_SetText(object, $0) }
                continue
            }
            setFillColor(edit.color, on: replacement)
            guard FPDFPage_RemoveObject(page, object) != 0 else {
                FPDFPageObj_Destroy(replacement)
                continue
            }
            FPDFPageObj_Destroy(object)
            _ = FPDFPage_InsertObjectAtIndex(
                page,
                replacement,
                numericCast(reference.pageObjectIndex)
            )
        }
        guard FPDFPage_GenerateContent(page) != 0 else {
            throw PDFEngineError.renderFailed
        }
    }

    private func makeTextObject(
        text: String,
        fontSize: Double,
        fontData: Data,
        original: FPDF_PAGEOBJECT,
        document: FPDF_DOCUMENT
    ) -> FPDF_PAGEOBJECT? {
        guard !text.isEmpty else { return nil }
        let loadedFont = fontData.withUnsafeBytes { bytes in
            FPDFText_LoadFont(
                document,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                numericCast(bytes.count),
                FPDF_FONT_TRUETYPE,
                1
            )
        }
        guard let loadedFont else { return nil }
        defer { FPDFFont_Close(loadedFont) }
        guard
            let replacement = FPDFPageObj_CreateTextObj(
                document,
                loadedFont,
                Float(fontSize)
            )
        else { return nil }
        guard withPDFiumWideString(text, { FPDFText_SetText(replacement, $0) }) != 0 else {
            FPDFPageObj_Destroy(replacement)
            return nil
        }
        var matrix = FS_MATRIX()
        if FPDFPageObj_GetMatrix(original, &matrix) != 0 {
            _ = FPDFPageObj_SetMatrix(replacement, &matrix)
        }
        _ = FPDFTextObj_SetTextRenderMode(
            replacement,
            FPDFTextObj_GetTextRenderMode(original)
        )
        return replacement
    }

    private func setFillColor(_ color: RGBA, on object: FPDF_PAGEOBJECT) {
        _ = FPDFPageObj_SetFillColor(
            object,
            UInt32((color.r * 255).rounded()),
            UInt32((color.g * 255).rounded()),
            UInt32((color.b * 255).rounded()),
            UInt32((color.a * 255).rounded())
        )
    }

    private func withPDFiumWideString<T>(
        _ value: String,
        _ body: (UnsafePointer<UInt16>) -> T
    ) -> T {
        var utf16 = Array(value.utf16)
        utf16.append(0)
        return utf16.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                preconditionFailure("A null-terminated UTF-16 buffer cannot be empty")
            }
            return body(baseAddress)
        }
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
    private static let lock = NSRecursiveLock()

    static func initialize() {
        _ = initialized
    }

    static func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
