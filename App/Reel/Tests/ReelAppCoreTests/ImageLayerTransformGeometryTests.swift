import CoreGraphics
import Foundation
import Testing

@testable import ReelAppCore

@Suite("Image layer transform geometry")
struct ImageLayerTransformGeometryTests {
    private let canvas = CGSize(width: 1_000, height: 500)

    @Test("Normalized frames map independently across a non-square canvas")
    func displayRectUsesBothCanvasAxes() {
        let rect = ImageLayerTransformGeometry.displayRect(
            for: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            canvasSize: canvas
        )

        #expect(rect == CGRect(x: 100, y: 100, width: 300, height: 200))
    }

    @Test("Moving uses display points and clamps without changing layer size")
    func moveAndClamp() {
        let initial = ImageLayerTransformState(
            frame: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.4),
            rotationDegrees: 0
        )

        let moved = ImageLayerTransformGeometry.moved(
            initial,
            by: CGSize(width: 100, height: 50),
            canvasSize: canvas
        )
        #expect(close(moved.frame.minX, 0.3))
        #expect(close(moved.frame.minY, 0.3))
        #expect(close(moved.frame.width, 0.3))
        #expect(close(moved.frame.height, 0.4))

        let clamped = ImageLayerTransformGeometry.moved(
            initial,
            by: CGSize(width: 5_000, height: 5_000),
            canvasSize: canvas
        )
        #expect(close(clamped.frame.maxX, 1))
        #expect(close(clamped.frame.maxY, 1))
    }

    @Test("Each edge changes only its matching dimension")
    func edgeResize() {
        let initial = ImageLayerTransformState(
            frame: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        )

        let trailing = ImageLayerTransformGeometry.resized(
            initial,
            from: .trailing,
            by: CGSize(width: 100, height: 100),
            canvasSize: canvas
        )
        #expect(close(trailing.frame.minX, 0.2))
        #expect(close(trailing.frame.width, 0.5))
        #expect(close(trailing.frame.minY, 0.2))
        #expect(close(trailing.frame.height, 0.4))

        let top = ImageLayerTransformGeometry.resized(
            initial,
            from: .top,
            by: CGSize(width: 100, height: 50),
            canvasSize: canvas
        )
        #expect(close(top.frame.minX, 0.2))
        #expect(close(top.frame.width, 0.4))
        #expect(close(top.frame.minY, 0.3))
        #expect(close(top.frame.height, 0.3))
    }

    @Test("Corner resizing can preserve the source aspect ratio")
    func aspectRatioResize() {
        let initial = ImageLayerTransformState(
            frame: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
        )
        let initialRect = ImageLayerTransformGeometry.displayRect(
            for: initial.frame,
            canvasSize: canvas
        )

        let resized = ImageLayerTransformGeometry.resized(
            initial,
            from: .bottomTrailing,
            by: CGSize(width: 100, height: 5),
            canvasSize: canvas,
            preservingAspectRatio: true
        )
        let resizedRect = ImageLayerTransformGeometry.displayRect(
            for: resized.frame,
            canvasSize: canvas
        )

        #expect(
            close(resizedRect.width / resizedRect.height, initialRect.width / initialRect.height))
        #expect(close(resized.frame.minX, initial.frame.minX))
        #expect(close(resized.frame.minY, initial.frame.minY))
    }

    @Test("A rotated resize follows the layer's local axes")
    func rotatedResize() {
        let initial = ImageLayerTransformState(
            frame: CGRect(x: 0.3, y: 0.2, width: 0.2, height: 0.4),
            rotationDegrees: 90
        )

        // At 90°, the local right axis points down in display coordinates.
        let resized = ImageLayerTransformGeometry.resized(
            initial,
            from: .trailing,
            by: CGSize(width: 0, height: 100),
            canvasSize: canvas
        )

        #expect(close(resized.frame.width, 0.3))
        #expect(close(resized.frame.height, 0.4))
        #expect(close(resized.frame.midX, initial.frame.midX))
        #expect(close(resized.frame.midY, initial.frame.midY + 0.1))
    }

    @Test("Resize cannot cross the opposite edge")
    func minimumResizeSize() {
        let initial = ImageLayerTransformState(
            frame: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        )
        let resized = ImageLayerTransformGeometry.resized(
            initial,
            from: .bottomTrailing,
            by: CGSize(width: -1_000, height: -1_000),
            canvasSize: canvas,
            minimumPointSize: CGSize(width: 20, height: 30)
        )

        let display = ImageLayerTransformGeometry.displayRect(
            for: resized.frame,
            canvasSize: canvas
        )
        #expect(close(display.width, 20))
        #expect(close(display.height, 30))
        #expect(close(resized.frame.minX, initial.frame.minX))
        #expect(close(resized.frame.minY, initial.frame.minY))
    }

    @Test("Rotation measures pointer angle around the layer center")
    func rotation() {
        let initial = ImageLayerTransformState(
            frame: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.4),
            rotationDegrees: 10
        )
        let center = ImageLayerTransformGeometry.displayRect(
            for: initial.frame,
            canvasSize: canvas
        ).center

        let rotated = ImageLayerTransformGeometry.rotated(
            initial,
            from: CGPoint(x: center.x, y: center.y - 100),
            to: CGPoint(x: center.x + 100, y: center.y),
            canvasSize: canvas
        )

        #expect(close(rotated.rotationDegrees, 100))
        #expect(rotated.frame == initial.frame)
    }

    @Test("Handle positions rotate around the visual center")
    func rotatedHandlePosition() {
        let state = ImageLayerTransformState(
            frame: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4),
            rotationDegrees: 90
        )
        let rect = ImageLayerTransformGeometry.displayRect(
            for: state.frame,
            canvasSize: canvas
        )
        let top = ImageLayerTransformGeometry.position(
            of: .top,
            in: state,
            canvasSize: canvas
        )

        #expect(close(top.x, rect.midX + rect.height / 2))
        #expect(close(top.y, rect.midY))
    }

    @Test("Invalid inputs resolve to a finite safe transform")
    func invalidInput() {
        let invalid = ImageLayerTransformState(
            frame: CGRect(x: .nan, y: 0, width: 0.3, height: 0.2),
            rotationDegrees: .infinity
        )
        let result = ImageLayerTransformGeometry.moved(
            invalid,
            by: CGSize(width: CGFloat.infinity, height: 10),
            canvasSize: canvas
        )

        #expect(result.frame == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(result.rotationDegrees == 0)
    }

    private func close(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.000_001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}

extension CGRect {
    fileprivate var center: CGPoint { CGPoint(x: midX, y: midY) }
}
