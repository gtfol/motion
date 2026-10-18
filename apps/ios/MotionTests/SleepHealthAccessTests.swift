import XCTest
import HealthKit
@testable import Vitals

final class SleepHealthAccessTests: XCTestCase {
    private enum Failure: Error { case unavailable }

    @MainActor private final class PendingReads {
        var continuations: [CheckedContinuation<SleepHealthStore.LoadResult, Never>] = []
        func read(_ date: Date) async -> SleepHealthStore.LoadResult {
            await withCheckedContinuation { continuations.append($0) }
        }
        func waitForCount(_ count: Int) async {
            for _ in 0..<1000 where continuations.count < count { await Task.yield() }
            XCTAssertEqual(continuations.count, count)
        }
    }

    private func measurements(on day: Date, hours: Int) -> SleepMeasurements {
        SleepMeasurements(sessions: [SleepNight(day: day, segments: [
            SleepSegment(start: day, end: day.addingTimeInterval(Double(hours * 3600)), stage: .core)
        ])])
    }

    @MainActor func testRefreshRetainsCompleteTotalUntilReplacementIsReady() async {
        let reads = PendingReads(), day = Calendar.current.startOfDay(for: .now)
        let health = SleepHealthStore(reader: reads.read)
        let initial = Task { await health.load(endingOn: day) }
        await reads.waitForCount(1)
        XCTAssertTrue(health.loading)
        XCTAssertNil(health.loadedDay)
        reads.continuations[0].resume(returning: .init(records: [measurements(on: day, hours: 8)]))
        await initial.value
        let refresh = Task { await health.load(endingOn: day) }
        await reads.waitForCount(2)
        XCTAssertTrue(health.loading)
        XCTAssertEqual(health.records.first?.days.first?.asleepDuration, 8 * 3600)
        XCTAssertEqual(health.revision, 1)
        reads.continuations[1].resume(returning: .init(records: [measurements(on: day, hours: 9)]))
        await refresh.value
        XCTAssertFalse(health.loading)
        XCTAssertEqual(health.records.first?.days.first?.asleepDuration, 9 * 3600)
        XCTAssertEqual(health.revision, 2)
    }

    @MainActor func testFailedRefreshKeepsCompleteCachedMeasurements() async {
        let reads = PendingReads(), day = Calendar.current.startOfDay(for: .now)
        let health = SleepHealthStore(reader: reads.read)
        let initial = Task { await health.load(endingOn: day) }
        await reads.waitForCount(1)
        reads.continuations[0].resume(returning: .init(records: [measurements(on: day, hours: 8)]))
        await initial.value
        let refresh = Task { await health.load(endingOn: day) }
        await reads.waitForCount(2)
        reads.continuations[1].resume(returning: .init(message: "Health is temporarily unavailable"))
        await refresh.value
        XCTAssertEqual(health.records.first?.days.first?.asleepDuration, 8 * 3600)
        XCTAssertEqual(health.revision, 1)
        XCTAssertNotNil(health.message)
        XCTAssertFalse(health.loading)
    }

    @MainActor func testCompletedEmptyReadClearsPreviouslyReadableHealthData() async {
        let reads = PendingReads(), day = Calendar.current.startOfDay(for: .now)
        let health = SleepHealthStore(reader: reads.read)
        let initial = Task { await health.load(endingOn: day) }
        await reads.waitForCount(1)
        reads.continuations[0].resume(returning: .init(records: [measurements(on: day, hours: 8)]))
        await initial.value
        let refresh = Task { await health.load(endingOn: day) }
        await reads.waitForCount(2)
        XCTAssertFalse(health.records.isEmpty)
        // Health returns no samples when read access is denied; it does not expose that decision.
        reads.continuations[1].resume(returning: .init())
        await refresh.value
        XCTAssertTrue(health.records.isEmpty)
        XCTAssertEqual(health.loadedDay, day)
        XCTAssertFalse(health.loading)
    }

    @MainActor func testOlderDateRequestCannotReplaceNewerCompletedRead() async {
        let reads = PendingReads(), day = Calendar.current.startOfDay(for: .now)
        let previous = day.addingTimeInterval(-86400)
        let health = SleepHealthStore(reader: reads.read)
        let older = Task { await health.load(endingOn: previous) }
        await reads.waitForCount(1)
        let newer = Task { await health.load(endingOn: day) }
        await reads.waitForCount(2)
        reads.continuations[1].resume(returning: .init(records: [measurements(on: day, hours: 8)]))
        await newer.value
        reads.continuations[0].resume(returning: .init(records: [measurements(on: previous, hours: 6)]))
        await older.value
        XCTAssertEqual(health.loadedDay, day)
        XCTAssertEqual(health.records.first?.days.first?.asleepDuration, 8 * 3600)
        XCTAssertEqual(health.revision, 1)
        XCTAssertFalse(health.loading)
    }

    @MainActor func testFirstRequestThenManageAccessWithoutSecondPrompt() async {
        var requests = 0
        let health = SleepHealthStore(authorization: .init(available: { true },
            status: { requests == 0 ? .shouldRequest : .unnecessary }, request: { requests += 1 }))
        let first = await health.connect()
        XCTAssertEqual(first, .requested)
        let second = await health.connect()
        XCTAssertEqual(second, .manageAccess)
        XCTAssertEqual(requests, 1)
        // Neither completion nor an unnecessary request implies that read access was granted.
        XCTAssertTrue(health.records.isEmpty)
    }

    @MainActor func testUnknownRequestStatusStillAttemptsAuthorization() async {
        var requests = 0
        let health = SleepHealthStore(authorization: .init(available: { true },
            status: { .unknown }, request: { requests += 1 }))
        let result = await health.connect()
        XCTAssertEqual(result, .requested)
        XCTAssertEqual(requests, 1)
    }

    @MainActor func testAuthorizationErrorsReturnFailureInsteadOfSilentSuccess() async {
        for statusFails in [true, false] {
            var requests = 0
            let health = SleepHealthStore(authorization: .init(available: { true }, status: {
                if statusFails { throw Failure.unavailable }
                return .shouldRequest
            }, request: { requests += 1; throw Failure.unavailable }))
            let result = await health.connect()
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(requests, statusFails ? 0 : 1)
        }
    }

    @MainActor func testUnavailableHealthDoesNotTryToRequestAccess() async {
        let health = SleepHealthStore(authorization: .init(available: { false },
            status: { XCTFail("must not check unavailable Health"); return .unknown },
            request: { XCTFail("must not request unavailable Health") }))
        let result = await health.connect()
        XCTAssertEqual(result, .unavailable)
    }
}
