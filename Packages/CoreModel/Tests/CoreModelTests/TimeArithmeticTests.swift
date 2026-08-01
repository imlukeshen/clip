import CoreModel
import Testing

@Test func canonicalFrameDurationsAreExact() {
    #expect(FrameRate.fps24.frameDuration.value == 3_750)
    #expect(FrameRate.fps25.frameDuration.value == 3_600)
    #expect(FrameRate.fps30.frameDuration.value == 3_000)
    #expect(FrameRate.ntsc30.frameDuration.value == 3_003)
    #expect(FrameRate.fps50.frameDuration.value == 1_800)
    #expect(FrameRate.fps60.frameDuration.value == 1_500)
}

@Test func timeNormalizesAndRoundsToCanonicalTicks() throws {
    let fromMilliseconds = RationalTime(value: 1_000, timescale: 1_000)
    #expect(fromMilliseconds == RationalTime(seconds: 1))
    #expect(fromMilliseconds.timescale == 90_000)
    #expect(RationalTime(seconds: 1.0 / 60.0).value == 1_500)
}

@Test func halfOpenRangeIntersectionAndClamping() {
    let first = TimeRange(
        start: RationalTime(seconds: 1),
        duration: RationalTime(seconds: 2)
    )
    let touching = TimeRange(
        start: RationalTime(seconds: 3),
        duration: RationalTime(seconds: 1)
    )
    let overlapping = TimeRange(
        start: RationalTime(seconds: 2.5),
        duration: RationalTime(seconds: 1)
    )

    #expect(!first.intersects(touching))
    #expect(first.intersects(overlapping))
    #expect(
        first.clamped(to: overlapping)
            == TimeRange(
                start: RationalTime(seconds: 2.5),
                duration: RationalTime(seconds: 0.5)
            )
    )
}
