import CoreModel
import Foundation
import LibraryStore

/// The outcome of running one stage. Empty OCR or transcript output is skipped,
/// not failed, so legitimate media is never retried forever.
public enum IndexStageOutcome: Sendable, Equatable {
    case completed
    case noContent
}

/// Performs the stage-specific work owned by each later search milestone.
public protocol IndexStageProcessing: Sendable {
    func process(assetID: AssetID, stage: IndexStage) async throws -> IndexStageOutcome
}

/// A sendable processor that can be assembled from a closure in app code or tests.
public struct AnyIndexStageProcessor: IndexStageProcessing {
    private let operation: @Sendable (AssetID, IndexStage) async throws -> IndexStageOutcome

    public init(
        _ operation: @escaping @Sendable (AssetID, IndexStage) async throws -> IndexStageOutcome
    ) {
        self.operation = operation
    }

    public func process(assetID: AssetID, stage: IndexStage) async throws -> IndexStageOutcome {
        try await operation(assetID, stage)
    }

    /// The S0 processor completes metadata jobs. Later milestones replace this
    /// closure with OCR, transcript, embedding, and summary implementations.
    public static let metadataOnly = AnyIndexStageProcessor { _, stage in
        stage == .metadata ? .completed : .noContent
    }
}

/// User-visible reasons that background indexing is not consuming resources.
public enum IndexPauseReason: String, Sendable, Equatable, Hashable, CaseIterable {
    case playback
    case export
    case conversion
    case thermal
    case lowPower

    public var displayName: String {
        switch self {
        case .playback: "playback"
        case .export: "export"
        case .conversion: "conversion"
        case .thermal: "Mac temperature"
        case .lowPower: "Low Power Mode"
        }
    }
}

/// A snapshot of durable queue state suitable for a compact sidebar footer.
public struct IndexProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var failed: Int
    public var currentAssetID: AssetID?
    public var currentStage: IndexStage?
    public var pauseReasons: Set<IndexPauseReason>

    public var fraction: Double {
        guard total > 0 else { return 1 }
        return Double(completed + failed) / Double(total)
    }

    public var isComplete: Bool { total == 0 || completed + failed == total }
    public var isPaused: Bool { !pauseReasons.isEmpty }

    public init(
        completed: Int = 0,
        total: Int = 0,
        failed: Int = 0,
        currentAssetID: AssetID? = nil,
        currentStage: IndexStage? = nil,
        pauseReasons: Set<IndexPauseReason> = []
    ) {
        self.completed = completed
        self.total = total
        self.failed = failed
        self.currentAssetID = currentAssetID
        self.currentStage = currentStage
        self.pauseReasons = pauseReasons
    }
}

/// Coarse thermal levels avoid exposing non-Sendable ProcessInfo state to the actor.
public enum IndexThermalLevel: Int, Sendable, Comparable {
    case nominal
    case fair
    case serious
    case critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Current resource constraints, injected in tests for deterministic scheduling.
public struct IndexResourceSnapshot: Sendable, Equatable {
    public var thermalLevel: IndexThermalLevel
    public var isLowPowerModeEnabled: Bool

    public init(
        thermalLevel: IndexThermalLevel,
        isLowPowerModeEnabled: Bool
    ) {
        self.thermalLevel = thermalLevel
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    public static var current: Self {
        let process = ProcessInfo.processInfo
        let thermalLevel: IndexThermalLevel
        switch process.thermalState {
        case .nominal: thermalLevel = .nominal
        case .fair: thermalLevel = .fair
        case .serious: thermalLevel = .serious
        case .critical: thermalLevel = .critical
        @unknown default: thermalLevel = .serious
        }
        return Self(
            thermalLevel: thermalLevel,
            isLowPowerModeEnabled: process.isLowPowerModeEnabled
        )
    }
}

/// Resumable, resource-aware background indexing coordinator.
public actor IndexPipeline {
    private let store: LibraryStore
    private let processor: any IndexStageProcessing
    private let resourceSnapshot: @Sendable () -> IndexResourceSnapshot
    private let retryDelay: Duration
    private let continuation: AsyncStream<IndexProgress>.Continuation
    private var workerTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var manualPauseReasons: Set<IndexPauseReason> = []
    private var currentJob: IndexJobRecord?

    public nonisolated let progress: AsyncStream<IndexProgress>

    public init(
        store: LibraryStore,
        processor: any IndexStageProcessing = AnyIndexStageProcessor.metadataOnly,
        resourceSnapshot: @escaping @Sendable () -> IndexResourceSnapshot = {
            .current
        },
        retryDelay: Duration = .seconds(5)
    ) {
        let stream = AsyncStream<IndexProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.store = store
        self.processor = processor
        self.resourceSnapshot = resourceSnapshot
        self.retryDelay = retryDelay
        self.progress = stream.stream
        self.continuation = stream.continuation
    }

    deinit {
        workerTask?.cancel()
        wakeTask?.cancel()
        continuation.finish()
    }

    /// Adds durable jobs and begins work when resources permit.
    public func enqueue(_ assetID: AssetID, stages: Set<IndexStage>) async {
        do {
            try await store.enqueueIndexJobs(for: assetID, stages: stages)
            await publishProgress()
            startWorkerIfNeeded()
        } catch {
            await publishProgress()
        }
    }

    /// Resets a job left running by a prior process and drains the remaining queue.
    public func resumePending() async {
        do {
            try await store.resetInterruptedIndexJobs()
        } catch {
            await publishProgress()
            return
        }
        await publishProgress()
        startWorkerIfNeeded()
    }

    /// Stops future or in-flight work for one asset.
    public func cancel(_ assetID: AssetID) async {
        if currentJob?.assetID == assetID {
            workerTask?.cancel()
            _ = await workerTask?.value
            workerTask = nil
        }
        try? await store.cancelIndexJobs(for: assetID)
        currentJob = nil
        await publishProgress()
        startWorkerIfNeeded()
    }

    /// Requeues metadata work for a scope. Later milestones widen the stage set
    /// as their processors become available.
    public func rebuild(scope: IndexScope) async {
        do {
            try await store.rebuildIndexJobs(scope: scope, stages: [.metadata])
            await publishProgress()
            startWorkerIfNeeded()
        } catch {
            await publishProgress()
        }
    }

    /// Replaces selected stages for one changed asset without racing the active worker.
    public func reindex(_ assetID: AssetID, stages: Set<IndexStage>) async {
        guard !stages.isEmpty else { return }
        if currentJob?.assetID == assetID {
            workerTask?.cancel()
            _ = await workerTask?.value
            workerTask = nil
            currentJob = nil
            try? await store.resetInterruptedIndexJobs()
        }
        do {
            try await store.rebuildIndexJobs(scope: .assets([assetID]), stages: stages)
            await publishProgress()
            startWorkerIfNeeded()
        } catch {
            await publishProgress()
        }
    }

    /// Pauses immediately for foreground media work and resumes from the same durable job.
    public func setPauseReasons(_ reasons: Set<IndexPauseReason>) async {
        guard reasons != manualPauseReasons else { return }
        manualPauseReasons = reasons
        if !reasons.isEmpty {
            workerTask?.cancel()
            _ = await workerTask?.value
            workerTask = nil
            try? await store.resetInterruptedIndexJobs()
            currentJob = nil
            await publishProgress()
            return
        }
        try? await store.resetInterruptedIndexJobs()
        await publishProgress()
        startWorkerIfNeeded()
    }

    /// Gracefully stops the in-process worker; persisted work remains resumable.
    public func stop() async {
        wakeTask?.cancel()
        wakeTask = nil
        workerTask?.cancel()
        _ = await workerTask?.value
        workerTask = nil
        try? await store.resetInterruptedIndexJobs()
        currentJob = nil
        await publishProgress()
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil, manualPauseReasons.isEmpty else { return }
        workerTask = Task(priority: .background) { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        defer {
            currentJob = nil
            workerTask = nil
        }
        while !Task.isCancelled, manualPauseReasons.isEmpty {
            let resources = resourceSnapshot()
            guard resources.thermalLevel <= .fair else {
                await publishProgress(additionalPauseReasons: [.thermal])
                scheduleResourceRetry()
                return
            }

            let job: IndexJobRecord?
            do {
                job = try await store.claimNextIndexJob(
                    allowSummary: !resources.isLowPowerModeEnabled
                )
            } catch {
                await publishProgress()
                return
            }
            guard let job else {
                let reasons: Set<IndexPauseReason> =
                    resources.isLowPowerModeEnabled
                    ? [.lowPower] : []
                await publishProgress(additionalPauseReasons: reasons)
                if !reasons.isEmpty { scheduleResourceRetry() }
                return
            }

            currentJob = job
            await publishProgress()
            do {
                let outcome = try await processor.process(assetID: job.assetID, stage: job.stage)
                try Task.checkCancellation()
                try await store.finishIndexJob(
                    assetID: job.assetID,
                    stage: job.stage,
                    outcome: outcome == .completed ? .done : .skipped
                )
            } catch is CancellationError {
                try? await store.resetInterruptedIndexJobs()
                return
            } catch {
                _ = try? await store.failIndexJob(
                    assetID: job.assetID,
                    stage: job.stage,
                    error: String(describing: error)
                )
            }
            currentJob = nil
            await publishProgress()
        }
    }

    private func scheduleResourceRetry() {
        guard wakeTask == nil else { return }
        let retryDelay = retryDelay
        wakeTask = Task(priority: .background) { [weak self] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled else { return }
            await self?.resourceRetryElapsed()
        }
    }

    private func resourceRetryElapsed() {
        wakeTask = nil
        startWorkerIfNeeded()
    }

    private func publishProgress(
        additionalPauseReasons: Set<IndexPauseReason> = []
    ) async {
        guard let jobs = try? await store.indexJobs() else {
            continuation.yield(
                IndexProgress(
                    currentAssetID: currentJob?.assetID,
                    currentStage: currentJob?.stage,
                    pauseReasons: manualPauseReasons.union(additionalPauseReasons)
                )
            )
            return
        }
        let completed = jobs.count { $0.state == .done || $0.state == .skipped }
        let failed = jobs.count { $0.state == .failed }
        continuation.yield(
            IndexProgress(
                completed: completed,
                total: jobs.count,
                failed: failed,
                currentAssetID: currentJob?.assetID,
                currentStage: currentJob?.stage,
                pauseReasons: manualPauseReasons.union(additionalPauseReasons)
            )
        )
    }
}
