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
    case webP
}

/// Formats exposed by the conversion queue.
public enum TargetFormat: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
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
    case webP
    case pdf
    case html
    case markdown
    case rtf
    case plainText
    case docx
    case xlsx
    case pptx

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
        case .webP: "WebP"
        case .pdf: "PDF"
        case .html: "HTML"
        case .markdown: "Markdown"
        case .rtf: "Rich Text"
        case .plainText: "Plain Text"
        case .docx: "Word Document"
        case .xlsx: "Excel Workbook"
        case .pptx: "PowerPoint Presentation"
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
        case .webP: "webp"
        case .pdf: "pdf"
        case .html: "html"
        case .markdown: "md"
        case .rtf: "rtf"
        case .plainText: "txt"
        case .docx: "docx"
        case .xlsx: "xlsx"
        case .pptx: "pptx"
        }
    }

    public var formatID: FormatID {
        switch self {
        case .mp4H264: ConversionFormats.mp4H264
        case .mp4HEVC: ConversionFormats.mp4HEVC
        case .movH264: ConversionFormats.movH264
        case .movProRes422: ConversionFormats.movProRes422
        case .webMVP9: ConversionFormats.webMVP9
        case .webMAV1: ConversionFormats.webMAV1
        case .animatedGIF: ConversionFormats.animatedGIF
        case .matroska: ConversionFormats.matroska
        case .flac: ConversionFormats.flac
        case .png: ConversionFormats.png
        case .jpeg: ConversionFormats.jpeg
        case .heic: ConversionFormats.heic
        case .tiff: ConversionFormats.tiff
        case .webP: ConversionFormats.webP
        case .pdf: ConversionFormats.pdf
        case .html: ConversionFormats.html
        case .markdown: ConversionFormats.markdown
        case .rtf: ConversionFormats.rtf
        case .plainText: ConversionFormats.plainText
        case .docx: ConversionFormats.docx
        case .xlsx: ConversionFormats.xlsx
        case .pptx: ConversionFormats.pptx
        }
    }
}
