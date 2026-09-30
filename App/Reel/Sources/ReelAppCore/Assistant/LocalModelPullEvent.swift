import Foundation

/// One line of Ollama's streaming install response.
///
/// `/api/pull` answers with newline-delimited JSON rather than SSE: a run of
/// `{"status":…,"total":…,"completed":…}` objects, then either a final
/// `{"status":"success"}` or an object carrying `error`. A transport failure and
/// a refusal therefore look nothing alike — the second arrives as a perfectly
/// successful HTTP response — so both are modelled here instead of only one.
public enum LocalModelPullEvent: Equatable, Sendable {
    case progress(LocalModelDownloadProgress)
    case finished
    case failed(String)

    /// Reads one response line, or returns nil when it carries nothing to show.
    public init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let error = object["error"] as? String, !error.isEmpty {
            self = .failed(error)
            return
        }
        guard let status = object["status"] as? String else { return nil }
        if status == "success" {
            self = .finished
            return
        }
        self = .progress(
            LocalModelDownloadProgress(
                status: status,
                completedBytes: (object["completed"] as? NSNumber)?.int64Value ?? 0,
                totalBytes: (object["total"] as? NSNumber)?.int64Value ?? 0
            )
        )
    }
}
