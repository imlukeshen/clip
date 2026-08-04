import Foundation
import UniformTypeIdentifiers

/// A concrete file representation. Codecs distinguish formats that share a
/// container, such as H.264 and HEVC MP4 files.
public struct FormatID: Hashable, Sendable {
    public var type: UTType
    public var codec: String?

    public init(type: UTType, codec: String? = nil) {
        self.type = type
        self.codec = codec?.lowercased()
    }

    /// A stable extension for intermediate files created by a multi-hop plan.
    public var preferredFilenameExtension: String {
        if let preferred = type.preferredFilenameExtension { return preferred }
        return type.identifier.split(separator: ".").last.map(String.init) ?? "tmp"
    }
}

public enum ConversionFormats {
    public static let movH264 = FormatID(type: .quickTimeMovie, codec: "h264")
    public static let movHEVC = FormatID(type: .quickTimeMovie, codec: "hevc")
    public static let movProRes422 = FormatID(type: .quickTimeMovie, codec: "prores422")
    public static let mp4H264 = FormatID(type: .mpeg4Movie, codec: "h264")
    public static let mp4HEVC = FormatID(type: .mpeg4Movie, codec: "hevc")
    public static let webMVP9 = FormatID(type: type("webm"), codec: "vp9")
    public static let webMAV1 = FormatID(type: type("webm"), codec: "av1")
    public static let matroska = FormatID(type: type("mkv"))
    public static let animatedGIF = FormatID(type: .gif)
    public static let flac = FormatID(type: type("flac"), codec: "flac")
    public static let png = FormatID(type: .png)
    public static let jpeg = FormatID(type: .jpeg)
    public static let heic = FormatID(type: .heic)
    public static let tiff = FormatID(type: .tiff)
    public static let webP = FormatID(type: type("webp"))
    public static let avif = FormatID(type: type("avif"))
    public static let pdf = FormatID(type: .pdf)
    public static let html = FormatID(type: .html)
    public static let plainText = FormatID(type: .plainText)
    public static let markdown = FormatID(type: type("md"))
    public static let rtf = FormatID(type: .rtf)
    public static let doc = FormatID(type: type("doc"))
    public static let docx = FormatID(type: type("docx"))
    public static let svg = FormatID(type: .svg)

    public static let imageInputs: [FormatID] = [
        png, jpeg, heic, tiff, animatedGIF,
        FormatID(type: .bmp),
        FormatID(type: type("ico")),
        webP,
        avif,
    ]
    public static let rawInputs: [FormatID] = [
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf",
    ].map { FormatID(type: type($0)) }
    public static let richTextInputs: [FormatID] = [docx, doc, rtf, html, plainText]
    public static let videoInputs: [FormatID] = [
        movH264, movHEVC, movProRes422, mp4H264, mp4HEVC, webMVP9, webMAV1, matroska,
    ]
    public static let audioInputs: [FormatID] = [
        "mp3", "aac", "m4a", "wav", "flac", "opus", "ogg", "aiff", "wma", "caf",
    ].map { FormatID(type: type($0)) }

    public static func type(_ extension: String) -> UTType {
        UTType(filenameExtension: `extension`) ?? UTType(importedAs: "app.clip.\(`extension`)")
    }
}

/// A declarative input predicate used by conversion edges.
public enum FormatMatcher: Sendable {
    case exact(FormatID)
    case type(UTType)
    case conformsTo(UTType)
    case oneOf([FormatID])

    public func matches(_ format: FormatID) -> Bool {
        switch self {
        case .exact(let expected):
            format == expected
        case .type(let expected):
            format.type == expected
        case .conformsTo(let expected):
            format.type.conforms(to: expected)
        case .oneOf(let formats):
            formats.contains { expected in
                expected.type == format.type
                    && (expected.codec == nil || expected.codec == format.codec)
            }
        }
    }
}

public enum BackendID: String, Sendable, Equatable, Hashable {
    case passthrough
    case videoToolbox
    case imageIO
    case pdfKit
    case attributedString
    case webKit
    case markdown
    case ffmpeg
    case libreOffice
}

public enum ConversionCost: Int, Sendable, Equatable, Comparable {
    case passthrough = 0
    case cheap = 10
    case hardware = 25
    case expensive = 50

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ConversionOptionSupport: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let quality = Self(rawValue: 1 << 0)
    public static let resize = Self(rawValue: 1 << 1)
    public static let frameRate = Self(rawValue: 1 << 2)
    public static let audio = Self(rawValue: 1 << 3)
    public static let trim = Self(rawValue: 1 << 4)
    public static let stripMetadata = Self(rawValue: 1 << 5)
    public static let pageRange = Self(rawValue: 1 << 6)
    public static let rasterizationDPI = Self(rawValue: 1 << 7)
}

public struct ConversionOptions: Sendable, Equatable {
    public var requested: ConversionOptionSupport

    public init(requested: ConversionOptionSupport = []) {
        self.requested = requested
    }
}

public struct ConversionEdge: Sendable {
    public var from: FormatMatcher
    public var to: FormatID
    public var backend: BackendID
    public var implementation: Backend
    public var cost: ConversionCost
    public var isLossless: Bool
    public var warnings: [String]
    public var supportedOptions: ConversionOptionSupport

    public init(
        from: FormatMatcher,
        to: FormatID,
        backend: BackendID,
        implementation: Backend,
        cost: ConversionCost,
        isLossless: Bool,
        warnings: [String] = [],
        supportedOptions: ConversionOptionSupport = []
    ) {
        self.from = from
        self.to = to
        self.backend = backend
        self.implementation = implementation
        self.cost = cost
        self.isLossless = isLossless
        self.warnings = warnings
        self.supportedOptions = supportedOptions
    }
}

public struct PlannedStep: Sendable, Equatable {
    public var from: FormatID
    public var to: FormatID
    public var backend: BackendID
    public var implementation: Backend
    public var cost: ConversionCost
    public var isLossless: Bool
    public var warnings: [String]

    public init(from: FormatID, edge: ConversionEdge) {
        self.from = from
        self.to = edge.to
        self.backend = edge.backend
        self.implementation = edge.implementation
        self.cost = edge.cost
        self.isLossless = edge.isLossless
        self.warnings = edge.warnings
    }
}

/// Metadata and execution supplied by one conversion implementation.
public protocol ConversionBackend: Sendable {
    var id: BackendID { get }
    var isAvailable: Bool { get }
    func edges() -> [ConversionEdge]
    func run(
        _ step: PlannedStep,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error>
}
