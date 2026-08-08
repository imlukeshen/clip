import Testing

@testable import ReelAppCore

@Suite("Timeline ruler scale")
struct TimelineRulerScaleTests {
    /// The reported failure: fitting a long recording drops the scale to a few
    /// points per second, where a fixed ten-second increment overlaps.
    @Test("Labels never come closer than the space they need")
    func labelsKeepTheirRequestedSpacing() {
        let spacing = 48.0
        for pointsPerSecond in stride(from: 1.0, through: 900.0, by: 1.0) {
            let scale = TimelineRuler.scale(
                pointsPerSecond: pointsPerSecond,
                minimumLabelSpacing: spacing
            )
            #expect(scale.labelInterval * pointsPerSecond >= spacing)
        }
    }

    @Test("Zooming out lengthens the increment and never shortens it")
    func incrementGrowsMonotonicallyAsTheTimelineZoomsOut() {
        var previous = Double.infinity
        for pointsPerSecond in stride(from: 400.0, through: 1.0, by: -1.0) {
            let interval = TimelineRuler.scale(
                pointsPerSecond: pointsPerSecond,
                minimumLabelSpacing: 48
            ).labelInterval
            #expect(interval >= previous || previous == .infinity)
            previous = interval
        }
    }

    @Test("Every increment reads as a whole timecode step")
    func incrementsComeFromTheReadableLadder() {
        for pointsPerSecond in stride(from: 1.0, through: 900.0, by: 0.5) {
            let interval = TimelineRuler.scale(
                pointsPerSecond: pointsPerSecond,
                minimumLabelSpacing: 48
            ).labelInterval
            #expect(TimelineRuler.ladder.contains(interval))
        }
    }

    @Test("Subdivisions divide the labelled increment and stay legible")
    func subdivisionsDivideTheLabelledIncrement() {
        for pointsPerSecond in stride(from: 1.0, through: 900.0, by: 0.5) {
            let scale = TimelineRuler.scale(
                pointsPerSecond: pointsPerSecond,
                minimumLabelSpacing: 48,
                minimumTickSpacing: 7
            )
            #expect(scale.tickInterval <= scale.labelInterval)
            let divisions = scale.labelInterval / scale.tickInterval
            #expect(abs(divisions - divisions.rounded()) < 1e-9)
            if scale.tickInterval < scale.labelInterval {
                #expect(scale.tickInterval * pointsPerSecond >= 7)
            }
        }
    }

    @Test("A fitted hour-long project labels in minutes rather than seconds")
    func fittedLongProjectUsesCoarseIncrements() {
        // 3,600 s across roughly 1,400 points is the case in the report.
        let scale = TimelineRuler.scale(
            pointsPerSecond: 1_400.0 / 3_600.0,
            minimumLabelSpacing: 48
        )
        #expect(scale.labelInterval >= 300)
    }

    @Test("A degenerate zoom still produces a usable increment")
    func degenerateInputsFallBack() {
        let scale = TimelineRuler.scale(
            pointsPerSecond: .nan,
            minimumLabelSpacing: .nan
        )
        #expect(scale.labelInterval > 0)
        #expect(scale.tickInterval > 0)
        #expect(scale.tickInterval <= scale.labelInterval)
    }

    @Test("Labels format minutes, hours, and tenths only where they are needed")
    func labelsFormatForTheirIncrement() {
        #expect(TimelineRuler.label(forSeconds: 0, labelInterval: 5, usesHours: false) == "0:00")
        #expect(TimelineRuler.label(forSeconds: 65, labelInterval: 5, usesHours: false) == "1:05")
        #expect(
            TimelineRuler.label(forSeconds: 3_725, labelInterval: 300, usesHours: true)
                == "1:02:05"
        )
        #expect(
            TimelineRuler.label(forSeconds: 2.5, labelInterval: 0.5, usesHours: false) == "0:02.5"
        )
        // A tenth-second increment accumulates binary error; the label must not
        // round backwards onto the previous second.
        #expect(
            TimelineRuler.label(forSeconds: 2.9999999, labelInterval: 0.1, usesHours: false)
                == "0:03.0"
        )
        #expect(TimelineRuler.label(forSeconds: -5, labelInterval: 1, usesHours: false) == "0:00")
    }
}
