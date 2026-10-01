import CoreModel
import Foundation

/// The volume curve one audio track plays with: its gain keyframes (in dB,
/// with their easing) multiplied by each clip's fade, as piecewise-linear
/// ramps that `AVAudioMix` can play exactly.
///
/// `AVMutableAudioMixInputParameters` only ramps linearly in amplitude, and
/// overlapping ramps are undefined. Gain, though, is keyed in decibels with
/// eased segments, and fades multiply it. So the curve is sampled: every
/// keyframe, clip edge, and fade boundary is a breakpoint, any segment whose
/// value changes is split into steps of at most 50 ms, and the result is one
/// run of contiguous, non-overlapping ramps.
struct AudioGainEnvelope: Equatable {
    struct Ramp: Equatable {
        var start: RationalTime
        var duration: RationalTime
        var from: Float
        var to: Float
    }

    var initialVolume: Float
    var ramps: [Ramp]

    private static let maximumStep = RationalTime(seconds: 0.05)
    private static let maximumStepsPerSegment = 64

    init(track: Track, audible: Bool) {
        guard audible else {
            initialVolume = 0
            ramps = []
            return
        }
        let items = track.items.filter(\.isEnabled)
        var times: Set<RationalTime> = [.zero]
        for keyframe in track.gain.keyframes where keyframe.time > .zero {
            times.insert(keyframe.time)
        }
        for item in items {
            times.insert(item.timelineStart)
            times.insert(item.timelineEnd)
            let fade = item.audioFade
            if fade.fadeIn > .zero {
                times.insert(min(item.timelineStart + fade.fadeIn, item.timelineEnd))
            }
            if fade.fadeOut > .zero {
                times.insert(max(item.timelineEnd - fade.fadeOut, item.timelineStart))
            }
        }
        let breakpoints = times.sorted()
        func gain(at time: RationalTime, approachingFromLeft: Bool) -> Float {
            Self.gain(of: track, items: items, at: time, approachingFromLeft: approachingFromLeft)
        }

        initialVolume = gain(at: .zero, approachingFromLeft: false)
        var ramps: [Ramp] = []
        for (start, end) in zip(breakpoints, breakpoints.dropFirst()) where end > start {
            let duration = end - start
            let startValue = gain(at: start, approachingFromLeft: false)
            let endValue = gain(at: end, approachingFromLeft: true)
            let middle = start + duration.scaled(by: 0.5)
            let isConstant =
                startValue == endValue
                && gain(at: middle, approachingFromLeft: false) == startValue
            let steps =
                isConstant
                ? 1
                : min(
                    max(Int((duration.seconds / Self.maximumStep.seconds).rounded(.up)), 1),
                    Self.maximumStepsPerSegment
                )
            var stepStart = start
            for step in 1...steps {
                let stepEnd =
                    step == steps
                    ? end : start + duration.scaled(by: Double(step) / Double(steps))
                guard stepEnd > stepStart else { continue }
                ramps.append(
                    Ramp(
                        start: stepStart,
                        duration: stepEnd - stepStart,
                        from: gain(at: stepStart, approachingFromLeft: false),
                        to: gain(at: stepEnd, approachingFromLeft: true)
                    ))
                stepStart = stepEnd
            }
        }
        self.ramps = ramps
    }

    /// Linear amplitude at `time`. At a clip boundary the left limit belongs
    /// to the clip that is ending and the right limit to the one starting, so
    /// a fade-out reaches silence and the next clip's fade-in starts from it.
    private static func gain(
        of track: Track,
        items: [TimelineItem],
        at time: RationalTime,
        approachingFromLeft: Bool
    ) -> Float {
        let decibels = track.gain.value(at: time)
        let item = items.first { item in
            approachingFromLeft
                ? item.timelineStart < time && time <= item.timelineEnd
                : item.timelineStart <= time && time < item.timelineEnd
        }
        let fade =
            item.map {
                $0.audioFade.value(at: time - $0.timelineStart, duration: $0.timelineDuration)
            } ?? 1
        return Float(pow(10, decibels / 20) * fade)
    }
}
