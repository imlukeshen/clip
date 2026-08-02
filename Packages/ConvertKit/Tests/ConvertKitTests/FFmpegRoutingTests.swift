import ConvertKit
import CoreModel
import Foundation
import LibraryStore
import Testing

@Suite("FFmpeg routing")
struct FFmpegRoutingTests {
    @Test("MOV to WebM completes through the injected in-process FFmpeg backend")
    func movToWebMUsesFFmpeg() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reel-ffmpeg-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.mov")
        let output = folder.appendingPathComponent("output.webm")
        try Data("movie".utf8).write(to: input)
        let spy = FFmpegSpy()
        let converter = Converter(ffmpeg: spy)
        let conversion = plan(from: videoRecord(), to: .webMVP9)

        let stream = await converter.convert(conversion, input: input, output: output)
        var progress: [Double] = []
        for try await value in stream { progress.append(value) }

        #expect(await spy.recipes == [.webMVP9])
        #expect(try Data(contentsOf: output) == Data([0x1A, 0x45, 0xDF, 0xA3]))
        #expect(progress == [0, 0.5, 1])
    }

    private func videoRecord() -> AssetRecord {
        AssetRecord(
            id: AssetID.generate(),
            relativePath: "Assets/input.mov",
            displayName: "input.mov",
            kind: .video,
            container: "mov",
            codec: "h264",
            createdAt: Date(timeIntervalSince1970: 1),
            importedAt: Date(timeIntervalSince1970: 2),
            byteSize: 5,
            contentHash: "hash",
            ingestState: .ready
        )
    }
}

private actor FFmpegSpy: FFmpegTranscoding {
    private(set) var recipes: [FFmpegRecipe] = []

    func transcode(
        input: URL,
        output: URL,
        recipe: FFmpegRecipe
    ) async -> AsyncThrowingStream<Double, Error> {
        recipes.append(recipe)
        return AsyncThrowingStream { continuation in
            continuation.yield(0)
            continuation.yield(0.5)
            do {
                try Data([0x1A, 0x45, 0xDF, 0xA3]).write(to: output)
                continuation.yield(1)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
