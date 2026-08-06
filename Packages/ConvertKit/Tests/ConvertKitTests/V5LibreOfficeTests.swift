import CoreGraphics
import Foundation
import Testing

@testable import ConvertKit

@Suite("V5 LibreOffice", .serialized)
struct V5LibreOfficeTests {
    @Test("App Store capabilities never expose external Office edges")
    func appStoreGating() throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("soffice")
        try makeFakeLibreOffice(at: executable)
        let capabilities = ConversionCapabilities(
            allowsExternalProcesses: false,
            libreOfficeExecutable: executable
        )

        #expect(!capabilities.isLibreOfficeAvailable)
        #expect(LibreOfficeBackend(capabilities: capabilities).edges().isEmpty)
        #expect(
            ConversionPlanner(capabilities: capabilities).plan(
                from: ConversionFormats.pdf,
                to: ConversionFormats.docx
            ) == nil
        )
    }

    @Test("Direct build detects LibreOffice and converts PDF to DOCX")
    func directAcceptance() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("soffice")
        try makeFakeLibreOffice(at: executable)
        let capabilities = ConversionCapabilities.direct(
            libreOfficeExecutable: executable
        )
        let planner = ConversionPlanner(capabilities: capabilities)
        let plan = try #require(
            planner.plan(from: ConversionFormats.pdf, to: ConversionFormats.docx)
        )

        #expect(capabilities.isLibreOfficeAvailable)
        #expect(plan.steps.map(\.backend) == [.libreOffice])
        #expect(plan.steps.map(\.to) == [ConversionFormats.docx])
        #expect(!plan.isLossless)
        #expect(
            Set(planner.reachableTargets(from: ConversionFormats.pdf)).isSuperset(
                of: [ConversionFormats.docx, ConversionFormats.pptx]
            )
        )

        let input = folder.appendingPathComponent("brief.pdf")
        let output = folder.appendingPathComponent("Exports/brief.docx")
        let fixture = Data("%PDF-1.7\nClip V5 fixture\n".utf8)
        try fixture.write(to: input)
        let stream = await Converter(capabilities: capabilities).convert(
            plan,
            input: input,
            output: output
        )
        for try await _ in stream {}

        #expect(try Data(contentsOf: output) == fixture)
    }

    @Test("Execution rechecks an installation removed after planning")
    func rechecksAvailability() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("soffice")
        try makeFakeLibreOffice(at: executable)
        let capabilities = ConversionCapabilities.direct(
            libreOfficeExecutable: executable
        )
        let plan = try #require(
            ConversionPlanner(capabilities: capabilities).plan(
                from: ConversionFormats.pdf,
                to: ConversionFormats.docx
            )
        )
        try FileManager.default.removeItem(at: executable)
        let stream = await Converter(capabilities: capabilities).convert(
            plan,
            input: folder.appendingPathComponent("missing.pdf"),
            output: folder.appendingPathComponent("missing.docx")
        )

        do {
            for try await _ in stream {}
            Issue.record("Conversion unexpectedly ran after LibreOffice was removed")
        } catch {
            #expect(error.localizedDescription.contains("LibreOffice is no longer available"))
        }
    }

    @Test("An installed LibreOffice produces a real DOCX from PDF")
    func installedLibreOfficeAcceptance() async throws {
        let capabilities = ConversionCapabilities.direct()
        guard capabilities.isLibreOfficeAvailable else { return }
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.pdf")
        let output = folder.appendingPathComponent("source.docx")
        try makePDF(at: input)
        let plan = try #require(
            ConversionPlanner(capabilities: capabilities).plan(
                from: ConversionFormats.pdf,
                to: ConversionFormats.docx
            )
        )
        let stream = await Converter(capabilities: capabilities).convert(
            plan,
            input: input,
            output: output
        )
        for try await _ in stream {}

        let data = try Data(contentsOf: output)
        #expect(data.count > 1_000)
        #expect(data.starts(with: [0x50, 0x4B]))
    }

    @Test("Runaway LibreOffice diagnostic output is stopped and bounded")
    func runawayDiagnosticOutputIsStopped() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("soffice")
        try Data(
            """
            #!/bin/sh
            while :; do
              printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' >&2
            done
            """.utf8
        ).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let capabilities = ConversionCapabilities.direct(
            libreOfficeExecutable: executable
        )
        let step = try #require(
            ConversionPlanner(capabilities: capabilities)
                .plan(from: ConversionFormats.pdf, to: ConversionFormats.docx)?
                .steps.first
        )
        let input = folder.appendingPathComponent("brief.pdf")
        try Data("%PDF-1.7\n".utf8).write(to: input)
        let output = folder.appendingPathComponent("brief.docx")
        let backend = LibreOfficeBackend(
            capabilities: capabilities,
            processTimeout: .seconds(2),
            logSizeLimit: 1_024
        )
        let clock = ContinuousClock()
        let started = clock.now

        do {
            for try await _ in await backend.run(step, input: input, output: output) {}
            Issue.record("Runaway diagnostic output should be rejected")
        } catch {
            #expect(
                error as? ConversionError
                    == .conversionFailed(
                        "LibreOffice produced too much diagnostic output and was stopped."
                    )
            )
        }
        #expect(started.duration(to: clock.now) < .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    private func fixtureFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-v5-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeFakeLibreOffice(at url: URL) throws {
        let script = """
            #!/bin/sh
            outdir=""
            target=""
            input=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --convert-to) target="${2%%:*}"; shift 2 ;;
                --outdir) outdir="$2"; shift 2 ;;
                --*|-env:*) shift ;;
                *) input="$1"; shift ;;
              esac
            done
            base="$(basename "$input")"
            base="${base%.*}"
            cp "$input" "$outdir/$base.$target"
            """
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func makePDF(at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw ConversionError.cannotCreateOutput }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 72, y: 680, width: 468, height: 40))
        context.endPDFPage()
        context.closePDF()
    }
}
