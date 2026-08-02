import Foundation

/// A canvas-relative item transform. Translation is expressed as a fraction of
/// the output width and height, rotation is clockwise in degrees.
public struct Transform2D: Codable, Sendable, Equatable {
    public var translationX: Double
    public var translationY: Double
    public var scaleX: Double
    public var scaleY: Double
    public var rotationDegrees: Double

    public init(
        translationX: Double = 0,
        translationY: Double = 0,
        scaleX: Double = 1,
        scaleY: Double = 1,
        rotationDegrees: Double = 0
    ) {
        self.translationX = translationX
        self.translationY = translationY
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.rotationDegrees = rotationDegrees
    }

    public static let identity = Transform2D()
}

/// Porter-Duff and Core Image blend modes available to overlay items.
public enum BlendMode: String, Codable, Sendable, Equatable, CaseIterable {
    case normal
    case multiply
    case screen
    case overlay
}
