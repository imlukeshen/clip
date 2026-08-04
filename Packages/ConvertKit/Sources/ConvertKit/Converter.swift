import Foundation

public actor Converter {
    private let remuxer: any Remuxing
    private let videoToolbox: any VideoTranscoding
    private let imageIO: any ImageTranscoding
    private let ffmpeg: any FFmpegTranscoding
    private let pdfKit = PDFKitBackend()
    private let attributedString = AttributedStringBackend()
    private let webKit = WebKitBackend()
    private let markdown = MarkdownBackend()

    public init(ffmpeg: any FFmpegTranscoding = FFmpegTranscoder()) {
        self.remuxer = RemuxTranscoder()
        self.videoToolbox = VideoToolboxTranscoder()
        self.imageIO = ImageIOTranscoder()
        self.ffmpeg = ffmpeg
    }

    public func convert(
        _ plan: ConversionPlan,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error> {
        if !plan.steps.isEmpty {
            return execute(plan.steps, input: input, output: output)
        }
        return await executeLegacy(plan, input: input, output: output)
    }

    private func execute(
        _ steps: [PlannedStep],
        input: URL,
        output: URL
    ) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let workspace = FileManager.default.temporaryDirectory
                    .appendingPathComponent("clip-convert-\(UUID().uuidString)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(
                        at: workspace,
                        withIntermediateDirectories: true
                    )
                    defer { try? FileManager.default.removeItem(at: workspace) }
                    var currentInput = input
                    for (index, step) in steps.enumerated() {
                        try Task.checkCancellation()
                        let isFinal = index == steps.indices.last
                        let stepOutput =
                            isFinal
                            ? output
                            : workspace.appendingPathComponent(
                                "step-\(index + 1).\(step.to.preferredFilenameExtension)"
                            )
                        let stream = await self.execute(
                            step, input: currentInput, output: stepOutput)
                        for try await value in stream {
                            let overall =
                                (Double(index) + min(max(value, 0), 1)) / Double(steps.count)
                            continuation.yield(overall)
                        }
                        currentInput = stepOutput
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ConversionError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(
        _ step: PlannedStep,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error> {
        switch step.backend {
        case .passthrough:
            return await remuxer.remux(input: input, output: output)
        case .videoToolbox:
            guard case .videoToolbox(let codec) = step.implementation else {
                return failedStream(ConversionError.invalidInput)
            }
            return await videoToolbox.transcode(input: input, output: output, codec: codec)
        case .imageIO:
            guard case .imageIO(let format) = step.implementation else {
                return failedStream(ConversionError.invalidInput)
            }
            return await imageIO.transcode(input: input, output: output, format: format)
        case .pdfKit:
            return await pdfKit.run(step, input: input, output: output)
        case .attributedString:
            return await attributedString.run(step, input: input, output: output)
        case .webKit:
            return await webKit.run(step, input: input, output: output)
        case .markdown:
            return await markdown.run(step, input: input, output: output)
        case .ffmpeg:
            guard case .ffmpeg(let recipe) = step.implementation else {
                return failedStream(ConversionError.invalidInput)
            }
            return await ffmpeg.transcode(input: input, output: output, recipe: recipe)
        case .libreOffice:
            return failedStream(ConversionError.backendUnavailable("LibreOffice is not available"))
        }
    }

    private func executeLegacy(
        _ plan: ConversionPlan,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error> {
        switch plan.backend {
        case .remux:
            return await remuxer.remux(input: input, output: output)
        case .videoToolbox(let codec):
            return await videoToolbox.transcode(input: input, output: output, codec: codec)
        case .imageIO(let format):
            return await imageIO.transcode(input: input, output: output, format: format)
        case .ffmpeg(let recipe):
            return await ffmpeg.transcode(input: input, output: output, recipe: recipe)
        case .pdfKit, .attributedString, .webKit, .markdown, .libreOffice:
            return failedStream(
                ConversionError.backendUnavailable("This plan has no executable step"))
        case .unsupported(let reason):
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ConversionError.unsupported(reason))
            }
        }
    }

    public func convert(
        _ plans: [(ConversionPlan, URL, URL)],
        concurrency: Int = 2
    ) -> AsyncThrowingStream<BatchProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard concurrency > 0 else {
                        throw ConversionError.conversionFailed("Concurrency must be positive")
                    }
                    let counter = BatchCounter()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        var nextIndex = 0
                        func addJob(_ index: Int) {
                            let job = plans[index]
                            group.addTask {
                                let stream = await self.convert(
                                    job.0,
                                    input: job.1,
                                    output: job.2
                                )
                                for try await progress in stream {
                                    continuation.yield(
                                        BatchProgress(
                                            completed: await counter.completed,
                                            total: plans.count,
                                            itemIndex: index,
                                            itemProgress: progress
                                        )
                                    )
                                }
                                let completed = await counter.increment()
                                continuation.yield(
                                    BatchProgress(
                                        completed: completed,
                                        total: plans.count,
                                        itemIndex: index,
                                        itemProgress: 1
                                    )
                                )
                            }
                        }

                        while nextIndex < min(concurrency, plans.count) {
                            addJob(nextIndex)
                            nextIndex += 1
                        }
                        while try await group.next() != nil {
                            if nextIndex < plans.count {
                                addJob(nextIndex)
                                nextIndex += 1
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor BatchCounter {
    private(set) var completed = 0

    func increment() -> Int {
        completed += 1
        return completed
    }
}
