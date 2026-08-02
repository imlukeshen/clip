import Foundation
@preconcurrency import Speech

/// A time-coded on-device transcription segment.
public struct TranscriptSegment: Codable, Sendable, Equatable {
    public var start: TimeInterval
    public var duration: TimeInterval
    public var text: String

    public init(start: TimeInterval, duration: TimeInterval, text: String) {
        self.start = start
        self.duration = duration
        self.text = text
    }
}

/// A completed on-device transcription.
public struct Transcript: Codable, Sendable, Equatable {
    public var text: String
    public var segments: [TranscriptSegment]

    public init(text: String, segments: [TranscriptSegment]) {
        self.text = text
        self.segments = segments
    }
}

/// Generates captions with Apple's on-device recognizer and no provider key.
public struct OnDeviceTranscriber: Sendable {
    private let locale: Locale

    public init(locale: Locale = .current) { self.locale = locale }

    public static func isAvailable(locale: Locale = .current) -> Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
    }

    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    public func transcribe(_ url: URL) async throws -> Transcript {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
            recognizer.supportsOnDeviceRecognition
        else {
            throw AIKitError.transcriptionUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            final class Box: @unchecked Sendable {
                var task: SFSpeechRecognitionTask?
                var resumed = false
                let lock = NSLock()
            }
            let box = Box()
            box.task = recognizer.recognitionTask(with: request) { result, error in
                box.lock.lock()
                guard !box.resumed else {
                    box.lock.unlock()
                    return
                }
                if let result, result.isFinal {
                    box.resumed = true
                    box.lock.unlock()
                    let segments = result.bestTranscription.segments.map {
                        TranscriptSegment(
                            start: $0.timestamp, duration: $0.duration, text: $0.substring)
                    }
                    continuation.resume(
                        returning: Transcript(
                            text: result.bestTranscription.formattedString, segments: segments))
                } else if let error {
                    box.resumed = true
                    box.lock.unlock()
                    continuation.resume(
                        throwing: AIKitError.transcriptionFailed(error.localizedDescription))
                } else {
                    box.lock.unlock()
                }
            }
        }
    }
}
