import CoreGraphics
import CoreModel
import CoreText
import Foundation
import Testing

@testable import PDFEngine

@Suite("PDF Markdown and OCR")
struct PDFMarkdownConverterTests {
    @Test("Layout conversion preserves headings and tables while honoring edits")
    func layoutAwareMarkdown() throws {
        let redaction = PDFLayer.redaction(
            PDFRedactionLayer(regions: [CGRect(x: 0.08, y: 0.7, width: 0.3, height: 0.08)])
        )
        let addedText = PDFLayer.text(
            PDFTextLayer(
                text: "Approved",
                frame: CGRect(x: 0.1, y: 0.84, width: 0.2, height: 0.05),
                fontSize: 12
            )
        )
        let page = PDFPage(
            sourcePageIndex: 0,
            size: PDFPageSize(width: 612, height: 792),
            layers: [redaction, addedText]
        )
        let scan = PDFPage(
            sourcePageIndex: 1,
            size: PDFPageSize(width: 612, height: 792),
            ocrText: "Scanned agreement"
        )
        let document = try PDFEditDocument(
            sourceAssetID: AssetID(rawValue: "markdown-fixture"),
            title: "Fixture",
            pages: [page, scan]
        )
        let glyphs =
            positionedText("Quarterly Results", x: 0.08, y: 0.08, size: 24)
            + positionedText("Region", x: 0.08, y: 0.28, size: 12)
            + positionedText("Revenue", x: 0.55, y: 0.28, size: 12)
            + positionedText("West", x: 0.08, y: 0.36, size: 12)
            + positionedText("42", x: 0.55, y: 0.36, size: 12)
            + positionedText("SECRET", x: 0.1, y: 0.72, size: 12)
        let analysis = PDFPageAnalysis(text: "", glyphs: glyphs, fonts: [])

        let markdown = PDFMarkdownConverter.convert(
            document,
            analyses: [analysis, PDFPageAnalysis(text: "", glyphs: [], fonts: [])]
        )

        #expect(
            markdown.contains("## Quarterly Results") || markdown.contains("# Quarterly Results"))
        #expect(markdown.contains("| Region | Revenue |"))
        #expect(markdown.contains("| West | 42 |"))
        #expect(markdown.contains("Approved"))
        #expect(markdown.contains("Scanned agreement"))
        #expect(!markdown.contains("SECRET"))
        #expect(markdown.contains("<!-- Page 2 -->"))
    }

    @Test("Vision recognizes text from an in-memory page without network access")
    func onDeviceOCR() async throws {
        let result = try await OnDevicePDFOCR().recognize(try textImage("LOCAL OCR"))
        #expect(result.localizedCaseInsensitiveContains("LOCAL OCR"))
    }

    private func positionedText(
        _ text: String,
        x: Double,
        y: Double,
        size: Double
    ) -> [PDFTextGlyph] {
        text.enumerated().map { offset, character in
            PDFTextGlyph(
                text: String(character),
                bounds: CGRect(
                    x: x + Double(offset) * 0.012,
                    y: y,
                    width: 0.01,
                    height: 0.025
                ),
                font: nil,
                fontSize: size
            )
        }
    }

    private func textImage(_ text: String) throws -> CGImage {
        let width = 1_200
        let height = 260
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "Helvetica-Bold" as CFString,
                96,
                nil
            ),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                gray: 0,
                alpha: 1
            ),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        context.textPosition = CGPoint(x: 70, y: 85)
        CTLineDraw(line, context)
        return try #require(context.makeImage())
    }
}
