import Foundation

/// A canvas-space shadow applied to a framed clip.
public struct ShadowSpec: Codable, Sendable, Equatable {
    public var color: RGBA
    public var radius: Double
    public var offsetX: Double
    public var offsetY: Double

    public init(color: RGBA, radius: Double, offsetX: Double, offsetY: Double) {
        self.color = color
        self.radius = radius
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}
