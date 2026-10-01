import Foundation

extension Animatable {
    /// This curve moved onto a new time axis and limited to `0...duration`.
    ///
    /// `map` sends an old keyframe time to the new axis and `unmap` sends a new
    /// time back. Keyframes that land outside the window are dropped, and the
    /// value the old curve had at each edge is pinned there, so what plays
    /// inside the window looks the same as before the edit.
    func retimed(
        duration: RationalTime,
        map: (RationalTime) -> RationalTime,
        unmap: (RationalTime) -> RationalTime
    ) -> Animatable {
        guard !keyframes.isEmpty else { return self }
        var result = Animatable(constant: constant)
        var kept: [Keyframe<Value>] = []
        var droppedBefore = false
        var droppedAfter = false
        for keyframe in keyframes {
            let time = map(keyframe.time)
            if time < .zero {
                droppedBefore = true
            } else if time > duration {
                droppedAfter = true
            } else {
                kept.append(Keyframe(time: time, value: keyframe.value, easing: keyframe.easing))
            }
        }
        if droppedBefore, kept.first?.time != .zero {
            kept.insert(Keyframe(time: .zero, value: value(at: unmap(.zero))), at: 0)
        }
        if droppedAfter, kept.last?.time != duration {
            let easing = keyframes.first { map($0.time) > duration }?.easing ?? .linear
            kept.append(Keyframe(time: duration, value: value(at: unmap(duration)), easing: easing))
        }
        for keyframe in kept { result.setKeyframe(keyframe) }
        return result
    }

    /// This curve shifted earlier by `offset` and limited to `0...duration`.
    func shifted(by offset: RationalTime, within duration: RationalTime) -> Animatable {
        retimed(duration: duration, map: { $0 - offset }, unmap: { $0 + offset })
    }
}
