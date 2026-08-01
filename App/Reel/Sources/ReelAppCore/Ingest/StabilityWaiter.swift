import Foundation

/// Waits for repeated identical file observations and successful media validation.
public struct StabilityWaiter: Sendable {
    public let configuration: StabilityConfiguration

    public init(configuration: StabilityConfiguration = StabilityConfiguration()) {
        self.configuration = configuration
    }

    public func wait<Value: Sendable>(
        for url: URL,
        progress: @Sendable (Double) -> Void,
        validate: @Sendable (URL) async throws -> Value
    ) async throws -> Value {
        let clock = ContinuousClock()
        let start = clock.now
        var previous: FileSnapshot?
        var matchingPolls = 0

        while start.duration(to: clock.now) < configuration.timeout {
            let snapshot = try readSnapshot(url)
            if snapshot == previous {
                matchingPolls += 1
            } else {
                previous = snapshot
                matchingPolls = 0
            }

            let elapsed = start.duration(to: clock.now)
            progress(min(durationSeconds(elapsed) / durationSeconds(configuration.timeout), 0.99))

            if matchingPolls >= configuration.requiredMatchingPolls {
                do {
                    return try await validate(url)
                } catch let error as IngestError {
                    switch error {
                    case .unreadable:
                        matchingPolls = 0
                    case .neverStabilized, .unsupportedType, .zeroDuration, .diskFull,
                        .bookmarkStale:
                        throw error
                    }
                } catch {
                    matchingPolls = 0
                }
            }
            try await Task.sleep(for: configuration.pollInterval)
        }
        throw IngestError.neverStabilized(url)
    }

    public func snapshot(of url: URL) throws -> FileSnapshot {
        try readSnapshot(url)
    }

    private func readSnapshot(_ url: URL) throws -> FileSnapshot {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                let modifiedAt = attributes[.modificationDate] as? Date
            else {
                throw IngestError.unreadable(url, underlying: "missing file attributes")
            }
            return FileSnapshot(byteSize: size.int64Value, modifiedAt: modifiedAt)
        } catch let error as IngestError {
            throw error
        } catch {
            throw IngestError.unreadable(url, underlying: "file attributes unavailable")
        }
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
