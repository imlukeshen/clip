import Foundation
import LibraryStore
import UniformTypeIdentifiers

/// Bounded weighted-path planning over backend-declared conversion edges.
public struct ConversionPlanner: Sendable {
    public static let maximumHops = 3

    private let edges: [ConversionEdge]

    public init(edges: [ConversionEdge] = BuiltInConversionGraph.edges) {
        self.edges = edges
    }

    public func plan(
        from source: FormatID,
        to target: FormatID,
        options: ConversionOptions = ConversionOptions()
    ) -> ConversionPlan? {
        guard source != target else { return ConversionPlan(steps: []) }
        var queue = [Candidate(format: source, score: 0, steps: [], supportedOptions: [])]
        var bestScore: [CandidateKey: Int] = [CandidateKey(format: source, supportedOptions: []): 0]

        while !queue.isEmpty {
            queue.sort { $0.score < $1.score }
            let candidate = queue.removeFirst()
            let candidateKey = CandidateKey(
                format: candidate.format,
                supportedOptions: candidate.supportedOptions
            )
            guard candidate.score <= bestScore[candidateKey, default: .max] else { continue }
            if candidate.format == target,
                options.requested.isSubset(of: candidate.supportedOptions)
            {
                return ConversionPlan(steps: candidate.steps)
            }
            guard candidate.steps.count < Self.maximumHops else { continue }

            for edge in edges where edge.from.matches(candidate.format) {
                let step = PlannedStep(from: candidate.format, edge: edge, options: options)
                let score =
                    candidate.score + edge.cost.rawValue
                    + (candidate.steps.isEmpty ? 0 : 40)
                    + (edge.isLossless ? 0 : 60)
                let supportedOptions = candidate.supportedOptions.union(edge.supportedOptions)
                let key = CandidateKey(format: edge.to, supportedOptions: supportedOptions)
                guard score < bestScore[key, default: .max] else { continue }
                bestScore[key] = score
                queue.append(
                    Candidate(
                        format: edge.to,
                        score: score,
                        steps: candidate.steps + [step],
                        supportedOptions: supportedOptions
                    )
                )
            }
        }
        return nil
    }

    public func reachableTargets(
        from source: FormatID,
        options: ConversionOptions = ConversionOptions()
    ) -> [FormatID] {
        Set(edges.map(\.to)).filter { target in
            target != source && plan(from: source, to: target, options: options) != nil
        }.sorted(by: formatOrdering)
    }

    private struct Candidate {
        var format: FormatID
        var score: Int
        var steps: [PlannedStep]
        var supportedOptions: ConversionOptionSupport
    }

    private struct CandidateKey: Hashable {
        var format: FormatID
        var supportedOptions: ConversionOptionSupport
    }
}

/// Compatibility entry point used by the current queue while the richer UI is
/// introduced milestone-by-milestone.
public func plan(
    from source: AssetRecord,
    to target: TargetFormat,
    options: ConversionOptions = ConversionOptions()
) -> ConversionPlan {
    guard let sourceFormat = FormatID(asset: source) else {
        return unsupported("The input format could not be identified")
    }
    return ConversionPlanner().plan(from: sourceFormat, to: target.formatID, options: options)
        ?? unsupported("That target is not reachable from this source")
}

extension FormatID {
    public init?(asset: AssetRecord) {
        let rawExtension = URL(fileURLWithPath: asset.displayName).pathExtension.lowercased()
        let container = asset.container?.lowercased() ?? rawExtension
        let type: UTType
        switch container {
        case "mov": type = .quickTimeMovie
        case "mp4", "m4v": type = .mpeg4Movie
        case "png": type = .png
        case "jpg", "jpeg": type = .jpeg
        case "heic", "heif": type = .heic
        case "tif", "tiff": type = .tiff
        case "gif": type = .gif
        case "pdf": type = .pdf
        case "html", "htm": type = .html
        case "txt": type = .plainText
        case "rtf": type = .rtf
        default:
            guard !container.isEmpty else { return nil }
            type = ConversionFormats.type(container)
        }
        self.init(type: type, codec: normalizedCodec(asset.codec))
    }
}

public enum BuiltInConversionGraph {
    public static var edges: [ConversionEdge] {
        RemuxTranscoder().edges()
            + VideoToolboxTranscoder().edges()
            + ImageIOTranscoder().edges()
            + PDFKitBackend().edges()
            + AttributedStringBackend().edges()
            + WebKitBackend().edges()
            + MarkdownBackend().edges()
            + FFmpegTranscoder().edges()
    }
}

private func normalizedCodec(_ value: String?) -> String? {
    switch value?.lowercased().replacingOccurrences(of: ".", with: "") {
    case "h264", "avc1": "h264"
    case "h265", "hevc", "hvc1", "hev1": "hevc"
    case "apcn", "prores422": "prores422"
    case let value?: value
    case nil: nil
    }
}

private func unsupported(_ reason: String) -> ConversionPlan {
    ConversionPlan(
        backend: .unsupported(reason),
        estimate: .instant,
        lossless: false,
        warnings: [reason]
    )
}

private func formatOrdering(_ lhs: FormatID, _ rhs: FormatID) -> Bool {
    if lhs.type.identifier != rhs.type.identifier {
        return lhs.type.identifier < rhs.type.identifier
    }
    return (lhs.codec ?? "") < (rhs.codec ?? "")
}
