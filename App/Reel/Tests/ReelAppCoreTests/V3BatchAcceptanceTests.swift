import ConvertKit
import Foundation
import ReelAppCore
import Testing

@Suite("V3 batch conversion acceptance")
struct V3BatchAcceptanceTests {
    @Test("Forty mixed files finish with two actionable failures in a templated destination")
    func mixedBatchCompletesPartially() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-v3-batch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let inputExtensions = ["mov", "png", "wav", "pdf", "md", "tiff"]
        let failedIndices: Set<Int> = [7, 31]
        let failedNames = Set(failedIndices.map { "source-\($0).\(inputExtensions[$0 % 6])" })
        let converter = Converter(ffmpeg: MixedBatchBackend(failingInputs: failedNames))
        let plan = ConversionPlan(
            backend: .ffmpeg(.webMVP9),
            estimate: .proportional(1),
            lossless: false
        )
        let destination = ExportDestination(
            bookmarkKey: "acceptance",
            subpathTemplate: "Exports/{date}",
            filenameTemplate: "{project}-{preset}-{index}",
            onCompletion: .nothing
        )
        let date = try #require(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 8, day: 3)
            )
        )
        let jobs = try (0..<40).map { index in
            let name = "source-\(index).\(inputExtensions[index % inputExtensions.count])"
            let output = try destination.resolve(
                in: folder,
                context: ExportTemplateContext(
                    project: "source-\(index)",
                    date: date,
                    preset: "web",
                    codec: "vp9",
                    resolution: "source",
                    duration: "0",
                    index: index + 1
                ),
                extension: "webm"
            )
            return BatchConversionJob(
                plan: plan,
                input: folder.appendingPathComponent(name),
                output: output
            )
        }

        let stream = await converter.convert(jobs)
        var outcomes: [UUID: BatchItemOutcome] = [:]
        var finalProgress: BatchProgress?
        for try await update in stream {
            finalProgress = update
            if let id = update.itemID, let outcome = update.outcome {
                outcomes[id] = outcome
            }
        }

        let failures = outcomes.values.compactMap { outcome -> String? in
            if case .failed(let reason) = outcome { return reason }
            return nil
        }
        let successes = outcomes.values.compactMap { outcome -> URL? in
            if case .succeeded(let url) = outcome { return url }
            return nil
        }
        #expect(finalProgress?.completed == 40)
        #expect(finalProgress?.aggregateProgress == 1)
        #expect(failures.count == 2)
        #expect(failures.allSatisfy { $0.contains("source-") && $0.contains("Try again") })
        #expect(successes.count == 38)
        #expect(
            successes.allSatisfy {
                $0.path.contains("/Exports/2026-08-03/")
                    && FileManager.default.fileExists(atPath: $0.path)
            }
        )
    }
}

private actor MixedBatchBackend: FFmpegTranscoding {
    let failingInputs: Set<String>

    init(failingInputs: Set<String>) {
        self.failingInputs = failingInputs
    }

    func transcode(
        input: URL,
        output: URL,
        recipe _: FFmpegRecipe
    ) async -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            do {
                continuation.yield(0)
                if failingInputs.contains(input.lastPathComponent) {
                    throw ConversionError.conversionFailed(
                        "Could not convert \(input.lastPathComponent). Try again or choose another target."
                    )
                }
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data([0x1A, 0x45, 0xDF, 0xA3]).write(to: output)
                continuation.yield(1)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
