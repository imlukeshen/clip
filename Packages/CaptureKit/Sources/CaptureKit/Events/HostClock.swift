import Darwin
import Foundation

enum HostClock {
    static func now() -> UInt64 {
        mach_absolute_time()
    }

    static func seconds(from ticks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        guard end >= start else { return -seconds(from: start - end) }
        return seconds(from: end - start)
    }

    static func ticks(for seconds: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return UInt64(
            (seconds * 1_000_000_000 * Double(info.denom) / Double(info.numer)).rounded()
        )
    }
}
