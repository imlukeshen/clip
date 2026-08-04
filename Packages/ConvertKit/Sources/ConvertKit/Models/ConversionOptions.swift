import Foundation

public struct ConversionColor: Codable, Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = Self(red: 1, green: 1, blue: 1)
}

public enum VideoResolution: Codable, Sendable, Equatable {
    case source
    case p2160
    case p1080
    case p720
    case p480
    case custom(width: Int, height: Int)
}

public struct ConversionTrimRange: Codable, Sendable, Equatable {
    public var startSeconds: Double
    public var endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct VideoConversionOptions: Codable, Sendable, Equatable {
    public var resolution: VideoResolution?
    public var frameRate: Double?
    public var quality: Double?
    public var bitrate: Int?
    public var audioCodec: String?
    public var audioBitrate: Int?
    public var trim: ConversionTrimRange?
    public var mute: Bool
    public var stripMetadata: Bool
    public var twoPass: Bool
    public var maximumFileSize: Int?

    public init(
        resolution: VideoResolution? = nil,
        frameRate: Double? = nil,
        quality: Double? = nil,
        bitrate: Int? = nil,
        audioCodec: String? = nil,
        audioBitrate: Int? = nil,
        trim: ConversionTrimRange? = nil,
        mute: Bool = false,
        stripMetadata: Bool = false,
        twoPass: Bool = false,
        maximumFileSize: Int? = nil
    ) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.quality = quality
        self.bitrate = bitrate
        self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate
        self.trim = trim
        self.mute = mute
        self.stripMetadata = stripMetadata
        self.twoPass = twoPass
        self.maximumFileSize = maximumFileSize
    }
}

public enum ImageResize: Codable, Sendable, Equatable {
    case longestSide(Int)
    case exact(width: Int, height: Int)
    case percentage(Double)
}

public enum ConversionColorProfile: String, Codable, Sendable, Equatable {
    case preserve
    case sRGB
    case displayP3
}

public struct ImageConversionOptions: Codable, Sendable, Equatable {
    public var quality: Double?
    public var resize: ImageResize?
    public var backgroundColor: ConversionColor?
    public var stripMetadata: Bool
    public var colorProfile: ConversionColorProfile

    public init(
        quality: Double? = nil,
        resize: ImageResize? = nil,
        backgroundColor: ConversionColor? = nil,
        stripMetadata: Bool = false,
        colorProfile: ConversionColorProfile = .preserve
    ) {
        self.quality = quality
        self.resize = resize
        self.backgroundColor = backgroundColor
        self.stripMetadata = stripMetadata
        self.colorProfile = colorProfile
    }
}

public struct ConversionPageRange: Codable, Sendable, Equatable {
    public var firstPage: Int
    public var lastPage: Int

    public init(firstPage: Int, lastPage: Int) {
        self.firstPage = firstPage
        self.lastPage = lastPage
    }
}

public enum ConversionPageSize: String, Codable, Sendable, Equatable {
    case source
    case letter
    case a4
}

public struct ConversionMargins: Codable, Sendable, Equatable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double, leading: Double, bottom: Double, trailing: Double) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static let standard = Self(top: 36, leading: 36, bottom: 36, trailing: 36)
}

public struct DocumentConversionOptions: Codable, Sendable, Equatable {
    public var pageRange: ConversionPageRange?
    public var rasterizationDPI: Double?
    public var pageSize: ConversionPageSize?
    public var margins: ConversionMargins?
    public var embedFonts: Bool

    public init(
        pageRange: ConversionPageRange? = nil,
        rasterizationDPI: Double? = nil,
        pageSize: ConversionPageSize? = nil,
        margins: ConversionMargins? = nil,
        embedFonts: Bool = false
    ) {
        self.pageRange = pageRange
        self.rasterizationDPI = rasterizationDPI
        self.pageSize = pageSize
        self.margins = margins
        self.embedFonts = embedFonts
    }
}

public enum ConversionConflictPolicy: String, Codable, Sendable, Equatable {
    case rename
    case overwrite
    case skip
}

public struct ConversionOptions: Codable, Sendable, Equatable {
    public var video: VideoConversionOptions?
    public var image: ImageConversionOptions?
    public var document: DocumentConversionOptions?
    public var stripAllMetadata: Bool
    public var outputNamingTemplate: String
    public var conflictPolicy: ConversionConflictPolicy
    private var explicitlyRequested: ConversionOptionSupport

    public init(
        requested: ConversionOptionSupport = [],
        video: VideoConversionOptions? = nil,
        image: ImageConversionOptions? = nil,
        document: DocumentConversionOptions? = nil,
        stripAllMetadata: Bool = false,
        outputNamingTemplate: String = "{name}",
        conflictPolicy: ConversionConflictPolicy = .rename
    ) {
        self.video = video
        self.image = image
        self.document = document
        self.stripAllMetadata = stripAllMetadata
        self.outputNamingTemplate = outputNamingTemplate
        self.conflictPolicy = conflictPolicy
        self.explicitlyRequested = requested
    }

    public var requested: ConversionOptionSupport {
        var result = explicitlyRequested
        if stripAllMetadata { result.insert(.stripMetadata) }
        if let video {
            if video.resolution != nil { result.insert(.resize) }
            if video.frameRate != nil { result.insert(.frameRate) }
            if video.quality != nil || video.bitrate != nil { result.insert(.quality) }
            if video.audioCodec != nil || video.audioBitrate != nil { result.insert(.audio) }
            if video.trim != nil { result.insert(.trim) }
            if video.mute { result.insert(.mute) }
            if video.stripMetadata { result.insert(.stripMetadata) }
            if video.twoPass { result.insert(.twoPass) }
        }
        if let image {
            if image.quality != nil { result.insert(.quality) }
            if image.resize != nil { result.insert(.resize) }
            if image.backgroundColor != nil { result.insert(.backgroundColor) }
            if image.stripMetadata { result.insert(.stripMetadata) }
            if image.colorProfile != .preserve { result.insert(.colorProfile) }
        }
        if let document {
            if document.pageRange != nil { result.insert(.pageRange) }
            if document.rasterizationDPI != nil { result.insert(.rasterizationDPI) }
            if document.pageSize != nil { result.insert(.pageSize) }
            if document.margins != nil { result.insert(.margins) }
            if document.embedFonts { result.insert(.embedFonts) }
        }
        return result
    }

    public var removesMetadata: Bool {
        stripAllMetadata || video?.stripMetadata == true || image?.stripMetadata == true
    }
}
