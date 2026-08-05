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
    private let tectonic = TectonicBackend()
    private let libreOffice: LibreOfficeBackend
    private nonisolated let cancellationRegistry = BatchCancellationRegistry()

    public nonisolated static var defaultConcurrency: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    public init(
        ffmpeg: any FFmpegTranscoding = FFmpegTranscoder(),
        capabilities: ConversionCapabilities = .appStore
    ) {
        self.remuxer = RemuxTranscoder()
        self.videoToolbox = VideoToolboxTranscoder()
        self.imageIO = ImageIOTranscoder()
        self.ffmpeg = ffmpeg
        self.libreOffice = LibreOfficeBackend(capabilities: capabilities)
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
            return await remuxer.remux(input: input, output: output, options: step.options)
        case .videoToolbox:
            guard case .videoToolbox(let codec) = step.implementation else {
                return failedStream(ConversionError.invalidInput)
            }
            return await videoToolbox.transcode(
                input: input,
                output: output,
                codec: codec,
                options: step.options
            )
        case .imageIO:
            guard case .imageIO(let format) = step.implementation else {
                return failedStream(ConversionError.invalidInput)
            }
            return await imageIO.transcode(
                input: input,
                output: output,
                format: format,
                options: step.options
            )
        case .pdfKit:
            return await pdfKit.run(step, input: input, output: output)
        case .attributedString:
            return await attributedString.run(step, input: input, output: output)
        case .webKit:
            return await webKit.run(step, input: input, output: output)
        case .markdown:
            return await markdown.run(step, input: input, output: output)
        case .tectonic:
            return await tectonic.run(step, input: input, output: output)
        case .ffmpeg:
            guard case .ffmpeg(let recipe) = step.implementation else {
                return failedStream(ConversionError.invalidInput)
            }
            return await ffmpeg.transcode(
                input: input,
                output: output,
                recipe: recipe,
                options: step.options
            )
        case .libreOffice:
            guard libreOffice.isAvailable else {
                return failedStream(
                    ConversionError.backendUnavailable(
                        "LibreOffice is no longer available. Reinstall it or choose another format."
                    )
                )
            }
            return await libreOffice.run(step, input: input, output: output)
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
        case .pdfKit, .attributedString, .webKit, .markdown, .tectonic, .libreOffice:
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
        concurrency: Int = Converter.defaultConcurrency
    ) -> AsyncThrowingStream<BatchProgress, Error> {
        let jobs = plans.map { plan, input, output in
            BatchConversionJob(plan: plan, input: input, output: output)
        }
        return convert(jobs, concurrency: concurrency)
    }

    public func convert(
        _ jobs: [BatchConversionJob],
        concurrency: Int = Converter.defaultConcurrency
    ) -> AsyncThrowingStream<BatchProgress, Error> {
        guard concurrency > 0 else {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: ConversionError.conversionFailed("Concurrency must be positive")
                )
            }
        }
        guard !jobs.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }

        let cancellations = cancellationRegistry
        return AsyncThrowingStream { continuation in
            let task = Task {
                await cancellations.register(jobs.map(\.id))
                let state = BatchState(total: jobs.count)
                await withTaskGroup(of: Void.self) { group in
                    var nextIndex = 0
                    func addJob(_ index: Int) {
                        let job = jobs[index]
                        group.addTask {
                            let result = BatchJobResult()
                            let gate = BatchOperationGate()
                            let operation = Task {
                                let outcome: BatchItemOutcome
                                do {
                                    await gate.wait()
                                    try Task.checkCancellation()
                                    let stream = await self.convert(
                                        job.plan,
                                        input: job.input,
                                        output: job.output
                                    )
                                    for try await progress in stream {
                                        try Task.checkCancellation()
                                        let update = await state.update(
                                            index: index, progress: progress)
                                        continuation.yield(
                                            update.progress(
                                                itemIndex: index,
                                                itemID: job.id,
                                                itemProgress: progress
                                            )
                                        )
                                    }
                                    try Task.checkCancellation()
                                    outcome = .succeeded(job.output)
                                } catch is CancellationError {
                                    outcome = .cancelled
                                } catch ConversionError.cancelled {
                                    outcome = .cancelled
                                } catch {
                                    outcome = .failed(error.localizedDescription)
                                }
                                await result.resolve(outcome)
                            }
                            await cancellations.register(operation, for: job.id)
                            await gate.open()
                            while await result.outcome == nil {
                                let cancellationRequested =
                                    await cancellations
                                    .isCancelled(job.id)
                                if Task.isCancelled || cancellationRequested {
                                    operation.cancel()
                                }
                                try? await Task.sleep(for: .milliseconds(20))
                            }
                            let outcome = await result.outcome ?? .cancelled
                            await cancellations.finish(job.id)
                            let update = await state.finish(index: index)
                            continuation.yield(
                                update.progress(
                                    itemIndex: index,
                                    itemID: job.id,
                                    itemProgress: 1,
                                    outcome: outcome
                                )
                            )
                        }
                    }

                    while nextIndex < min(concurrency, jobs.count) {
                        addJob(nextIndex)
                        nextIndex += 1
                    }
                    while await group.next() != nil {
                        if nextIndex < jobs.count {
                            addJob(nextIndex)
                            nextIndex += 1
                        }
                    }
                }
                // Individual workers yield after leaving BatchState. Their
                // snapshots can therefore arrive out of order even though the
                // actor counted every completion correctly. End with one
                // deterministic aggregate update for UI and automation clients.
                continuation.yield(await state.finalProgress())
                continuation.finish()
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                Task { await cancellations.cancel(jobs.map(\.id)) }
            }
        }
    }

    public nonisolated func cancel(jobID: UUID) async {
        await cancellationRegistry.cancel(jobID)
    }

    public nonisolated func cancelAll() async {
        await cancellationRegistry.cancelAll()
    }
}

private actor BatchJobResult {
    private(set) var outcome: BatchItemOutcome?

    func resolve(_ outcome: BatchItemOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
    }
}

private actor BatchOperationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private actor BatchCancellationRegistry {
    private var activeJobs: Set<UUID> = []
    private var cancelledJobs: Set<UUID> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func register(_ ids: [UUID]) {
        activeJobs.formUnion(ids)
    }

    func cancel(_ id: UUID) {
        cancelledJobs.insert(id)
        tasks[id]?.cancel()
    }

    func cancel(_ ids: [UUID]) {
        cancelledJobs.formUnion(ids)
        for id in ids { tasks[id]?.cancel() }
    }

    func cancelAll() {
        cancelledJobs.formUnion(activeJobs)
        for task in tasks.values { task.cancel() }
    }

    func isCancelled(_ id: UUID) -> Bool {
        cancelledJobs.contains(id)
    }

    func finish(_ id: UUID) {
        activeJobs.remove(id)
        cancelledJobs.remove(id)
        tasks[id] = nil
    }

    func register(_ task: Task<Void, Never>, for id: UUID) {
        tasks[id] = task
        if cancelledJobs.contains(id) { task.cancel() }
    }
}

private actor BatchState {
    struct Snapshot: Sendable {
        var completed: Int
        var total: Int
        var aggregateProgress: Double

        func progress(
            itemIndex: Int,
            itemID: UUID,
            itemProgress: Double,
            outcome: BatchItemOutcome? = nil
        ) -> BatchProgress {
            BatchProgress(
                completed: completed,
                total: total,
                itemIndex: itemIndex,
                itemID: itemID,
                itemProgress: min(max(itemProgress, 0), 1),
                aggregateProgress: aggregateProgress,
                outcome: outcome
            )
        }
    }

    private let total: Int
    private var completed = 0
    private var progressByIndex: [Int: Double] = [:]
    private var finishedIndices: Set<Int> = []

    init(total: Int) {
        self.total = total
    }

    func update(index: Int, progress: Double) -> Snapshot {
        progressByIndex[index] = min(max(progress, 0), 1)
        return snapshot()
    }

    func finish(index: Int) -> Snapshot {
        if finishedIndices.insert(index).inserted {
            completed += 1
        }
        progressByIndex[index] = 1
        return snapshot()
    }

    func finalProgress() -> BatchProgress {
        let final = snapshot()
        return BatchProgress(
            completed: final.completed,
            total: final.total,
            itemIndex: max(total - 1, 0),
            itemProgress: 1,
            aggregateProgress: final.aggregateProgress
        )
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            completed: completed,
            total: total,
            aggregateProgress: progressByIndex.values.reduce(0, +) / Double(max(total, 1))
        )
    }
}
