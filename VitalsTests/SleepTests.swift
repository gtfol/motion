import XCTest
import Foundation
#if canImport(Vitals)
@testable import Vitals
#else
@testable import VitalsCore
#endif

final class SleepTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func segment(_ start: Double, _ end: Double, _ stage: SleepStage) -> SleepSegment {
        SleepSegment(start: origin.addingTimeInterval(start * 3_600), end: origin.addingTimeInterval(end * 3_600), stage: stage)
    }

    func testDuplicateAndGenericRecordsDoNotInflateSleep() throws {
        let input = [segment(0, 8, .asleep), segment(0, 8, .asleep), segment(0, 2, .deep),
                     segment(2, 5, .core), segment(5, 6, .awake), segment(6, 8, .rem)]
        let night = try XCTUnwrap(SleepSummary.nights(input).first)
        XCTAssertEqual(night.asleepDuration, 7 * 3_600)
        XCTAssertEqual(night.duration(.deep), 2 * 3_600)
        XCTAssertEqual(night.duration(.awake), 3_600)
        XCTAssertEqual(night.duration(.asleep), 0)
        XCTAssertEqual(night.awakeCount, 1)
    }

    func testUnrecordedGapsAndAwakeReadingsAreExcludedFromAverage() throws {
        let night = try XCTUnwrap(SleepSummary.nights([
            segment(0, 1, .core), segment(1, 2, .awake), segment(3, 4, .deep)
        ]).first)
        let points = [(0.5, 50.0), (1.5, 100.0), (2.5, 150.0), (3.5, 60.0), (4.0, 200.0)]
            .map { SleepReading(date: origin.addingTimeInterval($0.0 * 3_600), value: $0.1) }
        XCTAssertEqual(night.asleepDuration, 2 * 3_600)
        XCTAssertEqual(try XCTUnwrap(night.average(points)), 55)
        XCTAssertNil(night.stage(at: origin.addingTimeInterval(2.5 * 3_600)))
        XCTAssertNil(night.average([]), "missing data must not become zero")
    }

    func testMainSleepUsesWakeDateAndExcludesSeparateNap() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: origin)
        let input = [
            SleepSegment(start: day.addingTimeInterval(-2 * 3_600), end: day.addingTimeInterval(6 * 3_600), stage: .asleep),
            SleepSegment(start: day.addingTimeInterval(14 * 3_600), end: day.addingTimeInterval(15 * 3_600), stage: .asleep)
        ]
        let nights = SleepSummary.nights(input, calendar: calendar)
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights.first?.day, day)
        XCTAssertEqual(nights.first?.asleepDuration, 8 * 3_600)
        XCTAssertFalse(try XCTUnwrap(nights.first).hasStages)
    }

    func testDaylightSavingUsesElapsedDuration() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00-07:00"))
        let end = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T08:00:00-08:00"))
        let night = try XCTUnwrap(SleepSummary.nights([SleepSegment(start: start, end: end, stage: .asleep)], calendar: calendar).first)
        XCTAssertEqual(night.asleepDuration, 9 * 3_600)
        XCTAssertEqual(calendar.component(.day, from: night.day), 1)
    }

    func testInvalidAndOnlyAwakeRecordsDoNotProduceSleep() {
        XCTAssertTrue(SleepSummary.nights([segment(2, 1, .deep), segment(3, 3, .core), segment(4, 5, .awake)]).isEmpty)
    }

    func testOverlappingStageResolutionIsDeterministic() {
        let input = [segment(0, 4, .asleep), segment(1, 3, .core), segment(2, 3, .deep)]
        XCTAssertEqual(SleepSummary.normalized(input), SleepSummary.normalized(input.reversed()))
    }
}
