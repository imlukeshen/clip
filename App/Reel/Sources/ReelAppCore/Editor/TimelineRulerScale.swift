import Foundation

/// The increments one ruler drawing pass uses.
public struct TimelineRulerScale: Equatable, Sendable {
    /// Seconds between labelled ticks.
    public let labelInterval: Double
    /// Seconds between the unlabelled ticks that subdivide each label.
    public let tickInterval: Double

    public init(labelInterval: Double, tickInterval: Double) {
        let label = labelInterval.isFinite ? max(labelInterval, 0.001) : 1
        let tick = tickInterval.isFinite ? max(tickInterval, 0.001) : label
        self.labelInterval = label
        self.tickInterval = min(tick, label)
    }
}

/// Picks timeline ruler increments for the current zoom.
///
/// A fixed increment cannot serve every zoom: the same 10-second step that
/// reads well on a short project collapses into overlapping labels once an
/// hour of footage is fitted to the viewport. Editors solve this by stepping
/// through a ladder of increments that read cleanly as timecode and taking the
/// densest one whose labels still clear each other, so zooming out lengthens
/// the increment instead of crowding the ruler.
public enum TimelineRuler {
    /// Increments that read cleanly as timecode, from a tenth of a second to
    /// six hours. Longer projects double the last entry.
    static let ladder: [Double] = [
        0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30,
        60, 120, 300, 600, 900, 1_800,
        3_600, 7_200, 10_800, 21_600,
    ]

    /// Divisions tried for the unlabelled ticks between labels, densest first.
    static let divisions = [10, 5, 4, 2]

    /// Chooses the label and tick increments for a zoom level.
    ///
    /// - Parameters:
    ///   - pointsPerSecond: Horizontal points one second of project time
    ///     occupies at the current zoom.
    ///   - minimumLabelSpacing: Points two adjacent labels need between their
    ///     origins to stay legible, measured from the rendered label width.
    ///   - minimumTickSpacing: Points two adjacent unlabelled ticks need before
    ///     the subdivision reads as a solid band instead of ticks.
    public static func scale(
        pointsPerSecond: Double,
        minimumLabelSpacing: Double,
        minimumTickSpacing: Double = 7
    ) -> TimelineRulerScale {
        let scale = pointsPerSecond.isFinite && pointsPerSecond > 0 ? pointsPerSecond : 1
        let labelSpacing = minimumLabelSpacing.isFinite ? max(minimumLabelSpacing, 1) : 1
        var labelInterval = ladder.first { $0 * scale >= labelSpacing } ?? ladder[ladder.count - 1]
        // A project long enough to leave the ladder keeps doubling its coarsest
        // increment, which stays a whole number of hours.
        while labelInterval * scale < labelSpacing, labelInterval < 31_536_000 {
            labelInterval *= 2
        }
        let tickSpacing = minimumTickSpacing.isFinite ? max(minimumTickSpacing, 1) : 1
        let tickInterval =
            divisions.lazy
            .map { labelInterval / Double($0) }
            .first { $0 * scale >= tickSpacing } ?? labelInterval
        return TimelineRulerScale(labelInterval: labelInterval, tickInterval: tickInterval)
    }

    /// Formats a ruler label.
    ///
    /// Hours appear only when the visible range reaches them and tenths only
    /// when labels sit closer than a second apart, so the ordinary case stays a
    /// compact `m:ss` that fits between two ticks.
    ///
    /// - Parameters:
    ///   - seconds: Project time the label marks.
    ///   - labelInterval: Seconds between labels, which decides whether tenths
    ///     are shown.
    ///   - usesHours: Whether the ruler shows an hours component.
    public static func label(
        forSeconds seconds: Double,
        labelInterval: Double,
        usesHours: Bool
    ) -> String {
        let time = seconds.isFinite ? max(seconds, 0) : 0
        let showsTenths = labelInterval.isFinite && labelInterval < 1
        let precision: Double = showsTenths ? 10 : 1
        let quantized = (time * precision).rounded() / precision
        let whole = Int(quantized)
        let text =
            usesHours
            ? String(format: "%d:%02d:%02d", whole / 3_600, (whole % 3_600) / 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
        guard showsTenths else { return text }
        let tenths = Int(((quantized - Double(whole)) * 10).rounded())
        return text + String(format: ".%d", tenths)
    }
}
