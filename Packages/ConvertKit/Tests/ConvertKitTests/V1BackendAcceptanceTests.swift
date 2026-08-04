import AppKit
import ConvertKit
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers

@Suite("V1 image and document backends", .serialized)
struct V1BackendAcceptanceTests {
    @Test("Markdown converts to a searchable PDF through HTML")
    @MainActor
    func markdownToPDF() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("notes.md")
        let output = folder.appendingPathComponent("notes.pdf")
        try Data("# Release notes\n\nClip keeps this text searchable.".utf8).write(to: input)

        let plan = try #require(
            ConversionPlanner().plan(from: ConversionFormats.markdown, to: ConversionFormats.pdf)
        )
        #expect(plan.steps.map(\.backend) == [.markdown, .webKit])
        try await run(plan, input: input, output: output)

        let pdf = try #require(PDFDocument(url: output))
        #expect(pdf.pageCount >= 1)
        #expect(pdf.string?.contains("Release notes") == true)
    }

    @Test("GFM Markdown with fenced code and math exports through the shared PDF graph")
    @MainActor
    func richMarkdownToPDF() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("README.md")
        let output = folder.appendingPathComponent("README.pdf")
        let markdown = """
            # Clip README

            | Feature | State |
            | --- | --- |
            | Preview | Ready |

            ```swift
            let answer = 42
            ```

            $$E = mc^2$$

            ![Blocked](https://tracking.example/pixel.png)
            """
        try Data(markdown.utf8).write(to: input)

        let plan = try #require(
            ConversionPlanner().plan(from: ConversionFormats.markdown, to: ConversionFormats.pdf)
        )
        try await run(plan, input: input, output: output)

        let pdf = try #require(PDFDocument(url: output))
        let text = pdf.string ?? ""
        #expect(text.contains("Clip README"))
        #expect(text.contains("Preview"))
        #expect(text.contains("answer"))
        #expect(!text.contains("tracking.example"))
    }

    @Test("DOCX converts to a searchable PDF through native rich text and HTML")
    @MainActor
    func docxToPDF() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceText = folder.appendingPathComponent("source.txt")
        let input = folder.appendingPathComponent("source.docx")
        let output = folder.appendingPathComponent("source.pdf")
        try Data("A genuine DOCX conversion from Clip.".utf8).write(to: sourceText)
        try makeDOCX(sourceText, at: input)

        let plan = try #require(
            ConversionPlanner().plan(from: ConversionFormats.docx, to: ConversionFormats.pdf)
        )
        #expect(plan.steps.map(\.backend) == [.attributedString, .webKit])
        try await run(plan, input: input, output: output)

        let pdf = try #require(PDFDocument(url: output))
        #expect(pdf.string?.contains("genuine DOCX") == true)
    }

    @Test("PDF rasterizes to a valid PNG")
    @MainActor
    func pdfToPNG() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("page.pdf")
        let output = folder.appendingPathComponent("page.png")
        try makePDF(at: input)

        let plan = try #require(
            ConversionPlanner().plan(from: ConversionFormats.pdf, to: ConversionFormats.png)
        )
        try await run(plan, input: input, output: output)

        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        #expect(CGImageSourceGetCount(source) == 1)
    }

    @Test("HEIC converts to a valid WebP through a local raster intermediate")
    @MainActor
    func heicToWebP() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("photo.heic")
        let output = folder.appendingPathComponent("photo.webp")
        try makeImage(at: input, type: .heic)

        let plan = try #require(
            ConversionPlanner().plan(from: ConversionFormats.heic, to: ConversionFormats.webP)
        )
        #expect(plan.steps.map(\.backend) == [.imageIO, .ffmpeg])
        try await run(plan, input: input, output: output)

        let data = try Data(contentsOf: output)
        #expect(data.count > 12)
        #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.dropFirst(8).prefix(4), encoding: .ascii) == "WEBP")
        #expect(CGImageSourceCreateWithURL(output as CFURL, nil) != nil)
    }

    @Test("Camera raw inputs use ImageIO's read-only decode path")
    @MainActor
    func rawToJPEG() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("camera.dng")
        let output = folder.appendingPathComponent("camera.jpg")
        // A deterministic TIFF payload exercises the raw-decode edge without
        // committing a multi-megabyte proprietary camera fixture to the repo.
        try makeImage(at: input, type: .tiff)
        let raw = FormatID(type: ConversionFormats.type("dng"))

        let plan = try #require(
            ConversionPlanner().plan(from: raw, to: ConversionFormats.jpeg)
        )
        #expect(plan.steps.map(\.backend) == [.imageIO])
        try await run(plan, input: input, output: output)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
    }

    @MainActor
    private func run(_ plan: ConversionPlan, input: URL, output: URL) async throws {
        let stream = await Converter().convert(plan, input: input, output: output)
        var lastProgress = 0.0
        for try await progress in stream {
            #expect(progress >= lastProgress)
            lastProgress = progress
        }
        #expect(lastProgress == 1)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    private func fixtureFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-v1-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @MainActor
    private func makeImage(at url: URL, type: UTType) throws {
        guard
            let context = CGContext(
                data: nil,
                width: 48,
                height: 32,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw ConversionError.cannotCreateOutput }
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                type.identifier as CFString,
                1,
                nil
            )
        else { throw ConversionError.cannotCreateOutput }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.conversionFailed("Fixture image export failed")
        }
    }

    @MainActor
    private func makePDF(at url: URL) throws {
        let image = NSImage(size: NSSize(width: 320, height: 180))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        NSColor.black.setFill()
        NSString(string: "Clip PDF page").draw(at: NSPoint(x: 24, y: 80))
        image.unlockFocus()
        let document = PDFDocument()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        #expect(document.write(to: url))
    }

    private func makeDOCX(_ input: URL, at output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "docx", "-output", output.path, input.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConversionError.conversionFailed("Could not create the DOCX fixture")
        }
    }
}
