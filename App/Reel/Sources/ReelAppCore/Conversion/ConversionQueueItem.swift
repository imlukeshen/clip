import ConvertKit
import Foundation
import LibraryStore

public enum ConversionQueueStatus: Sendable, Equatable {
    case waiting
    case converting
    case completed(URL)
    case failed(String)
}

public struct ConversionQueueItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let asset: AssetRecord
    public let inputURL: URL
    public private(set) var target: TargetFormat
    public private(set) var plan: ConversionPlan
    public var progress: Double
    public var status: ConversionQueueStatus

    public init(
        id: UUID = UUID(),
        asset: AssetRecord,
        inputURL: URL,
        target: TargetFormat? = nil,
        progress: Double = 0,
        status: ConversionQueueStatus = .waiting
    ) {
        let selectedTarget = target ?? Self.defaultTarget(for: asset)
        self.id = id
        self.asset = asset
        self.inputURL = inputURL
        self.target = selectedTarget
        self.plan = ConvertKit.plan(from: asset, to: selectedTarget)
        self.progress = progress
        self.status = status
    }

    public var availableTargets: [TargetFormat] {
        guard let source = FormatID(asset: asset) else { return [] }
        let reachable = Set(ConversionPlanner().reachableTargets(from: source))
        return TargetFormat.allCases.filter { reachable.contains($0.formatID) }
    }

    public var sourceDescription: String {
        let container = asset.container?.uppercased() ?? asset.kind.rawValue.capitalized
        guard let codec = asset.codec, !codec.isEmpty else { return container }
        return "\(container) · \(codecDisplayName(codec))"
    }

    public var outputFilename: String {
        let stem = inputURL.deletingPathExtension().lastPathComponent
        return "\(stem).\(target.fileExtension)"
    }

    public mutating func selectTarget(_ target: TargetFormat) {
        if case .converting = status { return }
        guard availableTargets.contains(target) else { return }
        self.target = target
        self.plan = ConvertKit.plan(from: asset, to: target)
        progress = 0
        status = .waiting
    }

    private static func defaultTarget(for asset: AssetRecord) -> TargetFormat {
        switch asset.kind {
        case .video:
            if asset.container?.lowercased() == "mp4",
                ["h264", "avc1"].contains(asset.codec?.lowercased())
            {
                return .movH264
            }
            return .mp4H264
        case .image: return .jpeg
        case .audio: return .flac
        case .document: return .png
        // No text target exists yet (T2/T3); the planner reports it unsupported,
        // so this placeholder is never actually offered or run.
        case .text: return .png
        }
    }
}

private func codecDisplayName(_ codec: String) -> String {
    switch codec.lowercased() {
    case "h264", "avc1": "H.264"
    case "h265", "hevc", "hvc1", "hev1": "HEVC"
    case "apcn", "prores422": "ProRes 422"
    case "lpcm": "PCM"
    default: codec.uppercased()
    }
}
