import Foundation
import Testing

@testable import CaptureKit

@Suite("Capture history limit")
struct CaptureHistoryLimitTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func item(
        ageInDays: Double,
        id: UUID = UUID(),
        byteSize: Int64 = 1_024
    ) -> CaptureHistoryItem {
        CaptureHistoryItem(
            id: id,
            fileName: "\(id.uuidString).png",
            displayName: "Screenshot.png",
            kind: .image,
            capturedAt: now.addingTimeInterval(-ageInDays * 24 * 60 * 60),
            byteSize: byteSize
        )
    }

    @Test("Entries inside both bounds are kept, newest first")
    func keepsRecentEntries() {
        let limit = CaptureHistoryLimit(maximumCount: 10, maximumAge: 7 * 24 * 60 * 60)
        let oldest = item(ageInDays: 3)
        let newest = item(ageInDays: 1)
        let result = limit.apply(to: [oldest, newest], now: now)
        #expect(result.kept.map(\.id) == [newest.id, oldest.id])
        #expect(result.expired.isEmpty)
    }

    @Test("Entries past the age bound expire even when there is room")
    func expiresByAge() {
        let limit = CaptureHistoryLimit(maximumCount: 50, maximumAge: 7 * 24 * 60 * 60)
        let fresh = item(ageInDays: 6.9)
        let stale = item(ageInDays: 7.1)
        let result = limit.apply(to: [fresh, stale], now: now)
        #expect(result.kept.map(\.id) == [fresh.id])
        #expect(result.expired.map(\.id) == [stale.id])
    }

    @Test("Entries past the count bound expire even when they are new")
    func expiresByCount() {
        let limit = CaptureHistoryLimit(maximumCount: 2, maximumAge: 7 * 24 * 60 * 60)
        let first = item(ageInDays: 0.1)
        let second = item(ageInDays: 0.2)
        let third = item(ageInDays: 0.3)
        let result = limit.apply(to: [third, first, second], now: now)
        #expect(result.kept.map(\.id) == [first.id, second.id])
        #expect(result.expired.map(\.id) == [third.id])
    }

    /// A clock change should not wipe the history it makes look futuristic.
    @Test("An entry dated in the future is treated as brand new")
    func toleratesFutureDates() {
        let limit = CaptureHistoryLimit(maximumCount: 10, maximumAge: 60)
        let future = item(ageInDays: -5)
        let result = limit.apply(to: [future], now: now)
        #expect(result.kept.map(\.id) == [future.id])
        #expect(result.expired.isEmpty)
    }

    @Test("Newest entries are retained within the aggregate byte budget")
    func expiresByAggregateBytes() {
        let limit = CaptureHistoryLimit(
            maximumCount: 10,
            maximumAge: 60,
            maximumBytes: 2_000
        )
        let newest = item(ageInDays: 0.1, byteSize: 1_200)
        let older = item(ageInDays: 0.2, byteSize: 1_000)
        let result = limit.apply(to: [older, newest], now: now)
        #expect(result.kept.map(\.id) == [newest.id])
        #expect(result.expired.map(\.id) == [older.id])
    }
}
