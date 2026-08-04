import ConvertKit
import Foundation
import LibraryStore

public enum ConversionQueueStatus: Sendable, Equatable {
    case waiting
    case converting
    case completed(URL)
    case failed(String)
    case cancelled
    case skipped(String)
}

public struct ConversionQueueItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let asset: AssetRecord
    public let inputURL: URL
    public private(set) var target: TargetFormat
    public private(set) var plan: ConversionPlan
    public private(set) var options: ConversionOptions
    public private(set) var selectedPresetID: String?
    public var progress: Double
    public var status: ConversionQueueStatus

    public init(
        id: UUID = UUID(),
        asset: AssetRecord,
        inputURL: URL,
        target: TargetFormat? = nil,
        options: ConversionOptions = ConversionOptions(),
        selectedPresetID: String? = nil,
        progress: Double = 0,
        status: ConversionQueueStatus = .waiting
    ) {
        let selectedTarget = target ?? Self.defaultTarget(for: asset)
        self.id = id
        self.asset = asset
        self.inputURL = inputURL
        self.target = selectedTarget
        self.options = options
        self.selectedPresetID = selectedPresetID
        self.plan = ConvertKit.plan(from: asset, to: selectedTarget, options: options)
        self.progress = progress
        self.status = status
    }

    public var availableTargets: [TargetFormat] {
        guard let source = FormatID(asset: asset) else { return [] }
        let reachable = Set(ConversionPlanner().reachableTargets(from: source, options: options))
        return TargetFormat.allCases.filter { reachable.contains($0.formatID) }
    }

    public var compatiblePresets: [ConversionPreset] {
        guard let source = FormatID(asset: asset) else { return [] }
        return ConversionPreset.builtIns.filter { preset in
            ConversionPlanner().plan(
                from: source,
                to: preset.target.formatID,
                options: preset.options
            ) != nil
        }
    }

    public var stripsMetadata: Bool { options.removesMetadata }

    public var planDescription: String {
        guard !plan.steps.isEmpty else { return backendDisplayName(plan.backend) }
        let formats = [plan.steps[0].from] + plan.steps.map(\.to)
        let route = formats.map(formatDisplayName).joined(separator: " → ")
        let backends = plan.steps.map(\.backend).reduce(into: [BackendID]()) { names, backend in
            if !names.contains(backend) { names.append(backend) }
        }
        let backendNames = backends.map(backendDisplayName).joined(separator: " + ")
        let stepLabel = "\(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s")"
        return "\(route) · \(stepLabel) · \(backendNames)"
    }

    public var visibleWarnings: [String] {
        var warnings = plan.warnings
        if stripsMetadata, !warnings.contains("Metadata will be stripped.") {
            warnings.append("Metadata will be stripped.")
        }
        return warnings
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
        selectedPresetID = nil
        self.plan = ConvertKit.plan(from: asset, to: target, options: options)
        progress = 0
        status = .waiting
    }

    public mutating func applyPreset(_ preset: ConversionPreset) {
        if case .converting = status { return }
        guard let source = FormatID(asset: asset),
            let plan = ConversionPlanner().plan(
                from: source,
                to: preset.target.formatID,
                options: preset.options
            )
        else { return }
        target = preset.target
        options = preset.options
        selectedPresetID = preset.id
        self.plan = plan
        progress = 0
        status = .waiting
    }

    public mutating func setStripMetadata(_ shouldStrip: Bool) {
        if case .converting = status { return }
        options.stripAllMetadata = shouldStrip
        selectedPresetID = nil
        plan = ConvertKit.plan(from: asset, to: target, options: options)
        progress = 0
        status = .waiting
    }

    public mutating func setConflictPolicy(_ policy: ConversionConflictPolicy) {
        if case .converting = status { return }
        options.conflictPolicy = policy
        if case .completed = status { return }
        status = .waiting
    }

    public mutating func retry() {
        switch status {
        case .failed, .cancelled, .skipped:
            progress = 0
            status = .waiting
        case .waiting, .converting, .completed:
            break
        }
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
        case .document:
            return asset.container?.lowercased() == "pdf" ? .png : .pdf
        case .text: return .pdf
        }
    }
}

private func formatDisplayName(_ format: FormatID) -> String {
    let container = format.preferredFilenameExtension.uppercased()
    guard let codec = format.codec else { return container }
    return "\(container)/\(codecDisplayName(codec))"
}

private func backendDisplayName(_ backend: BackendID) -> String {
    switch backend {
    case .passthrough: "Remux"
    case .videoToolbox: "VideoToolbox"
    case .imageIO: "ImageIO"
    case .pdfKit: "PDFKit"
    case .attributedString: "Rich Text"
    case .webKit: "WebKit"
    case .markdown: "Markdown"
    case .ffmpeg: "FFmpeg"
    case .libreOffice: "LibreOffice"
    }
}

private func backendDisplayName(_ backend: Backend) -> String {
    switch backend {
    case .remux: "Remux"
    case .videoToolbox: "VideoToolbox"
    case .imageIO: "ImageIO"
    case .pdfKit: "PDFKit"
    case .attributedString: "Rich Text"
    case .webKit: "WebKit"
    case .markdown: "Markdown"
    case .ffmpeg: "FFmpeg"
    case .libreOffice: "LibreOffice"
    case .unsupported(let reason): reason
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
