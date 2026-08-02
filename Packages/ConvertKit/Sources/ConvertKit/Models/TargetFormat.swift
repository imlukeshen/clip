import Foundation

public enum VideoCodec: String, Sendable, Equatable, CaseIterable {
    case h264
    case hevc
    case proRes422
}

public enum ImageFormat: String, Sendable, Equatable, CaseIterable {
    case png
    case jpeg
    case heic
    case tiff
}

public enum FFmpegRecipe: String, Sendable, Equatable, CaseIterable {
    case webMVP9
    case webMAV1
    case animatedGIF
    case matroska
    case flac
}

/// Formats exposed by the conversion queue.
public enum TargetFormat: String, Sendable, Equatable, CaseIterable, Identifiable {
    case mp4H264
    case mp4HEVC
    case movH264
    case movProRes422
    case webMVP9
    case webMAV1
    case animatedGIF
    case matroska
    case flac
    case png
    case jpeg
    case heic
    case tiff

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .mp4H264: "MP4 · H.264"
        case .mp4HEVC: "MP4 · HEVC"
        case .movH264: "MOV · H.264"
        case .movProRes422: "MOV · ProRes 422"
        case .webMVP9: "WebM · VP9"
        case .webMAV1: "WebM · AV1"
        case .animatedGIF: "GIF"
        case .matroska: "MKV"
        case .flac: "FLAC"
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .mp4H264, .mp4HEVC: "mp4"
        case .movH264, .movProRes422: "mov"
        case .webMVP9, .webMAV1: "webm"
        case .animatedGIF: "gif"
        case .matroska: "mkv"
        case .flac: "flac"
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        case .tiff: "tiff"
        }
    }
}
