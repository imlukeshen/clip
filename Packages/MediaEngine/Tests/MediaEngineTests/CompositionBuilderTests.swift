@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CoreModel
import CoreVideo
import Foundation
import Testing

@testable import MediaEngine

@Suite("Composition building")
struct CompositionBuilderTests {
    @Test("Three clips form one gapless video track and aligned silent audio timeline")
    func threeClipsAreGapless() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reel-composition-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var urls: [AssetID: URL] = [:]
        var items: [TimelineItem] = []
        for index in 0..<3 {
            let id = AssetID(rawValue: "asset-\(index)")
            let url = folder.appendingPathComponent("clip-\(index).mov")
            try await makeMovie(at: url, shade: UInt8(index * 50))
            urls[id] = url
            items.append(
                TimelineItem(
                    id: ItemID(rawValue: "item-\(index)"),
                    assetID: id,
                    sourceRange: TimeRange(
                        start: .zero,
                        duration: RationalTime(seconds: 0.2)
                    )
                )
            )
        }
        let document = try ProjectDocument(
            id: ProjectID(rawValue: "project"),
            name: "Three clips",
            canvas: CanvasSpec(
                width: 640,
                height: 360,
                frameRate: .fps30,
                colorSpace: .sRGB,
                background: .black
            ),
            timeline: Timeline(video: items),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )

        let resolvedURLs = urls
        let built = try await CompositionBuilder().build(
            document,
            resolving: { id in try #require(resolvedURLs[id]) },
            quality: .proxy(180)
        )
        let tracks = built.composition.tracks(withMediaType: .video)
        let audioTracks = built.composition.tracks(withMediaType: .audio)
        let videoTrack = try #require(tracks.first)
        let audioTrack = try #require(audioTracks.first)
        let segments = try #require(videoTrack.segments)

        #expect(tracks.count == 1)
        #expect(audioTracks.count == 1)
        #expect(audioTrack.segments?.isEmpty == true)
        #expect(segments.count == 3)
        #expect(segments[0].timeMapping.target.start == .zero)
        #expect(segments[1].timeMapping.target.start == RationalTime(seconds: 0.2).cmTime)
        #expect(segments[2].timeMapping.target.start == RationalTime(seconds: 0.4).cmTime)
        #expect(built.composition.duration.rational == document.duration)
        #expect(built.videoComposition.instructions.count == 3)
        #expect(built.videoComposition.renderSize == CGSize(width: 320, height: 180))
    }

    @Test("Core Media conversion preserves canonical ticks")
    func timeBridge() {
        let time = RationalTime(value: 123_456)
        #expect(time.cmTime.rational == time)
    }

    @Test("The compositor creates one reusable CI context")
    func compositorContextIsShared() {
        let compositor = EffectCompositor()
        #expect(compositor.contextCreationCount == 1)
    }

    @Test("Migrated V1 rendering is pixel-identical to the legacy single-layer path")
    func migratedV1RenderingIsPixelIdentical() throws {
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 36)
        let source = CIImage(
            color: CIColor(red: 0.12, green: 0.48, blue: 0.91, alpha: 1)
        ).cropped(to: bounds)
        let item = TimelineItem(
            id: ItemID(rawValue: "legacy-item"),
            assetID: AssetID(rawValue: "legacy-asset"),
            sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 1))
        )
        let migrated = Timeline(video: [item]).video[0]
        let canvas = CIImage(color: .black).cropped(to: bounds)
        let legacy = FrameEffectRenderer.render(
            source,
            effects: migrated.effects,
            at: .zero,
            bounds: bounds,
            background: canvas
        )
        let v2 = VideoLayerRenderer.compose(
            [
                (
                    ReelVideoLayer(
                        item: migrated,
                        preferredTransform: .identity,
                        sourceTrackID: 1
                    ),
                    source
                )
            ],
            at: .zero,
            bounds: bounds,
            background: canvas
        )

        #expect(renderBytes(legacy, bounds: bounds) == renderBytes(v2, bounds: bounds))
    }

    @Test("V2 transform and opacity composite a PiP over V1")
    func pictureInPictureCompositesOverPrimary() throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
            .cropped(to: bounds)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1))
            .cropped(to: bounds)
        let range = TimeRange(start: .zero, duration: RationalTime(seconds: 1))
        let primary = TimelineItem(
            id: ItemID(rawValue: "primary"),
            assetID: AssetID(rawValue: "red"),
            sourceRange: range
        )
        let overlay = TimelineItem(
            id: ItemID(rawValue: "pip"),
            assetID: AssetID(rawValue: "blue"),
            sourceRange: range,
            transform: Transform2D(
                translationX: 0.25,
                translationY: 0.25,
                scaleX: 0.5,
                scaleY: 0.5
            ),
            opacity: 0.5
        )
        let output = VideoLayerRenderer.compose(
            [
                (
                    ReelVideoLayer(item: primary, preferredTransform: .identity, sourceTrackID: 1),
                    red
                ),
                (
                    ReelVideoLayer(item: overlay, preferredTransform: .identity, sourceTrackID: 2),
                    blue
                ),
            ],
            at: .zero,
            bounds: bounds,
            background: CIImage(color: .black).cropped(to: bounds)
        )
        let bytes = renderBytes(output, bounds: bounds)
        let outside = pixel(in: bytes, width: 100, x: 10, y: 90)
        // CIContext's bitmap rows are top-down; the Core Image destination at
        // y = 25 is therefore row 75 in this 100-pixel fixture.
        let inside = pixel(in: bytes, width: 100, x: 75, y: 75)

        #expect(outside.r > 245 && outside.b < 10)
        // The working color space gamma-encodes a 50% linear blend to ~188.
        #expect((180...195).contains(Int(inside.r)))
        #expect((180...195).contains(Int(inside.b)))
        #expect(abs(Int(inside.r) - Int(inside.b)) <= 2)
    }

    @Test("Visual fade envelopes are evaluated in timeline time")
    func visualFadeEnvelopeRenders() {
        let bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1))
            .cropped(to: bounds)
        let item = TimelineItem(
            id: ItemID(rawValue: "fade"),
            assetID: AssetID(rawValue: "blue"),
            sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 2)),
            videoFade: FadeEnvelope(
                fadeIn: RationalTime(seconds: 1),
                fadeOut: .zero
            )
        )
        let layer = ReelVideoLayer(
            item: item,
            preferredTransform: .identity,
            sourceTrackID: 1
        )
        let background = CIImage(color: .black).cropped(to: bounds)
        let start = VideoLayerRenderer.compose(
            [(layer, blue)], at: .zero, bounds: bounds, background: background
        )
        let halfway = VideoLayerRenderer.compose(
            [(layer, blue)],
            at: RationalTime(seconds: 0.5),
            bounds: bounds,
            background: background
        )
        let full = VideoLayerRenderer.compose(
            [(layer, blue)],
            at: RationalTime(seconds: 1),
            bounds: bounds,
            background: background
        )

        #expect(pixel(in: renderBytes(start, bounds: bounds), width: 20, x: 10, y: 10).b < 5)
        #expect(
            (180...195).contains(
                Int(pixel(in: renderBytes(halfway, bounds: bounds), width: 20, x: 10, y: 10).b)
            )
        )
        #expect(pixel(in: renderBytes(full, bounds: bounds), width: 20, x: 10, y: 10).b > 245)
    }

    @Test("Opacity keyframes animate through the shared compositor")
    func opacityKeyframesRender() {
        let bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        let source = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: bounds)
        let animation = Animatable(
            constant: 0.0,
            keyframes: [
                Keyframe(time: .zero, value: 0),
                Keyframe(time: RationalTime(seconds: 1), value: 1),
            ]
        )
        let item = TimelineItem(
            id: ItemID(rawValue: "opacity"),
            assetID: AssetID(rawValue: "white"),
            sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 2)),
            opacityAnimation: animation
        )
        let layer = ReelVideoLayer(
            item: item,
            preferredTransform: .identity,
            sourceTrackID: 1
        )
        let output = VideoLayerRenderer.compose(
            [(layer, source)],
            at: RationalTime(seconds: 0.5),
            bounds: bounds,
            background: CIImage(color: .black).cropped(to: bounds)
        )
        let value = pixel(
            in: renderBytes(output, bounds: bounds),
            width: 20,
            x: 10,
            y: 10
        ).r
        #expect((180...195).contains(Int(value)))
    }

    @Test("Video instructions report every time-varying visual property")
    func videoInstructionTweenDetection() {
        let range = TimeRange(start: .zero, duration: RationalTime(seconds: 2))
        func item(
            _ id: String,
            videoFade: FadeEnvelope = .none,
            transformAnimation: Animatable<Transform2D>? = nil,
            opacityAnimation: Animatable<Double>? = nil
        ) -> TimelineItem {
            TimelineItem(
                id: ItemID(rawValue: id),
                assetID: AssetID(rawValue: "asset-\(id)"),
                sourceRange: range,
                transformAnimation: transformAnimation,
                opacityAnimation: opacityAnimation,
                videoFade: videoFade
            )
        }
        func instruction(for item: TimelineItem) -> ReelVideoInstruction {
            ReelVideoInstruction(
                timeRange: CMTimeRange(start: .zero, duration: range.duration.cmTime),
                layers: [
                    ReelVideoLayer(
                        item: item,
                        preferredTransform: .identity,
                        sourceTrackID: 1
                    )
                ],
                background: .black
            )
        }
        let transform = Animatable(
            constant: Transform2D.identity,
            keyframes: [
                Keyframe(time: .zero, value: .identity),
                Keyframe(
                    time: RationalTime(seconds: 1),
                    value: Transform2D(scaleX: 1.5, scaleY: 1.5)
                ),
            ]
        )
        let opacity = Animatable(
            constant: 1.0,
            keyframes: [
                Keyframe(time: .zero, value: 0.0),
                Keyframe(time: RationalTime(seconds: 1), value: 1.0),
            ]
        )

        #expect(!instruction(for: item("constant")).containsTweening)
        #expect(
            instruction(
                for: item(
                    "fade-in",
                    videoFade: FadeEnvelope(fadeIn: RationalTime(seconds: 0.5))
                )
            ).containsTweening
        )
        #expect(
            instruction(
                for: item(
                    "fade-out",
                    videoFade: FadeEnvelope(fadeOut: RationalTime(seconds: 0.5))
                )
            ).containsTweening
        )
        #expect(
            instruction(for: item("transform", transformAnimation: transform)).containsTweening
        )
        #expect(
            instruction(for: item("opacity", opacityAnimation: opacity)).containsTweening
        )
    }

    @Test("Builder emits overlapping V1 and V2 source tracks and ignores disabled tracks")
    func builderCreatesV2Instructions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reel-v2-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clip.mov")
        try await makeMovie(at: url, shade: 90)
        let range = TimeRange(start: .zero, duration: RationalTime(seconds: 0.2))
        func item(_ value: String) -> TimelineItem {
            TimelineItem(
                id: ItemID(rawValue: value),
                assetID: AssetID(rawValue: "asset"),
                sourceRange: range
            )
        }
        let document = try ProjectDocument(
            id: ProjectID(rawValue: "v2-project"),
            name: "PiP",
            canvas: CanvasSpec(
                width: 640,
                height: 360,
                frameRate: .fps30,
                colorSpace: .sRGB,
                background: .black
            ),
            timeline: Timeline(
                videoTracks: [
                    Track(id: TrackID(rawValue: "v1"), name: "V1", items: [item("v1")]),
                    Track(id: TrackID(rawValue: "v2"), name: "V2", items: [item("v2")]),
                    Track(
                        id: TrackID(rawValue: "disabled"),
                        name: "Disabled",
                        items: [item("disabled")],
                        isEnabled: false
                    ),
                ]
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let built = try await CompositionBuilder().build(
            document,
            resolving: { _ in url },
            quality: .full
        )
        let instruction = try #require(
            built.videoComposition.instructions.first as? ReelVideoInstruction
        )

        #expect(built.composition.tracks(withMediaType: .video).count == 2)
        #expect(
            instruction.layers.map(\.item.id) == [
                ItemID(rawValue: "v1"), ItemID(rawValue: "v2"),
            ])
        #expect(instruction.requiredSourceTrackIDs?.count == 2)
    }

    @Test("Audio track mute, solo, and gain produce deterministic mix levels")
    func audioTrackControlsProduceMixLevels() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reel-audio-controls-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("video-only.mov")
        try await makeMovie(at: url, shade: 120)
        let range = TimeRange(start: .zero, duration: RationalTime(seconds: 0.2))
        func item(_ value: String) -> TimelineItem {
            TimelineItem(
                id: ItemID(rawValue: value),
                assetID: AssetID(rawValue: "asset"),
                sourceRange: range
            )
        }
        let document = try ProjectDocument(
            id: ProjectID(rawValue: "audio-controls"),
            name: "Audio controls",
            timeline: Timeline(
                videoTracks: [
                    Track(id: TrackID(rawValue: "v1"), name: "V1", items: [item("video")])
                ],
                audioTracks: [
                    Track(id: TrackID(rawValue: "a1"), name: "A1", items: [item("audio-1")]),
                    Track(
                        id: TrackID(rawValue: "a2"),
                        name: "A2",
                        items: [item("audio-2")],
                        isSolo: true,
                        gain: -6,
                        gainAnimation: Animatable(
                            constant: -6,
                            keyframes: [
                                Keyframe(time: .zero, value: -6),
                                Keyframe(time: RationalTime(seconds: 0.2), value: 0),
                            ]
                        )
                    ),
                    Track(
                        id: TrackID(rawValue: "a3"),
                        name: "A3",
                        items: [item("audio-3")],
                        isMuted: true,
                        isSolo: true
                    ),
                ]
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let built = try await CompositionBuilder().build(
            document,
            resolving: { _ in url },
            quality: .proxy(180)
        )
        let volumes = built.audioMix.inputParameters.map(volume(atStartOf:))

        #expect(built.composition.tracks(withMediaType: .audio).count == 3)
        #expect(volumes.count == 3)
        #expect(volumes[0] == 0)
        #expect(abs(volumes[1] - 0.501_187) < 0.001)
        #expect(volumes[2] == 0)
        let gainRamp = volumeRamp(
            built.audioMix.inputParameters[1],
            at: RationalTime(seconds: 0.1).cmTime
        )
        #expect(abs(gainRamp.start - 0.501_187) < 0.001)
        #expect(abs(gainRamp.end - 1) < 0.001)
    }

    private func renderBytes(_ image: CIImage, bounds: CGRect) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        CIContext(options: [.useSoftwareRenderer: true]).render(
            image,
            toBitmap: &bytes,
            rowBytes: Int(bounds.width) * 4,
            bounds: bounds,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return bytes
    }

    private func pixel(
        in bytes: [UInt8],
        width: Int,
        x: Int,
        y: Int
    ) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    private func volume(atStartOf parameters: AVAudioMixInputParameters) -> Float {
        var start: Float = -1
        var end: Float = -1
        var range = CMTimeRange.invalid
        guard
            parameters.getVolumeRamp(
                for: .zero,
                startVolume: &start,
                endVolume: &end,
                timeRange: &range
            )
        else {
            return -1
        }
        return start
    }

    private func volumeRamp(
        _ parameters: AVAudioMixInputParameters,
        at time: CMTime
    ) -> (start: Float, end: Float) {
        var start: Float = -1
        var end: Float = -1
        var range = CMTimeRange.invalid
        guard
            parameters.getVolumeRamp(
                for: time,
                startVolume: &start,
                endVolume: &end,
                timeRange: &range
            )
        else {
            return (-1, -1)
        }
        return (start, end)
    }

    private func makeMovie(at url: URL, shade: UInt8) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<6 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            var pixelBuffer: CVPixelBuffer?
            #expect(
                CVPixelBufferCreate(
                    nil,
                    64,
                    64,
                    kCVPixelFormatType_32BGRA,
                    nil,
                    &pixelBuffer
                ) == kCVReturnSuccess
            )
            let buffer = try #require(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let address = CVPixelBufferGetBaseAddress(buffer) {
                memset(address, Int32(shade), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)
                )
            )
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        #expect(writer.status == .completed)
    }
}
