import CoreModel
import Foundation
import Testing

@testable import MediaEngine

@Suite("Audio gain envelope")
struct AudioGainEnvelopeTests {
    private func item(
        _ id: String,
        start: Double,
        duration: Double,
        fade: FadeEnvelope = .none
    ) -> TimelineItem {
        TimelineItem(
            id: ItemID(rawValue: id),
            assetID: AssetID(rawValue: "asset"),
            sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: duration)),
            timelineStart: RationalTime(seconds: start),
            audioFade: fade
        )
    }

    /// The value the envelope plays at `seconds`, read off its ramps.
    private func volume(_ envelope: AudioGainEnvelope, at seconds: Double) -> Float {
        let time = RationalTime(seconds: seconds)
        guard
            let ramp = envelope.ramps.first(where: {
                $0.start <= time && time <= $0.start + $0.duration
            })
        else { return envelope.ramps.last?.to ?? envelope.initialVolume }
        let progress = (time - ramp.start).seconds / ramp.duration.seconds
        return ramp.from + (ramp.to - ramp.from) * Float(progress)
    }

    @Test("Eased gain keyframes play the eased decibel curve, not a straight amplitude line")
    func easedKeyframesAreFollowed() {
        var gain = Animatable<Double>(constant: 0)
        gain.setKeyframe(Keyframe(time: .zero, value: 0))
        gain.setKeyframe(Keyframe(time: RationalTime(seconds: 2), value: -40, easing: .smoothstep))
        let track = Track(
            id: TrackID(rawValue: "a1"),
            name: "A1",
            items: [item("clip", start: 0, duration: 4)],
            gainAnimation: gain
        )
        let envelope = AudioGainEnvelope(track: track, audible: true)

        for seconds in [0.3, 0.5, 1.0, 1.5] {
            let expected = Float(pow(10, gain.value(at: RationalTime(seconds: seconds)) / 20))
            #expect(abs(volume(envelope, at: seconds) - expected) < 0.02, "at \(seconds) s")
        }
    }

    @Test("Ramps are contiguous and never overlap")
    func rampsAreContiguous() {
        let track = Track(
            id: TrackID(rawValue: "a1"),
            name: "A1",
            items: [
                item(
                    "a", start: 0, duration: 2,
                    fade: FadeEnvelope(fadeOut: RationalTime(seconds: 0.5))),
                item(
                    "b", start: 2, duration: 2,
                    fade: FadeEnvelope(fadeIn: RationalTime(seconds: 0.5))),
            ],
            gain: -6
        )
        let ramps = AudioGainEnvelope(track: track, audible: true).ramps
        for (left, right) in zip(ramps, ramps.dropFirst()) {
            #expect(left.start + left.duration == right.start)
        }
    }

    @Test("A fade-out reaches silence at the cut and the next clip fades in from it")
    func fadesMeetAtTheCut() {
        let track = Track(
            id: TrackID(rawValue: "a1"),
            name: "A1",
            items: [
                item(
                    "a", start: 0, duration: 2,
                    fade: FadeEnvelope(fadeOut: RationalTime(seconds: 0.5))),
                item(
                    "b", start: 2, duration: 2,
                    fade: FadeEnvelope(fadeIn: RationalTime(seconds: 0.5))),
            ]
        )
        let envelope = AudioGainEnvelope(track: track, audible: true)
        let cut = RationalTime(seconds: 2)
        #expect(envelope.ramps.first { $0.start + $0.duration == cut }?.to == 0)
        #expect(envelope.ramps.first { $0.start == cut }?.from == 0)
        #expect(abs(volume(envelope, at: 1.0) - 1) < 0.001)
        #expect(abs(volume(envelope, at: 3.0) - 1) < 0.001)
    }

    @Test("A muted track is silent with no ramps")
    func mutedIsSilent() {
        let track = Track(
            id: TrackID(rawValue: "a1"), name: "A1", items: [item("a", start: 0, duration: 2)])
        let envelope = AudioGainEnvelope(track: track, audible: false)
        #expect(envelope.initialVolume == 0)
        #expect(envelope.ramps.isEmpty)
    }
}
