import Foundation

public struct ConversionPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var target: TargetFormat
    public var options: ConversionOptions
    public var isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        target: TargetFormat,
        options: ConversionOptions,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.options = options
        self.isBuiltIn = isBuiltIn
    }
}

extension ConversionPreset {
    public static let webReadyMP4 = ConversionPreset(
        id: "web-ready-mp4",
        name: "Web-ready MP4",
        target: .mp4H264,
        options: ConversionOptions(
            video: VideoConversionOptions(
                resolution: .p1080,
                quality: 0.78,
                bitrate: 6_000_000,
                audioCodec: "aac",
                audioBitrate: 160_000,
                stripMetadata: true
            )
        ),
        isBuiltIn: true
    )

    public static let slackGIF = ConversionPreset(
        id: "slack-gif",
        name: "Slack GIF",
        target: .animatedGIF,
        options: ConversionOptions(
            video: VideoConversionOptions(
                resolution: .p480,
                frameRate: 15,
                quality: 0.82,
                stripMetadata: true,
                maximumFileSize: 8 * 1_024 * 1_024
            )
        ),
        isBuiltIn: true
    )

    public static let emailPDF = ConversionPreset(
        id: "email-pdf",
        name: "Email PDF",
        target: .pdf,
        options: ConversionOptions(
            document: DocumentConversionOptions(rasterizationDPI: 150),
            stripAllMetadata: true
        ),
        isBuiltIn: true
    )

    public static let archiveProRes = ConversionPreset(
        id: "archive-prores",
        name: "Archive ProRes",
        target: .movProRes422,
        options: ConversionOptions(
            video: VideoConversionOptions(audioCodec: "copy")
        ),
        isBuiltIn: true
    )

    public static let losslessShrink = ConversionPreset(
        id: "lossless-shrink",
        name: "Lossless shrink",
        target: .mp4H264,
        options: ConversionOptions(),
        isBuiltIn: true
    )

    public static let builtIns: [ConversionPreset] = [
        .webReadyMP4, .slackGIF, .emailPDF, .archiveProRes, .losslessShrink,
    ]
}

public actor ConversionPresetStore {
    private let url: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func presets() throws -> [ConversionPreset] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ConversionPreset.builtIns
        }
        let custom = try decoder.decode([ConversionPreset].self, from: Data(contentsOf: url))
        return ConversionPreset.builtIns + custom.filter { !$0.isBuiltIn }
    }

    public func save(_ preset: ConversionPreset) throws {
        var custom = try presets().filter { !$0.isBuiltIn && $0.id != preset.id }
        var value = preset
        value.isBuiltIn = false
        custom.append(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(custom).write(to: url, options: .atomic)
    }

    public func remove(_ id: String) throws {
        let custom = try presets().filter { !$0.isBuiltIn && $0.id != id }
        try encoder.encode(custom).write(to: url, options: .atomic)
    }
}
