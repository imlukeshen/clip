@preconcurrency import CoreMedia
import CoreModel

extension RationalTime {
    public var cmTime: CMTime {
        CMTime(value: CMTimeValue(value), timescale: timescale)
    }
}

extension CMTime {
    public var rational: RationalTime {
        guard isNumeric, timescale > 0 else { return .zero }
        return RationalTime(value: Int64(value), timescale: timescale)
    }
}

extension TimeRange {
    var cmTimeRange: CMTimeRange {
        CMTimeRange(start: start.cmTime, duration: duration.cmTime)
    }
}
