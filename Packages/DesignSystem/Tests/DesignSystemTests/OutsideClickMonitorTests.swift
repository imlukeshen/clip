import CoreGraphics
import Testing

@testable import DesignSystem

@Suite("Outside click boundary")
struct OutsideClickMonitorTests {
    private let bounds = CGRect(x: 0, y: 0, width: 420, height: 34)

    @Test("Keeps clicks inside the search field")
    func inside() {
        #expect(
            OutsideClickBoundary.contains(
                CGPoint(x: 210, y: 17),
                in: bounds,
                edgeTolerance: 1
            ))
    }

    @Test("Includes antialiased edge clicks")
    func edgeTolerance() {
        #expect(
            OutsideClickBoundary.contains(
                CGPoint(x: -0.5, y: 17),
                in: bounds,
                edgeTolerance: 1
            ))
        #expect(
            OutsideClickBoundary.contains(
                CGPoint(x: 420.5, y: 17),
                in: bounds,
                edgeTolerance: 1
            ))
    }

    @Test("Dismisses clicks beyond the field edge")
    func outside() {
        #expect(
            !OutsideClickBoundary.contains(
                CGPoint(x: -1.5, y: 17),
                in: bounds,
                edgeTolerance: 1
            ))
        #expect(
            !OutsideClickBoundary.contains(
                CGPoint(x: 421.5, y: 17),
                in: bounds,
                edgeTolerance: 1
            ))
    }

    @Test("Clamps negative tolerance")
    func negativeTolerance() {
        #expect(
            !OutsideClickBoundary.contains(
                CGPoint(x: -0.5, y: 17),
                in: bounds,
                edgeTolerance: -4
            ))
    }
}
