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
        #expect(updates.last?.aggregateProgress == 1)
        #expect(jobs.allSatisfy { FileManager.default.fileExists(atPath: $0.2.path) })
    }

    @Test("A failed item does not stop the rest of the batch")
    func isolatesFailures() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-partial-batch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let failures: Set<String> = ["input-1.mov", "input-3.mov"]
        let converter = Converter(ffmpeg: BatchFFmpegSpy(failingInputs: failures))
        let conversion = ConversionPlan(
            backend: .ffmpeg(.webMVP9),
            estimate: .proportional(1),
            lossless: false
        )
        let jobs = (0..<5).map { index in
            BatchConversionJob(
                plan: conversion,
                input: folder.appendingPathComponent("input-\(index).mov"),
                output: folder.appendingPathComponent("output-\(index).webm")
            )
        }

        let stream = await converter.convert(jobs, concurrency: 2)
        var outcomes: [UUID: BatchItemOutcome] = [:]
        var finalUpdate: BatchProgress?
        for try await update in stream {
            finalUpdate = update
            if let id = update.itemID, let outcome = update.outcome {
                outcomes[id] = outcome
            }
        }

        #expect(finalUpdate?.completed == 5)
        #expect(finalUpdate?.aggregateProgress == 1)
        #expect(outcomes.values.filter { if case .failed = $0 { true } else { false } }.count == 2)
        #expect(
            outcomes.values.filter { if case .succeeded = $0 { true } else { false } }.count == 3
        )
        #expect(FileManager.default.fileExists(atPath: jobs[4].output.path))
    }

    @Test("One item can be cancelled without cancelling its neighbors")
    func individualCancellation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-cancel-batch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let converter = Converter(ffmpeg: BatchFFmpegSpy())
        let conversion = ConversionPlan(
            backend: .ffmpeg(.webMVP9),
            estimate: .proportional(1),
            lossless: false
        )
        let jobs = (0..<2).map { index in
            BatchConversionJob(
                plan: conversion,
                input: folder.appendingPathComponent("input-\(index).mov"),
                output: folder.appendingPathComponent("output-\(index).webm")
            )
        }

        let cancellation = Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            await converter.cancel(jobID: jobs[0].id)
        }
        let stream = await converter.convert(jobs, concurrency: 2)
        var outcomes: [UUID: BatchItemOutcome] = [:]
        for try await update in stream {
            if let id = update.itemID, let outcome = update.outcome {
                outcomes[id] = outcome
            }
        }
        await cancellation.value

        #expect(outcomes[jobs[0].id] == .cancelled)
        #expect(outcomes[jobs[1].id] == .succeeded(jobs[1].output))
        #expect(!FileManager.default.fileExists(atPath: jobs[0].output.path))
        #expect(FileManager.default.fileExists(atPath: jobs[1].output.path))
    }
}

private actor BatchFFmpegSpy: FFmpegTranscoding {
    private var active = 0
    private(set) var maximumActive = 0
    private let failingInputs: Set<String>

    init(failingInputs: Set<String> = []) {
        self.failingInputs = failingInputs
    }

    func transcode(
        input: URL,
        output: URL,
        recipe _: FFmpegRecipe
    ) async -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    active += 1
                    maximumActive = max(maximumActive, active)
                    defer { active -= 1 }
                    continuation.yield(0)
                    try await Task.sleep(for: .milliseconds(100))
                    continuation.yield(0.5)
                    try await Task.sleep(for: .milliseconds(100))
                    if failingInputs.contains(input.lastPathComponent) {
                        throw ConversionError.conversionFailed(
                            "Deliberate failure for \(input.lastPathComponent)"
                        )
                    }
                    try Data([0x1A, 0x45, 0xDF, 0xA3]).write(to: output)
                    continuation.yield(1)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
