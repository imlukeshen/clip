@preconcurrency import AVFoundation
import CoreImage
import CoreModel
import Foundation
import Testing

@testable import MediaEngine

@Test func stillImageBecomesAThreeSecondTimelineClip() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-still-builder-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let imageURL = root.appendingPathComponent("Still.png")
    let movieURL = root.appendingPathComponent("Still.mov")
    let image = CIImage(color: .red).cropped(
        to: CGRect(x: 0, y: 0, width: 96, height: 64)
    )
    try CIContext().writePNGRepresentation(
        of: image,
        to: imageURL,
        format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    )

    try await StillImageClipBuilder().build(imageAt: imageURL, outputURL: movieURL)

    let asset = AVURLAsset(url: movieURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let duration = try await asset.load(.duration).rational
    #expect(tracks.count == 1)
    #expect(abs(duration.seconds - StillImageClipBuilder.defaultDuration.seconds) <= 1.0 / 30.0)
}
