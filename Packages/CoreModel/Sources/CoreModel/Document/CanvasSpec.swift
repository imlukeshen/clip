import Foundation

/// Color spaces supported by a Clip project.
public enum ColorSpaceTag: String, Codable, Sendable {
    case sRGB
    case displayP3
}

/// The output geometry and presentation defaults for a project.
public struct CanvasSpec: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    public var colorSpace: ColorSpaceTag
    public var background: RGBA

    public init(
        width: Int,
        height: Int,
        frameRate: FrameRate,
        colorSpace: ColorSpaceTag,
        background: RGBA
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.colorSpace = colorSpace
        self.background = background
    }

    public static let fullHD = CanvasSpec(
        width: 1_920,
        height: 1_080,
        frameRate: .fps60,
        colorSpace: .sRGB,
        background: .black
    )
}
