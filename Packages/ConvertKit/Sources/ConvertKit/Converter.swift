import Foundation

public actor Converter {
    private let remuxer: any Remuxing
    private let videoToolbox: any VideoTranscoding
    private let imageIO: any ImageTranscoding
    private let ffmpeg: any FFmpegTranscoding

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
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: ConversionError.backendUnavailable(
                        "This conversion backend is not available yet"
                    ))
            }
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
