import XCTest
import Foundation
#if canImport(Vitals)
@testable import Vitals
#else
@testable import MotionCore
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

    func testAllSleepUsesWakeDateAndIncludesNap() throws {
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
        XCTAssertEqual(nights.first?.asleepDuration, 9 * 3_600)
        XCTAssertFalse(try XCTUnwrap(nights.first).hasStages)
    }

    func testEarlyMorningNapAndDaytimeSleepShareOneTimelineAndTotal() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: origin)
        func part(_ start: Int, _ end: Int, _ stage: SleepStage) -> SleepSegment {
            SleepSegment(start: day.addingTimeInterval(Double(start * 60)),
                         end: day.addingTimeInterval(Double(end * 60)), stage: stage)
        }
        // The reported layout: 02:54–04:32 nap; 12:52–15:03 main sleep, both with 1m awake.
        let sessions = SleepSummary.sessions([
            part(174, 230, .deep), part(230, 231, .awake), part(231, 272, .core),
            part(772, 850, .core), part(850, 851, .awake), part(851, 903, .rem)
        ], calendar: calendar)
        let result = SleepSummary.combined(helio: SleepMeasurements(sessions: sessions), health: [])
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(Set(result.sessions.map(\.id)).count, 2, "sessions on one date need separate UI identities")
        XCTAssertEqual(result.days.count, 1)
        let summary = try XCTUnwrap(result.days.first)
        XCTAssertEqual(summary.asleepDuration, 227 * 60)
        XCTAssertEqual(summary.day, day)
        XCTAssertEqual(summary.start, day.addingTimeInterval(174 * 60))
        XCTAssertEqual(summary.end, day.addingTimeInterval(903 * 60))
        XCTAssertEqual(summary.segments.count, 6)
        XCTAssertEqual(summary.duration(.deep), 56 * 60)
        XCTAssertEqual(summary.duration(.core), 119 * 60)
        XCTAssertEqual(summary.duration(.rem), 52 * 60)
        XCTAssertEqual(summary.duration(.awake), 2 * 60)
        XCTAssertEqual(summary.awakeCount, 2)
        XCTAssertNil(summary.stage(at: day.addingTimeInterval(500 * 60)), "the gap between sleep periods stays empty")
        let readings = [(200, 50.0), (230, 90.0), (500, 150.0), (800, 60.0)]
            .map { SleepReading(date: day.addingTimeInterval(Double($0.0 * 60)), value: $0.1) }
        XCTAssertEqual(summary.readings(readings).map(\.value), [50, 90, 60], "charts exclude the gap, but keep measured awakenings")
        XCTAssertEqual(summary.average(readings), 55, "the combined average uses both periods, excluding awake time and gaps")
    }

    func testHealthFillsSeparateNapsOnHelioDateWithoutDuplicatingThem() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: origin)
        func period(_ start: Double, _ end: Double, _ stage: SleepStage) -> SleepNight {
            SleepNight(day: day, segments: [SleepSegment(start: day.addingTimeInterval(start * 3600),
                                                       end: day.addingTimeInterval(end * 3600), stage: stage)])
        }
        let main = period(0, 7, .deep), nap = period(14, 15, .core), secondNap = period(19, 19.5, .asleep)
        let health = SleepMeasurements(sessions: [period(0, 7.1, .asleep), nap, secondNap],
            heartRate: [SleepReading(date: day.addingTimeInterval(14.5 * 3600), value: 62)],
            respiratoryRate: [SleepReading(date: day.addingTimeInterval(14.5 * 3600), value: 13)])
        let before = SleepSummary.combined(helio: SleepMeasurements(sessions: [main]), health: [health, health])
        XCTAssertEqual(before.sessions.count, 3)
        XCTAssertEqual(before.days.count, 1)
        XCTAssertEqual(before.days.first?.asleepDuration, 8.5 * 3600)
        XCTAssertEqual(nap.average(before.heartRate), 62)
        XCTAssertNil(main.average(before.heartRate), "nap readings must not change the main sleep average")
        let after = SleepSummary.combined(helio: SleepMeasurements(sessions: [main, nap],
            heartRate: [SleepReading(date: day.addingTimeInterval(14.5 * 3600), value: 55)]), health: [health])
        XCTAssertEqual(after.sessions.count, 3)
        XCTAssertEqual(after.days.first?.asleepDuration, 8.5 * 3600)
        XCTAssertEqual(nap.average(after.heartRate), 55)
        XCTAssertEqual(nap.average(after.respiratoryRate), 13)
    }

    func testDailyTimelineIsStableAndDuplicateSegmentsDoNotInflateTotals() throws {
        let day = Calendar.current.startOfDay(for: origin)
        let first = SleepNight(day: day, segments: [segment(0, 1, .core)])
        let second = SleepNight(day: day, segments: [segment(6, 7, .core)])
        let forward = try XCTUnwrap(SleepMeasurements(sessions: [first, second, first]).days.first)
        let reversed = try XCTUnwrap(SleepMeasurements(sessions: [second, first]).days.first)
        XCTAssertEqual(forward.segments, reversed.segments)
        XCTAssertEqual(forward.asleepDuration, 2 * 3600)
        XCTAssertEqual(SleepMeasurements(sessions: [first]).days.first?.segments, first.segments)
    }

    func testWeeklySummariesKeepAllSleepOnEachWakeDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: origin)
        let periods = (0..<7).flatMap { offset in
            let wakeDay = calendar.date(byAdding: .day, value: offset, to: day)!
            return [(-1.0, 6.0), (14.0, 15.0)].map { start, end in
                SleepSegment(start: wakeDay.addingTimeInterval(start * 3600),
                             end: wakeDay.addingTimeInterval(end * 3600), stage: .core)
            }
        }
        let days = SleepSummary.nights(periods, calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.map(\.asleepDuration), Array(repeating: 8 * 3600, count: 7))
        XCTAssertEqual(days.reduce(0) { $0 + $1.asleepDuration }, 56 * 3600)
    }

    func testDaylightSavingUsesElapsedDuration() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00-07:00"))
        let end = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T08:00:00-08:00"))
        let night = try XCTUnwrap(SleepSummary.nights([SleepSegment(start: start, end: end, stage: .asleep)], calendar: calendar).first)
        XCTAssertEqual(night.asleepDuration, 9 * 3_600)
        XCTAssertEqual(calendar.component(.day, from: night.day), 1)
        let napStart = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T14:00:00-08:00"))
        let nap = SleepNight(day: night.day, segments: [SleepSegment(start: napStart, end: napStart.addingTimeInterval(3600), stage: .core)])
        let combined = try XCTUnwrap(SleepMeasurements(sessions: [night, nap]).days.first)
        XCTAssertEqual(combined.asleepDuration, 10 * 3600)
        XCTAssertNil(combined.stage(at: end.addingTimeInterval(3600)))
    }

    func testInvalidAndOnlyAwakeRecordsDoNotProduceSleep() {
        XCTAssertTrue(SleepSummary.nights([segment(2, 1, .deep), segment(3, 3, .core), segment(4, 5, .awake)]).isEmpty)
    }

    func testOverlappingStageResolutionIsDeterministic() {
        let input = [segment(0, 4, .asleep), segment(1, 3, .core), segment(2, 3, .deep)]
        XCTAssertEqual(SleepSummary.normalized(input), SleepSummary.normalized(input.reversed()))
    }

    func testHelioNightWinsWithoutSplicingHealthStagesOrDoubleCounting() throws {
        let direct = try XCTUnwrap(SleepSummary.nights([segment(0, 2, .deep), segment(3, 8, .core)]).first)
        let health = SleepNight(day: direct.day, segments: [segment(-1, 9, .rem)])
        let result = SleepSummary.combined(helio: SleepMeasurements(sessions: [direct]),
                                           health: [SleepMeasurements(sessions: [health])])
        XCTAssertEqual(result.days.count, 1)
        XCTAssertEqual(result.days[0].segments, direct.segments)
        XCTAssertEqual(result.days[0].asleepDuration, 7 * 3_600)
        XCTAssertNil(result.days[0].stage(at: origin.addingTimeInterval(2.5 * 3_600)))
    }

    func testHealthFillsMissingDatesAndHelioReplacesFallbackAfterSync() throws {
        let first = try XCTUnwrap(SleepSummary.nights([segment(0, 8, .deep)]).first)
        let second = try XCTUnwrap(SleepSummary.nights([segment(24, 32, .core)]).first)
        let fallback = SleepMeasurements(sessions: [first, second])
        let missing = SleepSummary.combined(helio: SleepMeasurements(sessions: [second]), health: [fallback])
        XCTAssertEqual(missing.days.map(\.day), [first.day, second.day])
        let synced = SleepNight(day: first.day, segments: [segment(1, 7, .rem)])
        let result = SleepSummary.combined(helio: SleepMeasurements(sessions: [synced, second]), health: [fallback])
        XCTAssertEqual(result.days.count, 2)
        XCTAssertEqual(result.days[0].segments, synced.segments)
    }

    func testMetricsPreferHelioIndependentlyWithHealthReadingsWithoutHealthSleep() throws {
        let night = try XCTUnwrap(SleepSummary.nights([segment(0, 8, .core)]).first)
        let at = origin.addingTimeInterval(3_600)
        let direct = SleepMeasurements(sessions: [night], heartRate: [SleepReading(date: at, value: 52)])
        let health = SleepMeasurements(heartRate: [SleepReading(date: at, value: 90)],
                                       respiratoryRate: [SleepReading(date: at, value: 13)])
        let result = SleepSummary.combined(helio: direct, health: [health])
        XCTAssertEqual(night.average(result.heartRate), 52)
        XCTAssertEqual(night.average(result.respiratoryRate), 13)
        XCTAssertEqual(result.heartRate.count, 1)
        let allDirect = SleepMeasurements(sessions: [night], heartRate: direct.heartRate,
                                          respiratoryRate: [SleepReading(date: at, value: 12)])
        XCTAssertEqual(night.average(SleepSummary.combined(helio: allDirect, health: [health]).respiratoryRate), 12)
    }

    func testHealthMetricUsesSleepRecorderBeforeOtherDevices() throws {
        let night = try XCTUnwrap(SleepSummary.nights([segment(0, 8, .core)]).first)
        let at = origin.addingTimeInterval(3_600)
        let other = SleepMeasurements(heartRate: [SleepReading(date: at, value: 95), SleepReading(date: at.addingTimeInterval(60), value: 100)])
        let recorder = SleepMeasurements(sessions: [night], heartRate: [SleepReading(date: at, value: 55)])
        let result = SleepSummary.combined(helio: SleepMeasurements(), health: [other, recorder])
        XCTAssertEqual(night.average(result.heartRate), 55)
        XCTAssertNil(night.average(result.respiratoryRate))
    }

    func testInvalidOrAwakeOnlyDirectReadingsDoNotBlockHealthFallback() throws {
        let night = try XCTUnwrap(SleepSummary.nights([segment(0, 2, .core), segment(2, 3, .awake), segment(3, 8, .deep)]).first)
        let points = [SleepReading(date: origin.addingTimeInterval(3_600), value: .nan),
                      SleepReading(date: origin.addingTimeInterval(4 * 3_600), value: 0),
                      SleepReading(date: origin.addingTimeInterval(2.5 * 3_600), value: 80)]
        let health = SleepMeasurements(heartRate: [SleepReading(date: origin.addingTimeInterval(3_600), value: 56)])
        let result = SleepSummary.combined(helio: SleepMeasurements(sessions: [night], heartRate: points), health: [health])
        XCTAssertEqual(night.average(result.heartRate), 56)
    }

    func testOverlappingNightOnNeighboringDateIsNotCountedAgain() throws {
        let night = try XCTUnwrap(SleepSummary.nights([segment(0, 8, .deep)]).first)
        let duplicate = SleepNight(day: night.day.addingTimeInterval(86_400), segments: [segment(1, 9, .core)])
        let result = SleepSummary.combined(helio: SleepMeasurements(sessions: [night]),
                                           health: [SleepMeasurements(sessions: [duplicate])])
        XCTAssertEqual(result.days.count, 1)
        XCTAssertEqual(result.days[0].day, night.day)
    }

    func testHealthOnlyFallbackChoosesOneRecordingAndEmptyDataStaysEmpty() throws {
        let night = try XCTUnwrap(SleepSummary.nights([segment(0, 8, .deep)]).first)
        let generic = SleepNight(day: night.day, segments: [segment(-1, 9, .asleep)])
        let result = SleepSummary.combined(helio: SleepMeasurements(),
                                           health: [SleepMeasurements(sessions: [generic]), SleepMeasurements(sessions: [night])])
        XCTAssertEqual(result.days.count, 1)
        XCTAssertEqual(result.days[0].segments, night.segments)
        let empty = SleepSummary.combined(helio: SleepMeasurements(), health: [])
        XCTAssertTrue(empty.days.isEmpty)
        XCTAssertTrue(empty.heartRate.isEmpty)
        XCTAssertTrue(empty.respiratoryRate.isEmpty)
    }
}
