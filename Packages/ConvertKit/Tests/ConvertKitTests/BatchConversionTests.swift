import ConvertKit
import Foundation
import Testing

@Suite("Batch conversion")
struct BatchConversionTests {
    @Test("Batch work respects the requested concurrency and reports completion")
    func boundedConcurrency() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reel-batch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let backend = BatchFFmpegSpy()
        let converter = Converter(ffmpeg: backend)
        let conversion = ConversionPlan(
            backend: .ffmpeg(.webMVP9),
            estimate: .proportional(1),
            lossless: false
        )
        let jobs = (0..<4).map { index in
            (
                conversion,
                folder.appendingPathComponent("input-\(index).mov"),
                folder.appendingPathComponent("output-\(index).webm")
            )
        }

        let stream = await converter.convert(jobs, concurrency: 2)
        var updates: [BatchProgress] = []
        for try await update in stream { updates.append(update) }

        #expect(await backend.maximumActive == 2)
        #expect(updates.contains { $0.completed == 4 })
        #expect(jobs.allSatisfy { FileManager.default.fileExists(atPath: $0.2.path) })
    }
}

private actor BatchFFmpegSpy: FFmpegTranscoding {
    private var active = 0
    private(set) var maximumActive = 0

    func transcode(
        input _: URL,
        output: URL,
        recipe _: FFmpegRecipe
    ) async -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            Task {
                active += 1
                maximumActive = max(maximumActive, active)
                continuation.yield(0)
                try await Task.sleep(for: .milliseconds(35))
                try Data([0x1A, 0x45, 0xDF, 0xA3]).write(to: output)
                continuation.yield(1)
                active -= 1
                continuation.finish()
            }
        }
    }
}
