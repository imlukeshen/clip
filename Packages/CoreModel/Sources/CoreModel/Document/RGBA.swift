import Foundation

/// An unpremultiplied red, green, blue, and alpha color in the range zero through one.
public struct RGBA: Codable, Sendable, Equatable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
}
