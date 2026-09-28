import XCTest
import Foundation
#if canImport(Vitals)
@testable import Vitals
#else
@testable import VitalsCore
#endif

private let us = Locale(identifier: "en_US")
private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func working(_ reps: Int, _ kilograms: Double, done: Bool = true) -> SetEntry {
    SetEntry(kind: .working, reps: reps, loadKilograms: kilograms, completed: done, completedAt: done ? start : nil)
}
private func warmup(_ reps: Int, _ kilograms: Double) -> SetEntry {
    SetEntry(kind: .warmup, reps: reps, loadKilograms: kilograms, completed: true, completedAt: start)
}

final class UnitTests: XCTestCase {
    func testPoundsRoundTripThroughKilogramStorage() {
        let stored = WeightUnit.pounds.kilograms(fromDisplayed: 135)
        XCTAssertEqual(stored, 61.234_969_95, accuracy: 0.000_001)
        XCTAssertEqual(LoadText.number(stored, unit: .pounds, locale: us), "135")
        XCTAssertEqual(LoadText.number(stored, unit: .kilograms, locale: us), "61.23")
        XCTAssertEqual(LoadText.number(100, unit: .kilograms, locale: us), "100")
        XCTAssertEqual(LoadText.number(WeightUnit.kilograms.kilograms(fromDisplayed: 101.25), unit: .kilograms, locale: us), "101.25")
    }

    func testParsingRejectsUnusableInput() {
        XCTAssertEqual(NumberText.parseDecimal(" 2.5 "), 2.5)
        XCTAssertEqual(NumberText.parseDecimal("61,5"), 61.5)
        XCTAssertNil(NumberText.parseDecimal(""))
        XCTAssertNil(NumberText.parseDecimal("-5"))
        XCTAssertNil(NumberText.parseDecimal("abc"))
        XCTAssertNil(NumberText.parseDecimal("1e999"))
        XCTAssertEqual(NumberText.parseReps("8"), 8)
        XCTAssertEqual(NumberText.parseReps("0"), 0)
        XCTAssertNil(NumberText.parseReps("5.5"))
        XCTAssertNil(NumberText.parseReps("1000"))
        XCTAssertNil(NumberText.parseReps("-1"))
        XCTAssertEqual(NumberText.parseLoad("135", unit: .pounds)!, 61.234_97, accuracy: 0.000_01)
        XCTAssertNil(NumberText.parseLoad("2300", unit: .pounds))
        XCTAssertEqual(NumberText.parseLoad("0", unit: .kilograms), 0)
    }

    func testLoadTextNeverCallsBodyweightZero() {
        XCTAssertEqual(LoadText.load(0, unit: .pounds, isBodyweight: false, locale: us), "bw")
        XCTAssertEqual(LoadText.load(0, unit: .kilograms, isBodyweight: true, locale: us), "bw")
        let twentyPounds = WeightUnit.pounds.kilograms(fromDisplayed: 20)
        XCTAssertEqual(LoadText.load(twentyPounds, unit: .pounds, isBodyweight: true, locale: us), "bw + 20 lb")
        XCTAssertEqual(LoadText.load(60, unit: .kilograms, isBodyweight: false, locale: us), "60 kg")
        XCTAssertEqual(LoadText.set(reps: 12, kilograms: 0, unit: .pounds, isBodyweight: true, locale: us), "bw × 12")
        XCTAssertEqual(LoadText.set(reps: 5, kilograms: 100, unit: .kilograms, isBodyweight: false, locale: us), "100 × 5")
        XCTAssertEqual(LoadText.volume(WeightUnit.pounds.kilograms(fromDisplayed: 12_340), unit: .pounds, locale: us), "12,340 lb")
    }
}

final class ClockTests: XCTestCase {
    func testDurationText() {
        XCTAssertEqual(ClockText.duration(7.9), "0:07")
        XCTAssertEqual(ClockText.duration(754), "12:34")
        XCTAssertEqual(ClockText.duration(3_723), "1:02:03")
        XCTAssertEqual(ClockText.duration(-5), "0:00")
        XCTAssertEqual(ClockText.summary(45), "45 s")
        XCTAssertEqual(ClockText.summary(43 * 60 + 20), "43 min")
        XCTAssertEqual(ClockText.summary(3_600 + 5 * 60), "1 h 5 min")
        XCTAssertEqual(ClockText.ago(start, now: start.addingTimeInterval(1)), "now")
        XCTAssertEqual(ClockText.ago(start, now: start.addingTimeInterval(12)), "12 s ago")
        XCTAssertEqual(ClockText.ago(start, now: start.addingTimeInterval(190)), "3 min ago")
    }

    func testRestTimerIsDerivedFromTimestamps() {
        let timer = RestTimer(startedAt: start, target: 120)
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(45)), 75)
        XCTAssertFalse(timer.isOver(at: start.addingTimeInterval(119)))
        XCTAssertTrue(timer.isOver(at: start.addingTimeInterval(120)))
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(500)), 0)
        XCTAssertEqual(timer.elapsed(at: start.addingTimeInterval(500)), 500)
        // A relaunch rebuilds the timer from the stored start and target and lands on the same values.
        let restored = RestTimer(startedAt: timer.startedAt, target: timer.target)
        XCTAssertEqual(restored.remaining(at: start.addingTimeInterval(80)), timer.remaining(at: start.addingTimeInterval(80)))
        XCTAssertEqual(timer.extended().remaining(at: start.addingTimeInterval(45)), 105)
        XCTAssertEqual(RestTimer.clampedTarget(5), 15)
        XCTAssertEqual(RestTimer.clampedTarget(9_999), 600)
    }
}

final class TrainingTests: XCTestCase {
    func testEpleyEstimateLimits() {
        XCTAssertEqual(TrainingMath.estimatedOneRepMax(reps: 5, loadKilograms: 100)!, 116.666, accuracy: 0.001)
        XCTAssertEqual(TrainingMath.estimatedOneRepMax(reps: 1, loadKilograms: 100), 100)
        XCTAssertEqual(TrainingMath.estimatedOneRepMax(reps: 10, loadKilograms: 60)!, 80, accuracy: 0.001)
        XCTAssertNil(TrainingMath.estimatedOneRepMax(reps: 11, loadKilograms: 60))
        XCTAssertNil(TrainingMath.estimatedOneRepMax(reps: 0, loadKilograms: 60))
        XCTAssertNil(TrainingMath.estimatedOneRepMax(reps: 5, loadKilograms: 0))
    }

    func testVolumeCountsCompletedWorkingSetsOnly() {
        let sets = [warmup(5, 40), working(5, 100), working(5, 100), working(5, 110, done: false), working(12, 0)]
        XCTAssertEqual(TrainingMath.volumeKilograms(sets), 1_000)
        XCTAssertEqual(TrainingMath.volumeKilograms([SetEntry]()), 0)
    }

    func testBestsIgnoreWarmupsIncompleteZeroRepAndBodyweight() {
        let heavy = working(3, 120)
        let bests = ExerciseBests.of([warmup(1, 200), working(1, 250, done: false), working(0, 300), heavy, working(3, 120)], isBodyweight: false)
        XCTAssertEqual(bests.heaviestLoad, 120)
        XCTAssertEqual(bests.heaviestLoadSetID, heavy.id, "a tie keeps the first set")
        XCTAssertEqual(ExerciseBests.of([working(10, 20)], isBodyweight: true), .none)
        XCTAssertEqual(ExerciseBests.of([working(10, 0)], isBodyweight: false), .none)
    }

    func testFirstSessionIsABaselineNotARecord() {
        XCTAssertTrue(PersonalRecords.hits(in: [working(5, 100)], isBodyweight: false, prior: .none).isEmpty)
    }

    func testRecordsCompareWithEarlierSessionsOnly() {
        let prior = ExerciseBests.of([working(5, 100)], isBodyweight: false)
        let heavier = working(3, 105)
        let hits = PersonalRecords.hits(in: [working(5, 100), heavier], isBodyweight: false, prior: prior)
        XCTAssertEqual(hits.map(\.kind), [.heaviestLoad])
        XCTAssertEqual(hits.first?.previous, 100)
        XCTAssertEqual(hits.first?.value, 105)
        XCTAssertEqual(hits.first?.setID, heavier.id)
        // More reps at the same load beats the estimate without a heavier load.
        let moreReps = working(8, 100)
        XCTAssertEqual(PersonalRecords.hits(in: [moreReps], isBodyweight: false, prior: prior).map(\.kind), [.estimatedOneRepMax])
        XCTAssertTrue(PersonalRecords.hits(in: [working(5, 100)], isBodyweight: false, prior: prior).isEmpty, "a tie is not a record")
        XCTAssertTrue(PersonalRecords.hits(in: [warmup(1, 140)], isBodyweight: false, prior: prior).isEmpty)
        XCTAssertTrue(PersonalRecords.hits(in: [working(1, 140, done: false)], isBodyweight: false, prior: prior).isEmpty)
        XCTAssertTrue(PersonalRecords.hits(in: [working(5, 140)], isBodyweight: true, prior: prior).isEmpty)
    }

    func testEditingOrDeletingTheRecordSetRemovesTheRecord() {
        let prior = ExerciseBests.of([working(5, 100)], isBodyweight: false)
        var sets = [working(5, 100), working(5, 110)]
        XCTAssertEqual(PersonalRecords.hits(in: sets, isBodyweight: false, prior: prior).count, 2)
        sets[1].loadKilograms = 95
        XCTAssertTrue(PersonalRecords.hits(in: sets, isBodyweight: false, prior: prior).isEmpty)
        sets[1].loadKilograms = 110
        sets.remove(at: 1)
        XCTAssertTrue(PersonalRecords.hits(in: sets, isBodyweight: false, prior: prior).isEmpty)
        XCTAssertEqual(TrainingMath.volumeKilograms(sets), 500)
    }

    func testUnitSwitchingNeverCreatesARecord() {
        let pounds = WeightUnit.pounds.kilograms(fromDisplayed: 225)
        let prior = ExerciseBests.of([working(5, pounds)], isBodyweight: false)
        let reentered = NumberText.parseLoad(LoadText.number(pounds, unit: .pounds, locale: us), unit: .pounds)!
        XCTAssertTrue(PersonalRecords.hits(in: [working(5, reentered)], isBodyweight: false, prior: prior).isEmpty)
    }

    func testExerciseHistoryEvaluatesRecordsChronologically() {
        let id = UUID(), first = UUID(), second = UUID(), third = UUID()
        func entry(_ session: UUID, _ offset: TimeInterval, _ sets: [SetEntry]) -> ExerciseSessionLog {
            ExerciseSessionLog(sessionID: session, startedAt: start.addingTimeInterval(offset),
                               log: ExerciseLog(exerciseID: id, name: "bench press", isBodyweight: false, sets: sets))
        }
        let history = ExerciseHistory.build([
            entry(third, 200, [working(5, 105)]),
            entry(first, 0, [working(5, 100)]),
            entry(second, 100, [working(5, 95)]),
            entry(second, 100, [working(12, 0)]) // the same exercise added twice in one session
        ], isBodyweight: false)
        XCTAssertEqual(history.rows.map(\.sessionID), [third, second, first])
        XCTAssertEqual(history.rows[0].hits.map(\.kind), [.heaviestLoad, .estimatedOneRepMax])
        XCTAssertTrue(history.rows[1].hits.isEmpty)
        XCTAssertTrue(history.rows[2].hits.isEmpty, "the first session is a baseline")
        XCTAssertEqual(history.rows[1].sets.count, 2)
        XCTAssertEqual(history.allTime.heaviestLoad, 105)
        XCTAssertEqual(history.mostBodyweightReps, 12)
    }

    func testPreviousPerformancePairsByKindAndPosition() {
        let previous = [warmup(5, 40), working(5, 100), working(5, 100), working(3, 105, done: false)]
        let current = [SetEntry(kind: .warmup, reps: 5, loadKilograms: 40), working(5, 100, done: false),
                       working(5, 100, done: false), working(5, 100, done: false)]
        let matches = PreviousPerformance.matches(current: current, previous: previous)
        XCTAssertEqual(matches[current[0].id]?.loadKilograms, 40)
        XCTAssertEqual(matches[current[2].id]?.reps, 5)
        XCTAssertNil(matches[current[3].id], "an incomplete previous set isn't shown as performed")
        XCTAssertEqual(PreviousPerformance.summary(previous, unit: .kilograms, isBodyweight: false, locale: us), "100 × 5 · 100 × 5")
        XCTAssertNil(PreviousPerformance.summary([warmup(5, 40)], unit: .kilograms, isBodyweight: false, locale: us))
    }

    func testWorkoutSummary() {
        let bench = UUID(), pullup = UUID()
        let heavier = working(3, 105)
        let exercises = [
            ExerciseLog(exerciseID: bench, name: "bench press", isBodyweight: false, sets: [warmup(5, 40), working(5, 100), heavier]),
            ExerciseLog(exerciseID: pullup, name: "pull-up", isBodyweight: true, sets: [working(10, 0), working(8, 10), working(8, 0, done: false)]),
            ExerciseLog(exerciseID: UUID(), name: "curl", isBodyweight: false, sets: [])
        ]
        let points = (0..<30).map { HeartRatePoint(date: start.addingTimeInterval(Double($0)), bpm: 100 + $0) }
        let summary = WorkoutSummary.build(startedAt: start, endedAt: start.addingTimeInterval(2_700), exercises: exercises,
                                           priorBests: [bench: ExerciseBests.of([working(5, 100)], isBodyweight: false),
                                                        pullup: ExerciseBests.of([working(8, 5)], isBodyweight: false)],
                                           heartRate: points)
        XCTAssertEqual(summary.duration, 2_700)
        XCTAssertEqual(summary.exerciseCount, 2)
        XCTAssertEqual(summary.completedWorkingSets, 4)
        XCTAssertEqual(summary.completedWarmupSets, 1)
        XCTAssertEqual(summary.incompleteSets, 1)
        XCTAssertEqual(summary.volumeKilograms, 500 + 315 + 80, accuracy: 0.001)
        XCTAssertEqual(summary.records.map(\.name), ["bench press"], "bodyweight exercises aren't compared")
        XCTAssertEqual(summary.records.first?.hits.first?.setID, heavier.id)
        XCTAssertEqual(summary.heartRate?.stats.highest, 129)
        XCTAssertEqual(summary.heartRate?.stats.count, 30)
        let empty = WorkoutSummary.build(startedAt: start, endedAt: start, exercises: [], priorBests: [:], heartRate: [])
        XCTAssertFalse(empty.hasCompletedSets)
        XCTAssertNil(empty.heartRate)
    }
}

final class HeartRateTests: XCTestCase {
    func testParsesEightAndSixteenBitValues() {
        XCTAssertEqual(HeartRateMeasurement.parse(Data([0x00, 72])), HeartRateMeasurement(bpm: 72, sensorContact: .unsupported, energyExpendedKilojoules: nil, rrIntervals: []))
        XCTAssertEqual(HeartRateMeasurement.parse(Data([0x01, 0x2C, 0x01]))?.bpm, 300)
        XCTAssertEqual(HeartRateMeasurement.parse(Data([0x06, 64]))?.sensorContact, .detected)
        XCTAssertEqual(HeartRateMeasurement.parse(Data([0x04, 64]))?.sensorContact, .notDetected)
    }

    func testParsesEnergyAndRawRRIntervals() {
        let packet = Data([0x18, 80, 0x10, 0x00, 0x00, 0x04, 0x20, 0x03, 0xFF])
        let parsed = HeartRateMeasurement.parse(packet)
        XCTAssertEqual(parsed?.bpm, 80)
        XCTAssertEqual(parsed?.energyExpendedKilojoules, 16)
        XCTAssertEqual(parsed?.rrIntervals, [1_024, 800], "a trailing odd byte is ignored")
        XCTAssertEqual(RRIntervals.seconds(1_024), 1)
        XCTAssertEqual(RRIntervals.decode(RRIntervals.encode([1_024, 800])), [1_024, 800])
        XCTAssertNil(RRIntervals.encode([]))
        XCTAssertEqual(RRIntervals.decode(nil), [])
    }

    func testRejectsTruncatedPackets() {
        XCTAssertNil(HeartRateMeasurement.parse(Data()))
        XCTAssertNil(HeartRateMeasurement.parse(Data([0x00])))
        XCTAssertNil(HeartRateMeasurement.parse(Data([0x01, 0x40])))
        XCTAssertNil(HeartRateMeasurement.parse(Data([0x08, 70, 0x01])))
        XCTAssertEqual(HeartRateMeasurement.parse(Data([0x10, 70]))?.rrIntervals, [])
        XCTAssertFalse(HeartRateMeasurement.parse(Data([0x00, 0]))!.isPlausible, "0 means no reading")
        // Parsing works on a slice whose indices don't start at zero.
        let slice = Data([0xAA, 0x00, 91]).dropFirst()
        XCTAssertEqual(HeartRateMeasurement.parse(slice)?.bpm, 91)
    }

    func testBatteryLevel() {
        XCTAssertEqual(BatteryLevel.parse(Data([85])), 85)
        XCTAssertNil(BatteryLevel.parse(Data([101])))
        XCTAssertNil(BatteryLevel.parse(Data()))
    }

    func testStatsUseReceivedSamplesOnly() {
        var stats = HeartRateStats()
        XCTAssertNil(stats.average)
        for (offset, bpm) in [(0.0, 100), (1, 120), (2, 110), (40, 90)] {
            stats.add(HeartRatePoint(date: start.addingTimeInterval(offset), bpm: bpm))
        }
        XCTAssertEqual(stats.count, 4)
        XCTAssertEqual(stats.average, 105)
        XCTAssertEqual(stats.lowest, 90)
        XCTAssertEqual(stats.highest, 120)
        XCTAssertEqual(stats.latest?.bpm, 90)
    }

    func testGapsAreShownNotFilled() {
        let points = [0.0, 1, 2, 30, 31, 90].map { HeartRatePoint(date: start.addingTimeInterval($0), bpm: 100) }
        let gaps = HeartRateSeries.gaps(in: points)
        XCTAssertEqual(gaps.map(\.duration), [28, 59])
        let segments = HeartRateSeries.segments(points)
        XCTAssertEqual(segments.map(\.count), [3, 2, 1])
        XCTAssertEqual(HeartRateSummary(points)?.gapDuration, 87)
        XCTAssertNil(HeartRateSummary([]))
    }

    func testThinningKeepsGapsAndBoundsPointCount() {
        let first = (0..<3_600).map { HeartRatePoint(date: start.addingTimeInterval(Double($0)), bpm: 120) }
        let second = (0..<600).map { HeartRatePoint(date: start.addingTimeInterval(4_000 + Double($0)), bpm: 140) }
        let segments = HeartRateSeries.segments(first + second, maxPoints: 200)
        XCTAssertEqual(segments.count, 2)
        XCTAssertLessThanOrEqual(segments.map(\.count).reduce(0, +), 204)
        XCTAssertTrue(segments[0].allSatisfy { $0.bpm == 120 })
        XCTAssertTrue(segments[1].allSatisfy { $0.bpm == 140 })
        XCTAssertLessThan(segments[0].last!.date, segments[1].first!.date)
    }

    func testApproximateZones() {
        XCTAssertEqual(HeartRateZone.estimatedMaximum(age: 30), 190)
        XCTAssertNil(HeartRateZone.zone(bpm: 94, age: 30))
        XCTAssertEqual(HeartRateZone.zone(bpm: 95, age: 30), 1)
        XCTAssertEqual(HeartRateZone.zone(bpm: 114, age: 30), 2)
        XCTAssertEqual(HeartRateZone.zone(bpm: 171, age: 30), 5)
        XCTAssertEqual(HeartRateZone.zone(bpm: 250, age: 30), 5)
        XCTAssertNil(HeartRateZone.zone(bpm: 150, age: nil))
        XCTAssertNil(HeartRateZone.zone(bpm: 150, age: 8))
    }
}

final class SessionCoreTests: XCTestCase {
    func testHealthPayloadKeepsSamplesInsideTheWorkout() {
        let samples = [-5.0, 0, 1, 60, 61].map { HealthWorkoutPayload.Sample(id: UUID(), date: start.addingTimeInterval($0), bpm: 100) }
        let payload = HealthWorkoutPayload(sessionID: UUID(), activity: .strength, start: start, end: start.addingTimeInterval(60),
                                           samples: samples.reversed(), strapName: "helio strap", strapID: UUID())
        XCTAssertEqual(payload.samples.map { $0.date.timeIntervalSince(start) }, [1, 60])
        let backwards = HealthWorkoutPayload(sessionID: UUID(), activity: .other, start: start, end: start.addingTimeInterval(-10),
                                             samples: [], strapName: nil, strapID: nil)
        XCTAssertEqual(backwards.end, start)
    }

    func testSyncIdentifiersAreStableAndDistinct() {
        let id = UUID()
        XCTAssertEqual(HealthSync.workoutIdentifier(session: id), HealthSync.workoutIdentifier(session: id))
        XCTAssertNotEqual(HealthSync.workoutIdentifier(session: id), HealthSync.sampleIdentifier(sample: id))
    }

    func testRecoveryUsesLastKnownActivity() {
        XCTAssertEqual(SessionRecovery.lastActivity(startedAt: start, lastSeenAt: nil, setCompletions: [], lastSample: nil), start)
        let latest = SessionRecovery.lastActivity(startedAt: start, lastSeenAt: start.addingTimeInterval(600),
                                                  setCompletions: [start.addingTimeInterval(900), start.addingTimeInterval(300)],
                                                  lastSample: start.addingTimeInterval(700))
        XCTAssertEqual(latest, start.addingTimeInterval(900))
    }

    func testExportStatesThatAllowRetry() {
        XCTAssertTrue(HealthExportState.failed.canRetry)
        XCTAssertTrue(HealthExportState.notAllowed.canRetry)
        XCTAssertFalse(HealthExportState.saved.canRetry)
        XCTAssertFalse(HealthExportState.saving.canRetry)
        XCTAssertFalse(HealthExportState.unavailable.canRetry)
        XCTAssertTrue(ActivityKind.strength.logsSets)
        XCTAssertFalse(ActivityKind.running.logsSets)
    }
}
