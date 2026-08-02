import CoreImage
import CoreModel
import Foundation
import Testing

@testable import MediaEngine

@Suite("Frame effect rendering")
struct FrameEffectRendererTests {
    private let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
    private let activeRange = TimeRange(start: .zero, duration: RationalTime(seconds: 1))

    @Test("Background padding exposes the configured solid canvas")
    func backgroundPadding() throws {
        let effect = BackgroundEffect(
            id: EffectID(rawValue: "background"),
            range: activeRange,
            padding: 0.25,
            cornerRadius: 0,
            style: .solid(RGBA(r: 1, g: 0, b: 0, a: 1))
        )
        let effects: [Effect] = [.background(effect)]
        let background = FrameEffectRenderer.background(
            .black,
            effects: effects,
            at: RationalTime(seconds: 0.5),
            bounds: bounds
        )
        let rendered = FrameEffectRenderer.render(
            CIImage(color: .white).cropped(to: bounds),
            effects: effects,
            at: RationalTime(seconds: 0.5),
            bounds: bounds,
            background: background
        )

        #expect(try pixel(rendered, x: 2, y: 2) == [255, 0, 0, 255])
        #expect(try pixel(rendered, x: 32, y: 32) == [255, 255, 255, 255])
    }

    @Test("Crop is evaluated before aspect fitting")
    func cropBeforeFit() throws {
        let left = CIImage(color: .red).cropped(
            to: CGRect(x: 0, y: 0, width: 32, height: 64)
        )
        let right = CIImage(color: .blue).cropped(
            to: CGRect(x: 32, y: 0, width: 32, height: 64)
        )
        let source = right.composited(over: left)
        let effects: [Effect] = [
            .crop(
                CropEffect(
                    id: EffectID(rawValue: "crop"),
                    range: activeRange,
                    rect: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
                )
            )
        ]
        let rendered = FrameEffectRenderer.render(
            source,
            effects: effects,
            at: RationalTime(seconds: 0.5),
            bounds: bounds,
            background: CIImage(color: .black).cropped(to: bounds)
        )

        #expect(try pixel(rendered, x: 32, y: 32) == [0, 0, 255, 255])
        #expect(try pixel(rendered, x: 2, y: 32) == [0, 0, 0, 255])
    }

    @Test("A regional Gaussian blur blends a hard edge")
    func regionalBlur() throws {
        let black = CIImage(color: .black).cropped(to: bounds)
        let white = CIImage(color: .white).cropped(
            to: CGRect(x: 32, y: 0, width: 32, height: 64)
        )
        let source = white.composited(over: black)
        let effects: [Effect] = [
            .blur(
                BlurEffect(
                    id: EffectID(rawValue: "blur"),
                    range: activeRange,
                    regions: [
                        TimedRegion(
                            time: .zero,
                            rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
                        )
                    ],
                    mode: .gaussian(radius: 8),
                    isDestructiveOnExport: true
                )
            )
        ]
        let rendered = FrameEffectRenderer.render(
            source,
            effects: effects,
            at: RationalTime(seconds: 0.5),
            bounds: bounds,
            background: black
        )
        let edge = try pixel(rendered, x: 32, y: 32)

        #expect(edge[0] > 0)
        #expect(edge[0] < 255)
    }

    private func pixel(_ image: CIImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        try bytes.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else {
                throw MediaEngineError.exportFailed("Pixel buffer allocation failed.")
            }
            context.render(
                image,
                toBitmap: address,
                rowBytes: 64 * 4,
                bounds: bounds,
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }
        let index = (y * 64 + x) * 4
        return Array(bytes[index..<(index + 4)])
    }
}
