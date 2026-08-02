import Foundation
import LibraryStore

/// Pure, total conversion planning for every source/target pairing.
public func plan(from source: AssetRecord, to target: TargetFormat) -> ConversionPlan {
    if source.kind == .document || source.container?.lowercased() == "pdf" {
        return ConversionPlan(
            backend: .unsupported("PDF conversion is planned for v2"),
            estimate: .instant,
            lossless: false
        )
    }

    if let recipe = ffmpegRecipe(for: target) {
        return ConversionPlan(
            backend: .ffmpeg(recipe),
            estimate: .proportional(1.5),
            lossless: recipe == .flac,
            warnings: recipe == .flac ? [] : ["This format requires re-encoding."]
        )
    }

    if let imageFormat = imageFormat(for: target) {
        guard source.kind == .image else {
            return unsupported("The source is not an image")
        }
        return ConversionPlan(
            backend: .imageIO(imageFormat),
            estimate: .instant,
            lossless: imageFormat == .png || imageFormat == .tiff,
            warnings: imageFormat == .jpeg || imageFormat == .heic
                ? ["This image format uses lossy compression."] : []
        )
    }

    guard source.kind == .video else {
        return unsupported("The source is not a video")
    }

    let container = source.container?.lowercased()
    let isH264 = normalizedCodec(source.codec) == .h264
    if isH264,
        (container == "mov" && target == .mp4H264)
            || (container == "mp4" && target == .movH264)
    {
        return ConversionPlan(backend: .remux, estimate: .seconds(2), lossless: true)
    }

    guard let codec = videoCodec(for: target) else {
        return unsupported("That target is not available for this source")
    }
    return ConversionPlan(
        backend: .videoToolbox(codec),
        estimate: .proportional(1),
        lossless: false,
        warnings: ["The video will be re-encoded."]
    )
}

private func normalizedCodec(_ value: String?) -> VideoCodec? {
    switch value?.lowercased().replacingOccurrences(of: ".", with: "") {
    case "h264", "avc1": .h264
    case "h265", "hevc", "hvc1", "hev1": .hevc
    case "apcn", "prores422": .proRes422
    default: nil
    }
}

private func videoCodec(for target: TargetFormat) -> VideoCodec? {
    switch target {
    case .mp4H264, .movH264: .h264
    case .mp4HEVC: .hevc
    case .movProRes422: .proRes422
    default: nil
    }
}

private func imageFormat(for target: TargetFormat) -> ImageFormat? {
    switch target {
    case .png: .png
    case .jpeg: .jpeg
    case .heic: .heic
    case .tiff: .tiff
    default: nil
    }
}

private func ffmpegRecipe(for target: TargetFormat) -> FFmpegRecipe? {
    switch target {
    case .webMVP9: .webMVP9
    case .webMAV1: .webMAV1
    case .animatedGIF: .animatedGIF
    case .matroska: .matroska
    case .flac: .flac
    default: nil
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
